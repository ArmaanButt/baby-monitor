@preconcurrency import AVFoundation
import CoreAudio
import Combine
import Foundation

@MainActor
final class RoomAudioCaptureController: ObservableObject {
    @Published private(set) var state: RoomAudioCaptureState = .idle
    @Published private(set) var diagnostics = RoomAudioCaptureDiagnostics()

    private nonisolated let engine: RoomAudioCaptureEngine

    init() {
        let engine = RoomAudioCaptureEngine()
        self.engine = engine
        engine.eventHandler = { [weak self] event in
            DispatchQueue.main.async {
                guard let self else { return }
                switch event {
                case .state(let state):
                    self.state = state
                case .diagnostics(let diagnostics):
                    self.diagnostics = diagnostics
                }
            }
        }
    }

    func start() {
        state = .starting
        diagnostics = RoomAudioCaptureDiagnostics()
        engine.start()
    }

    func stop() {
        engine.stop()
    }

    func setOutputHandler(
        _ handler: (@Sendable (AudioWireFrame) -> Void)?
    ) {
        engine.setOutputHandler(handler)
    }
}

private nonisolated final class RoomAudioCaptureEngine: @unchecked Sendable {
    enum Event {
        case state(RoomAudioCaptureState)
        case diagnostics(RoomAudioCaptureDiagnostics)
    }

    var eventHandler: (@Sendable (Event) -> Void)?

    private let queue = DispatchQueue(
        label: "com.armaanbutt.BabyMonitor.audio.capture",
        qos: .userInitiated
    )
    private let packetCapacity = DispatchSemaphore(value: 4)
    private let audioEngine = AVAudioEngine()
    private let audioSession = AVAudioSession.sharedInstance()

    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var outputHandler: (@Sendable (AudioWireFrame) -> Void)?
    private var observerTokens: [NSObjectProtocol] = []
    private var diagnostics = RoomAudioCaptureDiagnostics()
    private var sequenceNumber: UInt64 = 0
    private var isStarted = false
    private var hasInstalledTap = false

    init() {
        observeAudioSession()
    }

    deinit {
        observerTokens.forEach(NotificationCenter.default.removeObserver)
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopLocked(deactivateSession: false, emitIdle: false)
            self.diagnostics = RoomAudioCaptureDiagnostics()
            self.sequenceNumber = 0

            do {
                try self.audioSession.setCategory(
                    .record,
                    mode: .measurement,
                    options: []
                )
                try self.audioSession.setPreferredSampleRate(
                    Double(AudioWireFrame.sampleRate)
                )
                try self.audioSession.setActive(true)

                let inputNode = self.audioEngine.inputNode
                let inputFormat = inputNode.outputFormat(forBus: 0)
                guard
                    inputFormat.sampleRate > 0,
                    inputFormat.channelCount > 0,
                    let targetFormat = AVAudioFormat(
                        commonFormat: .pcmFormatInt16,
                        sampleRate: Double(AudioWireFrame.sampleRate),
                        channels: AVAudioChannelCount(
                            AudioWireFrame.channelCount
                        ),
                        interleaved: false
                    ),
                    let converter = AVAudioConverter(
                        from: inputFormat,
                        to: targetFormat
                    )
                else {
                    throw RoomAudioCaptureError.unsupportedInputFormat
                }

                self.targetFormat = targetFormat
                self.converter = converter
                inputNode.installTap(
                    onBus: 0,
                    bufferSize: 1_024,
                    format: inputFormat
                ) { [weak self] buffer, time in
                    self?.capture(buffer: buffer, time: time)
                }
                self.hasInstalledTap = true
                self.audioEngine.prepare()
                try self.audioEngine.start()
                self.isStarted = true
                self.emit(
                    .state(.running(route: self.currentInputRoute()))
                )
            } catch {
                self.stopLocked(deactivateSession: true, emitIdle: false)
                self.emit(.state(.failed(error.localizedDescription)))
            }
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.stopLocked(deactivateSession: true, emitIdle: true)
        }
    }

    func setOutputHandler(
        _ handler: (@Sendable (AudioWireFrame) -> Void)?
    ) {
        queue.async { [weak self] in
            self?.outputHandler = handler
        }
    }

    private func capture(buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        guard packetCapacity.wait(timeout: .now()) == .success else {
            queue.async { [weak self] in
                guard let self else { return }
                self.diagnostics.droppedPacketCount += 1
                self.emit(.diagnostics(self.diagnostics))
            }
            return
        }

        guard let copiedBuffer = Self.copy(buffer) else {
            packetCapacity.signal()
            return
        }
        let sendableBuffer = SendableAudioBuffer(copiedBuffer)
        let timestamp = time.hostTime > 0
            ? Int64(
                (
                    AVAudioTime.seconds(forHostTime: time.hostTime)
                        * 1_000_000
                ).rounded()
            )
            : 0

        queue.async { [weak self] in
            guard let self else { return }
            self.diagnostics.pendingPacketCount += 1
            defer {
                self.packetCapacity.signal()
                self.diagnostics.pendingPacketCount = max(
                    0,
                    self.diagnostics.pendingPacketCount - 1
                )
                self.emit(.diagnostics(self.diagnostics))
            }

            guard
                self.isStarted,
                let converter = self.converter,
                let targetFormat = self.targetFormat
            else {
                return
            }

            do {
                let frame = try self.convert(
                    sendableBuffer.value,
                    presentationTimeMicroseconds: timestamp,
                    converter: converter,
                    targetFormat: targetFormat
                )
                self.diagnostics.capturedPacketCount += 1
                self.outputHandler?(frame)
            } catch {
                self.diagnostics.droppedPacketCount += 1
            }
        }
    }

    private func convert(
        _ input: AVAudioPCMBuffer,
        presentationTimeMicroseconds: Int64,
        converter: AVAudioConverter,
        targetFormat: AVAudioFormat
    ) throws -> AudioWireFrame {
        let ratio = targetFormat.sampleRate / input.format.sampleRate
        let outputCapacity = AVAudioFrameCount(
            ceil(Double(input.frameLength) * ratio) + 8
        )
        guard
            let output = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: outputCapacity
            )
        else {
            throw RoomAudioCaptureError.cannotAllocateOutput
        }

        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(
            to: output,
            error: &conversionError
        ) { _, inputStatus in
            if suppliedInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return input
        }

        guard
            conversionError == nil,
            status != .error,
            output.frameLength > 0,
            let samples = output.int16ChannelData?.pointee
        else {
            throw conversionError ?? RoomAudioCaptureError.conversionFailed
        }

        sequenceNumber &+= 1
        let byteCount = Int(output.frameLength) * MemoryLayout<Int16>.size
        return AudioWireFrame(
            sequenceNumber: sequenceNumber,
            presentationTimeMicroseconds: presentationTimeMicroseconds,
            frameCount: UInt32(output.frameLength),
            pcmInt16LittleEndian: Data(bytes: samples, count: byteCount)
        )
    }

    private func stopLocked(deactivateSession: Bool, emitIdle: Bool) {
        if hasInstalledTap {
            audioEngine.inputNode.removeTap(onBus: 0)
            hasInstalledTap = false
        }
        audioEngine.stop()
        converter = nil
        targetFormat = nil
        isStarted = false
        diagnostics.pendingPacketCount = 0
        if deactivateSession {
            try? audioSession.setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
        }
        if emitIdle {
            emit(.diagnostics(diagnostics))
            emit(.state(.idle))
        }
    }

    private func observeAudioSession() {
        let center = NotificationCenter.default
        observerTokens.append(
            center.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: audioSession,
                queue: nil
            ) { [weak self] notification in
                self?.queue.async {
                    self?.handleInterruption(notification)
                }
            }
        )
        observerTokens.append(
            center.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: audioSession,
                queue: nil
            ) { [weak self] _ in
                self?.queue.async {
                    guard let self, self.isStarted else { return }
                    self.emit(
                        .state(.running(route: self.currentInputRoute()))
                    )
                }
            }
        )
    }

    private func handleInterruption(_ notification: Notification) {
        guard
            let rawType = notification.userInfo?[
                AVAudioSessionInterruptionTypeKey
            ] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: rawType),
            isStarted
        else {
            return
        }

        switch type {
        case .began:
            audioEngine.pause()
            emit(.state(.interrupted("another app is using audio")))
        case .ended:
            do {
                try audioSession.setActive(true)
                try audioEngine.start()
                emit(.state(.running(route: currentInputRoute())))
            } catch {
                emit(.state(.failed(error.localizedDescription)))
            }
        @unknown default:
            break
        }
    }

    private func currentInputRoute() -> String {
        audioSession.currentRoute.inputs.first?.portName ?? "Built-in microphone"
    }

    private func emit(_ event: Event) {
        eventHandler?(event)
    }

    private static func copy(
        _ buffer: AVAudioPCMBuffer
    ) -> AVAudioPCMBuffer? {
        guard
            let copy = AVAudioPCMBuffer(
                pcmFormat: buffer.format,
                frameCapacity: buffer.frameLength
            )
        else {
            return nil
        }
        copy.frameLength = buffer.frameLength

        let sourceBuffers = UnsafeMutableAudioBufferListPointer(
            buffer.mutableAudioBufferList
        )
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(
            copy.mutableAudioBufferList
        )
        guard sourceBuffers.count == destinationBuffers.count else {
            return nil
        }

        for index in sourceBuffers.indices {
            let source = sourceBuffers[index]
            var destination = destinationBuffers[index]
            guard
                let sourceData = source.mData,
                let destinationData = destination.mData
            else {
                return nil
            }
            let byteCount = Int(source.mDataByteSize)
            memcpy(destinationData, sourceData, byteCount)
            destination.mDataByteSize = source.mDataByteSize
            destinationBuffers[index] = destination
        }
        return copy
    }
}

private nonisolated final class SendableAudioBuffer: @unchecked Sendable {
    let value: AVAudioPCMBuffer

    init(_ value: AVAudioPCMBuffer) {
        self.value = value
    }
}

private nonisolated enum RoomAudioCaptureError: LocalizedError {
    case unsupportedInputFormat
    case cannotAllocateOutput
    case conversionFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedInputFormat:
            return "The microphone format cannot be converted for streaming."
        case .cannotAllocateOutput:
            return "An audio packet buffer could not be allocated."
        case .conversionFailed:
            return "A room-audio packet could not be converted."
        }
    }
}

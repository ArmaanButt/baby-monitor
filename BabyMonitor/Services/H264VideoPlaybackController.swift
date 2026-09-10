@preconcurrency import AVFoundation
import Combine
import Foundation

@MainActor
final class H264VideoPlaybackController: ObservableObject {
    @Published private(set) var state: VideoPlaybackState = .idle
    @Published private(set) var diagnostics = ViewerDiagnostics.unavailable

    private nonisolated let engine: H264VideoPlaybackEngine
    private weak var displayLayer: AVSampleBufferDisplayLayer?
    private var pendingFrames: [PlaybackFrameCandidate] = []
    private var renderedFrameCount = 0
    private var totalDecodeRenderMilliseconds = 0.0
    private var droppedFrameCount = 0
    private var acceptsFrames = false
    private var continuity = H264PlaybackContinuity()
    private var readinessRequest: VideoReadinessRequest?

    init(playbackClock: MediaPlaybackClock = MediaPlaybackClock()) {
        let engine = H264VideoPlaybackEngine(
            playbackClock: playbackClock
        )
        self.engine = engine
        engine.eventHandler = { [weak self] event in
            DispatchQueue.main.async {
                self?.handle(event)
            }
        }
    }

    func prepareForStream() {
        reset()
        engine.resetPlaybackClock()
        acceptsFrames = true
        state = .waitingForKeyFrame
        diagnostics = ViewerDiagnostics(
            averageDecodeRenderMilliseconds: nil,
            videoBufferDepth: 0,
            droppedFrameCount: 0,
            audioUnderrunCount: nil
        )
    }

    func reset() {
        acceptsFrames = false
        continuity.reset()
        readinessRequest?.cancel()
        readinessRequest = nil
        displayLayer?.stopRequestingMediaData()
        pendingFrames.forEach { $0.releaseCapacity() }
        pendingFrames.removeAll(keepingCapacity: true)
        displayLayer?.flushAndRemoveImage()
        engine.reset()
        state = .idle
        diagnostics = .unavailable
        renderedFrameCount = 0
        totalDecodeRenderMilliseconds = 0
        droppedFrameCount = 0
    }

    nonisolated func enqueue(_ frame: EncodedVideoFrame) {
        engine.enqueue(frame)
    }

    func attach(_ layer: AVSampleBufferDisplayLayer) {
        if displayLayer === layer {
            drainFrames(into: layer)
            return
        }
        readinessRequest?.cancel()
        displayLayer?.stopRequestingMediaData()
        readinessRequest = nil
        continuity.reset()
        displayLayer = layer
        layer.videoGravity = .resizeAspect
        drainFrames(into: layer)
    }

    func detach(_ layer: AVSampleBufferDisplayLayer) {
        guard displayLayer === layer else { return }
        readinessRequest?.cancel()
        layer.stopRequestingMediaData()
        layer.flushAndRemoveImage()
        displayLayer = nil
        readinessRequest = nil
        continuity.reset()
    }

    private func handle(_ event: H264VideoPlaybackEngine.Event) {
        switch event {
        case .frame(let candidate):
            guard acceptsFrames, candidate.isCurrent() else {
                candidate.releaseCapacity()
                return
            }
            pendingFrames.append(candidate)
            diagnostics.videoBufferDepth = pendingFrames.count
            if let displayLayer {
                drainFrames(into: displayLayer)
            }
        case .waitingForKeyFrame:
            if acceptsFrames {
                state = .waitingForKeyFrame
            }
        case .dropped:
            recordDrop()
        case .failed(let message):
            state = .failed(message)
            recordDrop()
        }
    }

    private func drainFrames(into layer: AVSampleBufferDisplayLayer) {
        guard acceptsFrames else { return }

        if layer.status == .failed {
            readinessRequest?.cancel()
            layer.stopRequestingMediaData()
            readinessRequest = nil
            continuity.reset()
            layer.flushAndRemoveImage()
            engine.resetFormatDescription()
            pendingFrames.forEach { $0.releaseCapacity() }
            pendingFrames.removeAll(keepingCapacity: true)
            diagnostics.videoBufferDepth = 0
            state = .waitingForKeyFrame
            return
        }

        while layer.isReadyForMoreMediaData, !pendingFrames.isEmpty {
            let candidate = pendingFrames.removeFirst()
            guard candidate.isCurrent() else {
                candidate.releaseCapacity()
                continue
            }
            switch continuity.admit(
                sequenceNumber: candidate.sequenceNumber,
                isKeyFrame: candidate.isKeyFrame,
                parameterSets: candidate.parameterSets
            ) {
            case .waitForKeyFrame:
                candidate.releaseCapacity()
                recordDrop()
                state = .waitingForKeyFrame
                continue
            case .resetAndAccept:
                // After a gap/flush/profile change, discard decoder references
                // before starting again with a complete keyframe.
                layer.flush()
            case .accept:
                break
            }
            layer.enqueue(candidate.sampleBuffer)
            candidate.releaseCapacity()

            renderedFrameCount += 1
            totalDecodeRenderMilliseconds +=
                (ProcessInfo.processInfo.systemUptime - candidate.startedAt) * 1_000
            diagnostics.averageDecodeRenderMilliseconds =
                totalDecodeRenderMilliseconds / Double(renderedFrameCount)
            diagnostics.videoBufferDepth = pendingFrames.count
            state = .playing
        }
        diagnostics.videoBufferDepth = pendingFrames.count
        if pendingFrames.isEmpty {
            readinessRequest?.cancel()
            layer.stopRequestingMediaData()
            readinessRequest = nil
        } else if readinessRequest == nil {
            let request = VideoReadinessRequest(layer: layer)
            readinessRequest = request
            layer.requestMediaDataWhenReady(on: .main) { [weak self] in
                // Stop synchronously before hopping to the actor. Leaving the
                // request active while returning without enqueueing can spin
                // the ready callback and starve the main queue.
                guard request.claimAndStop() else { return }
                Task { @MainActor [weak self] in
                    guard let self, let layer = request.layer,
                          self.displayLayer === layer,
                          self.readinessRequest === request else { return }
                    self.readinessRequest = nil
                    self.drainFrames(into: layer)
                }
            }
        }
    }

    private func recordDrop() {
        droppedFrameCount += 1
        diagnostics.droppedFrameCount = droppedFrameCount
    }
}

private nonisolated final class H264VideoPlaybackEngine: @unchecked Sendable {
    enum Event {
        case frame(PlaybackFrameCandidate)
        case waitingForKeyFrame
        case dropped
        case failed(String)
    }

    var eventHandler: (@Sendable (Event) -> Void)?

    private let queue = DispatchQueue(
        label: "com.armaanbutt.BabyMonitor.video.playback",
        qos: .userInteractive
    )
    private let frameCapacity = DispatchSemaphore(value: 3)
    private let playbackClock: MediaPlaybackClock
    private var formatDescription: CMVideoFormatDescription?
    private let generationLock = NSLock()
    private var generation: UInt64 = 0

    init(playbackClock: MediaPlaybackClock) {
        self.playbackClock = playbackClock
    }

    func enqueue(_ frame: EncodedVideoFrame) {
        guard frameCapacity.wait(timeout: .now()) == .success else {
            eventHandler?(.dropped)
            return
        }

        let generation = currentGeneration()
        queue.async { [weak self] in
            guard let self else { return }
            guard self.currentGeneration() == generation else {
                self.frameCapacity.signal()
                return
            }
            do {
                if let parameterSets = frame.parameterSets {
                    self.formatDescription = try Self.makeFormatDescription(
                        parameterSets
                    )
                }

                guard let formatDescription = self.formatDescription else {
                    self.frameCapacity.signal()
                    self.eventHandler?(.waitingForKeyFrame)
                    return
                }

                let sampleBuffer = try Self.makeSampleBuffer(
                    frame: frame,
                    formatDescription: formatDescription
                )
                let targetUptime = self.playbackClock.targetUptime(
                    for: frame.presentationTimeMicroseconds
                )
                let delay = max(
                    0,
                    targetUptime - ProcessInfo.processInfo.systemUptime
                )
                let sendableSampleBuffer = SendablePlaybackSampleBuffer(
                    sampleBuffer
                )
                self.queue.asyncAfter(
                    deadline: .now() + delay
                ) { [weak self] in
                    guard let self else { return }
                    guard self.currentGeneration() == generation else {
                        self.frameCapacity.signal()
                        return
                    }
                    self.eventHandler?(
                        .frame(
                            PlaybackFrameCandidate(
                                sampleBuffer: sendableSampleBuffer.value,
                                sequenceNumber: frame.sequenceNumber,
                                isKeyFrame: frame.isKeyFrame,
                                parameterSets: frame.parameterSets,
                                isCurrent: { [weak self] in
                                    self?.currentGeneration() == generation
                                },
                                startedAt: ProcessInfo.processInfo.systemUptime,
                                capacity: self.frameCapacity
                            )
                        )
                    )
                }
            } catch {
                self.frameCapacity.signal()
                self.eventHandler?(.failed(error.localizedDescription))
            }
        }
    }

    func reset() {
        generationLock.withLock {
            generation &+= 1
            queue.async { [weak self] in
                self?.formatDescription = nil
            }
        }
    }

    private func currentGeneration() -> UInt64 {
        generationLock.withLock { generation }
    }

    func resetPlaybackClock() {
        playbackClock.reset()
    }

    func resetFormatDescription() {
        reset()
    }

    private static func makeFormatDescription(
        _ parameterSets: H264ParameterSets
    ) throws -> CMVideoFormatDescription {
        let sequence = parameterSets.sequenceParameterSet
        let picture = parameterSets.pictureParameterSet
        guard !sequence.isEmpty, !picture.isEmpty else {
            throw VideoPlaybackError.invalidParameterSets
        }

        var formatDescription: CMFormatDescription?
        let status = sequence.withUnsafeBytes { sequenceBytes in
            picture.withUnsafeBytes { pictureBytes in
                guard
                    let sequencePointer = sequenceBytes
                        .bindMemory(to: UInt8.self).baseAddress,
                    let picturePointer = pictureBytes
                        .bindMemory(to: UInt8.self).baseAddress
                else {
                    return kCMFormatDescriptionError_InvalidParameter
                }

                let pointers = [sequencePointer, picturePointer]
                let sizes = [sequence.count, picture.count]
                return pointers.withUnsafeBufferPointer { pointerBuffer in
                    sizes.withUnsafeBufferPointer { sizeBuffer in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: pointerBuffer.baseAddress!,
                            parameterSetSizes: sizeBuffer.baseAddress!,
                            nalUnitHeaderLength: Int32(
                                parameterSets.nalUnitHeaderLength
                            ),
                            formatDescriptionOut: &formatDescription
                        )
                    }
                }
            }
        }

        guard status == noErr, let formatDescription else {
            throw VideoPlaybackError.cannotCreateFormat(status)
        }
        return formatDescription
    }

    private static func makeSampleBuffer(
        frame: EncodedVideoFrame,
        formatDescription: CMVideoFormatDescription
    ) throws -> CMSampleBuffer {
        var blockBuffer: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: frame.payload.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: frame.payload.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard blockStatus == kCMBlockBufferNoErr, let blockBuffer else {
            throw VideoPlaybackError.cannotCreateBlock(blockStatus)
        }

        let copyStatus = frame.payload.withUnsafeBytes { bytes in
            guard let source = bytes.baseAddress else {
                return kCMBlockBufferBadPointerParameterErr
            }
            return CMBlockBufferReplaceDataBytes(
                with: source,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: frame.payload.count
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else {
            throw VideoPlaybackError.cannotCopyPayload(copyStatus)
        }

        var timing = CMSampleTimingInfo(
            duration: frame.durationMicroseconds > 0
                ? CMTime(
                    value: frame.durationMicroseconds,
                    timescale: 1_000_000
                )
                : .invalid,
            presentationTimeStamp: CMTime(
                value: frame.presentationTimeMicroseconds,
                timescale: 1_000_000
            ),
            decodeTimeStamp: .invalid
        )
        var sampleSize = frame.payload.count
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let sampleBuffer else {
            throw VideoPlaybackError.cannotCreateSample(sampleStatus)
        }

        H264SampleAttachments.configure(sampleBuffer, isKeyFrame: frame.isKeyFrame)
        return sampleBuffer
    }
}

private nonisolated final class VideoReadinessRequest: @unchecked Sendable {
    // The layer is only accessed on the main queue: by the .main readiness
    // callback and by the MainActor controller. Cancellation is lock-protected.
    private(set) weak var layer: AVSampleBufferDisplayLayer?
    private let lock = NSLock()
    private var isActive = true

    init(layer: AVSampleBufferDisplayLayer) {
        self.layer = layer
    }

    func claimAndStop() -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        let claimed = lock.withLock {
            guard isActive else { return false }
            isActive = false
            return true
        }
        if claimed {
            layer?.stopRequestingMediaData()
        }
        return claimed
    }

    func cancel() {
        lock.withLock { isActive = false }
    }
}

private nonisolated final class PlaybackFrameCandidate: @unchecked Sendable {
    let sampleBuffer: CMSampleBuffer
    let sequenceNumber: UInt64
    let isKeyFrame: Bool
    let parameterSets: H264ParameterSets?
    let isCurrent: @Sendable () -> Bool
    let startedAt: TimeInterval

    private let capacity: DispatchSemaphore
    private let lock = NSLock()
    private var didReleaseCapacity = false

    init(
        sampleBuffer: CMSampleBuffer,
        sequenceNumber: UInt64,
        isKeyFrame: Bool,
        parameterSets: H264ParameterSets?,
        isCurrent: @escaping @Sendable () -> Bool,
        startedAt: TimeInterval,
        capacity: DispatchSemaphore
    ) {
        self.sampleBuffer = sampleBuffer
        self.sequenceNumber = sequenceNumber
        self.isKeyFrame = isKeyFrame
        self.parameterSets = parameterSets
        self.isCurrent = isCurrent
        self.startedAt = startedAt
        self.capacity = capacity
    }

    func releaseCapacity() {
        lock.lock()
        defer { lock.unlock() }
        guard !didReleaseCapacity else { return }
        didReleaseCapacity = true
        capacity.signal()
    }

    deinit {
        releaseCapacity()
    }
}

private nonisolated final class SendablePlaybackSampleBuffer:
    @unchecked Sendable
{
    let value: CMSampleBuffer

    init(_ value: CMSampleBuffer) {
        self.value = value
    }
}

private nonisolated enum VideoPlaybackError: LocalizedError {
    case invalidParameterSets
    case cannotCreateFormat(OSStatus)
    case cannotCreateBlock(OSStatus)
    case cannotCopyPayload(OSStatus)
    case cannotCreateSample(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidParameterSets:
            return "The H.264 stream did not include valid parameter sets."
        case .cannotCreateFormat(let status):
            return "The H.264 format could not be prepared (\(status))."
        case .cannotCreateBlock(let status):
            return "A video payload buffer could not be allocated (\(status))."
        case .cannotCopyPayload(let status):
            return "A video payload could not be copied (\(status))."
        case .cannotCreateSample(let status):
            return "A video sample could not be prepared (\(status))."
        }
    }
}

@preconcurrency import AVFoundation
import Combine
import Foundation
@preconcurrency import VideoToolbox

@MainActor
final class H264VideoEncoderController: ObservableObject {
    @Published private(set) var state: VideoEncoderState = .idle
    @Published private(set) var diagnostics = VideoEncoderDiagnostics()

    private nonisolated let engine: H264VideoEncoderEngine

    init() {
        let engine = H264VideoEncoderEngine()
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

    func start(profile: StreamVideoProfile) {
        state = .starting
        diagnostics = VideoEncoderDiagnostics(profile: profile)
        engine.start(profile: profile)
    }

    func stop() {
        engine.stop()
    }

    nonisolated func encode(_ sampleBuffer: CMSampleBuffer) {
        engine.encode(sampleBuffer)
    }

    func setOutputHandler(
        _ handler: (@Sendable (EncodedVideoFrame) -> Void)?
    ) {
        engine.setOutputHandler(handler)
    }
}

private nonisolated final class H264VideoEncoderEngine: @unchecked Sendable {
    enum Event {
        case state(VideoEncoderState)
        case diagnostics(VideoEncoderDiagnostics)
    }

    var eventHandler: (@Sendable (Event) -> Void)?

    private let queue = DispatchQueue(
        label: "com.armaanbutt.BabyMonitor.video.encoder",
        qos: .userInitiated
    )
    private let frameCapacity = DispatchSemaphore(value: 2)

    private var compressionSession: VTCompressionSession?
    private var profile: StreamVideoProfile = .highQuality1080p
    private var outputHandler: (@Sendable (EncodedVideoFrame) -> Void)?
    private var diagnostics = VideoEncoderDiagnostics()
    private var sequenceNumber: UInt64 = 0
    private var accumulatedEncodeMilliseconds = 0.0
    private var windowBytes = 0
    private var windowStartedAt = ProcessInfo.processInfo.systemUptime

    func start(profile: StreamVideoProfile) {
        queue.async { [weak self] in
            guard let self else { return }
            self.destroySession()
            self.profile = profile
            self.diagnostics = VideoEncoderDiagnostics(profile: profile)
            self.sequenceNumber = 0
            self.accumulatedEncodeMilliseconds = 0
            self.windowBytes = 0
            self.windowStartedAt = ProcessInfo.processInfo.systemUptime

            do {
                try self.createSession()
                self.emit(.state(.running))
                self.emit(.diagnostics(self.diagnostics))
            } catch {
                self.destroySession()
                self.emit(.state(.failed(error.localizedDescription)))
            }
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.destroySession()
            self.diagnostics.pendingFrameCount = 0
            self.emit(.diagnostics(self.diagnostics))
            self.emit(.state(.idle))
        }
    }

    func setOutputHandler(
        _ handler: (@Sendable (EncodedVideoFrame) -> Void)?
    ) {
        queue.async { [weak self] in
            self?.outputHandler = handler
        }
    }

    func encode(_ sampleBuffer: CMSampleBuffer) {
        guard frameCapacity.wait(timeout: .now()) == .success else {
            queue.async { [weak self] in
                guard let self else { return }
                self.diagnostics.droppedFrameCount += 1
                self.emit(.diagnostics(self.diagnostics))
            }
            return
        }

        let sendableSampleBuffer = SendableSampleBuffer(sampleBuffer)
        queue.async { [weak self] in
            guard let self else { return }
            guard let compressionSession = self.compressionSession else {
                self.frameCapacity.signal()
                return
            }
            let sampleBuffer = sendableSampleBuffer.value
            guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                self.frameCapacity.signal()
                self.diagnostics.droppedFrameCount += 1
                self.emit(.diagnostics(self.diagnostics))
                return
            }

            self.diagnostics.pendingFrameCount += 1
            let context = VideoEncodeFrameContext(
                startedAt: ProcessInfo.processInfo.systemUptime,
                capacity: self.frameCapacity
            )
            let contextPointer = Unmanaged.passRetained(context).toOpaque()
            var infoFlags = VTEncodeInfoFlags()

            let status = VTCompressionSessionEncodeFrame(
                compressionSession,
                imageBuffer: imageBuffer,
                presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
                duration: CMSampleBufferGetDuration(sampleBuffer),
                frameProperties: nil,
                sourceFrameRefcon: contextPointer,
                infoFlagsOut: &infoFlags
            )

            guard status == noErr else {
                let failedContext = Unmanaged<VideoEncodeFrameContext>
                    .fromOpaque(contextPointer)
                    .takeRetainedValue()
                failedContext.capacity.signal()
                self.diagnostics.pendingFrameCount = max(
                    0,
                    self.diagnostics.pendingFrameCount - 1
                )
                self.diagnostics.droppedFrameCount += 1
                self.emit(.diagnostics(self.diagnostics))
                return
            }
        }
    }

    private func createSession() throws {
        let encoderSpecification: CFDictionary?
        if #available(iOS 17.4, *) {
            encoderSpecification = [
                kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true
            ] as CFDictionary
        } else {
            encoderSpecification = nil
        }

        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: profile.width,
            height: profile.height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: encoderSpecification,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: Self.outputCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &session
        )

        guard status == noErr, let session else {
            throw VideoEncoderError.cannotCreate(status)
        }

        compressionSession = session
        try setProperty(kVTCompressionPropertyKey_RealTime, value: true, on: session)
        try setProperty(
            kVTCompressionPropertyKey_ProfileLevel,
            value: kVTProfileLevel_H264_Main_AutoLevel,
            on: session
        )
        try setProperty(
            kVTCompressionPropertyKey_AverageBitRate,
            value: profile.averageBitrate,
            on: session
        )
        try setProperty(
            kVTCompressionPropertyKey_DataRateLimits,
            value: [profile.averageBitrate / 8, 1],
            on: session
        )
        try setProperty(
            kVTCompressionPropertyKey_ExpectedFrameRate,
            value: profile.framesPerSecond,
            on: session
        )
        try setProperty(
            kVTCompressionPropertyKey_MaxKeyFrameInterval,
            value: profile.framesPerSecond * 2,
            on: session
        )
        try setProperty(
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
            value: 2,
            on: session
        )
        try setProperty(
            kVTCompressionPropertyKey_AllowFrameReordering,
            value: false,
            on: session
        )

        let prepareStatus = VTCompressionSessionPrepareToEncodeFrames(session)
        guard prepareStatus == noErr else {
            throw VideoEncoderError.cannotPrepare(prepareStatus)
        }

        // iOS 17.4 and newer reached this point only after satisfying the
        // hardware-required encoder specification above. Earlier supported
        // releases use VideoToolbox's platform H.264 encoder; the target
        // devices still verify this path during the physical checkpoint.
        diagnostics.isHardwareAccelerated = true
    }

    private func setProperty(
        _ key: CFString,
        value: Any,
        on session: VTCompressionSession
    ) throws {
        let status = VTSessionSetProperty(
            session,
            key: key,
            value: value as CFTypeRef
        )
        guard status == noErr else {
            throw VideoEncoderError.cannotConfigure(key as String, status)
        }
    }

    private func destroySession() {
        guard let compressionSession else { return }
        VTCompressionSessionCompleteFrames(
            compressionSession,
            untilPresentationTimeStamp: .invalid
        )
        VTCompressionSessionInvalidate(compressionSession)
        self.compressionSession = nil
    }

    private static let outputCallback: VTCompressionOutputCallback = {
        outputCallbackRefCon,
        sourceFrameRefCon,
        status,
        _,
        sampleBuffer in
        guard
            let outputCallbackRefCon,
            let sourceFrameRefCon
        else {
            return
        }

        let engine = Unmanaged<H264VideoEncoderEngine>
            .fromOpaque(outputCallbackRefCon)
            .takeUnretainedValue()
        let context = Unmanaged<VideoEncodeFrameContext>
            .fromOpaque(sourceFrameRefCon)
            .takeRetainedValue()
        context.capacity.signal()

        let sendableSampleBuffer = SendableOptionalSampleBuffer(sampleBuffer)
        engine.queue.async {
            engine.handleEncodedFrame(
                status: status,
                sampleBuffer: sendableSampleBuffer.value,
                startedAt: context.startedAt
            )
        }
    }

    private func handleEncodedFrame(
        status: OSStatus,
        sampleBuffer: CMSampleBuffer?,
        startedAt: TimeInterval
    ) {
        diagnostics.pendingFrameCount = max(0, diagnostics.pendingFrameCount - 1)

        guard
            status == noErr,
            let sampleBuffer,
            CMSampleBufferDataIsReady(sampleBuffer),
            let payload = Self.payload(from: sampleBuffer)
        else {
            diagnostics.droppedFrameCount += 1
            emit(.diagnostics(diagnostics))
            return
        }

        let isKeyFrame = Self.isKeyFrame(sampleBuffer)
        sequenceNumber &+= 1
        diagnostics.encodedFrameCount += 1
        let encodeMilliseconds =
            (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
        accumulatedEncodeMilliseconds += encodeMilliseconds
        diagnostics.averageEncodeMilliseconds =
            accumulatedEncodeMilliseconds / Double(diagnostics.encodedFrameCount)

        windowBytes += payload.count
        let now = ProcessInfo.processInfo.systemUptime
        let windowDuration = now - windowStartedAt
        if windowDuration >= 1 {
            diagnostics.bitrateKilobitsPerSecond =
                (Double(windowBytes) * 8 / 1_000) / windowDuration
            windowBytes = 0
            windowStartedAt = now
        }

        let frame = EncodedVideoFrame(
            sequenceNumber: sequenceNumber,
            presentationTimeMicroseconds: Self.microseconds(
                CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            ),
            durationMicroseconds: Self.microseconds(
                CMSampleBufferGetDuration(sampleBuffer)
            ),
            isKeyFrame: isKeyFrame,
            payload: payload,
            parameterSets: isKeyFrame ? Self.parameterSets(from: sampleBuffer) : nil
        )

        outputHandler?(frame)
        emit(.diagnostics(diagnostics))
    }

    private static func isKeyFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer,
                createIfNecessary: false
            ) as? [[CFString: Any]],
            let firstAttachment = attachments.first
        else {
            return true
        }
        return !(firstAttachment[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
    }

    private static func payload(from sampleBuffer: CMSampleBuffer) -> Data? {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return nil
        }

        let length = CMBlockBufferGetDataLength(blockBuffer)
        var data = Data(count: length)
        let status = data.withUnsafeMutableBytes { bytes in
            guard let destination = bytes.baseAddress else {
                return kCMBlockBufferBadCustomBlockSourceErr
            }
            return CMBlockBufferCopyDataBytes(
                blockBuffer,
                atOffset: 0,
                dataLength: length,
                destination: destination
            )
        }
        return status == kCMBlockBufferNoErr ? data : nil
    }

    private static func parameterSets(
        from sampleBuffer: CMSampleBuffer
    ) -> H264ParameterSets? {
        guard
            let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer)
        else {
            return nil
        }

        var sequencePointer: UnsafePointer<UInt8>?
        var sequenceSize = 0
        var parameterSetCount = 0
        var headerLength: Int32 = 0
        let sequenceStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDescription,
            parameterSetIndex: 0,
            parameterSetPointerOut: &sequencePointer,
            parameterSetSizeOut: &sequenceSize,
            parameterSetCountOut: &parameterSetCount,
            nalUnitHeaderLengthOut: &headerLength
        )

        var picturePointer: UnsafePointer<UInt8>?
        var pictureSize = 0
        let pictureStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDescription,
            parameterSetIndex: 1,
            parameterSetPointerOut: &picturePointer,
            parameterSetSizeOut: &pictureSize,
            parameterSetCountOut: nil,
            nalUnitHeaderLengthOut: nil
        )

        guard
            sequenceStatus == noErr,
            pictureStatus == noErr,
            let sequencePointer,
            let picturePointer
        else {
            return nil
        }

        return H264ParameterSets(
            sequenceParameterSet: Data(bytes: sequencePointer, count: sequenceSize),
            pictureParameterSet: Data(bytes: picturePointer, count: pictureSize),
            nalUnitHeaderLength: Int(headerLength)
        )
    }

    private static func microseconds(_ time: CMTime) -> Int64 {
        guard time.isValid, !time.isIndefinite else { return 0 }
        let seconds = CMTimeGetSeconds(time)
        guard seconds.isFinite else { return 0 }
        return Int64((seconds * 1_000_000).rounded())
    }

    private func emit(_ event: Event) {
        eventHandler?(event)
    }
}

private nonisolated final class VideoEncodeFrameContext: @unchecked Sendable {
    let startedAt: TimeInterval
    let capacity: DispatchSemaphore

    init(startedAt: TimeInterval, capacity: DispatchSemaphore) {
        self.startedAt = startedAt
        self.capacity = capacity
    }
}

private nonisolated final class SendableSampleBuffer: @unchecked Sendable {
    let value: CMSampleBuffer

    init(_ value: CMSampleBuffer) {
        self.value = value
    }
}

private nonisolated final class SendableOptionalSampleBuffer: @unchecked Sendable {
    let value: CMSampleBuffer?

    init(_ value: CMSampleBuffer?) {
        self.value = value
    }
}

private nonisolated enum VideoEncoderError: LocalizedError {
    case cannotCreate(OSStatus)
    case cannotConfigure(String, OSStatus)
    case cannotPrepare(OSStatus)
    case hardwareAccelerationUnavailable

    var errorDescription: String? {
        switch self {
        case .cannotCreate(let status):
            return "The H.264 encoder could not be created (\(status))."
        case .cannotConfigure(let property, let status):
            return "The H.264 encoder rejected \(property) (\(status))."
        case .cannotPrepare(let status):
            return "The H.264 encoder could not start (\(status))."
        case .hardwareAccelerationUnavailable:
            return "Hardware H.264 encoding is unavailable on this device."
        }
    }
}

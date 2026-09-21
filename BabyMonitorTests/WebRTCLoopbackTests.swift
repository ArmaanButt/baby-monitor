@preconcurrency import AVFoundation
import CryptoKit
import Foundation
import Testing
@preconcurrency import WebRTC
@testable import BabyMonitor

@Suite(.serialized)
struct WebRTCLoopbackTests {
    @Test func realH264FramesContinueAcrossStopRestartAndStaleSignaling() async throws {
        let pair = WebRTCTestPair()
        pair.start()
        defer { pair.close() }
        try await pair.sendFrames(width: 1920, height: 1080, count: 90)
        #expect(pair.recorder.frameCount > 15, "\(pair.recorder.summary)")
        #expect(pair.recorder.lumaRange > 30)
        #expect(pair.recorder.videoSize == CGSize(width: 1920, height: 1080))
        #expect(pair.recorder.failures.isEmpty)
        #expect(pair.recorder.offers.allSatisfy {
            $0.contains("profile-level-id=640c28") && !$0.contains("VP8")
        })
        let firstStream = try #require(pair.recorder.streamIDs.first)

        pair.monitor.setMonitoring(profile: nil)
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(pair.recorder.state == .waitingForMonitor)
        #expect(!pair.recorder.hasTrack)

        pair.monitor.setMonitoring(profile: .fallback720p)
        // Late setup from a previous channel and stream must have no effect.
        pair.viewer.handle(.signal(channelID: UUID(), WebRTCSignal(kind: .stop, streamID: firstStream)))
        try await pair.sendFrames(width: 1280, height: 720, count: 60)
        pair.viewer.handle(.signal(channelID: pair.viewerChannel,
                                   WebRTCSignal(kind: .stop, streamID: firstStream)))
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(pair.recorder.streamIDs.count == 2)
        #expect(pair.recorder.streamIDs.first != pair.recorder.streamIDs.last)
        #expect(pair.recorder.hasTrack)
        #expect(pair.recorder.state == .live)
        #expect(pair.recorder.videoSize == CGSize(width: 1280, height: 720))
        #expect(pair.recorder.failures.isEmpty)
    }
}

private nonisolated final class WebRTCTestPair: @unchecked Sendable {
    let monitor = WebRTCStreamEngine(enableAudio: false)
    let viewer = WebRTCStreamEngine(enableAudio: false)
    let monitorChannel = UUID()
    let viewerChannel = UUID()
    let recorder = WebRTCTestRecorder()
    private let signaling = DispatchQueue(label: "WebRTCLoopbackTests.signaling")
    private var monitorCipher = WebRTCSignalingCipher()
    private var viewerCipher = WebRTCSignalingCipher()
    private let key = SymmetricKey(size: .bits256)

    init() {
        monitor.signalHandler = { [weak self] signal, _ in
            guard let self else { return }
            self.signaling.async {
                do {
                    let encrypted = try self.monitorCipher.seal(signal, sender: .monitor, key: self.key)
                    let decoded = try self.viewerCipher.open(encrypted, expectedSender: .monitor, key: self.key)
                    self.recorder.record(signal)
                    self.viewer.handle(.signal(channelID: self.viewerChannel, decoded))
                } catch { self.recorder.fail(String(describing: error)) }
            }
        }
        viewer.signalHandler = { [weak self] signal, _ in
            guard let self else { return }
            self.signaling.async {
                do {
                    let encrypted = try self.viewerCipher.seal(signal, sender: .viewer, key: self.key)
                    let decoded = try self.monitorCipher.open(encrypted, expectedSender: .viewer, key: self.key)
                    self.monitor.handle(.signal(channelID: self.monitorChannel, decoded))
                } catch { self.recorder.fail(String(describing: error)) }
            }
        }
        viewer.eventHandler = { [weak recorder] event in recorder?.record(event) }
        monitor.eventHandler = { [weak recorder] event in
            if case .state(.failed(let message)) = event { recorder?.fail(message) }
            if case .diagnostics(let diagnostics) = event { recorder?.recordSender(diagnostics) }
        }
    }

    func start() {
        viewer.handle(.authenticated(id: viewerChannel, role: .viewer))
        monitor.handle(.authenticated(id: monitorChannel, role: .monitor))
        monitor.setMonitoring(profile: .highQuality1080p)
    }

    func close() {
        monitor.handle(.disconnected)
        viewer.handle(.disconnected)
    }

    func sendFrames(width: Int, height: Int, count: Int) async throws {
        for index in 0..<count {
            try Task.checkCancellation()
            let sample = try Self.makeFrame(width: width, height: height, luma: UInt8(40 + (index % 30) * 5))
            monitor.capture(sample)
            try await Task.sleep(nanoseconds: 66_666_667)
        }
    }

    static func makeFrame(width: Int, height: Int, luma: UInt8) throws -> CMSampleBuffer {
        var pixel: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel
        )
        #expect(status == kCVReturnSuccess)
        let pixelBuffer = try #require(pixel)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        for plane in 0..<2 {
            if let address = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane) {
                memset(address, plane == 0 ? Int32(luma) : 128,
                       CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane)
                        * CVPixelBufferGetHeightOfPlane(pixelBuffer, plane))
            }
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        var format: CMVideoFormatDescription?
        #expect(CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &format
        ) == noErr)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 15),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        #expect(CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
            formatDescription: try #require(format), sampleTiming: &timing, sampleBufferOut: &sample
        ) == noErr)
        return try #require(sample)
    }
}

private nonisolated final class WebRTCTestRecorder: NSObject, RTCVideoRenderer, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var minimum = 255
    private var maximum = 0
    private var size: CGSize = .zero
    private var track: RTCVideoTrack?
    private var currentState: WebRTCStreamState = .idle
    private var errors: [String] = []
    private var descriptions: [String] = []
    private var ids: [UUID] = []
    private var senderStats = WebRTCStreamDiagnostics()

    var frameCount: Int { lock.withLock { count } }
    var lumaRange: Int { lock.withLock { maximum - minimum } }
    var videoSize: CGSize { lock.withLock { size } }
    var hasTrack: Bool { lock.withLock { track != nil } }
    var state: WebRTCStreamState { lock.withLock { currentState } }
    var failures: [String] { lock.withLock { errors } }
    var offers: [String] { lock.withLock { descriptions } }
    var streamIDs: [UUID] { lock.withLock { ids } }
    var summary: String { lock.withLock { senderStats.text + "\n" + descriptions.joined(separator: "\n") } }
    func recordSender(_ stats: WebRTCStreamDiagnostics) { lock.withLock { senderStats = stats } }

    func record(_ signal: WebRTCSignal) {
        if signal.kind == .offer {
            lock.withLock { descriptions.append(signal.sdp ?? ""); ids.append(signal.streamID) }
        }
    }

    func fail(_ message: String) { lock.withLock { errors.append(message) } }

    func record(_ event: WebRTCStreamEngine.Event) {
        switch event {
        case .state(let state):
            lock.withLock { currentState = state }
            if case .failed(let message) = state { fail(message) }
        case .track(let newTrack):
            let old = lock.withLock { let old = track; track = newTrack; return old }
            old?.remove(self)
            newTrack?.add(self)
        case .diagnostics: break
        }
    }

    func setSize(_ size: CGSize) {}
    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame else { return }
        let decoded = frame.buffer.toI420()
        let value = withExtendedLifetime(decoded) { Int(decoded.dataY.pointee) }
        lock.withLock {
            count += 1
            minimum = min(minimum, value)
            maximum = max(maximum, value)
            size = CGSize(width: Int(frame.width), height: Int(frame.height))
        }
    }
}

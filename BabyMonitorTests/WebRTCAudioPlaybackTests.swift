@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import Testing
@preconcurrency import WebRTC
@testable import BabyMonitor

@Suite(.serialized)
struct WebRTCAudioPlaybackTests {
    @Test func outputOnlyDevicePullsAudioAndRestartsWithoutRecording() async throws {
        let device = WebRTCPlaybackAudioDevice()
        let delegate = PlaybackTestDelegate()
        let permission = AVAudioSession.sharedInstance().recordPermission
        defer { delegate.dispatchSync { _ = device.terminateDevice() } }
        delegate.dispatchSync {
            #expect(device.initialize(with: delegate))
            #expect(device.initializePlayout())
            #expect(!device.initializeRecording())
            #expect(!device.startRecording())
            #expect(device.startPlayout())
        }
        for _ in 0..<40 where delegate.pullCount == 0 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(delegate.pullCount > 0)
        #expect(delegate.recordCount == 0)
        let before = delegate.pullCount
        delegate.dispatchSync {
            #expect(device.stopPlayout())
            #expect(device.startPlayout())
        }
        for _ in 0..<40 where delegate.pullCount == before {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(delegate.pullCount > before)
        #expect(AVAudioSession.sharedInstance().recordPermission == permission)
        #expect(AVAudioSession.sharedInstance().category == .playback)
    }

    @Test func playbackConversionIsBoundedAndSilencesFailedPulls() {
        let scratch = WebRTCPlaybackScratch()
        var timestamp = AudioTimeStamp()
        var result = [Float](repeating: 0, count: 4)
        result.withUnsafeMutableBytes { bytes in
            var output = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: 16, mData: bytes.baseAddress)
            )
            _ = scratch.render(frameCount: 4, timestamp: &timestamp, output: &output) {
                _, _, _, count, buffers in
                #expect(count == 4)
                let pcm = buffers.pointee.mBuffers.mData!.assumingMemoryBound(to: Int16.self)
                pcm[0] = .min; pcm[1] = -16384; pcm[2] = 0; pcm[3] = 16384
                return noErr
            }
        }
        #expect(result == [-1, -0.5, 0, 0.5])
        result.withUnsafeMutableBytes { bytes in
            var output = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: 16, mData: bytes.baseAddress)
            )
            _ = scratch.render(frameCount: 4, timestamp: &timestamp, output: &output) { _, _, _, _, _ in -1 }
        }
        #expect(result == [0, 0, 0, 0])
    }
}

private nonisolated final class PlaybackTestDelegate: NSObject, RTCAudioDeviceDelegate, @unchecked Sendable {
    let preferredInputSampleRate = 48_000.0
    let preferredInputIOBufferDuration = 0.01
    let preferredOutputSampleRate = 48_000.0
    let preferredOutputIOBufferDuration = 0.01
    private let queue = DispatchQueue(label: "WebRTCAudioPlaybackTests.owner")
    private let lock = NSLock()
    private var pulls = 0
    private var recordings = 0
    var pullCount: Int { lock.withLock { pulls } }
    var recordCount: Int { lock.withLock { recordings } }

    var getPlayoutData: RTCAudioDeviceGetPlayoutDataBlock {
        { [weak self] _, _, _, _, buffers in
            self?.lock.withLock { self?.pulls += 1 }
            for buffer in UnsafeMutableAudioBufferListPointer(buffers) {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }
            return noErr
        }
    }
    var deliverRecordedData: RTCAudioDeviceDeliverRecordedDataBlock {
        { [weak self] _, _, _, _, _, _, _ in
            self?.lock.withLock { self?.recordings += 1 }
            return noErr
        }
    }
    func notifyAudioInputParametersChange() {}
    func notifyAudioOutputParametersChange() {}
    func notifyAudioInputInterrupted() {}
    func notifyAudioOutputInterrupted() {}
    func dispatchAsync(_ block: @escaping () -> Void) { queue.async(execute: DispatchWorkItem(block: block)) }
    func dispatchSync(_ block: () -> Void) { queue.sync(execute: block) }
}

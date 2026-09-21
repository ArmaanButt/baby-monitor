@preconcurrency import AVFoundation
import CoreAudio
import Foundation
@preconcurrency import WebRTC

/// WebRTC's default iOS voice audio unit requires an input route even for a
/// receive-only peer. This output-only adapter keeps the Viewer microphone
/// closed. WebRTC still owns Opus decoding, jitter buffering, and audio timing.
nonisolated final class WebRTCPlaybackAudioDevice: NSObject, RTCAudioDevice, @unchecked Sendable {
    var statusHandler: (@Sendable (String) -> Void)?
    let deviceInputSampleRate = 48_000.0
    let inputIOBufferDuration = 0.01
    let inputNumberOfChannels = 1
    let inputLatency = 0.0
    let deviceOutputSampleRate = 48_000.0
    var outputIOBufferDuration: TimeInterval { AVAudioSession.sharedInstance().ioBufferDuration }
    let outputNumberOfChannels = 1
    var outputLatency: TimeInterval { AVAudioSession.sharedInstance().outputLatency }
    private(set) var isInitialized = false
    private(set) var isPlayoutInitialized = false
    private(set) var isPlaying = false
    let isRecordingInitialized = false
    let isRecording = false

    private let delegateLock = NSLock()
    private weak var audioDelegate: RTCAudioDeviceDelegate?
    private var engine: AVAudioEngine?
    private var observers: [NSObjectProtocol] = []
    private var interrupted = false

    func initialize(with delegate: RTCAudioDeviceDelegate) -> Bool {
        delegateLock.withLock { audioDelegate = delegate }
        isInitialized = true
        for name in [AVAudioSession.interruptionNotification, AVAudioSession.routeChangeNotification,
                     AVAudioSession.mediaServicesWereResetNotification, .AVAudioEngineConfigurationChange] {
            observers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: nil
            ) { [weak self] notification in
                guard let self, let delegate = self.delegateLock.withLock({ self.audioDelegate }) else { return }
                let began = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue
                    == AVAudioSession.InterruptionType.began.rawValue
                delegate.dispatchAsync { [weak self, weak delegate] in
                    guard let self, let delegate, self.isInitialized else { return }
                    if name == .AVAudioEngineConfigurationChange,
                       notification.object as? AVAudioEngine !== self.engine { return }
                    if name == AVAudioSession.interruptionNotification { self.interrupted = began }
                    self.engine?.stop()
                    self.engine = nil
                    delegate.notifyAudioOutputInterrupted()
                    delegate.notifyAudioOutputParametersChange()
                    if self.isPlaying, !self.interrupted { _ = self.startEngine(delegate: delegate) }
                    if self.interrupted { self.statusHandler?("Interrupted") }
                }
            })
        }
        return true
    }

    func terminateDevice() -> Bool {
        _ = stopPlayout()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        delegateLock.withLock { audioDelegate = nil }
        isInitialized = false
        isPlayoutInitialized = false
        return true
    }

    func initializePlayout() -> Bool {
        isPlayoutInitialized = isInitialized
        return isPlayoutInitialized
    }

    func startPlayout() -> Bool {
        guard isInitialized,
              let delegate = delegateLock.withLock({ audioDelegate }) else { return false }
        if engine?.isRunning == true { isPlaying = true; return true }
        isPlaying = startEngine(delegate: delegate)
        return isPlaying
    }

    func stopPlayout() -> Bool {
        isPlaying = false
        engine?.stop()
        engine = nil
        statusHandler?("Stopped")
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return true
    }

    func initializeRecording() -> Bool { false }
    func startRecording() -> Bool { false }
    func stopRecording() -> Bool { true }

    private func startEngine(delegate: RTCAudioDeviceDelegate) -> Bool {
        do {
            let session = AVAudioSession.sharedInstance()
            if session.category != .playback || session.mode != .default {
                try session.setCategory(.playback, mode: .default)
            }
            try session.setPreferredSampleRate(deviceOutputSampleRate)
            try session.setPreferredIOBufferDuration(0.01)
            try session.setActive(true)
            delegate.notifyAudioOutputParametersChange()
            let engine = AVAudioEngine()
            guard let format = AVAudioFormat(
                standardFormatWithSampleRate: deviceOutputSampleRate, channels: 1
            ) else { return false }
            let scratch = WebRTCPlaybackScratch()
            let pull = delegate.getPlayoutData
            let source = AVAudioSourceNode(format: format) { _, timestamp, count, output in
                scratch.render(frameCount: count, timestamp: timestamp, output: output, pull: pull)
            }
            engine.attach(source)
            engine.connect(source, to: engine.mainMixerNode, format: format)
            engine.prepare()
            try engine.start()
            self.engine = engine
            statusHandler?("Playing")
            return true
        } catch {
            engine = nil
            statusHandler?("Unavailable (\((error as NSError).code))")
            return false
        }
    }
}

/// Fixed storage at the audio callback boundary; no queued PCM or allocations.
nonisolated final class WebRTCPlaybackScratch: @unchecked Sendable {
    static let capacity = 4_096
    private let samples = UnsafeMutablePointer<Int16>.allocate(capacity: capacity)

    init() { samples.initialize(repeating: 0, count: Self.capacity) }
    deinit { samples.deinitialize(count: Self.capacity); samples.deallocate() }

    func render(
        frameCount: UInt32, timestamp: UnsafePointer<AudioTimeStamp>,
        output: UnsafeMutablePointer<AudioBufferList>,
        pull: RTCAudioDeviceGetPlayoutDataBlock
    ) -> OSStatus {
        let buffers = UnsafeMutableAudioBufferListPointer(output)
        guard frameCount <= Self.capacity else {
            for buffer in buffers {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }
            return noErr
        }
        var flags = AudioUnitRenderActionFlags()
        var pcm = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: 1, mDataByteSize: frameCount * 2, mData: samples
            )
        )
        let result = pull(&flags, timestamp, 0, frameCount, &pcm)
        for buffer in buffers {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let count = min(Int(frameCount), Int(buffer.mDataByteSize) / MemoryLayout<Float>.size)
            for index in 0..<count {
                data[index] = result == noErr ? Float(samples[index]) / 32_768 : 0
            }
        }
        return noErr
    }
}

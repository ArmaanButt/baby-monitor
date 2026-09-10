@preconcurrency import AVFoundation
import Combine
import Foundation

@MainActor
final class RoomAudioPlaybackController: ObservableObject {
    @Published private(set) var state: RoomAudioPlaybackState = .idle
    @Published private(set) var diagnostics = RoomAudioPlaybackDiagnostics()

    private nonisolated let engine: RoomAudioPlaybackEngine

    init(playbackClock: MediaPlaybackClock = MediaPlaybackClock()) {
        let engine = RoomAudioPlaybackEngine(
            playbackClock: playbackClock
        )
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

    func prepareForStream() {
        state = .starting
        diagnostics = RoomAudioPlaybackDiagnostics()
        engine.start()
    }

    func reset() {
        engine.stop()
        state = .idle
        diagnostics = RoomAudioPlaybackDiagnostics()
    }

    nonisolated func enqueue(_ frame: AudioWireFrame) {
        engine.enqueue(frame)
    }
}

private nonisolated final class RoomAudioPlaybackEngine: @unchecked Sendable {
    enum Event {
        case state(RoomAudioPlaybackState)
        case diagnostics(RoomAudioPlaybackDiagnostics)
    }

    var eventHandler: (@Sendable (Event) -> Void)?

    private let queue = DispatchQueue(
        label: "com.armaanbutt.BabyMonitor.audio.playback",
        qos: .userInteractive
    )
    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let audioSession = AVAudioSession.sharedInstance()
    private let admission = AudioPacketAdmission(limit: 8)
    private let playbackClock: MediaPlaybackClock
    private var playbackPCM: RoomAudioPlaybackPCM?

    private var observerTokens: [NSObjectProtocol] = []
    private var diagnostics = RoomAudioPlaybackDiagnostics()
    private var isPlayerNodeConnected = false
    private var isStarted = false
    private var hasScheduledAudio = false
    private var hasStartedPlayback = false
    private var lastPlaybackCompletion = ProcessInfo.processInfo.systemUptime

    init(playbackClock: MediaPlaybackClock) {
        self.playbackClock = playbackClock
        audioEngine.attach(playerNode)
        observeAudioSession()
    }

    deinit {
        observerTokens.forEach(NotificationCenter.default.removeObserver)
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopLocked(deactivateSession: false, emitIdle: false)
            self.diagnostics = RoomAudioPlaybackDiagnostics()

            do {
                let playbackPCM = try self.playbackPCM ?? RoomAudioPlaybackPCM()
                try self.audioSession.setCategory(
                    .playback,
                    mode: .spokenAudio,
                    options: []
                )
                try self.audioSession.setActive(true)
                if !self.isPlayerNodeConnected {
                    self.audioEngine.connect(
                        self.playerNode,
                        to: self.audioEngine.mainMixerNode,
                        format: playbackPCM.format
                    )
                    self.isPlayerNodeConnected = true
                }
                self.playbackPCM = playbackPCM
                self.audioEngine.prepare()
                try self.audioEngine.start()
                self.isStarted = true
                self.emit(.state(.starting))
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

    func enqueue(_ frame: AudioWireFrame) {
        guard let reservation = admission.reserve() else {
            queue.async { [weak self] in
                guard let self else { return }
                self.diagnostics.droppedPacketCount += 1
                self.emit(.diagnostics(self.diagnostics))
            }
            return
        }

        queue.async { [weak self] in
            guard let self else { return }
            guard
                self.isStarted,
                let playbackPCM = self.playbackPCM,
                self.admission.isCurrent(reservation)
            else {
                _ = self.admission.release(reservation)
                return
            }

            do {
                let buffer = try playbackPCM.makeBuffer(frame)
                if self.hasScheduledAudio,
                   reservation.previousCount == 0,
                   ProcessInfo.processInfo.systemUptime
                       - self.lastPlaybackCompletion > 0.08 {
                    self.diagnostics.underrunCount += 1
                }

                self.diagnostics.scheduledPacketCount += 1
                self.diagnostics.bufferedPacketCount =
                    self.admission.currentCount
                self.emit(.diagnostics(self.diagnostics))
                self.hasScheduledAudio = true

                self.playerNode.scheduleBuffer(
                    buffer,
                    completionCallbackType: .dataPlayedBack
                ) { [weak self] _ in
                    guard let self else { return }
                    self.queue.async {
                        guard let count = self.admission.release(
                            reservation
                        ) else {
                            return
                        }
                        self.lastPlaybackCompletion =
                            ProcessInfo.processInfo.systemUptime
                        self.diagnostics.bufferedPacketCount = count
                        self.emit(.diagnostics(self.diagnostics))
                    }
                }
                if !self.hasStartedPlayback {
                    self.startPlayback(
                        atSourceTime: frame.presentationTimeMicroseconds
                    )
                }
                self.emit(
                    .state(.playing(route: self.currentOutputRoute()))
                )
            } catch {
                _ = self.admission.release(reservation)
                self.diagnostics.droppedPacketCount += 1
                self.diagnostics.bufferedPacketCount =
                    self.admission.currentCount
                self.emit(.diagnostics(self.diagnostics))
            }
        }
    }

    private func startPlayback(atSourceTime sourceTime: Int64) {
        let targetUptime = playbackClock.targetUptime(
            for: sourceTime
        )
        let currentUptime = ProcessInfo.processInfo.systemUptime
        if targetUptime > currentUptime {
            let hostTime = AVAudioTime.hostTime(
                forSeconds: targetUptime
            )
            playerNode.play(at: AVAudioTime(hostTime: hostTime))
        } else {
            playerNode.play()
        }
        hasStartedPlayback = true
    }

    private func stopLocked(deactivateSession: Bool, emitIdle: Bool) {
        playerNode.stop()
        audioEngine.stop()
        admission.reset()
        diagnostics.bufferedPacketCount = 0
        isStarted = false
        hasScheduledAudio = false
        hasStartedPlayback = false
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
                        .state(.playing(route: self.currentOutputRoute()))
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
            playerNode.pause()
            audioEngine.pause()
            emit(.state(.interrupted("another app is using audio")))
        case .ended:
            do {
                try audioSession.setActive(true)
                try audioEngine.start()
                playerNode.play()
                emit(
                    .state(.playing(route: currentOutputRoute()))
                )
            } catch {
                emit(.state(.failed(error.localizedDescription)))
            }
        @unknown default:
            break
        }
    }

    private func currentOutputRoute() -> String {
        let names = audioSession.currentRoute.outputs.map(\.portName)
        return names.isEmpty ? "Built-in speaker" : names.joined(separator: ", ")
    }

    private func emit(_ event: Event) {
        eventHandler?(event)
    }
}

private nonisolated final class AudioPacketAdmission: @unchecked Sendable {
    struct Reservation: Sendable {
        let generation: UInt64
        let previousCount: Int
    }

    private let lock = NSLock()
    private let limit: Int
    private var generation: UInt64 = 0
    private var count = 0

    init(limit: Int) {
        self.limit = limit
    }

    var currentCount: Int {
        lock.withLock { count }
    }

    func reserve() -> Reservation? {
        lock.withLock {
            guard count < limit else { return nil }
            let reservation = Reservation(
                generation: generation,
                previousCount: count
            )
            count += 1
            return reservation
        }
    }

    func isCurrent(_ reservation: Reservation) -> Bool {
        lock.withLock {
            reservation.generation == generation
        }
    }

    @discardableResult
    func release(_ reservation: Reservation) -> Int? {
        lock.withLock {
            guard reservation.generation == generation else {
                return nil
            }
            count = max(0, count - 1)
            return count
        }
    }

    func reset() {
        lock.withLock {
            generation &+= 1
            count = 0
        }
    }
}

import Foundation

nonisolated final class MediaPlaybackClock: @unchecked Sendable {
    static let defaultPlayoutDelay: TimeInterval = 0.15

    private let lock = NSLock()
    private let playoutDelay: TimeInterval
    private let uptime: @Sendable () -> TimeInterval
    private var sourceEpochMicroseconds: Int64?
    private var localEpochUptime: TimeInterval?

    init(
        playoutDelay: TimeInterval = MediaPlaybackClock.defaultPlayoutDelay,
        uptime: @escaping @Sendable () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        }
    ) {
        self.playoutDelay = max(0, playoutDelay)
        self.uptime = uptime
    }

    func reset() {
        lock.withLock {
            sourceEpochMicroseconds = nil
            localEpochUptime = nil
        }
    }

    func targetUptime(
        for sourceTimeMicroseconds: Int64
    ) -> TimeInterval {
        lock.withLock {
            if sourceEpochMicroseconds == nil || localEpochUptime == nil {
                sourceEpochMicroseconds = sourceTimeMicroseconds
                localEpochUptime = uptime() + playoutDelay
            }

            let sourceEpoch = sourceEpochMicroseconds
                ?? sourceTimeMicroseconds
            let localEpoch = localEpochUptime ?? uptime()
            let relativeSeconds = Double(
                sourceTimeMicroseconds - sourceEpoch
            ) / 1_000_000
            return localEpoch + relativeSeconds
        }
    }
}

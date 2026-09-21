import Foundation

/// Three playback slots plus one producer waiting for a slot. The producer
/// must await admission before submitting another frame.
nonisolated final class VideoFrameAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var available: Int
    private var waiting: (@Sendable (Bool) -> Void)?

    init(limit: Int = ViewerDiagnostics.videoBufferLimit) {
        precondition(limit > 0)
        self.limit = limit
        available = limit
    }

    @discardableResult
    func reserve(_ admitted: @escaping @Sendable (Bool) -> Void) -> Bool {
        lock.lock()
        if available > 0 {
            available -= 1
            lock.unlock()
            admitted(true)
            return true
        }
        guard waiting == nil else {
            lock.unlock()
            return false
        }
        waiting = admitted
        lock.unlock()
        return true
    }

    func release() {
        lock.lock()
        let next = waiting
        waiting = nil
        if next == nil {
            precondition(available < limit, "A playback slot can be released only once.")
            available += 1
        }
        lock.unlock()
        next?(true)
    }

    func cancelPending() {
        lock.lock()
        let cancelled = waiting
        waiting = nil
        lock.unlock()
        cancelled?(false)
    }
}

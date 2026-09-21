import Foundation

/// Delivers one received TCP batch without overrunning a media consumer.
/// All state is confined to the connection's serial queue.
nonisolated final class WirePacketDelivery: @unchecked Sendable {
    typealias Handler = @Sendable (
        WirePacket, @escaping @Sendable () -> Void
    ) throws -> Void

    private struct Batch {
        let id = UUID()
        let packets: [WirePacket]
        let handle: Handler
        let completion: @Sendable (Error?) -> Void
        var index = 0
    }

    private let queue: DispatchQueue
    private var batch: Batch?

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    func deliver(
        _ packets: [WirePacket],
        handle: @escaping Handler,
        completion: @escaping @Sendable (Error?) -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(queue))
        precondition(batch == nil, "Receive the next batch only after consumption.")
        batch = Batch(packets: packets, handle: handle, completion: completion)
        deliverNext()
    }

    func cancel() {
        dispatchPrecondition(condition: .onQueue(queue))
        batch = nil
    }

    private func deliverNext() {
        guard let current = batch else { return }
        guard current.index < current.packets.count else {
            batch = nil
            current.completion(nil)
            return
        }

        do {
            try current.handle(current.packets[current.index]) { [weak self] in
                guard let self else { return }
                self.queue.async { [weak self] in
                    guard let self,
                          self.batch?.id == current.id,
                          self.batch?.index == current.index else { return }
                    self.batch?.index += 1
                    self.deliverNext()
                }
            }
        } catch {
            batch = nil
            current.completion(error)
        }
    }
}

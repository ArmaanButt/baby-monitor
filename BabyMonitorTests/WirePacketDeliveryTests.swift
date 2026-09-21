import Foundation
import Testing
@testable import BabyMonitor

struct WirePacketDeliveryTests {
    @Test func coalescedStreamPreservesEveryFrameWithASlowConsumer() throws {
        let queue = DispatchQueue(label: "WirePacketDeliveryTests.burst")
        let delivery = WirePacketDelivery(queue: queue)
        let recorder = DeliveryRecorder()
        let packets = (1...60).map {
            WirePacket(type: $0.isMultiple(of: 4) ? .audio : .video, payload: Data([UInt8($0)]))
        }
        // TCP is allowed to return many complete packets in a single read.
        let bytes = try packets.reduce(into: Data()) {
            $0.append(try WirePacketCodec.encode($1))
        }
        var framer = WirePacketFramer()
        let batch = try framer.append(bytes)
        queue.sync {
            delivery.deliver(batch, handle: { packet, consumed in
                recorder.packets.append(packet)
                recorder.acknowledgements.append(consumed)
            }, completion: { error in
                #expect(error == nil)
                recorder.completionCount += 1
            })
        }

        // Hold each consumption acknowledgement as playback holds a frame for
        // its presentation time. No later packet may overrun that consumer.
        for index in packets.indices {
            queue.sync {
                #expect(recorder.packets == Array(packets.prefix(index + 1)))
                #expect(recorder.acknowledgements.count == 1)
                #expect(recorder.completionCount == 0)
                recorder.acknowledgements.removeFirst()()
            }
        }
        queue.sync {
            #expect(recorder.packets == packets)
            #expect(recorder.completionCount == 1)
        }
    }

    @Test func duplicateAndCancelledAcknowledgementsCannotAdvanceANewStream() {
        let queue = DispatchQueue(label: "WirePacketDeliveryTests.cancel")
        let delivery = WirePacketDelivery(queue: queue)
        let recorder = DeliveryRecorder()
        let packets = (1...3).map { WirePacket(type: .video, payload: Data([UInt8($0)])) }

        queue.sync {
            delivery.deliver(packets, handle: { packet, consumed in
                recorder.packets.append(packet)
                recorder.acknowledgements.append(consumed)
            }, completion: { _ in recorder.completionCount += 1 })
            let acknowledge = recorder.acknowledgements.removeFirst()
            acknowledge()
            acknowledge()
        }
        queue.sync {
            #expect(recorder.packets == Array(packets.prefix(2)))
            let oldAcknowledgement = recorder.acknowledgements.removeFirst()
            delivery.cancel()
            delivery.deliver([packets[2]], handle: { packet, consumed in
                recorder.packets.append(packet)
                recorder.acknowledgements.append(consumed)
            }, completion: { _ in recorder.completionCount += 1 })
            oldAcknowledgement()
        }
        queue.sync {
            #expect(recorder.packets == packets)
            #expect(recorder.completionCount == 0)
            recorder.acknowledgements.removeFirst()()
        }
        queue.sync { #expect(recorder.completionCount == 1) }
    }

    @Test func malformedPacketEndsTheBatchWithoutDeliveringItsTail() {
        let queue = DispatchQueue(label: "WirePacketDeliveryTests.error")
        let delivery = WirePacketDelivery(queue: queue)
        let recorder = DeliveryRecorder()
        let packets = [WirePacket(type: .video, payload: Data([1])),
                       WirePacket(type: .audio, payload: Data([2]))]
        queue.sync {
            delivery.deliver(packets, handle: { packet, consumed in
                recorder.packets.append(packet)
                // A handler can acknowledge via defer and then throw.
                consumed()
                throw WireProtocolError.invalidLength
            }, completion: { error in
                #expect(error as? WireProtocolError == .invalidLength)
                recorder.completionCount += 1
            })
        }
        queue.sync {
            #expect(recorder.packets == [packets[0]])
            #expect(recorder.completionCount == 1)
        }
    }
}

// Accessed only on each test's serial delivery queue.
private nonisolated final class DeliveryRecorder: @unchecked Sendable {
    var packets: [WirePacket] = []
    var acknowledgements: [@Sendable () -> Void] = []
    var completionCount = 0
}

import Foundation
import Testing
@testable import BabyMonitor

struct VideoFrameAdmissionTests {
    @Test func aFullQueueWaitsForCapacityWithoutDroppingTheNextReference() throws {
        let admission = VideoFrameAdmission(limit: 3)
        let recorder = AdmissionRecorder()
        for _ in 0..<3 {
            #expect(admission.reserve { recorder.results.append($0) })
        }
        try #require(admission.reserve { recorder.results.append($0) })
        #expect(recorder.results == [true, true, true])
        // A producer must wait for its fourth frame before submitting more.
        #expect(!admission.reserve { _ in Issue.record("Unbounded admission") })
        admission.release()
        #expect(recorder.results == [true, true, true, true])
        for _ in 0..<3 { admission.release() }
    }

    @Test func cancellingAWaitingFrameDoesNotReleaseAnOccupiedSlot() {
        let admission = VideoFrameAdmission(limit: 1)
        let recorder = AdmissionRecorder()
        #expect(admission.reserve { recorder.results.append($0) })
        #expect(admission.reserve { recorder.results.append($0) })
        admission.cancelPending()
        admission.cancelPending()
        #expect(recorder.results == [true, false])
        #expect(admission.reserve { recorder.results.append($0) })
        #expect(recorder.results == [true, false])
        admission.release()
        #expect(recorder.results == [true, false, true])
        admission.release()
    }

    @Test func tcpBurstRetainsTheWholeH264ReferenceChainWithThreePlaybackSlots() throws {
        let queue = DispatchQueue(label: "VideoFrameAdmissionTests.burst")
        let delivery = WirePacketDelivery(queue: queue)
        let admission = VideoFrameAdmission(limit: 3)
        let recorder = AdmissionRecorder()
        let frames: [EncodedVideoFrame] = (1...60).map { sequence in
            let isKeyFrame = sequence == 1 || sequence == 31
            let parameterSets: H264ParameterSets? = isKeyFrame
                ? H264ParameterSets(sequenceParameterSet: Data([0x67]),
                                    pictureParameterSet: Data([0x68]),
                                    nalUnitHeaderLength: 4) : nil
            return EncodedVideoFrame(
                sequenceNumber: UInt64(sequence),
                presentationTimeMicroseconds: Int64(sequence) * 66_667,
                durationMicroseconds: 66_667,
                isKeyFrame: isKeyFrame,
                payload: Data([1]),
                parameterSets: parameterSets
            )
        }
        let packets = try frames.map {
            WirePacket(type: .video, payload: try VideoWireCodec.encode($0))
        }
        queue.sync {
            delivery.deliver(packets, handle: { packet, consumed in
                let frame = try VideoWireCodec.decode(packet.payload)
                let reserved = admission.reserve { acquired in
                    #expect(acquired)
                    recorder.sequences.append(frame.sequenceNumber)
                    #expect(recorder.continuity.admit(
                        sequenceNumber: frame.sequenceNumber,
                        isKeyFrame: frame.isKeyFrame,
                        parameterSets: frame.parameterSets
                    ) != .waitForKeyFrame)
                    consumed()
                    recorder.admitted.signal()
                }
                #expect(reserved)
            }, completion: { error in
                #expect(error == nil)
                recorder.completionCount += 1
            })
        }
        for _ in 0..<3 {
            #expect(recorder.admitted.wait(timeout: .now() + 2) == .success)
        }
        queue.sync {
            #expect(recorder.sequences == [1, 2, 3])
            #expect(recorder.completionCount == 0)
        }
        // Each presentation frees one slot and admits exactly the next frame.
        for _ in 3..<60 {
            queue.sync { admission.release() }
            #expect(recorder.admitted.wait(timeout: .now() + 2) == .success)
        }
        queue.sync {
            for _ in 0..<3 { admission.release() }
            #expect(recorder.sequences == frames.map(\.sequenceNumber))
            #expect(recorder.completionCount == 1)
        }
    }
}

// Used synchronously by the first tests, or exclusively on the burst test queue.
private nonisolated final class AdmissionRecorder: @unchecked Sendable {
    var results: [Bool] = []
    var sequences: [UInt64] = []
    var continuity = H264PlaybackContinuity()
    var completionCount = 0
    let admitted = DispatchSemaphore(value: 0)
}

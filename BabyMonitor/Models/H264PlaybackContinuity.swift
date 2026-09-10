import Foundation

/// Tracks frames actually submitted to the decoder, after all bounded queues.
nonisolated struct H264PlaybackContinuity {
    enum Decision: Equatable {
        case accept
        case resetAndAccept
        case waitForKeyFrame
    }

    private var lastSequenceNumber: UInt64?
    private var parameterSets: H264ParameterSets?

    mutating func reset() {
        lastSequenceNumber = nil
        parameterSets = nil
    }

    mutating func admit(
        sequenceNumber: UInt64,
        isKeyFrame: Bool,
        parameterSets incomingSets: H264ParameterSets?
    ) -> Decision {
        let isConsecutive = lastSequenceNumber.map { sequenceNumber == $0 &+ 1 } ?? false
        if isKeyFrame,
           let incomingSets,
           !incomingSets.sequenceParameterSet.isEmpty,
           !incomingSets.pictureParameterSet.isEmpty {
            let needsReset = !isConsecutive || parameterSets != incomingSets
            lastSequenceNumber = sequenceNumber
            parameterSets = incomingSets
            return needsReset ? .resetAndAccept : .accept
        }

        guard !isKeyFrame, isConsecutive, parameterSets != nil,
              incomingSets == nil || incomingSets == parameterSets else {
            // P-frames may refer to any earlier reference in the GOP. Skipping
            // one compressed frame invalidates all dependents until an IDR.
            reset()
            return .waitForKeyFrame
        }
        lastSequenceNumber = sequenceNumber
        return .accept
    }
}

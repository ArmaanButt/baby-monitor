import AVFoundation
import Testing
@testable import BabyMonitor

struct H264PlaybackTests {
    private let sets = H264ParameterSets(
        sequenceParameterSet: Data([0x67, 0x64]),
        pictureParameterSet: Data([0x68, 0xeb]),
        nalUnitHeaderLength: 4
    )

    @Test func playbackRequiresACompleteKeyFrameBeforeDependentFrames() {
        var stream = H264PlaybackContinuity()
        #expect(stream.admit(sequenceNumber: 12, isKeyFrame: false,
                             parameterSets: nil) == .waitForKeyFrame)
        #expect(stream.admit(sequenceNumber: 13, isKeyFrame: true,
                             parameterSets: nil) == .waitForKeyFrame)
        #expect(stream.admit(sequenceNumber: 30, isKeyFrame: true,
                             parameterSets: sets) == .resetAndAccept)
        #expect(stream.admit(sequenceNumber: 31, isKeyFrame: false,
                             parameterSets: nil) == .accept)
    }

    @Test func droppedReferenceInvalidatesEveryDependentUntilTheNextKeyFrame() {
        var stream = H264PlaybackContinuity()
        #expect(stream.admit(sequenceNumber: 1, isKeyFrame: true,
                             parameterSets: sets) == .resetAndAccept)
        #expect(stream.admit(sequenceNumber: 2, isKeyFrame: false,
                             parameterSets: nil) == .accept)
        // Frame 3 was dropped by either the transport or playback capacity.
        #expect(stream.admit(sequenceNumber: 4, isKeyFrame: false,
                             parameterSets: nil) == .waitForKeyFrame)
        #expect(stream.admit(sequenceNumber: 5, isKeyFrame: false,
                             parameterSets: nil) == .waitForKeyFrame)
        #expect(stream.admit(sequenceNumber: 30, isKeyFrame: true,
                             parameterSets: sets) == .resetAndAccept)
        #expect(stream.admit(sequenceNumber: 31, isKeyFrame: false,
                             parameterSets: nil) == .accept)
    }

    @Test func reorderedOrDuplicateFramesCannotReuseDecoderReferences() {
        for unexpectedSequence: UInt64 in [1, 0, 10] {
            var stream = H264PlaybackContinuity()
            _ = stream.admit(sequenceNumber: 1, isKeyFrame: true, parameterSets: sets)
            #expect(stream.admit(sequenceNumber: unexpectedSequence, isKeyFrame: false,
                                 parameterSets: nil) == .waitForKeyFrame)
            #expect(stream.admit(sequenceNumber: unexpectedSequence + 1, isKeyFrame: false,
                                 parameterSets: nil) == .waitForKeyFrame)
        }
    }

    @Test func resetAndProfileChangesRequireFreshDecoderReferences() {
        var stream = H264PlaybackContinuity()
        _ = stream.admit(sequenceNumber: 1, isKeyFrame: true, parameterSets: sets)
        #expect(stream.admit(sequenceNumber: 2, isKeyFrame: true,
                             parameterSets: sets) == .accept)
        let changedSets = H264ParameterSets(
            sequenceParameterSet: Data([0x67, 0x42]),
            pictureParameterSet: sets.pictureParameterSet,
            nalUnitHeaderLength: 4
        )
        #expect(stream.admit(sequenceNumber: 3, isKeyFrame: true,
                             parameterSets: changedSets) == .resetAndAccept)
        stream.reset()
        #expect(stream.admit(sequenceNumber: 4, isKeyFrame: false,
                             parameterSets: nil) == .waitForKeyFrame)
        #expect(stream.admit(sequenceNumber: 1, isKeyFrame: true,
                             parameterSets: sets) == .resetAndAccept)
    }

    @Test func videoTimingAndDependencyFlagsArePerSampleAttachments() throws {
        for isKeyFrame in [true, false] {
            let sample = try makeSampleBuffer()
            H264SampleAttachments.configure(sample, isKeyFrame: isKeyFrame)
            let attachments = try #require(
                CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                    as? [[String: Any]]
            )
            let first = try #require(attachments.first)
            #expect(first[kCMSampleAttachmentKey_DisplayImmediately as String] as? Bool == true)
            #expect(first[kCMSampleAttachmentKey_NotSync as String] as? Bool == !isKeyFrame)
            #expect(first[kCMSampleAttachmentKey_DependsOnOthers as String] as? Bool == !isKeyFrame)
            #expect(CMGetAttachment(sample, key: kCMSampleAttachmentKey_DisplayImmediately,
                                    attachmentModeOut: nil) == nil)
        }
    }

    private func makeSampleBuffer() throws -> CMSampleBuffer {
        var image: CVPixelBuffer?
        #expect(CVPixelBufferCreate(kCFAllocatorDefault, 16, 16,
                                    kCVPixelFormatType_32BGRA, nil, &image) == kCVReturnSuccess)
        let pixelBuffer = try #require(image)
        var description: CMVideoFormatDescription?
        #expect(CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
            formatDescriptionOut: &description
        ) == noErr)
        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 15),
                                        presentationTimeStamp: CMTime(value: 100, timescale: 1),
                                        decodeTimeStamp: .invalid)
        let format = try #require(description)
        #expect(CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
            formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample
        ) == noErr)
        return try #require(sample)
    }
}

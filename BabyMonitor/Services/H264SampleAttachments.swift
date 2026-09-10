@preconcurrency import AVFoundation

nonisolated enum H264SampleAttachments {
    static func configure(_ sampleBuffer: CMSampleBuffer, isKeyFrame: Bool) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer, createIfNecessary: true
        ), CFArrayGetCount(attachments) > 0 else { return }

        // CoreMedia requires per-sample keys in this mutable dictionary.
        // CMSetAttachment would put them on the buffer, where the renderer
        // ignores them and treats every sample as an independent sync frame.
        let dictionary = unsafeBitCast(
            CFArrayGetValueAtIndex(attachments, 0),
            to: CFMutableDictionary.self
        )
        let values: [(CFString, CFBoolean)] = [
            (kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue),
            (kCMSampleAttachmentKey_NotSync, isKeyFrame ? kCFBooleanFalse : kCFBooleanTrue),
            (kCMSampleAttachmentKey_DependsOnOthers, isKeyFrame ? kCFBooleanFalse : kCFBooleanTrue)
        ]
        for (key, value) in values {
            CFDictionarySetValue(
                dictionary,
                Unmanaged.passUnretained(key).toOpaque(),
                Unmanaged.passUnretained(value).toOpaque()
            )
        }
    }
}

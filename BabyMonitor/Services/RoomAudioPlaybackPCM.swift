@preconcurrency import AVFoundation
import Foundation

nonisolated struct RoomAudioPlaybackPCM {
    let format: AVAudioFormat

    init() throws {
        // iPadOS 15 rejects Int16 as AVAudioPlayerNode's output format with
        // an Objective-C exception. Use standard Float32 PCM in the graph,
        // keeping the compact Int16 format only on the wire.
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: Double(AudioWireFrame.sampleRate),
            channels: AVAudioChannelCount(AudioWireFrame.channelCount)
        ) else {
            throw RoomAudioPlaybackPCMError.unsupportedFormat
        }
        self.format = format
    }

    func makeBuffer(_ frame: AudioWireFrame) throws -> AVAudioPCMBuffer {
        let sampleCount = Int(frame.frameCount)
        guard
            sampleCount > 0,
            frame.pcmInt16LittleEndian.count == sampleCount * MemoryLayout<Int16>.size
        else {
            throw RoomAudioPlaybackPCMError.invalidPacket
        }
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(frame.frameCount)
            ),
            let destination = buffer.floatChannelData?.pointee
        else {
            throw RoomAudioPlaybackPCMError.cannotAllocateBuffer
        }

        buffer.frameLength = AVAudioFrameCount(frame.frameCount)
        frame.pcmInt16LittleEndian.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            for index in 0..<sampleCount {
                // Read bytes explicitly: network Data need not be Int16-aligned.
                let offset = index * 2
                let bits = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
                destination[index] = Float(Int16(bitPattern: bits)) / 32_768
            }
        }
        return buffer
    }
}

nonisolated enum RoomAudioPlaybackPCMError: LocalizedError {
    case unsupportedFormat
    case invalidPacket
    case cannotAllocateBuffer

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            return "The room-audio playback format is unavailable."
        case .invalidPacket:
            return "The room-audio packet was invalid."
        case .cannotAllocateBuffer:
            return "The room-audio playback buffer could not be allocated."
        }
    }
}

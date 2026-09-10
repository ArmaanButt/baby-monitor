import AVFoundation
import Foundation
import Testing
@testable import BabyMonitor

@Suite(.serialized)
struct RoomAudioPlaybackTests {
    @Test func wireSamplesBecomeStandardPlayerPCMWithoutChangingRateOrAmplitude() throws {
        let pcm = try RoomAudioPlaybackPCM()
        // -32768, -16384, -1, 0, 1, 16384, 32767 in little-endian order.
        // Keep a nonzero Data startIndex to cover sliced network data.
        var payload = Data([0xff, 0x00, 0x80, 0x00, 0xc0, 0xff, 0xff,
                            0x00, 0x00, 0x01, 0x00, 0x00, 0x40, 0xff, 0x7f])
        payload.removeFirst()
        let frame = AudioWireFrame(
            sequenceNumber: 7,
            presentationTimeMicroseconds: 123_456,
            frameCount: 7,
            pcmInt16LittleEndian: payload
        )
        let buffer = try pcm.makeBuffer(frame)

        #expect(pcm.format.commonFormat == .pcmFormatFloat32)
        #expect(!pcm.format.isInterleaved)
        #expect(pcm.format.sampleRate == 24_000)
        #expect(pcm.format.channelCount == 1)
        #expect(buffer.format == pcm.format)
        #expect(buffer.frameLength == frame.frameCount)
        let samples = try #require(buffer.floatChannelData?.pointee)
        #expect(Array(UnsafeBufferPointer(start: samples, count: 7)) == [
            -1, -0.5, -1 / Float(32_768), 0, 1 / Float(32_768),
            0.5, Float(32_767) / 32_768
        ])
        #expect(frame.pcmInt16LittleEndian == payload)
    }

    @Test func playbackRejectsEmptyTruncatedAndExtraSamples() throws {
        let pcm = try RoomAudioPlaybackPCM()
        let invalidPackets: [(UInt32, Data)] = [
            (0, Data()),
            (1, Data([0])),
            (1, Data([0, 0, 0])),
            (UInt32.max, Data([0, 0]))
        ]
        for (frameCount, payload) in invalidPackets {
            let frame = AudioWireFrame(
                sequenceNumber: 0,
                presentationTimeMicroseconds: 0,
                frameCount: frameCount,
                pcmInt16LittleEndian: payload
            )
            #expect(throws: RoomAudioPlaybackPCMError.invalidPacket) {
                try pcm.makeBuffer(frame)
            }
        }
    }

    @MainActor
    @Test func viewerAudioStartsAndSchedulesPacketsAcrossReconnects() async throws {
        let controller = RoomAudioPlaybackController()
        defer { controller.reset() }
        let frame = AudioWireFrame(
            sequenceNumber: 0,
            presentationTimeMicroseconds: 0,
            frameCount: 480,
            pcmInt16LittleEndian: Data(repeating: 0, count: 960)
        )

        for _ in 0..<3 {
            controller.prepareForStream()
            // Startup and packet admission run on the playback queue. Wait for
            // published results while supplying the first packet of a stream.
            for _ in 0..<100 {
                try await Task.sleep(nanoseconds: 20_000_000)
                if case .failed(let message) = controller.state {
                    Issue.record("Viewer audio failed to start: \(message)")
                    return
                }
                if controller.diagnostics.scheduledPacketCount > 0,
                   case .playing = controller.state {
                    break
                }
                controller.enqueue(frame)
            }

            #expect(controller.diagnostics.scheduledPacketCount > 0)
            #expect(controller.diagnostics.bufferedPacketCount <= 8)
            if case .playing = controller.state {
                // The real player graph accepted its first playback buffer.
            } else {
                Issue.record("Viewer audio did not reach playback.")
            }
            controller.reset()
            #expect(controller.state == .idle)
        }
    }
}

import Foundation
@preconcurrency import WebRTC

/// The bundled convenience factories advertise level 3.1, which cannot encode
/// a 1920×1080 picture. Advertise level 4.0 on both peers, then use the library's
/// own VideoToolbox codecs. No SDP rewriting or custom H.264 decoding is needed.
nonisolated enum WebRTCH264Profile {
    static var codecs: [RTCVideoCodecInfo] {
        ["640c28", "42e028"].map {
            RTCVideoCodecInfo(name: "H264", parameters: [
                "profile-level-id": $0,
                "level-asymmetry-allowed": "1",
                "packetization-mode": "1"
            ])
        }
    }
}

nonisolated final class WebRTCH264EncoderFactory: NSObject, RTCVideoEncoderFactory {
    func supportedCodecs() -> [RTCVideoCodecInfo] { WebRTCH264Profile.codecs }
    func createEncoder(_ info: RTCVideoCodecInfo) -> RTCVideoEncoder? {
        guard info.name == "H264" else { return nil }
        return RTCVideoEncoderH264(codecInfo: info)
    }
}

nonisolated final class WebRTCH264DecoderFactory: NSObject, RTCVideoDecoderFactory {
    func supportedCodecs() -> [RTCVideoCodecInfo] { WebRTCH264Profile.codecs }
    func createDecoder(_ info: RTCVideoCodecInfo) -> RTCVideoDecoder? {
        guard info.name == "H264" else { return nil }
        return RTCVideoDecoderH264()
    }
}

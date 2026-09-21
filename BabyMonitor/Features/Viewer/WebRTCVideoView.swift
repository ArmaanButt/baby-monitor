import SwiftUI
@preconcurrency import WebRTC

struct WebRTCVideoView: UIViewRepresentable {
    let track: RTCVideoTrack?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let view = RTCMTLVideoView(frame: .zero)
        view.videoContentMode = .scaleAspectFit
        view.backgroundColor = .black
        context.coordinator.attach(track, to: view)
        return view
    }

    func updateUIView(_ view: RTCMTLVideoView, context: Context) {
        context.coordinator.attach(track, to: view)
    }

    static func dismantleUIView(_ view: RTCMTLVideoView, coordinator: Coordinator) {
        coordinator.attach(nil, to: view)
    }

    @MainActor
    final class Coordinator {
        private var track: RTCVideoTrack?

        func attach(_ newTrack: RTCVideoTrack?, to view: RTCMTLVideoView) {
            guard track !== newTrack else { return }
            track?.remove(view)
            view.renderFrame(nil)
            track = newTrack
            track?.add(view)
        }
    }
}

@preconcurrency import AVFoundation
import SwiftUI
import UIKit

struct VideoPlaybackView: UIViewRepresentable {
    let controller: H264VideoPlaybackController

    func makeCoordinator() -> H264VideoPlaybackController {
        controller
    }

    func makeUIView(context: Context) -> SampleBufferDisplayView {
        let view = SampleBufferDisplayView()
        controller.attach(view.sampleBufferDisplayLayer)
        return view
    }

    func updateUIView(
        _ uiView: SampleBufferDisplayView,
        context: Context
    ) {
        controller.attach(uiView.sampleBufferDisplayLayer)
    }

    static func dismantleUIView(
        _ uiView: SampleBufferDisplayView,
        coordinator: H264VideoPlaybackController
    ) {
        coordinator.detach(uiView.sampleBufferDisplayLayer)
    }
}

final class SampleBufferDisplayView: UIView {
    override class var layerClass: AnyClass {
        AVSampleBufferDisplayLayer.self
    }

    var sampleBufferDisplayLayer: AVSampleBufferDisplayLayer {
        layer as! AVSampleBufferDisplayLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        sampleBufferDisplayLayer.backgroundColor = UIColor.black.cgColor
        sampleBufferDisplayLayer.videoGravity = .resizeAspect
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }
}

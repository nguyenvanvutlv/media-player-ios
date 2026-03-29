import SwiftUI
import UIKit

/// Updates layer geometry whenever Auto Layout / SwiftUI assigns a non‑zero size (same role as `viewDidLayoutSubviews`).
private final class VideoLayoutContainerView: UIView {
    weak var sampleRenderer: SampleBufferRenderer?

    override func layoutSubviews() {
        super.layoutSubviews()
        sampleRenderer?.layout(bounds: bounds)
    }
}

/// Hosts `AVSampleBufferDisplayLayer` via existing `SampleBufferRenderer.attach(to:)`.
struct VideoDisplayView: UIViewRepresentable {
    let sampleRenderer: SampleBufferRenderer

    func makeUIView(context: Context) -> UIView {
        let v = VideoLayoutContainerView()
        v.backgroundColor = .black
        v.sampleRenderer = sampleRenderer
        sampleRenderer.attach(to: v)
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        (uiView as? VideoLayoutContainerView)?.sampleRenderer = sampleRenderer
        sampleRenderer.layout(bounds: uiView.bounds)
    }
}

import SwiftUI
import UIKit

/// Transparent overlay above video; does **not** host `AVSampleBufferDisplayLayer` (see `VideoDisplayView`).
struct AssBitmapOverlayView: UIViewRepresentable {
    var image: UIImage?
    var verticalOffset: CGFloat = 0
    /// When `true`, the image is positioned to cover the full video bounds (used for bitmap subtitles like PGS/DVB/DVD).
    var fullFrame: Bool = false

    func makeUIView(context: Context) -> AssBitmapOverlayContainerView {
        let v = AssBitmapOverlayContainerView()
        v.isUserInteractionEnabled = false
        return v
    }

    func updateUIView(_ uiView: AssBitmapOverlayContainerView, context: Context) {
        uiView.setOverlayImage(image)
        uiView.verticalOffset = verticalOffset
        uiView.fullFrame = fullFrame
    }
}

/// Positions subtitle bitmap bottom-center with safe-area padding (independent of video layer).
final class AssBitmapOverlayContainerView: UIView {
    private let imageView = UIImageView()
    private var lastPlacementSignature: String?
    var verticalOffset: CGFloat = 0 {
        didSet { setNeedsLayout() }
    }
    var fullFrame: Bool = false {
        didSet { setNeedsLayout() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = .clear
        addSubview(imageView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    func setOverlayImage(_ image: UIImage?) {
        imageView.image = image
        imageView.isHidden = (image == nil)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let img = imageView.image else {
            imageView.frame = .zero
            return
        }
        if fullFrame {
            imageView.contentMode = .scaleAspectFit
            imageView.frame = bounds
            return
        }
        imageView.contentMode = .scaleAspectFit
        let maxW = bounds.width - 40
        let scale = min(1, maxW / max(img.size.width, 1))
        let w = img.size.width * scale
        let h = img.size.height * scale
        // `verticalOffset`: positive = move subtitles up (more bottom inset), negative = move down.
        // Keep a smaller base so "min" doesn't still feel too high, but never go under the home indicator.
        let clampedOffset = max(-260, min(260, verticalOffset))
        let preferredInset = safeAreaInsets.bottom + 70 + clampedOffset
        let bottomInset = max(safeAreaInsets.bottom + 20, preferredInset)
        let frame = CGRect(
            x: (bounds.width - w) * 0.5,
            y: bounds.height - h - bottomInset,
            width: w,
            height: h
        )
        imageView.frame = frame

        let sig = [
            "\(Int(bounds.width))x\(Int(bounds.height))",
            "sb=\(Int(safeAreaInsets.bottom))",
            "img=\(Int(img.size.width))x\(Int(img.size.height))",
            "s=\(String(format: "%.3f", scale))",
            "off=\(String(format: "%.1f", clampedOffset))",
            "bi=\(String(format: "%.1f", bottomInset))",
            "y=\(String(format: "%.1f", frame.origin.y))",
            imageView.isHidden ? "hidden=1" : "hidden=0",
        ].joined(separator: "|")
        if sig != lastPlacementSignature {
            lastPlacementSignature = sig
#if DEBUG
            PlaybackLog.subtitleOverlayPlacement(
                viewSize: bounds.size,
                safeAreaInsets: safeAreaInsets,
                imageSize: img.size,
                imageScaleToFit: scale,
                verticalOffset: clampedOffset,
                bottomInset: bottomInset,
                imageFrame: frame,
                isHidden: imageView.isHidden
            )
#endif
        }
    }
}

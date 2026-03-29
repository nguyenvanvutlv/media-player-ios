import UIKit

/// Renders subtitle text to a transparent RGBA bitmap for `CALayer` / `UIImageView`.
/// Default backend: CoreGraphics + CoreText (no libass link required). Swap-in libass can produce `CGImage` the same way.
enum SubtitleBitmapRenderer {
    struct Style: Equatable {
        var fontSize: CGFloat
        var textColor: UIColor
        var backgroundColor: UIColor?
    }

    /// - Parameters:
    ///   - plainText: Stripped dialogue (SRT/ASS text path).
    ///   - assRaw: Optional raw ASS dialogue; when non-nil, future libass backend may use it; CoreGraphics path uses `plainText` only.
    static func render(
        plainText: String,
        assRaw: String?,
        maxWidth: CGFloat,
        displayScale: CGFloat,
        style: Style
    ) -> UIImage? {
        let text = plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let font = UIFont.systemFont(ofSize: max(10, style.fontSize), weight: .semibold)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping

        let maxW = max(60, maxWidth - 48)
        let constraint = CGSize(width: maxW, height: CGFloat.greatestFiniteMagnitude)

        let strokeAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: paragraph,
            .strokeColor: UIColor.black,
            .strokeWidth: -4.0,
            .foregroundColor: UIColor.clear,
        ]
        let fillAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: paragraph,
            .foregroundColor: style.textColor,
        ]

        let strokeStr = NSAttributedString(string: text, attributes: strokeAttrs)
        let fillStr = NSAttributedString(string: text, attributes: fillAttrs)

        let textBounds = strokeStr.boundingRect(with: constraint, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        let pad: CGFloat = 14
        let bgCorner: CGFloat = 6
        let size = CGSize(
            width: ceil(min(textBounds.width, maxW) + pad * 2),
            height: ceil(textBounds.height + pad * 2)
        )

        let format = UIGraphicsImageRendererFormat()
        format.scale = max(1.0, displayScale)
        format.opaque = false

        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { ctx in
            let rect = CGRect(origin: .zero, size: size)
            if let bg = style.backgroundColor {
                let path = UIBezierPath(roundedRect: rect, cornerRadius: bgCorner)
                bg.setFill()
                path.fill()
            }

            let textRect = CGRect(
                x: pad,
                y: pad,
                width: size.width - pad * 2,
                height: size.height - pad * 2
            )
            strokeStr.draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            fillStr.draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        }

        _ = assRaw // reserved for libass-backed renderer
        return image
    }
}

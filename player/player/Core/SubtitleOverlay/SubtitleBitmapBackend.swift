import Foundation
import UIKit

/// Abstraction for “subtitle → RGBA bitmap” so a future **libass** backend (`ass_render_frame` → `ass_image_t` → RGBA)
/// can replace [`SubtitleBitmapRenderer`](SubtitleBitmapRenderer) without touching video/audio.
///
/// Integration notes when adding libass:
/// - Link `libass` + dependencies (typically FreeType, FriBidi; Fontconfig often skipped on iOS with `ass_set_fonts` paths).
/// - Build is **not** part of the current `libffmpeg.xcframework` script; add a separate xcframework or static archive.
/// - Feed `ASS_Track` from embedded header + dialogue lines; drive `ass_render_frame` with playback time in ms aligned with `SubtitleOverlayFrame.ptsMs` / video clock.
protocol SubtitleBitmapBackend {
    func render(plainText: String, assRaw: String?, maxWidth: CGFloat, displayScale: CGFloat) -> UIImage?
}

enum DefaultSubtitleBitmapBackend: SubtitleBitmapBackend {
    func render(plainText: String, assRaw: String?, maxWidth: CGFloat, displayScale: CGFloat) -> UIImage? {
        SubtitleBitmapRenderer.render(
            plainText: plainText,
            assRaw: assRaw,
            maxWidth: maxWidth,
            displayScale: displayScale,
            style: .init(fontSize: 18, textColor: .white, backgroundColor: UIColor.black.withAlphaComponent(0.45))
        )
    }
}

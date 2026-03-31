import Foundation
import UIKit

struct LibassStyleConfig: Equatable {
    var fontSize: CGFloat
    var isBold: Bool
    var textColor: UIColor
    var backgroundColor: UIColor?
    /// Positive values move subtitles up.
    var verticalOffset: CGFloat
}

/// Minimal libass overlay renderer that renders a single cue as a tight RGBA bitmap.
/// This avoids FFmpeg's `subtitles` filter (no network re-open, no filtergraph).
final class LibassSubtitleOneshotRenderer {
    static let shared = LibassSubtitleOneshotRenderer()

    private let lock = NSLock()
    private var library: OpaquePointer?
    private var renderer: OpaquePointer?
    private var lastKey: String?
    private var lastImage: UIImage?

    private init() {
        library = ass_library_init()
        renderer = library.flatMap { ass_renderer_init($0) }
        if let r = renderer {
            // System font fallback. On iOS/tvOS we avoid fontconfig and rely on fallback.
            ass_set_fonts(r, nil, "Helvetica", 1, nil, 1)
        }
    }

    deinit {
        lock.lock()
        let r = renderer
        let l = library
        renderer = nil
        library = nil
        lock.unlock()
        if let r { ass_renderer_done(r) }
        if let l { ass_library_done(l) }
    }

    func render(
        plainText: String,
        assRaw: String?,
        canvasWidth: CGFloat,
        canvasHeight: CGFloat,
        displayScale: CGFloat
        ,
        styleConfig: LibassStyleConfig
    ) -> UIImage? {
        let textKey = assRaw ?? plainText
        let w = max(64, Int((canvasWidth * displayScale).rounded(.up)))
        let h = max(64, Int((canvasHeight * displayScale).rounded(.up)))
        let key = "\(w)x\(h)|\(displayScale)|\(styleConfig.fontSize)|\(styleConfig.isBold ? 1 : 0)|\(styleConfig.verticalOffset)|\(styleConfig.textColor.description)|\(String(describing: styleConfig.backgroundColor))|\(textKey)"

        lock.lock()
        if key == lastKey, let img = lastImage {
            lock.unlock()
            return img
        }
        lock.unlock()

        guard let lib = library, let ren = renderer else { return nil }
        ass_set_frame_size(ren, Int32(w), Int32(h))

        guard let track = ass_new_track(lib) else { return nil }
        defer { ass_free_track(track) }

        let script = makeAssScript(
            plainText: plainText,
            assRaw: assRaw,
            playResX: w,
            playResY: h,
            displayScale: displayScale,
            styleConfig: styleConfig
        )
        script.withCString { ptr in
            ass_process_data(track, UnsafeMutablePointer(mutating: ptr), Int32(strlen(ptr)))
        }

        var changed: Int32 = 0
        guard let images = ass_render_frame(ren, track, 0, &changed) else { return nil }

        guard let cg = compositeAssImagesToFullCGImage(images: images, width: w, height: h) else { return nil }
        let img = UIImage(cgImage: cg, scale: displayScale, orientation: .up)

        lock.lock()
        lastKey = key
        lastImage = img
        lock.unlock()
        return img
    }

    private func makeAssScript(
        plainText: String,
        assRaw: String?,
        playResX: Int,
        playResY: Int,
        displayScale: CGFloat,
        styleConfig: LibassStyleConfig
    ) -> String {
        let dialogueText: String = {
            if let assRaw, !assRaw.isEmpty {
                let extracted = extractASSText(assRaw: assRaw)
                return normalizeTextForDialogueField(extracted)
            }
            return assEscape(plainText)
        }()

        let fontSize = max(10, Int((styleConfig.fontSize * displayScale).rounded()))
        let bold = styleConfig.isBold ? 1 : 0
        let primary = assColor(styleConfig.textColor)
        let back = assColor(styleConfig.backgroundColor ?? UIColor.clear)
        // Match SwiftUI overlay semantics: positive verticalOffset moves up (more bottom margin).
        let baseMarginV = Int((28.0 * displayScale).rounded())
        let off = Int((styleConfig.verticalOffset * displayScale).rounded())
        let marginV = max(0, baseMarginV + off)

        // Single event from 0s to 10s; we render at t=0 for a one-shot bitmap.
        // We keep a simple Default style; inline ASS tags in `assRaw` still apply.
        return """
        [Script Info]
        ScriptType: v4.00+
        PlayResX: \(playResX)
        PlayResY: \(playResY)
        WrapStyle: 0
        ScaledBorderAndShadow: yes

        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
        Style: Default,Helvetica,\(fontSize),\(primary),&H000000FF,&H80000000,\(back),\(bold),0,0,0,100,100,0,0,1,2,1,2,40,40,\(marginV),1

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:00.00,0:00:10.00,Default,,0,0,0,,\(dialogueText)
        """
    }

    private func extractASSText(assRaw: String) -> String {
        // FFmpeg often provides full "Dialogue:" CSV. Keep only the Text field (after 8 commas).
        // Also normalize `\N` into actual newlines for internal handling.
        let lines = assRaw.split(whereSeparator: \.isNewline)
        let extracted: [String] = lines.map { line in
            let s = String(line)
            let parts = s.split(separator: ",", maxSplits: 8, omittingEmptySubsequences: false)
            guard parts.count > 8 else { return s }
            return parts.dropFirst(8).joined(separator: ",")
        }
        return extracted.joined(separator: "\n").replacingOccurrences(of: "\\N", with: "\n")
    }

    private func normalizeTextForDialogueField(_ s: String) -> String {
        // Keep override tags, but ensure no literal newlines end up inside the Dialogue line.
        s
            .replacingOccurrences(of: "\r\n", with: "\\N")
            .replacingOccurrences(of: "\n", with: "\\N")
    }

    private func assColor(_ color: UIColor) -> String {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        let rr = UInt8(max(0, min(255, Int((r * 255.0).rounded()))))
        let gg = UInt8(max(0, min(255, Int((g * 255.0).rounded()))))
        let bb = UInt8(max(0, min(255, Int((b * 255.0).rounded()))))
        // ASS alpha: 00 opaque, FF transparent.
        let aa = UInt8(max(0, min(255, Int(((1.0 - a) * 255.0).rounded()))))
        return String(format: "&H%02X%02X%02X%02X", aa, bb, gg, rr)
    }

    private func assEscape(_ s: String) -> String {
        // ASS: newline is \N, and braces must be escaped to avoid tag parsing.
        s
            .replacingOccurrences(of: "{", with: "\\{")
            .replacingOccurrences(of: "}", with: "\\}")
            .replacingOccurrences(of: "\r\n", with: "\\N")
            .replacingOccurrences(of: "\n", with: "\\N")
    }

    private func compositeAssImagesToFullCGImage(
        images: UnsafeMutablePointer<ASS_Image>,
        width: Int,
        height: Int
    ) -> CGImage? {
        let outW = max(1, min(4096, width))
        let outH = max(1, min(4096, height))

        var rgba = Data(count: outW * outH * 4)
        rgba.withUnsafeMutableBytes { dstRaw in
            guard let dst = dstRaw.bindMemory(to: UInt8.self).baseAddress else { return }
            var cur: UnsafeMutablePointer<ASS_Image>? = images
            while let img = cur {
                let w = Int(img.pointee.w)
                let h = Int(img.pointee.h)
                if w <= 0 || h <= 0 { cur = img.pointee.next; continue }
                guard let bmp = img.pointee.bitmap else { cur = img.pointee.next; continue }
                let stride = Int(img.pointee.stride)
                let xOff = Int(img.pointee.dst_x)
                let yOff = Int(img.pointee.dst_y)

                let c = UInt32(img.pointee.color)
                // libass `ASS_Image.color` is documented as RGBA; in practice this is `0xRRGGBBAA`,
                // where alpha is inverted (0x00 = opaque, 0xFF = transparent).
                let r = UInt8((c >> 24) & 0xFF)
                let g = UInt8((c >> 16) & 0xFF)
                let b = UInt8((c >> 8) & 0xFF)
                let aBase = UInt8(255 - (c & 0xFF))

                for y in 0..<h {
                    let dy = yOff + y
                    if dy < 0 || dy >= outH { continue }
                    let row = bmp.advanced(by: y * stride)
                    for x in 0..<w {
                        let dx = xOff + x
                        if dx < 0 || dx >= outW { continue }
                        let cov = row[x] // 0..255
                        if cov == 0 { continue }
                        let a = (UInt16(aBase) * UInt16(cov)) / 255
                        if a == 0 { continue }

                        let o = (dy * outW + dx) * 4
                        let dstA = UInt16(dst[o + 3])
                        let srcA = a
                        let invA = 255 - srcA
                        dst[o + 0] = UInt8((UInt16(r) * srcA + UInt16(dst[o + 0]) * invA) / 255)
                        dst[o + 1] = UInt8((UInt16(g) * srcA + UInt16(dst[o + 1]) * invA) / 255)
                        dst[o + 2] = UInt8((UInt16(b) * srcA + UInt16(dst[o + 2]) * invA) / 255)
                        dst[o + 3] = UInt8(min(255, Int(srcA + (dstA * invA) / 255)))
                    }
                }
                cur = img.pointee.next
            }
        }

        guard let provider = CGDataProvider(data: rgba as CFData) else { return nil }
        let cs = CGColorSpaceCreateDeviceRGB()
        return CGImage(
            width: outW,
            height: outH,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: outW * 4,
            space: cs,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }
}


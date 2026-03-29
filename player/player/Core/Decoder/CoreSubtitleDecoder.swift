import Foundation

enum CoreSubtitleDecoderError: Error, LocalizedError {
    case noCodec
    case openFailed(code: Int32)

    var errorDescription: String? {
        switch self {
        case .noCodec: return "noCodec"
        case .openFailed(let code): return "openFailed(code: \(code))"
        }
    }
}

/// Decodes **text** subtitle packets (SubRip, ASS, etc.) via FFmpeg’s legacy subtitle API.
final class CoreSubtitleDecoder {
    private var codecContext: UnsafeMutablePointer<AVCodecContext>?

    func open(codecpar: UnsafePointer<AVCodecParameters>) throws {
        close()
        guard let codec = avcodec_find_decoder(codecpar.pointee.codec_id) else {
            throw CoreSubtitleDecoderError.noCodec
        }
        var ctxPtr: UnsafeMutablePointer<AVCodecContext>? = avcodec_alloc_context3(codec)
        guard let ctx = ctxPtr else { throw CoreSubtitleDecoderError.openFailed(code: ff_err_enomem()) }
        var err = avcodec_parameters_to_context(ctx, codecpar)
        if err < 0 { avcodec_free_context(&ctxPtr); throw CoreSubtitleDecoderError.openFailed(code: err) }
        err = avcodec_open2(ctx, codec, nil)
        if err < 0 { avcodec_free_context(&ctxPtr); throw CoreSubtitleDecoderError.openFailed(code: err) }
        codecContext = ctx
    }

    func close() {
        if codecContext != nil {
            avcodec_free_context(&codecContext)
        }
    }

    deinit { close() }

    func prepareForSeek() {
        if let ctx = codecContext {
            avcodec_flush_buffers(ctx)
        }
    }

    func decode(packet: UnsafeMutablePointer<AVPacket>, timeBase: AVRational) throws -> SubtitleDecodeOutcome {
        guard let ctx = codecContext else {
            return SubtitleDecodeOutcome(cue: nil, bitmapFrameWithoutText: false, rectKindSummary: "")
        }
        var sub = AVSubtitle()
        defer { avsubtitle_free(&sub) }
        var got: Int32 = 0
        let ret = avcodec_decode_subtitle2(ctx, &sub, &got, packet)
        if ret < 0 {
            throw CoreSubtitleDecoderError.openFailed(code: ret)
        }
        guard got != 0 else {
            return SubtitleDecodeOutcome(cue: nil, bitmapFrameWithoutText: false, rectKindSummary: "")
        }

        guard sub.num_rects > 0, let rects = sub.rects else {
            return SubtitleDecodeOutcome(cue: nil, bitmapFrameWithoutText: false, rectKindSummary: "")
        }

        var pieces: [String] = []
        var rawAssPieces: [String] = []
        var sawBitmapRect = false
        var sawTextRect = false
        var sawAssRect = false
        let n = Int(sub.num_rects)
        for i in 0..<n {
            guard let r = rects[i] else { continue }
            let type = r.pointee.type
            if type == SUBTITLE_BITMAP {
                sawBitmapRect = true
            } else if type == SUBTITLE_TEXT, let t = r.pointee.text {
                sawTextRect = true
                pieces.append(String(cString: t))
            } else if type == SUBTITLE_ASS, let a = r.pointee.ass {
                sawAssRect = true
                let raw = String(cString: a)
                rawAssPieces.append(raw)
                pieces.append(Self.stripASSDialogue(raw))
            } else {
                // Defensive: some builds use unexpected rect type values; try text/ass pointers if present.
                if let t = r.pointee.text {
                    sawTextRect = true
                    pieces.append(String(cString: t))
                } else if let a = r.pointee.ass {
                    sawAssRect = true
                    let raw = String(cString: a)
                    rawAssPieces.append(raw)
                    pieces.append(Self.stripASSDialogue(raw))
                }
            }
        }
        let rectKindSummary: String = {
            var parts: [String] = []
            if sawBitmapRect { parts.append("BITMAP") }
            if sawTextRect { parts.append("TEXT") }
            if sawAssRect { parts.append("ASS") }
            return parts.isEmpty ? "none" : parts.joined(separator: "+")
        }()
        let text = pieces.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            return SubtitleDecodeOutcome(cue: nil, bitmapFrameWithoutText: sawBitmapRect, rectKindSummary: rectKindSummary)
        }

        let nopts = Self.noptsInt64()
        let ptsRaw: Int64
        if packet.pointee.pts != nopts {
            ptsRaw = packet.pointee.pts
        } else if packet.pointee.dts != nopts {
            ptsRaw = packet.pointee.dts
        } else {
            ptsRaw = nopts
        }
        let ptsSec: Double
        if ptsRaw == nopts {
            ptsSec = 0
        } else {
            ptsSec = Double(ptsRaw) * Double(timeBase.num) / Double(timeBase.den)
        }
        let start = ptsSec + Double(sub.start_display_time) / 1000.0
        let end: Double
        if sub.end_display_time > 0 {
            end = ptsSec + Double(sub.end_display_time) / 1000.0
        } else {
            end = start + 3.0
        }
        let assRaw: String? = rawAssPieces.isEmpty ? nil : rawAssPieces.joined(separator: "\n")
        let cue = SubtitleCue(start: start, end: end, text: text, assRaw: assRaw)
        return SubtitleDecodeOutcome(cue: cue, bitmapFrameWithoutText: false, rectKindSummary: rectKindSummary)
    }

    private static func noptsInt64() -> Int64 {
        Int64(bitPattern: UInt64(0x8000_0000_0000_0000))
    }

    private static func stripASSDialogue(_ ass: String) -> String {
        let parts = ass.split(separator: ",", maxSplits: 8, omittingEmptySubsequences: false)
        guard parts.count > 8 else { return ass }
        return parts.dropFirst(8).joined(separator: ",").replacingOccurrences(of: "\\N", with: "\n")
    }
}

struct SubtitleCue: Equatable {
    let start: Double
    let end: Double
    let text: String
    /// Raw ASS dialogue fragment(s) from FFmpeg (e.g. SubRip decoder → ASS rects); used for future libass / rich styling.
    let assRaw: String?

    init(start: Double, end: Double, text: String, assRaw: String? = nil) {
        self.start = start
        self.end = end
        self.text = text
        self.assRaw = assRaw
    }
}

/// Result of `avcodec_decode_subtitle2` for the selected subtitle stream.
struct SubtitleDecodeOutcome {
    let cue: SubtitleCue?
    /// True when FFmpeg delivered a subtitle frame with bitmap rects but no usable text/ASS (typical for PGS/DVB).
    let bitmapFrameWithoutText: Bool
    /// Rect types in this subtitle event (`TEXT`, `ASS`, `BITMAP`, combined with `+`).
    let rectKindSummary: String
}

import Foundation

// MARK: - Track models (FFmpeg stream metadata)

/// One selectable audio stream (`index` matches `selectAudioTrack(_:)` / demuxer `audioStreamIndices`).
struct AudioTrack: Identifiable, Equatable, Hashable {
    let index: Int
    let streamIndex: Int
    let language: String?
    let codec: String?

    var id: Int { index }

    var displayTitle: String {
        let lang = language.map { "\($0) · " } ?? ""
        let c = codec ?? String(localized: "Unknown")
        return "\(lang)\(c)"
    }
}

/// Subtitle row: `index` 0 = Off in UI list; embedded then external.
struct SubtitleTrack: Identifiable, Equatable, Hashable {
    let index: Int
    let language: String?
    let isExternal: Bool
    /// Embedded FFmpeg stream index; `nil` for Off or external files.
    let embeddedStreamIndex: Int?
    let externalURL: URL?
    let codec: String?

    var id: Int { index }

    var displayTitle: String {
        if index == 0 { return String(localized: "Off") }
        if isExternal {
            return externalURL?.lastPathComponent ?? String(localized: "External")
        }
        let lang = language.map { "\($0) · " } ?? ""
        let c = codec ?? String(localized: "Subtitle")
        return "\(lang)\(c)"
    }
}

/// Timed subtitle line for overlay (decoded cues / parsed SRT).
struct SubtitleItem: Equatable {
    var startTime: Double
    var endTime: Double
    var text: String
}

extension SubtitleCue {
    var asSubtitleItem: SubtitleItem {
        SubtitleItem(startTime: start, endTime: end, text: text)
    }
}

enum ExternalSubtitleParser {
    static func parseSRT(data: String) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        let blocks = data.components(separatedBy: "\n\n")
        for block in blocks {
            let lines = block.split(whereSeparator: \.isNewline).map(String.init)
            guard lines.count >= 2 else { continue }
            var timeLineIndex = 0
            if lines[0].contains("-->") {
                timeLineIndex = 0
            } else if lines.count >= 2, lines[1].contains("-->") {
                timeLineIndex = 1
            } else {
                continue
            }
            let timeLine = lines[timeLineIndex]
            let parts = timeLine.components(separatedBy: "-->")
            guard parts.count == 2 else { continue }
            guard let start = parseSRTTime(parts[0].trimmingCharacters(in: .whitespaces)),
                  let end = parseSRTTime(parts[1].trimmingCharacters(in: .whitespaces)) else { continue }
            let textLines = lines.dropFirst(timeLineIndex + 1)
            let text = textLines.joined(separator: "\n")
            guard !text.isEmpty else { continue }
            cues.append(SubtitleCue(start: start, end: end, text: text))
        }
        return cues
    }

    private static func parseSRTTime(_ s: String) -> Double? {
        let t = s.replacingOccurrences(of: ",", with: ".")
        let parts = t.split(separator: ":")
        guard parts.count == 3 else { return nil }
        guard let h = Double(parts[0]), let m = Double(parts[1]) else { return nil }
        let secParts = parts[2].split(separator: ".")
        guard let sec = Double(secParts[0]) else { return nil }
        let frac = secParts.count > 1 ? (Double("0." + secParts[1]) ?? 0) : 0
        return h * 3600 + m * 60 + sec + frac
    }
}

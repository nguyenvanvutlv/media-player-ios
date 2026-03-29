import Foundation

/// One subtitle “frame” for bitmap overlay timing / future libass (`ass_render_frame` uses ms on the media timeline).
struct SubtitleOverlayFrame: Equatable {
    let plainText: String
    /// Raw ASS from FFmpeg rects (SubRip → ASS internally); reserved for a future libass backend.
    let assRaw: String?
    /// Cue start in milliseconds (absolute stream time, same basis as decoded cues).
    let ptsMs: Int64
}

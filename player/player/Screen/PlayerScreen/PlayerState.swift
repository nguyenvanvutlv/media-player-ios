import Combine
import Foundation
import UIKit

/// Central observable playback state for the SwiftUI layer (updated on main).
@MainActor
final class PlayerState: ObservableObject {
    @Published var isPlaying: Bool = true
    @Published var isBuffering: Bool = true
    @Published var isScrubbing: Bool = false
    @Published var isZoomed: Bool = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var buffered: Double = 0

    @Published var audioTracks: [AudioTrack] = []
    @Published var subtitleTracks: [SubtitleTrack] = []

    /// Index into `audioTracks`.
    @Published var selectedAudio: Int = 0
    /// `0` = subtitles off; otherwise index into `subtitleTracks` (row 0 is **Off**).
    @Published var selectedSubtitle: Int = 0

    @Published var title: String = ""

    /// Current subtitle line for the overlay (timed to `currentTime` / media timeline).
    @Published var currentSubtitleText: String?

    /// RGBA bitmap subtitle overlay (independent of `AVSampleBufferDisplayLayer`); nil = hidden.
    @Published var subtitleOverlayImage: UIImage?
    /// When true, the overlay image should be positioned full-frame (used for PGS/DVB/DVD bitmap subtitles).
    @Published var subtitleOverlayIsFullFrame: Bool = false
    /// Extra bottom padding for overlay placement; positive values move subtitles up.
    @Published var subtitleOverlayVerticalOffset: Double = 0
    /// Width from layout for text wrapping (defaults until first `GeometryReader` update).
    @Published var subtitleLayoutWidth: CGFloat = 400
    /// Device / scene pixel scale from SwiftUI `Environment` (avoid deprecated `UIScreen.main`).
    @Published var subtitleDisplayScale: CGFloat = 3.0

    /// One-shot user-visible error from playback.
    @Published var alertMessage: String?

    /// Updated by `PictureInPictureCoordinator` (PiP may stay false on Simulator or before playback is ready).
    @Published var isPictureInPicturePossible: Bool = false

    func resetForNewMedia() {
        isPlaying = true
        isBuffering = true
        isScrubbing = false
        isZoomed = false
        currentTime = 0
        duration = 0
        buffered = 0
        audioTracks = []
        subtitleTracks = []
        selectedAudio = 0
        selectedSubtitle = 0
        title = ""
        currentSubtitleText = nil
        subtitleOverlayImage = nil
        subtitleOverlayIsFullFrame = false
        subtitleOverlayVerticalOffset = 0
        subtitleLayoutWidth = 400
        alertMessage = nil
        isPictureInPicturePossible = false
    }
}

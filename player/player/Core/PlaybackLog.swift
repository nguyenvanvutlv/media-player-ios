import Foundation
import os.log
import UIKit

/// Unified logging for A/V sync, timing, and display-layer diagnostics (Console + Instruments).
enum PlaybackLog {
    enum Channel: String, CaseIterable {
        case seek
        case ffmpeg
        case video
        case audio
        case subtitle
        case backlog
    }

    // Runtime-togglable log channels (DEBUG only). In Release, keep behavior minimal.
    private static let channelLock = NSLock()
    private static var enabledChannels: Set<Channel> = Set(Channel.allCases)

    static func setChannelEnabled(_ channel: Channel, enabled: Bool) {
        channelLock.lock()
        if enabled {
            enabledChannels.insert(channel)
        } else {
            enabledChannels.remove(channel)
        }
        channelLock.unlock()
    }

    static func isChannelEnabled(_ channel: Channel) -> Bool {
#if DEBUG
        channelLock.lock()
        let ok = enabledChannels.contains(channel)
        channelLock.unlock()
        return ok
#else
        // In Release builds, keep logs conservative.
        return channel != .backlog
#endif
    }
    private static let syncLog = Logger(subsystem: "com.nvv.player", category: "sync")
    private static let videoLog = Logger(subsystem: "com.nvv.player", category: "video")
    private static let audioLog = Logger(subsystem: "com.nvv.player", category: "audio")
    private static let trackLog = Logger(subsystem: "com.nvv.player", category: "track")
    private static let subtitleLog = Logger(subsystem: "com.nvv.player", category: "subtitle")
    private static let seekLog = Logger(subsystem: "com.nvv.player", category: "seek")
    private static let ffmpegLog = Logger(subsystem: "com.nvv.player", category: "ffmpeg")
    private static let pipLog = Logger(subsystem: "com.nvv.player", category: "pip")

    /// `OSStatus -50` (`paramErr`) often appears when re-applying the same `AVAudioSession` category; playback can still work.
    static func isBenignAudioSessionOSStatus50(_ error: Error) -> Bool {
        let ns = error as NSError
        return ns.domain == NSOSStatusErrorDomain && ns.code == -50
    }

    static func sync(_ message: String) {
        // Single sink: Logger + os_log already surface in Console; avoid duplicating the same line as NSLog.
        syncLog.info("[player.sync] \(message, privacy: .public)")
    }

    static func video(_ message: String) {
        guard isChannelEnabled(.video) else { return }
        videoLog.info("\(message, privacy: .public)")
#if DEBUG
        NSLog("[player.video] %@", message)
#endif
    }

    static func audio(_ message: String) {
        guard isChannelEnabled(.audio) else { return }
        // Single sink (Logger only) — avoids duplicate lines in Console from Logger + NSLog.
        audioLog.info("[player.audio] \(message, privacy: .public)")
    }

    static func displayLayerError(_ message: String) {
        videoLog.error("\(message, privacy: .public)")
        NSLog("[player.display] %@", message)
    }

    static func trackSelection(_ message: String) {
        trackLog.info("\(message, privacy: .public)")
#if DEBUG
        NSLog("[player.track] %@", message)
#endif
    }

    /// Seek pipeline: demuxer + decoder flush + display layer (see `FFmpegPlaybackEngine.performSeek`).
    static func seek(_ message: String) {
        guard isChannelEnabled(.seek) else { return }
        let line = "[Seek] \(message)"
        seekLog.info("\(line, privacy: .public)")
#if DEBUG
        NSLog("%@", line)
        // Xcode debug console often shows `print` more reliably than unified logging filters.
        print(line)
#endif
    }

    /// Demuxer / `avformat_*` (PTS, stream index); does not add a `[Seek]` prefix.
    static func ffmpeg(_ message: String) {
        guard isChannelEnabled(.ffmpeg) else { return }
        let line = "[FFmpeg] \(message)"
        ffmpegLog.info("\(line, privacy: .public)")
#if DEBUG
        NSLog("%@", line)
        print(line)
#endif
    }

    static func playbackError(_ message: String) {
        let line = "[ERROR] \(message)"
        seekLog.error("\(line, privacy: .public)")
#if DEBUG
        NSLog("%@", line)
        print(line)
#endif
    }

    static func subtitleSelection(_ message: String) {
        guard isChannelEnabled(.subtitle) else { return }
        subtitleLog.info("\(message, privacy: .public)")
#if DEBUG
        NSLog("[player.subtitle] %@", message)
#endif
    }

    static func backlog(_ message: String) {
        guard isChannelEnabled(.backlog) else { return }
        let line = "[Backlog] \(message)"
        syncLog.info("\(line, privacy: .public)")
#if DEBUG
        NSLog("%@", line)
#endif
    }

    /// Decode-path log: text/ASS from `avcodec_decode_subtitle2` for the **currently selected** embedded track only.
    static func subtitleDecodedText(
        streamIndex: Int,
        uiTrackRow: Int?,
        ptsTicks: Int64,
        mediaSeconds: Double,
        text: String,
        rectKind: String = "",
        maxChars: Int = 200
    ) {
        let preview: String
        if text.count <= maxChars {
            preview = text.replacingOccurrences(of: "\n", with: "⏎")
        } else {
            preview = String(text.prefix(maxChars)).replacingOccurrences(of: "\n", with: "⏎") + "…"
        }
        let rowPart = uiTrackRow.map(String.init) ?? "?"
        let ptsStr = ptsTicks == Self.noptsInt64() ? "NOPTS" : "\(ptsTicks)"
        let t = String(format: "%.3f", mediaSeconds)
        let kindPart = rectKind.isEmpty ? "" : "[\(rectKind)] "
        let msg =
            "[Subtitle][Decode] stream_index=\(streamIndex) [FFmpeg][Subtitle][PTS=\(ptsStr)][t=\(t)s][Track=\(rowPart)] \(kindPart)\(preview)"
        subtitleLog.info("\(msg, privacy: .public)")
#if DEBUG
        NSLog("[player.subtitle.decode] %@", msg)
#endif
    }

    /// `avcodec_decode_subtitle2` failure or other decode-path error (throttle at call site if needed).
    static func subtitleDecodeFailure(_ message: String) {
        subtitleLog.error("[FFmpeg][Subtitle] \(message, privacy: .public)")
#if DEBUG
        NSLog("[FFmpeg][Subtitle] %@", message)
#endif
    }

    /// Bitmap / image-based subtitle: no dialogue text at decode layer (PGS, DVB, DVD bitmap, etc.).
    static func subtitleBitmapNoTextLog(streamIndex: Int, uiTrackRow: Int?, detail: String) {
        let rowPart = uiTrackRow.map(String.init) ?? "?"
        let msg =
            "[Subtitle] Bitmap subtitle — text logging not supported [Track=\(rowPart)][stream=\(streamIndex)] \(detail)"
        subtitleLog.notice("\(msg, privacy: .public)")
#if DEBUG
        NSLog("[player.subtitle] %@", msg)
#endif
    }

    private static func noptsInt64() -> Int64 {
        Int64(bitPattern: UInt64(0x8000_0000_0000_0000))
    }

    /// Log when a non-empty subtitle line is shown on screen (throttle long text in Console).
    static func subtitleDisplayed(mediaTime: Double, text: String, maxChars: Int = 120) {
        let preview: String
        if text.count <= maxChars {
            preview = text
        } else {
            preview = String(text.prefix(maxChars)) + "…"
        }
        let t = String(format: "%.3f", mediaTime)
        let line = "[t=\(t)s] \(preview)"
        subtitleLog.info("\(line, privacy: .public)")
#if DEBUG
        NSLog("[player.subtitle.display] %@", line)
#endif
    }

    /// UI / render path: same media seconds as `PlayerState.currentTime` when the overlay updates.
    static func renderSubtitle(ptsMediaSeconds: Double, text: String, maxChars: Int = 200) {
#if DEBUG
        let preview: String
        if text.count <= maxChars {
            preview = text.replacingOccurrences(of: "\n", with: "⏎")
        } else {
            preview = String(text.prefix(maxChars)).replacingOccurrences(of: "\n", with: "⏎") + "…"
        }
        let pts = String(format: "%.3f", ptsMediaSeconds)
        let line = "[Render][Subtitle][PTS=\(pts)] \(preview)"
        // Avoid triple-sinking (Logger + NSLog + print) on a hot path.
        // Keep this DEBUG-only and sample to reduce stutter.
        if Int.random(in: 0..<10) == 0 {
            subtitleLog.info("\(line, privacy: .public)")
            NSLog("%@", line)
        }
#else
        _ = ptsMediaSeconds
        _ = text
        _ = maxChars
#endif
    }

    /// Log when a subtitle track is selected but overlay text never updates (e.g. timing mismatch or bitmap-only).
    static func renderSubtitleMissingInUI() {
        let line = "[Render] Subtitle not passed to UI layer (no text for current media time)"
        subtitleLog.notice("\(line, privacy: .public)")
#if DEBUG
        NSLog("%@", line)
#endif
    }

    /// Bitmap overlay pipeline (CoreGraphics today; `backend` may become `libass` when linked).
    static func subtitleOverlayRender(ptsMs: Int64, width: Int, height: Int, hasImage: Bool, backend: String) {
#if DEBUG
        let msg =
            "[Subtitle][Render] pts_ms=\(ptsMs) has_image=\(hasImage) backend=\(backend) bitmap=\(width)x\(height)"
        if Int.random(in: 0..<10) == 0 {
            subtitleLog.info("\(msg, privacy: .public)")
            NSLog("%@", msg)
        }
#else
        _ = ptsMs; _ = width; _ = height; _ = hasImage; _ = backend
#endif
    }

    /// Placement diagnostic for bitmap overlay view (frame computed in `AssBitmapOverlayContainerView.layoutSubviews`).
    static func subtitleOverlayPlacement(
        viewSize: CGSize,
        safeAreaInsets: UIEdgeInsets,
        imageSize: CGSize,
        imageScaleToFit: CGFloat,
        verticalOffset: CGFloat,
        bottomInset: CGFloat,
        imageFrame: CGRect,
        isHidden: Bool
    ) {
#if DEBUG
        let msg =
            "[Subtitle][Overlay][Place] view=\(Int(viewSize.width))x\(Int(viewSize.height)) " +
            "safe_bottom=\(Int(safeAreaInsets.bottom)) " +
            "img=\(Int(imageSize.width))x\(Int(imageSize.height)) fit_scale=\(String(format: "%.3f", imageScaleToFit)) " +
            "offset=\(String(format: "%.1f", verticalOffset)) bottom_inset=\(String(format: "%.1f", bottomInset)) " +
            "frame=(x=\(String(format: "%.1f", imageFrame.origin.x)) y=\(String(format: "%.1f", imageFrame.origin.y)) w=\(String(format: "%.1f", imageFrame.size.width)) h=\(String(format: "%.1f", imageFrame.size.height))) " +
            "hidden=\(isHidden)"
        // Placement spam is extremely expensive; sample heavily.
        if Int.random(in: 0..<30) == 0 {
            subtitleLog.info("\(msg, privacy: .public)")
            NSLog("%@", msg)
        }
#else
        _ = viewSize; _ = safeAreaInsets; _ = imageSize; _ = imageScaleToFit
        _ = verticalOffset; _ = bottomInset; _ = imageFrame; _ = isHidden
#endif
    }

    static func subtitleOverlayLayer(sizeWidth: Int, sizeHeight: Int) {
#if DEBUG
        let msg = "[Subtitle][Overlay] rendered bitmap size=\(sizeWidth)x\(sizeHeight)"
        if Int.random(in: 0..<10) == 0 {
            subtitleLog.info("\(msg, privacy: .public)")
            NSLog("%@", msg)
        }
#else
        _ = sizeWidth; _ = sizeHeight
#endif
    }

    static func subtitleNoActiveFrame() {
        let msg = "[Subtitle] No active subtitle frame"
        subtitleLog.debug("\(msg, privacy: .public)")
#if DEBUG
        NSLog("%@", msg)
#endif
    }

    /// Picture-in-Picture lifecycle (`AVPictureInPictureController` + sample-buffer layer).
    static func pip(_ message: String) {
        pipLog.info("\(message, privacy: .public)")
#if DEBUG
        NSLog("%@", message)
        print(message)
#endif
    }

    // MARK: - Pipeline sync debug (Step 8)

    /// A/V sync drift diagnostic (video decode loop, throttled to ~2Hz).
    static func syncDrift(audioClockSec: Double, videoPtsSec: Double, diffMs: Double) {
#if DEBUG
        let msg = String(
            format: "[Sync][drift] audio=%.3fs video=%.3fs Δ=%.1fms",
            audioClockSec, videoPtsSec, diffMs
        )
        syncLog.info("\(msg, privacy: .public)")
#else
        _ = audioClockSec; _ = videoPtsSec; _ = diffMs
#endif
    }

    /// Drift alert: emitted when |drift| > 100ms.
    static func driftAlert(diffMs: Double) {
        let msg = String(format: "[Sync][ALERT] A/V drift=%.1fms (>100ms threshold)", diffMs)
        syncLog.warning("\(msg, privacy: .public)")
#if DEBUG
        NSLog("%@", msg)
#endif
    }

    /// Decode path diagnostic: hardware vs software, resolution. Emitted once per session.
    static func decodePath(format: String, isHardware: Bool, resolution: String) {
        let hw = isHardware ? "hardware" : "software"
        let msg = "[Decode] path=\(hw) format=\(format) resolution=\(resolution)"
        videoLog.info("\(msg, privacy: .public)")
#if DEBUG
        NSLog("%@", msg)
#endif
    }
}

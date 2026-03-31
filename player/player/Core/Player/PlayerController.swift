import AVFoundation
import Foundation
import UIKit

/// Logic layer for the FFmpeg pipeline: seek, tracks, subtitle sync. UI binds to `state`.
@MainActor
final class PlayerController {
    let state: PlayerState
    private let engine: FFmpegPlaybackEngine
#if os(iOS)
    private var pipCoordinator: PictureInPictureCoordinator?
#endif
    /// Avoid duplicate overlay logs / re-raster when cue unchanged.
    private var lastSubtitleOverlaySignature: String?
    private var hadActiveSubtitleFrame = false
    private var subtitleStyle = SubtitleBitmapRenderer.Style(
        fontSize: 18,
        textColor: .white,
        backgroundColor: UIColor.black.withAlphaComponent(0.45),
        isBoldEnabled: false
    )
    private var subtitlesEnabled = true
    private var lastSubtitleNoFrameLogTime: Double?
    private var lastSubtitlesDisabledLog = false
    private var lastSubtitleStatusLogTime: Double?
    private var pendingSubtitleDebounceWork: DispatchWorkItem?
    private var lastSubtitleRenderedAt: CFTimeInterval?
    private let subtitleRenderQueue = DispatchQueue(label: "com.nvv.player.subtitle.render", qos: .userInitiated)
    private var lastLibassHashLogSignature: String?

    var sampleRenderer: SampleBufferRenderer { engine.sampleRenderer }

    init(url: URL, externalSubtitleURLs: [URL] = [], enableLibass: Bool = false) {
        let state = PlayerState()
        self.state = state
        let engine = FFmpegPlaybackEngine(
            playerState: state,
            mediaURL: url,
            externalSubtitleURLs: externalSubtitleURLs,
            enableLibass: enableLibass
        )
        self.engine = engine
        engine.onPlaybackTick = { [weak self] mediaSeconds in
            self?.updateSubtitle(currentTime: mediaSeconds)
        }
    }

    func startPlayback() {
        engine.startPlayback()
    }

    func stopPlayback() {
        engine.stopPlayback()
    }

    func togglePause() {
        engine.togglePause()
    }

    func toggleZoom() {
        state.isZoomed.toggle()
        sampleRenderer.setZoomed(state.isZoomed)
    }

    func applySubtitleSettings(
        fontSize: Double,
        textColor: UIColor,
        backgroundColor: UIColor?,
        position: Double,
        isEnabled: Bool,
        isBoldEnabled: Bool
    ) {
        subtitleStyle = SubtitleBitmapRenderer.Style(
            fontSize: CGFloat(fontSize),
            textColor: textColor,
            backgroundColor: backgroundColor,
            isBoldEnabled: isBoldEnabled
        )
        subtitlesEnabled = isEnabled
        state.subtitleOverlayVerticalOffset = position
        lastSubtitleOverlaySignature = nil
        lastSubtitlesDisabledLog = false
        updateSubtitle(currentTime: state.currentTime)
    }

    /// Used by PiP system controls; only toggles when state differs (same effect as user pause/play).
    func setPlaybackPlaying(_ playing: Bool) {
        if state.isPlaying != playing {
            togglePause()
        }
    }

#if os(iOS)
    /// Call after the sample-buffer display layer is attached (e.g. `PlayerView.onAppear`).
    func preparePictureInPicture(displayLayer: AVSampleBufferDisplayLayer) {
        if pipCoordinator == nil {
            pipCoordinator = PictureInPictureCoordinator(playerController: self)
        }
        pipCoordinator?.prepareIfNeeded(displayLayer: displayLayer)
    }

    func refreshPictureInPictureReadiness() {
        pipCoordinator?.refreshPictureInPicturePossible()
    }

    func startPictureInPicture() {
        pipCoordinator?.startPictureInPicture()
    }
#endif

    // MARK: - Seek (progress bar + jump)

    func beginScrubbing() {
        state.isScrubbing = true
        state.currentSubtitleText = nil
        state.subtitleOverlayImage = nil
        lastSubtitleOverlaySignature = nil
        hadActiveSubtitleFrame = false
        engine.beginScrubbing()
    }

    func endScrubbing(atSeconds seconds: Double) {
        state.isScrubbing = false
        engine.endScrubbing(atSeconds: seconds)
    }

    func seek(to time: Double) {
        engine.seek(to: time)
    }

    func skip(by delta: Double) {
        seek(to: state.currentTime + delta)
    }

    // MARK: - Audio

    func selectAudioTrack(_ index: Int) {
        engine.selectAudioTrack(index)
    }

    // MARK: - Subtitles

    func selectSubtitle(_ index: Int?) {
        lastSubtitleOverlaySignature = nil
        hadActiveSubtitleFrame = false
        let row = index ?? 0
        engine.selectSubtitle(row)
    }

    /// Call when overlay width changes so wrapped bitmap is re-rasterized.
    func invalidateSubtitleOverlayLayout() {
        lastSubtitleOverlaySignature = nil
        updateSubtitle(currentTime: state.currentTime)
    }

    func updateSubtitle(currentTime: Double) {
#if DEBUG
        if (lastSubtitleStatusLogTime == nil) || (currentTime - (lastSubtitleStatusLogTime ?? 0) > 1.0) {
            lastSubtitleStatusLogTime = currentTime
            PlaybackLog.subtitleSelection(
                "[Subtitle][UI][Status] t=\(String(format: "%.3f", currentTime))s scrubbing=\(state.isScrubbing) enabled=\(subtitlesEnabled) selected=\(state.selectedSubtitle)"
            )
        }
#endif
        // Right after seek, avoid doing bitmap subtitle rasterization on the hot UI path.
        // Debounce briefly until video enqueue stabilizes.
        if sampleRenderer.isRecoveringFromSeek() {
            pendingSubtitleDebounceWork?.cancel()
            let t = currentTime
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pendingSubtitleDebounceWork = nil
                self.updateSubtitle(currentTime: t)
            }
            pendingSubtitleDebounceWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
            return
        }
        if state.isScrubbing {
            return
        }
        if !subtitlesEnabled {
            if !lastSubtitlesDisabledLog {
                lastSubtitlesDisabledLog = true
                PlaybackLog.subtitleSelection("[Subtitle][UI] rendering disabled by settings (isEnabled=false)")
            }
            if state.subtitleOverlayImage != nil || state.currentSubtitleText != nil {
                state.subtitleOverlayImage = nil
                state.currentSubtitleText = nil
                lastSubtitleOverlaySignature = nil
            }
            hadActiveSubtitleFrame = false
            return
        }
        lastSubtitlesDisabledLog = false
        if state.selectedSubtitle == 0 {
            if state.subtitleOverlayImage != nil || state.currentSubtitleText != nil {
                state.subtitleOverlayImage = nil
                state.currentSubtitleText = nil
                lastSubtitleOverlaySignature = nil
            }
            hadActiveSubtitleFrame = false
            return
        }

        guard let frame = engine.subtitleOverlayFrame(forMediaTime: currentTime) else {
            if (lastSubtitleNoFrameLogTime == nil) || (currentTime - (lastSubtitleNoFrameLogTime ?? 0) > 1.0) {
                lastSubtitleNoFrameLogTime = currentTime
                let stats = engine.debugSubtitleCueStats(forMediaTime: currentTime)
                let first = stats.firstStart.map { String(format: "%.3f", $0) } ?? "nil"
                let last = stats.lastEnd.map { String(format: "%.3f", $0) } ?? "nil"
                PlaybackLog.subtitleSelection(
                    "[Subtitle][UI] no active cue at t=\(String(format: "%.3f", currentTime))s selected=\(stats.selectedRow) cues=\(stats.cueCount) range=[\(first), \(last)]"
                )
            }
            if hadActiveSubtitleFrame {
                PlaybackLog.subtitleNoActiveFrame()
            }
            hadActiveSubtitleFrame = false
            if state.subtitleOverlayImage != nil || state.currentSubtitleText != nil {
                state.subtitleOverlayImage = nil
                state.subtitleOverlayIsFullFrame = false
                state.currentSubtitleText = nil
                lastSubtitleOverlaySignature = nil
            }
            return
        }

        hadActiveSubtitleFrame = true
        lastSubtitleNoFrameLogTime = nil

        // Bitmap subtitle image (PGS/DVB/DVD): display the decoded image directly.
        if let bmp = frame.bitmapImage {
            let w = max(60, state.subtitleLayoutWidth)
            let scale = max(1.0, state.subtitleDisplayScale)
            let widthBucket = Int((w / 8.0).rounded(.down)) * 8
            let scaleBucket = Int((scale * 10.0).rounded())
            let sig = "bmp|\(frame.ptsMs)|\(Int(bmp.size.width))x\(Int(bmp.size.height))|w\(widthBucket)|s\(scaleBucket)"
            guard sig != lastSubtitleOverlaySignature else { return }
            lastSubtitleOverlaySignature = sig
            state.currentSubtitleText = nil
            state.subtitleOverlayIsFullFrame = true
            state.subtitleOverlayImage = bmp
            return
        }

        // Avoid expensive re-rasterization when layout width/scale fluctuate by tiny amounts.
        // Bucket width/scale so 1px layout jitter doesn't invalidate the signature.
        let w = max(60, state.subtitleLayoutWidth)
        let scale = max(1.0, state.subtitleDisplayScale)
        let widthBucket = Int((w / 8.0).rounded(.down)) * 8
        let scaleBucket = Int((scale * 10.0).rounded()) // 0.1 steps
        let styleSig = "\(subtitleStyle.fontSize)|\(subtitleStyle.textColor.description)|\(String(describing: subtitleStyle.backgroundColor))|\(subtitleStyle.isBoldEnabled ? 1 : 0)|off=\(String(format: "%.1f", state.subtitleOverlayVerticalOffset))|h=\(Int(state.subtitleLayoutHeight))"
        let sig = "\(frame.plainText)|\(frame.ptsMs)|\(frame.assRaw ?? "")|w\(widthBucket)|s\(scaleBucket)|\(styleSig)"
        guard sig != lastSubtitleOverlaySignature else { return }
        lastSubtitleOverlaySignature = sig

        state.currentSubtitleText = frame.plainText
        state.subtitleOverlayIsFullFrame = false
        // Throttle UI subtitle render logging/rasterization in very hot scenarios (post-seek recovery).
        let now = CACurrentMediaTime()
        if sampleRenderer.isRecoveringFromSeek(),
           let last = lastSubtitleRenderedAt,
           (now - last) < 0.25 {
            return
        }
        lastSubtitleRenderedAt = now
        PlaybackLog.renderSubtitle(ptsMediaSeconds: currentTime, text: frame.plainText)

        // Render subtitles off the main thread to avoid UI hitches that can manifest as "video stutter".
        let renderSig = sig
        let renderText = frame.plainText
        let renderAss = frame.assRaw
        let renderPtsMs = frame.ptsMs
        let renderMaxWidth = w
        let renderCanvasHeight = max(60, state.subtitleLayoutHeight)
        let renderScale = scale
        let renderStyle = subtitleStyle
        let renderVerticalOffset = CGFloat(state.subtitleOverlayVerticalOffset)
        subtitleRenderQueue.async { [weak self] in
            guard let self else { return }
            let img: UIImage? = {
                if Settings.shared.enableLibass {
                    let cfg = LibassStyleConfig(
                        fontSize: renderStyle.fontSize,
                        isBold: renderStyle.isBoldEnabled,
                        textColor: renderStyle.textColor,
                        backgroundColor: renderStyle.backgroundColor,
                        verticalOffset: renderVerticalOffset
                    )
                    return LibassSubtitleOneshotRenderer.shared.render(
                        plainText: renderText,
                        assRaw: renderAss,
                        canvasWidth: renderMaxWidth,
                        canvasHeight: renderCanvasHeight,
                        displayScale: renderScale,
                        styleConfig: cfg
                    )
                }
                return SubtitleBitmapRenderer.render(
                    plainText: renderText,
                    assRaw: renderAss,
                    maxWidth: renderMaxWidth,
                    displayScale: renderScale,
                    style: renderStyle
                )
            }()
            Task { @MainActor in
                // Drop stale work if a newer subtitle/frame/style was selected.
                guard self.lastSubtitleOverlaySignature == renderSig else { return }
                self.state.subtitleOverlayImage = img
                self.state.subtitleOverlayIsFullFrame = Settings.shared.enableLibass
                if let img {
                    let sz = img.size
                    PlaybackLog.subtitleOverlayRender(
                        ptsMs: renderPtsMs,
                        width: Int(sz.width * renderScale),
                        height: Int(sz.height * renderScale),
                        hasImage: true,
                        backend: Settings.shared.enableLibass ? "libass" : "CoreGraphics"
                    )
                    PlaybackLog.subtitleOverlayLayer(
                        sizeWidth: Int(sz.width * renderScale),
                        sizeHeight: Int(sz.height * renderScale)
                    )
                } else {
                    PlaybackLog.subtitleOverlayRender(
                        ptsMs: renderPtsMs,
                        width: 0,
                        height: 0,
                        hasImage: false,
                        backend: Settings.shared.enableLibass ? "libass" : "CoreGraphics"
                    )
                }
            }
        }
    }
}

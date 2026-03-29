import AVFoundation
import Combine
import CoreMedia
import Foundation
import QuartzCore

// MARK: - Cue storage (playback thread writes; main reads for overlay — lock protects embedded list)

/// FFmpeg demux/decode + `AVSampleBufferDisplayLayer` video + `AVAudioEngine` audio.
/// Seek uses `avformat_seek_file` on the `AVFormatContext` (demuxer), then `avcodec_flush_buffers` on decoders — equivalent pipeline to `av_seek_frame` + flush.
final class FFmpegPlaybackEngine {
    private let playbackQueue = DispatchQueue(label: "com.nvv.player.playback", qos: .userInitiated)

    private var demuxer = FFmpegDemuxer()
    private let videoDecoder = CoreVideoDecoder()
    private let audioDecoder = CoreAudioDecoder()
    private let subtitleDecoder = CoreSubtitleDecoder()
    let sampleRenderer = SampleBufferRenderer()

    private var audioEngine: AVAudioEngine?
    private var audioPlayerNode: AVAudioPlayerNode?
    private var cachedPlayerNodeBusFormat: AVAudioFormat?
    private var decoderAudioStreamIndex: Int = -1
    private var installedAudioEngineSignature: String?

    private var sessionRunning = false
    /// Serialized by `playbackStateLock`. Never update seek/scrub/pause **only** via `playbackQueue.async`: the packet loop holds the serial queue until EOF, so those blocks would never run during playback.
    private var presentationPaused = false
    /// While `true`, the demux/decode loop idles so scrubbing does not decode continuously; seek runs on release.
    private var scrubbingActive = false
    private var pendingSeekSeconds: Double?
    /// Demuxer list index (`audioStreamIndices`); applied on playback thread before `performSeek` (must not use `playbackQueue.async` — same issue as seek).
    private var pendingAudioTrackListIndex: Int?
    /// When true, reopen audio decoder/engine for the newly selected stream without forcing a seek.
    private var pendingAudioReopenForSwitch = false
    private let playbackStateLock = NSLock()
    private let timelineLock = NSLock()
    private var mediaTimelineAnchor: Double = 0
    /// During seek we briefly suppress display-link clock updates until `flushForSeek()+setMediaTimelineAnchor`
    /// has been applied on the main thread (prevents visible clock jumps without blocking decode thread).
    private var suppressDisplayLinkTicks: Bool = false
    private let seekMetricsLock = NSLock()
    private var lastSeekStartHostTime: CFTimeInterval?
    private var lastSeekTargetSeconds: Double?
    private var lastSeekAppliedOnMainHostTime: CFTimeInterval?
    private var lastSeekMainScheduledHostTime: CFTimeInterval?

    private func mediaTimelineAnchorValue() -> Double {
        timelineLock.lock()
        defer { timelineLock.unlock() }
        return mediaTimelineAnchor
    }

    private func setMediaTimelineAnchor(_ value: Double) {
        timelineLock.lock()
        mediaTimelineAnchor = value
        timelineLock.unlock()
    }

    private func setSuppressDisplayLinkTicks(_ value: Bool) {
        timelineLock.lock()
        suppressDisplayLinkTicks = value
        timelineLock.unlock()
    }

    private func isSuppressDisplayLinkTicks() -> Bool {
        timelineLock.lock()
        defer { timelineLock.unlock() }
        return suppressDisplayLinkTicks
    }

    // MARK: - Seek / scrub / pause (thread-safe; packet loop runs on playback queue without yielding)

    private func takePendingSeekSecondsIfAny() -> Double? {
        playbackStateLock.lock()
        defer { playbackStateLock.unlock() }
        let v = pendingSeekSeconds
        pendingSeekSeconds = nil
        return v
    }

    private func hasPendingSeekRequest() -> Bool {
        playbackStateLock.lock()
        defer { playbackStateLock.unlock() }
        return pendingSeekSeconds != nil
    }

    private func setPendingSeekSeconds(_ value: Double?) {
        playbackStateLock.lock()
        defer { playbackStateLock.unlock() }
        pendingSeekSeconds = value
    }

    private func takePendingAudioTrackListIndexIfAny() -> Int? {
        playbackStateLock.lock()
        defer { playbackStateLock.unlock() }
        let v = pendingAudioTrackListIndex
        pendingAudioTrackListIndex = nil
        return v
    }

    private func takePendingAudioReopenForSwitchIfAny() -> Bool {
        playbackStateLock.lock()
        defer { playbackStateLock.unlock() }
        let v = pendingAudioReopenForSwitch
        pendingAudioReopenForSwitch = false
        return v
    }

    /// Like seek: set under lock from `@MainActor` so `packetLoop` (same serial queue) can apply while playing.
    /// Soft switch: do **not** force a seek (seeking + display-layer flush is what causes visible stutter on some devices).
    private func setPendingAudioTrackSwitch(listIndex: Int) {
        playbackStateLock.lock()
        pendingAudioTrackListIndex = listIndex
        pendingAudioReopenForSwitch = true
        playbackStateLock.unlock()
    }

    private func isScrubbingActive() -> Bool {
        playbackStateLock.lock()
        defer { playbackStateLock.unlock() }
        return scrubbingActive
    }

    private func setScrubbingActive(_ value: Bool) {
        playbackStateLock.lock()
        defer { playbackStateLock.unlock() }
        scrubbingActive = value
    }

    private func isPresentationPaused() -> Bool {
        playbackStateLock.lock()
        defer { playbackStateLock.unlock() }
        return presentationPaused
    }

    private func resetPlaybackControlStateForNewSession() {
        playbackStateLock.lock()
        pendingSeekSeconds = nil
        pendingAudioTrackListIndex = nil
        pendingAudioReopenForSwitch = false
        pendingSubtitleApplyIndex = nil
        scrubbingActive = false
        presentationPaused = false
        playbackStateLock.unlock()
    }

    /// Like seek: must not rely only on `playbackQueue.async` while `packetLoop` holds the serial queue.
    private var pendingSubtitleApplyIndex: Int?

    private func takePendingSubtitleApplyIndexIfAny() -> Int? {
        playbackStateLock.lock()
        defer { playbackStateLock.unlock() }
        let v = pendingSubtitleApplyIndex
        pendingSubtitleApplyIndex = nil
        return v
    }

    private func setPendingSubtitleApplyIndex(_ value: Int?) {
        playbackStateLock.lock()
        defer { playbackStateLock.unlock() }
        pendingSubtitleApplyIndex = value
    }

    private func hasPendingSubtitleApplyRequest() -> Bool {
        playbackStateLock.lock()
        defer { playbackStateLock.unlock() }
        return pendingSubtitleApplyIndex != nil
    }

    private var subtitleStreamIndex: Int = -1
    /// One bitmap “no text logging” line per embedded subtitle activation (codec-based or decode-rect fallback).
    private var loggedBitmapSubtitleNoText = false
    private let embeddedCueLock = NSLock()
    private var embeddedCues: [SubtitleCue] = []
    private var externalCues: [(URL, [SubtitleCue])] = []

    private var videoEnqueueLogCount = 0
    private var subtitleDecodeErrorCount = 0
    /// Set after `performSeek` when a video stream exists; cleared on first decoded video frame (watchdog for stuck seek).
    private var postSeekAwaitingFirstVideoFrame = false

    // MARK: - Post-seek buffering gate
    /// When true, video timebase and audio are held paused while buffers fill.
    private var postSeekBuffering = false
    private let bufferingMinVideoFrames = 8
    private let bufferingMinAudioSeconds: Double = 0.3

    /// Same constant offset applied to video PTS in `CoreVideoDecoder` so A/V share one media timeline.
    private var audioScheduleShiftSeconds: Double = 0
    private var audioSessionAnchorPtsSec: Double?
    /// End sample index of last scheduled buffer (avoids overlap when rounding).
    private var lastAudioScheduleEndSample: AVAudioFramePosition?
    /// Offset to convert cumulative `playerTime.sampleTime` to the relative timeline
    /// used by `lastAudioScheduleEndSample`. Set at each seek to the node’s current playhead.
    private var audioPlayheadSampleOffset: AVAudioFramePosition = 0

    /// Limits how far ahead of playback we push `scheduleBuffer` (reduces HAL “overload” from bursty scheduling).
    private let maxAudioScheduledAheadSeconds: Double = 1.5
    private let seekRecoveryLock = NSLock()
    private var audioSeekRecoveryUntilHostTime: CFTimeInterval = 0
    private let backlogMetricsLock = NSLock()
    private var lastAudioScheduledEndSeconds: Double = 0
    private var lastBacklogLogHostTime: CFTimeInterval = 0

    private let displayLinkDriver = DisplayLinkDriver()

    private let playerState: PlayerState

    /// Main-thread playback clock (media seconds); subtitle sync runs in `PlayerController.updateSubtitle`.
    var onPlaybackTick: ((Double) -> Void)?

    var mediaURL: URL?
    var externalSubtitleURLs: [URL] = []

    init(playerState: PlayerState, mediaURL: URL?, externalSubtitleURLs: [URL] = []) {
        self.playerState = playerState
        self.mediaURL = mediaURL
        self.externalSubtitleURLs = externalSubtitleURLs
        displayLinkDriver.onFire = { [weak self] in
            self?.onDisplayLink()
        }
    }

#if os(iOS) || os(tvOS) || targetEnvironment(macCatalyst)
    /// Configures `AVAudioSession` for movie playback. Deactivates first to reduce spurious `OSStatus -50` when reusing the same category.
    private static func configurePlaybackAudioSession(playerState: PlayerState) {
        let session = AVAudioSession.sharedInstance()
        do {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            // `defaultToSpeaker` is not applicable for `.playback` (only `.playAndRecord`).
            try session.setCategory(.playback, mode: .moviePlayback, options: [])
            try session.setActive(true)
            PlaybackLog.audio("AVAudioSession: category playback + active OK")
        } catch {
            if PlaybackLog.isBenignAudioSessionOSStatus50(error) {
                // Intentionally silent: -50 is common when re-applying category; logging it doubled Console noise.
            } else {
                Task { @MainActor in
                    playerState.alertMessage = "Audio session: \(error.localizedDescription)"
                }
            }
        }
    }
#endif

    @MainActor
    func startPlayback() {
        guard let url = mediaURL else {
            playerState.alertMessage = "Missing URL"
            return
        }
#if os(iOS) || os(tvOS) || targetEnvironment(macCatalyst)
        Self.configurePlaybackAudioSession(playerState: playerState)
#endif
        stopPlayback()
        sessionRunning = true
        resetPlaybackControlStateForNewSession()
        videoEnqueueLogCount = 0
        setMediaTimelineAnchor(0)
        embeddedCueLock.lock()
        embeddedCues.removeAll()
        embeddedCueLock.unlock()
        externalCues.removeAll()
        playerState.resetForNewMedia()
        playerState.title = url.lastPathComponent

        displayLinkDriver.start()

        sampleRenderer.onFirstFrameEnqueued = { [weak self] in
            Task { @MainActor in
                self?.playerState.isBuffering = false
            }
        }

        playbackQueue.async { [weak self] in
            guard let self else { return }
            defer {
                self.demuxer.close()
                self.videoDecoder.close()
                self.audioDecoder.close()
                self.subtitleDecoder.close()
                self.sessionRunning = false
            }
            do {
                self.audioSessionAnchorPtsSec = nil
                self.lastAudioScheduleEndSample = nil
                try self.openPipelines(url: url)
                self.loadExternalSubtitlesIfNeeded()
                var initialSub = 0
                DispatchQueue.main.sync {
                    initialSub = self.playerState.selectedSubtitle
                    self.sampleRenderer.beginPlaybackSession()
                }
                self.applySubtitleSelection(index: initialSub)
                try self.packetLoop()
            } catch {
                Task { @MainActor in
                    self.playerState.alertMessage = "Playback error: \(error.localizedDescription)"
                }
            }
        }
    }

    @MainActor
    func stopPlayback() {
        displayLinkDriver.stop()
        sessionRunning = false
        playbackQueue.sync { }
        if Thread.isMainThread {
            sampleRenderer.stop()
        } else {
            DispatchQueue.main.sync { [sampleRenderer] in
                sampleRenderer.stop()
            }
        }
        audioPlayerNode?.stop()
        audioEngine?.stop()
        audioEngine = nil
        audioPlayerNode = nil
    }

    @MainActor
    func seek(to seconds: Double) {
        let d = max(playerState.duration, 0.1)
        let clamped = max(0, min(seconds, d))
        PlaybackLog.seek("UI seek(to:) clamped=\(String(format: "%.3f", clamped))s (immediate, not queued)")
        setPendingSeekSeconds(clamped)
        playerState.isBuffering = true
    }

    @MainActor
    func selectAudioTrack(_ index: Int) {
        playerState.selectedAudio = index
        playerState.isBuffering = true
        guard index >= 0, index < playerState.audioTracks.count else {
            PlaybackLog.trackSelection("[Audio] switch SKIPPED invalid listIndex=\(index) tracks=\(playerState.audioTracks.count)")
            PlaybackLog.audio("[Audio][ERROR] invalid track index (list not ready or out of range)")
            return
        }
        let t = playerState.audioTracks[index]
        PlaybackLog.audio("[Audio] switching to track=\(index) streamIndex=\(t.streamIndex) title=\(t.displayTitle) (soft switch, no seek)")
        PlaybackLog.trackSelection(
            "[Audio] switched to track=\(index) streamIndex=\(t.streamIndex) title=\(t.displayTitle)"
        )
        setPendingAudioTrackSwitch(listIndex: index)
    }

    func selectSubtitle(_ index: Int) {
        Task { @MainActor in
            playerState.selectedSubtitle = index
            if index == 0 {
                PlaybackLog.subtitleSelection("[Subtitle] switched to track=0 (Off)")
            } else if index < playerState.subtitleTracks.count {
                let t = playerState.subtitleTracks[index]
                PlaybackLog.subtitleSelection(
                    "[Subtitle] switched to track=\(index) external=\(t.isExternal) title=\(t.displayTitle)"
                )
            }
        }
        setPendingSubtitleApplyIndex(index)
    }

    /// Idle demux/decode while the user drags the progress bar (seek on `endScrubbing`).
    func beginScrubbing() {
        PlaybackLog.seek("UI beginScrubbing (immediate)")
        setScrubbingActive(true)
    }

    /// Clear scrubbing and queue one seek on the playback queue (ordering vs `beginScrubbing` preserved).
    @MainActor
    func endScrubbing(atSeconds seconds: Double) {
        let d = max(playerState.duration, 0.1)
        let clamped = max(0, min(seconds, d))
        PlaybackLog.seek("UI endScrubbing(at:) clamped=\(String(format: "%.3f", clamped))s (immediate)")
        setScrubbingActive(false)
        setPendingSeekSeconds(clamped)
        playerState.isBuffering = true
    }

    /// Subtitle text for overlay at media timeline seconds (same basis as `currentTime` in `PlayerState`).
    @MainActor
    func subtitleText(forMediaTime fileTime: Double) -> String? {
        subtitleCue(forMediaTime: fileTime)?.text
    }

    /// Bitmap overlay + future libass: cue text, optional raw ASS, and start time in ms (media stream time).
    @MainActor
    func subtitleOverlayFrame(forMediaTime fileTime: Double) -> SubtitleOverlayFrame? {
        guard let cue = subtitleCue(forMediaTime: fileTime) else { return nil }
        let ms = Int64((cue.start * 1000.0).rounded())
        return SubtitleOverlayFrame(plainText: cue.text, assRaw: cue.assRaw, ptsMs: ms)
    }

    /// Debug-only helper: exposes basic cue stats for the currently selected subtitle track.
    /// Used to diagnose “decode logs exist but UI shows no subtitles”.
    @MainActor
    func debugSubtitleCueStats(forMediaTime fileTime: Double) -> (selectedRow: Int, cueCount: Int, firstStart: Double?, lastEnd: Double?) {
        let idx = playerState.selectedSubtitle
        guard idx > 0, idx < playerState.subtitleTracks.count else {
            return (selectedRow: idx, cueCount: 0, firstStart: nil, lastEnd: nil)
        }
        embeddedCueLock.lock()
        let cues = embeddedCues
        embeddedCueLock.unlock()
        let first = cues.first?.start
        let last = cues.last?.end
        _ = fileTime
        return (selectedRow: idx, cueCount: cues.count, firstStart: first, lastEnd: last)
    }

    /// Embedded cues use raw FFmpeg PTS in stream time; `currentTime` follows the video display clock (relative PTS + anchor + presentation shift).
    @MainActor
    private func subtitleCue(forMediaTime fileTime: Double) -> SubtitleCue? {
        let idx = playerState.selectedSubtitle
        guard idx > 0, idx < playerState.subtitleTracks.count else { return nil }
        let track = playerState.subtitleTracks[idx]
        if let url = track.externalURL {
            if let pair = externalCues.first(where: { $0.0 == url }) {
                return pair.1.first { fileTime >= $0.start && fileTime <= $0.end }
            }
            return nil
        }
        let origin = videoDecoder.mediaTimelineOriginSeconds()
        embeddedCueLock.lock()
        let cues = embeddedCues
        embeddedCueLock.unlock()
        // Prefer direct matching against UI media timeline (`PlayerState.currentTime`).
        // This is the most reliable when cue timestamps are already normalized to a 0-based (or seek-based) media timeline.
        if let cue = cues.first(where: { fileTime >= $0.start && fileTime <= $0.end }) {
            return cue
        }
        // Fallback: some files align subtitle PTS with an origin-shifted timeline derived from the video decoder.
        if let o = origin {
            let anchor = mediaTimelineAnchorValue()
            let shift = audioScheduleShiftSeconds
            let absoluteP = o + fileTime - anchor - shift
            if let cue = cues.first(where: { absoluteP >= $0.start && absoluteP <= $0.end }) {
                return cue
            }
        }
        return nil
    }

    @MainActor
    func togglePause() {
        playbackStateLock.lock()
        presentationPaused.toggle()
        let paused = presentationPaused
        playbackStateLock.unlock()
        playerState.isPlaying = !paused
        sampleRenderer.setPlaybackPaused(paused)
        if paused {
            audioPlayerNode?.pause()
        } else {
            audioPlayerNode?.play()
        }
    }

    // MARK: - Clock

    private func onDisplayLink() {
        if isSuppressDisplayLinkTicks() {
            return
        }
        let rel = sampleRenderer.presentationClockSeconds()
        let t = mediaTimelineAnchorValue() + rel
        MainActor.assumeIsolated {
            let clamped = min(max(0, t), playerState.duration)
            playerState.currentTime = clamped
            onPlaybackTick?(clamped)
        }

        // Backlog-driven logs: emit only when thresholds are exceeded (at most 2Hz).
        // This lets us see which subsystem is causing stalls without spamming per-frame logs.
        let now = CACurrentMediaTime()
        backlogMetricsLock.lock()
        let lastLog = lastBacklogLogHostTime
        let audioEnd = lastAudioScheduledEndSeconds
        backlogMetricsLock.unlock()
        if now - lastLog < 0.5 { return }

        let status = sampleRenderer.backlogStatus()
        let videoBacklogBad = status.fifoCount >= 18
        let audioBacklogBad = audioEnd >= 1.2
        if videoBacklogBad || audioBacklogBad || status.drainSuspended {
            backlogMetricsLock.lock()
            lastBacklogLogHostTime = now
            backlogMetricsLock.unlock()
            PlaybackLog.backlog(
                "video_fifo=\(status.fifoCount) drain_suspended=\(status.drainSuspended) recovering=\(status.isRecoveringFromSeek) " +
                    "req_media=\(status.isRequestingMediaData) ready=\(status.isReadyForMoreMediaData) layer=\(String(describing: status.displayStatus)) " +
                    "audio_scheduled_end=\(String(format: "%.3f", audioEnd))s"
            )
        }
    }

    // MARK: - Audio engine probe

    private func probePlayerNodeInputFormat() -> AVAudioFormat {
        if let cachedPlayerNodeBusFormat {
            return cachedPlayerNodeBusFormat
        }
        var result: AVAudioFormat!
        DispatchQueue.main.sync {
            let engine = AVAudioEngine()
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: nil)
            engine.prepare()
            result = node.outputFormat(forBus: 0)
        }
        cachedPlayerNodeBusFormat = result
        return result
    }

    /// (Re)builds `AVAudioEngine` + `AVAudioPlayerNode` for the decoder’s PCM format — required after **audio track switch** when sample rate/channels change.
    private func installAudioEngine(with format: AVAudioFormat) throws {
        let sig = "\(format.sampleRate)-\(format.channelCount)-\(format.isInterleaved ? 1 : 0)"
        if audioEngine != nil, audioPlayerNode != nil, installedAudioEngineSignature == sig {
            return
        }
        final class EngineBox: @unchecked Sendable {
            var engine: AVAudioEngine?
            var node: AVAudioPlayerNode?
            var error: Error?
        }
        let box = EngineBox()
        DispatchQueue.main.sync {
            audioEngine?.stop()
            audioPlayerNode?.stop()
            audioEngine = nil
            audioPlayerNode = nil
            let engine = AVAudioEngine()
            let node = AVAudioPlayerNode()
            engine.attach(node)
            do {
                engine.connect(node, to: engine.mainMixerNode, format: format)
                try engine.start()
                node.play()
                box.engine = engine
                box.node = node
            } catch {
                box.error = error
            }
        }
        if let err = box.error { throw err }
        audioEngine = box.engine
        audioPlayerNode = box.node
        installedAudioEngineSignature = sig
        PlaybackLog.audio("[Audio] engine restarted sampleRate=\(format.sampleRate) channels=\(format.channelCount)")
    }

    private func openPipelines(url: URL) throws {
        try demuxer.open(url: url)

        var videoPresentationShift: Double = 0
        if demuxer.videoStreamIndex >= 0, demuxer.audioStreamIndex >= 0 {
            let vStart = demuxer.streamMediaStartSeconds(streamIndex: demuxer.videoStreamIndex)
            let aStart = demuxer.streamMediaStartSeconds(streamIndex: demuxer.audioStreamIndex)
            if let vs = vStart, let aus = aStart {
                videoPresentationShift = max(0, aus - vs)
                PlaybackLog.sync(
                    "stream starts (s): video=\(String(format: "%.6f", vs)) audio=\(String(format: "%.6f", aus)) → video PTS shift=\(String(format: "%.6f", videoPresentationShift))"
                )
            }
        }
        audioScheduleShiftSeconds = videoPresentationShift

        if demuxer.videoStreamIndex >= 0, let vp = demuxer.videoCodecParameters() {
            try videoDecoder.open(codecpar: vp)
            videoDecoder.setPresentationShiftSeconds(videoPresentationShift)
        }
        if demuxer.audioStreamIndex >= 0, let ap = demuxer.audioCodecParameters() {
            let engineFmt = probePlayerNodeInputFormat()
            let aTb = demuxer.audioTimeBase()
            try audioDecoder.open(codecpar: ap, engineFormat: engineFmt, timeBase: aTb)
            decoderAudioStreamIndex = demuxer.audioStreamIndex
        }

        if let fmt = audioDecoder.outputFormat {
            try installAudioEngine(with: fmt)
        }

        let audio = Self.buildAudioTracks(demuxer: demuxer)
        let subs = Self.buildSubtitleTracks(demuxer: demuxer, externalURLs: externalSubtitleURLs)
        let dur = demuxer.durationSeconds
        let audioIdx = demuxer.activeAudioTrackListIndex()
        let titleText: String = {
            if let t = demuxer.formatTitleOrURL(), !t.hasPrefix("http") {
                return (t as NSString).lastPathComponent
            }
            if let t = demuxer.formatTitleOrURL() { return t }
            return ""
        }()
        DispatchQueue.main.async {
            self.playerState.audioTracks = audio
            self.playerState.subtitleTracks = subs
            self.playerState.duration = dur
            if !titleText.isEmpty { self.playerState.title = titleText }
            self.playerState.selectedAudio = audioIdx
            self.playerState.buffered = dur
        }
    }

    private static func buildAudioTracks(demuxer: FFmpegDemuxer) -> [AudioTrack] {
        demuxer.audioStreamIndices.enumerated().map { i, si in
            let info = demuxer.streamInfo(streamIndex: si)
            return AudioTrack(
                index: i,
                streamIndex: si,
                language: info?.language,
                codec: info?.codecName
            )
        }
    }

    private static func buildSubtitleTracks(demuxer: FFmpegDemuxer, externalURLs: [URL]) -> [SubtitleTrack] {
        var subs: [SubtitleTrack] = []
        subs.append(
            SubtitleTrack(
                index: 0,
                language: nil,
                isExternal: false,
                embeddedStreamIndex: nil,
                externalURL: nil,
                codec: nil
            )
        )
        var nid = 1
        for si in demuxer.subtitleStreamIndices {
            let info = demuxer.streamInfo(streamIndex: si)
            subs.append(
                SubtitleTrack(
                    index: nid,
                    language: info?.language,
                    isExternal: false,
                    embeddedStreamIndex: si,
                    externalURL: nil,
                    codec: info?.codecName
                )
            )
            nid += 1
        }
        for u in externalURLs {
            subs.append(
                SubtitleTrack(
                    index: nid,
                    language: nil,
                    isExternal: true,
                    embeddedStreamIndex: nil,
                    externalURL: u,
                    codec: nil
                )
            )
            nid += 1
        }
        return subs
    }

    private func loadExternalSubtitlesIfNeeded() {
        guard !externalSubtitleURLs.isEmpty else { return }
        var loaded: [(URL, [SubtitleCue])] = []
        for u in externalSubtitleURLs {
            if let data = try? Data(contentsOf: u), let s = String(data: data, encoding: .utf8) {
                let cues = ExternalSubtitleParser.parseSRT(data: s)
                loaded.append((u, cues))
            }
        }
        DispatchQueue.main.async {
            self.externalCues = loaded
        }
    }

    private func applySubtitleSelection(index: Int) {
        embeddedCueLock.lock()
        embeddedCues.removeAll()
        embeddedCueLock.unlock()
        subtitleDecoder.close()
        subtitleStreamIndex = -1
        loggedBitmapSubtitleNoText = false
        subtitleDecodeErrorCount = 0
        guard index > 0 else { return }
        let embeddedCount = demuxer.subtitleStreamIndices.count
        if index <= embeddedCount {
            let si = demuxer.subtitleStreamIndices[index - 1]
            guard let par = demuxer.codecParameters(streamIndex: si) else {
                PlaybackLog.subtitleSelection("subtitle decoder open FAILED: no codec parameters streamIndex=\(si)")
                return
            }
            do {
                try subtitleDecoder.open(codecpar: par)
                subtitleStreamIndex = si
                if Self.isBitmapSubtitleCodec(par.pointee.codec_id) {
                    logBitmapSubtitleUnsupportedOnce(streamIndex: si, uiTrackRow: index, detail: "bitmap_codec \(demuxer.streamInfo(streamIndex: si)?.codecName ?? "?")")
                }
                let cname = demuxer.streamInfo(streamIndex: si)?.codecName ?? "?"
                PlaybackLog.subtitleSelection(
                    "subtitle decoder open OK streamIndex=\(si) codec=\(cname) (soft switch, no seek)"
                )
            } catch {
                subtitleStreamIndex = -1
                PlaybackLog.subtitleSelection(
                    "subtitle decoder open FAILED streamIndex=\(si) \(error.localizedDescription)"
                )
            }
        } else {
            PlaybackLog.subtitleSelection("subtitle external track — using preloaded cues (no embedded decoder)")
        }
    }

    private func logBitmapSubtitleUnsupportedOnce(streamIndex: Int, uiTrackRow: Int?, detail: String) {
        guard !loggedBitmapSubtitleNoText else { return }
        loggedBitmapSubtitleNoText = true
        PlaybackLog.subtitleBitmapNoTextLog(streamIndex: streamIndex, uiTrackRow: uiTrackRow, detail: detail)
    }

    private static func isBitmapSubtitleCodec(_ id: AVCodecID) -> Bool {
        switch id {
        case AV_CODEC_ID_HDMV_PGS_SUBTITLE,
             AV_CODEC_ID_DVB_SUBTITLE,
             AV_CODEC_ID_DVD_SUBTITLE,
             AV_CODEC_ID_XSUB:
            return true
        default:
            return false
        }
    }

    /// Playback timeline in seconds — `sampleRenderer` clock must be read on the main thread.
    private func currentFileTimeSeconds() -> Double {
        let anchor = mediaTimelineAnchorValue()
        let rel: Double
        if Thread.isMainThread {
            rel = sampleRenderer.presentationClockSeconds()
        } else {
            rel = DispatchQueue.main.sync { sampleRenderer.presentationClockSeconds() }
        }
        return anchor + rel
    }

    /// Schedules PCM on the player timeline using FFmpeg PTS + the same shift as `CoreVideoDecoder` (lip-sync).
    private func scheduleAudioBuffer(_ buffer: AVAudioPCMBuffer, ptsStartSec: Double, outputFormat: AVAudioFormat) {
        guard let node = audioPlayerNode else { return }
        if audioSessionAnchorPtsSec == nil {
            audioSessionAnchorPtsSec = ptsStartSec
        }
        let anchor = audioSessionAnchorPtsSec!
        var relSec = (ptsStartSec - anchor) + audioScheduleShiftSeconds
        if relSec < 0 { relSec = 0 }
        let sr = outputFormat.sampleRate
        var sampleTime = AVAudioFramePosition((relSec * sr).rounded())
        if let end = lastAudioScheduleEndSample, sampleTime < end {
            sampleTime = end
        }
        let when = AVAudioTime(sampleTime: sampleTime + audioPlayheadSampleOffset, atRate: sr)
        node.scheduleBuffer(buffer, at: when, options: [], completionHandler: nil)
        lastAudioScheduleEndSample = sampleTime + AVAudioFramePosition(buffer.frameLength)
        backlogMetricsLock.lock()
        lastAudioScheduledEndSeconds = Double(lastAudioScheduleEndSample ?? 0) / sr
        backlogMetricsLock.unlock()
        paceAudioSchedulingIfNeeded(outputFormat: outputFormat)
    }

    /// Slows the demux thread when audio is scheduled far ahead of the audible playhead (same timeline as `sampleTime`).
    private func paceAudioSchedulingIfNeeded(outputFormat: AVAudioFormat) {
        guard sessionRunning, let node = audioPlayerNode, let end = lastAudioScheduleEndSample else { return }
        let sr = outputFormat.sampleRate
        let scheduledEndSec = Double(end) / sr
        // During seek recovery, be more conservative to avoid scheduling bursts that cause hitches.
        let now = CACurrentMediaTime()
        seekRecoveryLock.lock()
        let recoveringAudio = now < audioSeekRecoveryUntilHostTime
        seekRecoveryLock.unlock()
        let aheadLimit = recoveringAudio ? 0.5 : maxAudioScheduledAheadSeconds

        if let nodeTime = node.lastRenderTime,
           let playerTime = node.playerTime(forNodeTime: nodeTime) {
            // Subtract audioPlayheadSampleOffset so the playhead is on the same
            // relative timeline as lastAudioScheduleEndSample (which resets to 0 at seek).
            let relativeSample = playerTime.sampleTime - audioPlayheadSampleOffset
            let playheadSec = Double(relativeSample) / sr
            var ahead = scheduledEndSec - playheadSec
            while ahead > aheadLimit && sessionRunning {
                Thread.sleep(forTimeInterval: recoveringAudio ? 0.005 : 0.008)
                guard let nt = node.lastRenderTime,
                      let pt = node.playerTime(forNodeTime: nt) else { break }
                let relSample = pt.sampleTime - audioPlayheadSampleOffset
                ahead = scheduledEndSec - Double(relSample) / sr
            }
            return
        }

        // Before first render: `lastRenderTime` is nil so we can't compare against the
        // playhead. Block proportionally to how far ahead we've scheduled to prevent
        // the runaway where 20+ seconds of audio accumulate before video has started.
        if scheduledEndSec > aheadLimit {
            let excess = scheduledEndSec - aheadLimit
            let sleepTime = min(excess * 0.8, 0.1) // sleep up to 100ms, proportional to excess
            Thread.sleep(forTimeInterval: sleepTime)
        }
    }

    private func packetLoop() throws {
        guard let packet = demuxer.currentPacket else { return }

        while sessionRunning {
            if let audioListIdx = takePendingAudioTrackListIndexIfAny() {
                demuxer.setActiveAudioTrackIndex(audioListIdx)
                PlaybackLog.audio(
                    "[Audio] demuxer active streamIndex=\(demuxer.audioStreamIndex) listIndex=\(audioListIdx)"
                )
                if takePendingAudioReopenForSwitchIfAny(), demuxer.audioStreamIndex >= 0, let ap = demuxer.audioCodecParameters() {
                    do {
                        let engineFmt = probePlayerNodeInputFormat()
                        let aTb = demuxer.audioTimeBase()
                        try audioDecoder.open(codecpar: ap, engineFormat: engineFmt, timeBase: aTb)
                        decoderAudioStreamIndex = demuxer.audioStreamIndex
                        audioSessionAnchorPtsSec = nil
                        lastAudioScheduleEndSample = nil
                        PlaybackLog.audio("[Audio] soft-switch decoder reopened + schedule reset (no seek)")
                        if let fmt = audioDecoder.outputFormat {
                            try installAudioEngine(with: fmt)
                        }
                    } catch {
                        PlaybackLog.audio("[Audio][ERROR] soft-switch reopen failed: \(error.localizedDescription)")
                    }
                }
            }
            if let seek = takePendingSeekSecondsIfAny() {
                try performSeek(to: seek)
            }

            if let subIdx = takePendingSubtitleApplyIndexIfAny() {
                applySubtitleSelection(index: subIdx)
            }

            if isScrubbingActive() {
                Thread.sleep(forTimeInterval: 0.02)
                continue
            }

            if isPresentationPaused() {
                Thread.sleep(forTimeInterval: 0.02)
                continue
            }

            let has: Bool
            do {
                has = try demuxer.readPacket()
            } catch {
                throw error
            }
            if !has { break }

            let idx = Int(packet.pointee.stream_index)

            if idx == demuxer.videoStreamIndex {
                try videoDecoder.sendPacket(packet)
                while sessionRunning && !hasPendingSeekRequest() && !hasPendingSubtitleApplyRequest() {
                    let sb = try videoDecoder.receiveSampleBuffer(timeBase: demuxer.videoTimeBase())
                    guard let sample = sb else { break }
                    if !sessionRunning { break }
                    logVideoFrameIfNeeded(sample)
                    sampleRenderer.pushDecodedFrame(sample)
                }
                checkBufferingGate()
            } else if idx == demuxer.audioStreamIndex {
                try audioDecoder.sendPacket(packet)
                while sessionRunning && !hasPendingSeekRequest() && !hasPendingSubtitleApplyRequest() {
                    guard let (buffer, ptsStartSec) = try audioDecoder.receivePCM() else { break }
                    guard let fmt = audioDecoder.outputFormat else { break }
                    scheduleAudioBuffer(buffer, ptsStartSec: ptsStartSec, outputFormat: fmt)
                }
                checkBufferingGate()
            } else if subtitleStreamIndex >= 0, idx == subtitleStreamIndex {
                let tb = demuxer.timeBase(streamIndex: subtitleStreamIndex)
                let nopts = Self.avNoptsInt64()
                let ptsTicks: Int64
                if packet.pointee.pts != nopts {
                    ptsTicks = packet.pointee.pts
                } else if packet.pointee.dts != nopts {
                    ptsTicks = packet.pointee.dts
                } else {
                    ptsTicks = nopts
                }
                let uiRow = demuxer.subtitleStreamIndices.firstIndex(of: subtitleStreamIndex).map { $0 + 1 }
                do {
                    let outcome = try subtitleDecoder.decode(packet: packet, timeBase: tb)
                    if outcome.bitmapFrameWithoutText {
                        logBitmapSubtitleUnsupportedOnce(
                            streamIndex: subtitleStreamIndex,
                            uiTrackRow: uiRow,
                            detail: "decode_bitmap_rects_only"
                        )
                    }
                    if let cue = outcome.cue {
                        // Cue times are derived from packet PTS × time_base (+ display_time).
                        // Many files include a non-zero `AVStream.start_time` for subtitles, so decoded PTS can look like ~1287s while UI time is ~0..duration.
                        // Normalize cues to a 0-based media timeline by subtracting the subtitle stream's `start_time` (in seconds) when available.
                        let normalizedCue: SubtitleCue = {
                            guard let st0 = demuxer.streamMediaStartSeconds(streamIndex: subtitleStreamIndex) else {
                                return cue
                            }
                            let start = max(0, cue.start - st0)
                            let end = max(start, cue.end - st0)
                            return SubtitleCue(start: start, end: end, text: cue.text, assRaw: cue.assRaw)
                        }()

                        embeddedCueLock.lock()
                        embeddedCues.append(normalizedCue)
                        embeddedCueLock.unlock()
                        PlaybackLog.subtitleDecodedText(
                            streamIndex: subtitleStreamIndex,
                            uiTrackRow: uiRow,
                            ptsTicks: ptsTicks,
                            mediaSeconds: normalizedCue.start,
                            text: normalizedCue.text,
                            rectKind: outcome.rectKindSummary
                        )
                    }
                } catch {
                    subtitleDecodeErrorCount += 1
                    if subtitleDecodeErrorCount <= 8 || subtitleDecodeErrorCount % 128 == 0 {
                        PlaybackLog.subtitleDecodeFailure(
                            "decode error stream=\(subtitleStreamIndex) pktPts=\(packet.pointee.pts) pktDts=\(packet.pointee.dts) size=\(packet.pointee.size) err=\(error.localizedDescription) (#\(subtitleDecodeErrorCount))"
                        )
                    }
                }
            }

            av_packet_unref(packet)
        }
    }

    private func performSeek(to seconds: Double) throws {
        PlaybackLog.seek("requested=\(String(format: "%.3f", seconds))s")
        seekMetricsLock.lock()
        lastSeekStartHostTime = CACurrentMediaTime()
        lastSeekTargetSeconds = seconds
        lastSeekAppliedOnMainHostTime = nil
        lastSeekMainScheduledHostTime = nil
        seekMetricsLock.unlock()

        // Clear queued frames immediately; recovery window is set AFTER the network seek completes
        // so it covers the actual decode burst, not the network I/O wait.
        sampleRenderer.clearQueuedFramesForSeek()
        sampleRenderer.setDrainSuspended(true)
        setSuppressDisplayLinkTicks(true)
        var scheduledMainFlush = false
        // Never leave the UI clock suppressed if seek fails early.
        defer {
            if isSuppressDisplayLinkTicks() {
                setSuppressDisplayLinkTicks(false)
            }
            // Only resume draining here if we never got to schedule the main-thread flush.
            // On the success path, draining is resumed by the main-thread flush block.
            if !scheduledMainFlush {
                self.sampleRenderer.setDrainSuspended(false)
            }
        }
        // Safety valve: if main queue is overloaded and doesn't run the flush promptly,
        // ensure display-link ticks resume rather than getting "stuck".
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            self.setSuppressDisplayLinkTicks(false)
        }

        // Schedule UI-side flush+anchor immediately so the main queue doesn't wait for demuxer.seek/decoder work.
        scheduledMainFlush = true
        seekMetricsLock.lock()
        lastSeekMainScheduledHostTime = CACurrentMediaTime()
        seekMetricsLock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.sampleRenderer.flushForSeek()
            self.setMediaTimelineAnchor(seconds)
            self.sampleRenderer.setDrainSuspended(false)
            self.sampleRenderer.requestDrain()
            self.seekMetricsLock.lock()
            self.lastSeekAppliedOnMainHostTime = CACurrentMediaTime()
            self.seekMetricsLock.unlock()
            self.setSuppressDisplayLinkTicks(false)
        }

        videoDecoder.setSeekTarget(seconds)
        videoDecoder.prepareForSeek()
        audioDecoder.prepareForSeek()
        PlaybackLog.audio("[Audio] decoder flushed (prepareForSeek)")
        subtitleDecoder.prepareForSeek()
        PlaybackLog.seek("Decoder flushed (video+audio+subtitle buffers)")

        try demuxer.seek(toSeconds: seconds, flags: 0)

        if demuxer.videoStreamIndex >= 0, demuxer.audioStreamIndex >= 0 {
            let vStart = demuxer.streamMediaStartSeconds(streamIndex: demuxer.videoStreamIndex)
            let aStart = demuxer.streamMediaStartSeconds(streamIndex: demuxer.audioStreamIndex)
            if let vs = vStart, let aus = aStart {
                audioScheduleShiftSeconds = max(0, aus - vs)
                PlaybackLog.audio(
                    "[Audio] A/V shift recomputed=\(String(format: "%.6f", audioScheduleShiftSeconds))s (video vs audio start)"
                )
            }
        }

        embeddedCueLock.lock()
        embeddedCues.removeAll()
        embeddedCueLock.unlock()
        subtitleDecodeErrorCount = 0
        audioSessionAnchorPtsSec = nil
        lastAudioScheduleEndSample = nil
        // Capture the node’s current playhead so pacing compares on the same relative timeline.
        if let node = audioPlayerNode,
           let nt = node.lastRenderTime,
           let pt = node.playerTime(forNodeTime: nt) {
            audioPlayheadSampleOffset = pt.sampleTime
        }
        PlaybackLog.audio("[Audio] schedule state cleared (anchor + queued sample cursor)")

        // Audio seek: avoid restarting audio engine on every seek (can cause visible stutter on some devices).
        // Only reopen decoder / reinstall engine when the active audio stream changed (e.g. user switched audio track).
        if demuxer.audioStreamIndex >= 0, demuxer.audioStreamIndex != decoderAudioStreamIndex, let ap = demuxer.audioCodecParameters() {
            let engineFmt = probePlayerNodeInputFormat()
            let aTb = demuxer.audioTimeBase()
            try audioDecoder.open(codecpar: ap, engineFormat: engineFmt, timeBase: aTb)
            decoderAudioStreamIndex = demuxer.audioStreamIndex
            if let fmt = audioDecoder.outputFormat {
                try installAudioEngine(with: fmt)
            }
        }
        if subtitleStreamIndex >= 0, let sp = demuxer.codecParameters(streamIndex: subtitleStreamIndex) {
            do {
                try subtitleDecoder.open(codecpar: sp)
            } catch {
                PlaybackLog.subtitleSelection(
                    "subtitle decoder reopen after seek FAILED streamIndex=\(subtitleStreamIndex) \(error.localizedDescription)"
                )
                subtitleStreamIndex = -1
            }
        }

        // Start recovery window NOW (after network seek) so it covers the decode burst.
        sampleRenderer.setRecoveringFromSeek(true, windowSeconds: 0.5)
        seekRecoveryLock.lock()
        audioSeekRecoveryUntilHostTime = CACurrentMediaTime() + 0.6
        seekRecoveryLock.unlock()

        PlaybackLog.seek("Pipeline resumed from new position anchor=\(String(format: "%.3f", seconds))s")

        // Enter post-seek buffering: hold video timebase + audio node paused until thresholds met.
        postSeekBuffering = true
        audioPlayerNode?.pause()

        if demuxer.videoStreamIndex >= 0 {
            postSeekAwaitingFirstVideoFrame = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.playbackQueue.async {
                    guard let self else { return }
                    if self.postSeekAwaitingFirstVideoFrame {
                        PlaybackLog.playbackError(
                            "No new frame after seek within 2s (video stream=\(self.demuxer.videoStreamIndex))"
                        )
                        self.postSeekAwaitingFirstVideoFrame = false
                    }
                }
            }
        }
    }

    /// Checks if post-seek buffering thresholds are met; if so, starts playback atomically.
    private func checkBufferingGate() {
        guard postSeekBuffering else { return }

        let videoReady: Bool
        if demuxer.videoStreamIndex >= 0 {
            videoReady = sampleRenderer.fifoCount >= bufferingMinVideoFrames
        } else {
            videoReady = true // no video stream → skip check
        }

        let audioReady: Bool
        if demuxer.audioStreamIndex >= 0 {
            let scheduled = Double(lastAudioScheduleEndSample ?? 0) / (audioDecoder.outputFormat?.sampleRate ?? 44100)
            audioReady = scheduled >= bufferingMinAudioSeconds
        } else {
            audioReady = true // no audio stream → skip check
        }

        guard videoReady && audioReady else { return }

        // Thresholds met — start playback atomically.
        postSeekBuffering = false
        PlaybackLog.seek("[Seek] buffering complete: video_fifo=\(sampleRenderer.fifoCount) audio_sched=\(String(format: "%.2f", Double(lastAudioScheduleEndSample ?? 0) / (audioDecoder.outputFormat?.sampleRate ?? 44100)))s")

        // Release the display timebase and audio atomically (sync ensures they start at the same instant).
        DispatchQueue.main.sync { [weak self] in
            self?.sampleRenderer.releaseTimebaseHold()
        }
        // Resume audio playback.
        audioPlayerNode?.play()
    }

    private static func avNoptsInt64() -> Int64 {
        Int64(bitPattern: UInt64(0x8000_0000_0000_0000))
    }

    private func logVideoFrameIfNeeded(_ sample: CMSampleBuffer) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let sec = CMTimeGetSeconds(pts)
        guard sec.isFinite else { return }
        if postSeekAwaitingFirstVideoFrame {
            postSeekAwaitingFirstVideoFrame = false
            let now = CACurrentMediaTime()
            seekMetricsLock.lock()
            let start = lastSeekStartHostTime
            let applied = lastSeekAppliedOnMainHostTime
            let scheduled = lastSeekMainScheduledHostTime
            let target = lastSeekTargetSeconds
            seekMetricsLock.unlock()
            if let s = start {
                let ttffMs = (now - s) * 1000.0
                let mainApplyMs = applied.map { (max(0, $0 - s) * 1000.0) }
                let mainQueueDelayMs: Double? = {
                    guard let sch = scheduled, let ap = applied else { return nil }
                    return max(0, (ap - sch) * 1000.0)
                }()
                if let tgt = target {
                    if let ma = mainApplyMs {
                        if let mq = mainQueueDelayMs {
                            PlaybackLog.seek(
                                "seek metrics target=\(String(format: "%.3f", tgt))s ttff=\(String(format: "%.1f", ttffMs))ms main_apply=\(String(format: "%.1f", ma))ms main_queue=\(String(format: "%.1f", mq))ms relPTS=\(String(format: "%.4f", sec))s"
                            )
                        } else {
                            PlaybackLog.seek(
                                "seek metrics target=\(String(format: "%.3f", tgt))s ttff=\(String(format: "%.1f", ttffMs))ms main_apply=\(String(format: "%.1f", ma))ms relPTS=\(String(format: "%.4f", sec))s"
                            )
                        }
                    } else {
                        PlaybackLog.seek(
                            "seek metrics target=\(String(format: "%.3f", tgt))s ttff=\(String(format: "%.1f", ttffMs))ms main_apply=pending relPTS=\(String(format: "%.4f", sec))s"
                        )
                    }
                } else {
                    PlaybackLog.seek("seek metrics ttff=\(String(format: "%.1f", ttffMs))ms relPTS=\(String(format: "%.4f", sec))s")
                }
            } else {
                PlaybackLog.seek("Pipeline first video frame after seek relPTS=\(String(format: "%.4f", sec))s")
            }
        }
        videoEnqueueLogCount += 1
        let n = videoEnqueueLogCount
        if n <= 12 || n % 150 == 0 {
            PlaybackLog.video("decoded→FIFO #\(n) PTS=\(String(format: "%.5f", sec))")
        }
    }

}

// MARK: - Display link (main thread)

private final class DisplayLinkDriver: NSObject {
    var onFire: (() -> Void)?
    private var link: CADisplayLink?

    func start() {
        stop()
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick() {
        onFire?()
    }

    deinit {
        stop()
    }
}

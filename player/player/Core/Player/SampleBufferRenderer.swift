import AVFoundation
import CoreMedia
import CoreVideo
import QuartzCore
import UIKit

/// Thread-safe FIFO for decoded video frames. When full, drops **oldest** frames so decode never blocks the demux loop
/// (interleaved A/V files would otherwise starve audio while waiting on video backpressure).
private final class BoundedVideoFIFO {
    private let lock = NSLock()
    private var buffers: [CMSampleBuffer] = []
    private let capacity: Int
    private var closed = false

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    /// O(1) append; if at capacity, drops oldest sample(s) until there is room (keeps decode + demux unblocked).
    func put(_ sample: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        while buffers.count >= capacity {
            buffers.removeFirst()
        }
        buffers.append(sample)
    }

    /// Returns `nil` if empty.
    func take() -> CMSampleBuffer? {
        lock.lock()
        defer { lock.unlock() }
        guard !buffers.isEmpty else { return nil }
        return buffers.removeFirst()
    }

    func clear() {
        lock.lock()
        buffers.removeAll()
        lock.unlock()
    }

    func close() {
        lock.lock()
        closed = true
        buffers.removeAll()
        lock.unlock()
    }

    func resetForNewSession() {
        lock.lock()
        closed = false
        buffers.removeAll()
        lock.unlock()
    }

    func count() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return buffers.count
    }
}

/// Hosts `AVSampleBufferDisplayLayer` and paces `enqueue` using `requestMediaDataWhenReady` so the queue never runs far ahead of real-time playback.
final class SampleBufferRenderer {
    let displayLayer = AVSampleBufferDisplayLayer()
    private var controlTimebase: CMTimebase?
    private var timelineStarted = false
    /// Prefill a few frames before starting the timebase. This reduces visible stutter/freeze on some devices
    /// when the renderer is fed at full speed immediately after a seek/flush.
    private var prefillRemaining = 0
    private let recoveryLock = NSLock()
    private var recoveringUntilHostTime: CFTimeInterval = 0
    private var recoveryEnqueuedFrames: Int = 0
    private let drainControlLock = NSLock()
    private var drainSuspended: Bool = false
    private var lastLoggedDisplayErrorDescription: String?

    // MARK: - Post-seek buffering gate
    /// When `true`, frames are enqueued to the display layer but the timebase stays paused.
    /// The engine sets this during post-seek buffering and clears it via `releaseTimebaseHold()`.
    private var holdTimebase: Bool = false

    /// Bounded queue: 4K NV12 frames are large; cap depth to limit memory while keeping short bursts (was 40).
    private let fifo = BoundedVideoFIFO(capacity: 28)
    private var sessionStopped = true
    private var didInstallMediaRequest = false
    private let requestLock = NSLock()
    private var isRequestingMediaData = false
    private var didEmitFirstFrameForSession = false
    /// Avoid queuing one `main.async` per decoded frame when many arrive in one burst (reduces main-thread churn).
    private var mainDrainScheduled = false
    private var loggedFirstEnqueue = false

    /// Called on the main queue when the first video frame is enqueued after `beginPlaybackSession` / seek flush.
    var onFirstFrameEnqueued: (() -> Void)?

    /// Number of frames currently in the FIFO (used by engine for buffering gate).
    var fifoCount: Int { fifo.count() }

    init() {
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = UIColor.black.cgColor
    }

    /// Throttles main-thread enqueue bursts right after seek to avoid UI stalls.
    /// Safe to call from any thread.
    func setRecoveringFromSeek(_ recovering: Bool, windowSeconds: Double = 0.6) {
        recoveryLock.lock()
        if recovering {
            recoveringUntilHostTime = CACurrentMediaTime() + max(0.1, windowSeconds)
            recoveryEnqueuedFrames = 0
        } else {
            recoveringUntilHostTime = 0
            recoveryEnqueuedFrames = 0
        }
        recoveryLock.unlock()
    }

    /// Clears only the decoded-frame FIFO immediately (safe on any thread).
    /// Used at seek start to prevent old-frame leakage before the main-thread `displayLayer.flush...` runs.
    func clearQueuedFramesForSeek() {
        fifo.clear()
    }

    /// Temporarily disables main-thread draining/enqueue to avoid starving other main-queue work (e.g. seek flush).
    /// Safe to call from any thread.
    func setDrainSuspended(_ suspended: Bool) {
        drainControlLock.lock()
        drainSuspended = suspended
        drainControlLock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if suspended {
                self.stopRequestingMediaData()
            } else if self.didInstallMediaRequest {
                self.startRequestingMediaData()
            }
        }
    }

    /// Requests a drain pass on the main queue (no-op if suspended/stopped).
    func requestDrain() {
        DispatchQueue.main.async { [weak self] in
            self?.drainWhileReady()
        }
    }

    /// Safe to call from any thread.
    func isRecoveringFromSeek() -> Bool {
        recoveryLock.lock()
        let active = CACurrentMediaTime() < recoveringUntilHostTime
        recoveryLock.unlock()
        return active
    }

    struct BacklogStatus: Equatable {
        let fifoCount: Int
        let drainSuspended: Bool
        let isRecoveringFromSeek: Bool
        let isRequestingMediaData: Bool
        let displayStatus: AVQueuedSampleBufferRenderingStatus
        let isReadyForMoreMediaData: Bool
    }

    func backlogStatus() -> BacklogStatus {
        drainControlLock.lock()
        let suspended = drainSuspended
        drainControlLock.unlock()
        recoveryLock.lock()
        let recovering = CACurrentMediaTime() < recoveringUntilHostTime
        recoveryLock.unlock()
        requestLock.lock()
        let requesting = isRequestingMediaData
        requestLock.unlock()
        return BacklogStatus(
            fifoCount: fifo.count(),
            drainSuspended: suspended,
            isRecoveringFromSeek: recovering,
            isRequestingMediaData: requesting,
            displayStatus: displayLayer.status,
            isReadyForMoreMediaData: displayLayer.isReadyForMoreMediaData
        )
    }

    func setZoomed(_ zoomed: Bool) {
        let gravity: AVLayerVideoGravity = zoomed ? .resizeAspectFill : .resizeAspect
        if Thread.isMainThread {
            displayLayer.videoGravity = gravity
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.displayLayer.videoGravity = gravity
            }
        }
    }

    func attach(to view: UIView) {
        displayLayer.removeFromSuperlayer()
        view.layer.insertSublayer(displayLayer, at: 0)
        displayLayer.frame = view.bounds

        let clock = CMClockGetHostTimeClock()
        if let tb = try? CMTimebase(sourceClock: clock) {
            controlTimebase = tb
            displayLayer.controlTimebase = tb
            try? tb.setTime(CMTime.zero)
            try? tb.setRate(0)
        }
        timelineStarted = false
        lastLoggedDisplayErrorDescription = nil

        if !didInstallMediaRequest {
            didInstallMediaRequest = true
            startRequestingMediaData()
        }
    }

    func layout(bounds: CGRect) {
        displayLayer.frame = bounds
    }

    /// Called from the decode thread. Frames are queued for `requestMediaDataWhenReady`; excess frames are dropped (oldest first) so demux never blocks on interleaved audio.
    func pushDecodedFrame(_ sampleBuffer: CMSampleBuffer) {
        fifo.put(sampleBuffer)
        // If draining is suspended (e.g. during seek), do NOT schedule main-thread drain blocks.
        // Otherwise we can accumulate a large main-queue backlog that delays the seek flush/anchor apply.
        drainControlLock.lock()
        let suspended = drainSuspended
        drainControlLock.unlock()
        if suspended { return }
        // Avoid scheduling one main-queue drain per decoded frame.
        // Ensure `requestMediaDataWhenReady` is active and let it pull from the FIFO.
        requestDrain()
    }

    /// Begin a playback session: reset FIFO and allow the display pump to run (`requestMediaDataWhenReady` is installed once from `attach`).
    func beginPlaybackSession() {
        sessionStopped = false
        fifo.resetForNewSession()
        timelineStarted = false
        prefillRemaining = 2
        didEmitFirstFrameForSession = false
        loggedFirstEnqueue = false
        mainDrainScheduled = false
        DispatchQueue.main.async { [weak self] in
            self?.drainWhileReady()
        }
    }

    private func startRequestingMediaData() {
        requestLock.lock()
        let already = isRequestingMediaData
        if !already { isRequestingMediaData = true }
        requestLock.unlock()
        guard !already else { return }
        displayLayer.requestMediaDataWhenReady(on: DispatchQueue.main) { [weak self] in
            self?.drainWhileReady()
        }
    }

    private func stopRequestingMediaData() {
        requestLock.lock()
        let was = isRequestingMediaData
        if was { isRequestingMediaData = false }
        requestLock.unlock()
        guard was else { return }
        displayLayer.stopRequestingMediaData()
    }

    private func drainWhileReady() {
        guard !sessionStopped else { return }
        drainControlLock.lock()
        let suspended = drainSuspended
        drainControlLock.unlock()
        if suspended {
            return
        }
        if displayLayer.status == .failed {
            displayLayer.flush()
        }
        // Avoid blocking the main thread by enqueueing huge bursts in one run,
        // especially right after seek when decode can fill the FIFO quickly.
        var enqueued = 0
        let recovering: Bool = {
            recoveryLock.lock()
            let active = CACurrentMediaTime() < recoveringUntilHostTime
            recoveryLock.unlock()
            return active
        }()
        let maxPerDrain = recovering ? 6 : 8
        while displayLayer.isReadyForMoreMediaData && enqueued < maxPerDrain {
            guard let sb = fifo.take() else {
                // Prevent main-thread callback spin when FIFO is empty.
                stopRequestingMediaData()
                return
            }
            enqueueToDisplayLayer(sb)
            enqueued += 1
        }
        // Avoid recursively spamming the main queue. `requestMediaDataWhenReady` will invoke us again when needed.
    }

    private func enqueueToDisplayLayer(_ sampleBuffer: CMSampleBuffer) {
        if displayLayer.status == .failed {
            displayLayer.flush()
        }
        if !timelineStarted {
            // Keep the timebase paused while we prefill a couple frames.
            if prefillRemaining > 0 {
                prefillRemaining -= 1
                displayLayer.enqueue(sampleBuffer)
                if prefillRemaining == 0 {
                    timelineStarted = true
                    // Only start playback if the buffering gate is NOT held.
                    if !holdTimebase {
                        try? controlTimebase?.setTime(CMTime.zero)
                        try? controlTimebase?.setRate(1.0)
                    }
                }
            } else {
                timelineStarted = true
                if !holdTimebase {
                    try? controlTimebase?.setTime(CMTime.zero)
                    try? controlTimebase?.setRate(1.0)
                }
                displayLayer.enqueue(sampleBuffer)
            }
        } else {
            displayLayer.enqueue(sampleBuffer)
        }
        recoveryLock.lock()
        if CACurrentMediaTime() < recoveringUntilHostTime {
            recoveryEnqueuedFrames += 1
            // Auto-exit recovery once we have a small buffer on screen, even if the timer hasn't expired.
            if recoveryEnqueuedFrames >= 6 {
                recoveringUntilHostTime = 0
            }
        }
        recoveryLock.unlock()
        if !loggedFirstEnqueue {
            loggedFirstEnqueue = true
            let buf = CMSampleBufferGetImageBuffer(sampleBuffer)
            let w = buf.map { CVPixelBufferGetWidth($0) } ?? 0
            let h = buf.map { CVPixelBufferGetHeight($0) } ?? 0
            PlaybackLog.video("[Render] first frame pushed to displayLayer size=\(w)x\(h)")
        }
        if !didEmitFirstFrameForSession {
            didEmitFirstFrameForSession = true
            onFirstFrameEnqueued?()
        }
        if let err = displayLayer.error {
            let desc = err.localizedDescription
            if lastLoggedDisplayErrorDescription != desc {
                lastLoggedDisplayErrorDescription = desc
                PlaybackLog.displayLayerError("AVSampleBufferDisplayLayer error after enqueue: \(desc) status=\(String(describing: displayLayer.status))")
            }
        }
    }

    func flush() {
        displayLayer.flushAndRemoveImage()
    }

    func stop() {
        sessionStopped = true
        fifo.close()
        fifo.clear()
        try? controlTimebase?.setRate(0)
        timelineStarted = false
        didEmitFirstFrameForSession = false
        loggedFirstEnqueue = false
        lastLoggedDisplayErrorDescription = nil
        flush()
    }

    /// Host clock seconds for the displayed frame (uses `CMTimebase` when active).
    func presentationClockSeconds() -> Double {
        guard let tb = controlTimebase else { return 0 }
        let t = CMTimebaseGetTime(tb)
        let s = CMTimeGetSeconds(t)
        return s.isFinite ? max(0, s) : 0
    }

    func setPlaybackPaused(_ paused: Bool) {
        let rate: Double = paused ? 0 : 1
        try? controlTimebase?.setRate(rate)
    }

    /// After seek: drop queued frames but keep the last displayed image visible
    /// (avoids black-screen flash during network seek). The old frame is naturally
    /// replaced when the first new frame arrives after the seek completes.
    func flushForSeek() {
        fifo.clear()
        displayLayer.flush()
        holdTimebase = true  // arm the buffering gate
        timelineStarted = false
        prefillRemaining = 2
        didEmitFirstFrameForSession = false
        loggedFirstEnqueue = false
        lastLoggedDisplayErrorDescription = nil
        try? controlTimebase?.setTime(.zero)
        try? controlTimebase?.setRate(0)
    }

    // MARK: - Buffering gate

    /// Called by the engine to hold the display timebase while post-seek buffering accumulates.
    func setHoldTimebase(_ hold: Bool) {
        holdTimebase = hold
    }

    /// Called by the engine when minimum buffering thresholds are met.
    /// Starts the display timebase so video begins rendering.
    func releaseTimebaseHold() {
        holdTimebase = false
        if timelineStarted {
            try? controlTimebase?.setTime(.zero)
            try? controlTimebase?.setRate(1.0)
        }
        // Kick off immediate draining so buffered frames reach the display layer now.
        startRequestingMediaData()
        drainWhileReady()
    }
}

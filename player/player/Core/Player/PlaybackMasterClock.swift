import AVFoundation
import CoreMedia
import Foundation

/// Audio-driven master clock (VLC: "audio is truth"). Any thread can read the current
/// audio media time; the audio decode thread and main thread update it.
final class PlaybackMasterClock {
    private let lock = NSLock()

    private var anchorMediaSeconds: Double = 0

    /// Updated from `scheduleAudioBuffer` on the audio decode thread (schedule-derived estimate).
    private var playbackThreadAudioMediaSeconds: Double = 0

    /// Last main-thread sample from `AVAudioPlayerNode` (authoritative when available).
    private var mainThreadAudioMediaSeconds: Double = 0
    private var hasMainClockSample = false

    /// Updated from the audio decode thread by reading the player node's actual playhead.
    private var decodeThreadAudioMediaSeconds: Double = 0
    private var hasDecodeThreadSample = false

    func setAnchor(_ seconds: Double) {
        lock.lock()
        anchorMediaSeconds = seconds
        // Critical: before any audio buffer is scheduled, playback estimate must not sit at 0 while
        // anchor is already at first video PTS — sync would treat every video frame as wrong.
        if playbackThreadAudioMediaSeconds < seconds {
            playbackThreadAudioMediaSeconds = seconds
        }
        if decodeThreadAudioMediaSeconds < seconds {
            decodeThreadAudioMediaSeconds = seconds
        }
        lock.unlock()
    }

    func anchorSeconds() -> Double {
        lock.lock()
        defer { lock.unlock() }
        return anchorMediaSeconds
    }

    /// Call from `scheduleAudioBuffer`: `endRelativeSeconds` = `Double(lastAudioScheduleEndSample) / sr` on the same timeline as video PTS.
    func updatePlaybackEstimateFromScheduledEnd(anchor: Double, endRelativeSeconds: Double) {
        // Approximate playhead near end of scheduled PCM minus a small device buffer (~40ms).
        let playheadGuess = max(0, endRelativeSeconds - 0.04)
        lock.lock()
        anchorMediaSeconds = anchor
        playbackThreadAudioMediaSeconds = anchor + playheadGuess
        lock.unlock()
    }

    /// Call from the audio decode thread after scheduling a buffer. Reads the node's actual playhead
    /// for a more accurate clock than the schedule-derived estimate.
    func updateFromDecodeThread(
        node: AVAudioPlayerNode?, anchor: Double, offset: AVAudioFramePosition, sampleRate sr: Double
    ) {
        lock.lock()
        anchorMediaSeconds = anchor
        let srClamped = max(8000, sr)
        guard let node, let nt = node.lastRenderTime, let pt = node.playerTime(forNodeTime: nt) else {
            lock.unlock()
            return
        }
        let rel = Double(pt.sampleTime - offset) / srClamped
        decodeThreadAudioMediaSeconds = anchor + max(0, rel)
        hasDecodeThreadSample = true
        lock.unlock()
    }

    /// Main thread only: read playhead from `AVAudioPlayerNode`.
    func updateFromMainThread(
        node: AVAudioPlayerNode?, anchor: Double, offset: AVAudioFramePosition, sampleRate sr: Double
    ) {
        lock.lock()
        anchorMediaSeconds = anchor
        let srClamped = max(8000, sr)
        guard let node, let nt = node.lastRenderTime, let pt = node.playerTime(forNodeTime: nt) else {
            lock.unlock()
            return
        }
        let rel = Double(pt.sampleTime - offset) / srClamped
        mainThreadAudioMediaSeconds = anchor + max(0, rel)
        hasMainClockSample = true
        lock.unlock()
    }

    /// UI + subtitle tick: prefer main-thread audio; else video-only fallback uses `videoLayerClockSeconds`.
    func currentMediaSecondsForUI(
        duration: Double, videoLayerClockSeconds: Double, hasActiveAudio: Bool
    ) -> Double {
        lock.lock()
        let anchor = anchorMediaSeconds
        let mainT = mainThreadAudioMediaSeconds
        let playT = playbackThreadAudioMediaSeconds
        let mainOk = hasMainClockSample
        lock.unlock()
        let media: Double
        if hasActiveAudio {
            if mainOk {
                media = mainT
            } else {
                // Until `lastRenderTime` is valid, keep UI at least at anchor (same as video start).
                media = max(anchor, playT)
            }
        } else {
            media = anchor + videoLayerClockSeconds
        }
        return min(max(0, media), max(0.1, duration))
    }

    /// **Any-thread** read of the current audio media seconds for sync decisions.
    /// Prefers actual playhead readings (decode thread or main thread); falls back to schedule-derived estimate.
    func currentAudioMediaSeconds() -> Double {
        lock.lock()
        let a = anchorMediaSeconds
        let decT = decodeThreadAudioMediaSeconds
        let mainT = mainThreadAudioMediaSeconds
        let playT = playbackThreadAudioMediaSeconds
        let hasDecT = hasDecodeThreadSample
        let hasMainT = hasMainClockSample
        lock.unlock()
        if hasDecT {
            return max(a, decT)
        }
        if hasMainT {
            return max(a, mainT)
        }
        return max(a, playT)
    }

    /// Video sync on playback thread: schedule-derived estimate; never below anchor before audio runs.
    func mediaSecondsForVideoSync() -> Double {
        return currentAudioMediaSeconds()
    }

    func resetForNewSession() {
        lock.lock()
        anchorMediaSeconds = 0
        playbackThreadAudioMediaSeconds = 0
        mainThreadAudioMediaSeconds = 0
        decodeThreadAudioMediaSeconds = 0
        hasMainClockSample = false
        hasDecodeThreadSample = false
        lock.unlock()
    }

    /// Reset for seek: preserves session state but moves anchor + resets clock samples.
    func resetForSeek(newAnchor: Double) {
        lock.lock()
        anchorMediaSeconds = newAnchor
        playbackThreadAudioMediaSeconds = newAnchor
        mainThreadAudioMediaSeconds = newAnchor
        decodeThreadAudioMediaSeconds = newAnchor
        hasMainClockSample = false
        hasDecodeThreadSample = false
        lock.unlock()
    }
}

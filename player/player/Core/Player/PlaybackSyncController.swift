import CoreMedia
import Foundation

/// Video vs audio master clock: **drop late + delay early** (VLC-style "audio is truth").
/// `AVSampleBufferDisplayLayer` paces PTS internally; this controller gates what is pushed.
final class PlaybackSyncController {
    /// Frame is on-time with audio (push to display layer).
    /// Frame is too late relative to audio (discard).
    /// Frame is too early relative to audio (caller should sleep and re-check).
    enum Decision {
        case enqueue
        case drop
        case delay(TimeInterval)
    }

    private let lateSeconds: Double
    private let earlySeconds: Double
    /// Monotonic counter of dropped frames (for diagnostics).
    private(set) var droppedFrameCount: Int = 0
    private(set) var delayedFrameCount: Int = 0

    /// - Parameters:
    ///   - lateMs: Frames behind audio by more than this are dropped (default 80ms — tighter than old 120ms).
    ///   - earlyMs: Frames ahead of audio by more than this are delayed (default 40ms).
    init(lateMs: Double = 80, earlyMs: Double = 40) {
        self.lateSeconds = lateMs / 1000
        self.earlySeconds = earlyMs / 1000
    }

    func reset() {
        droppedFrameCount = 0
        delayedFrameCount = 0
    }

    /// Decide what to do with a decoded video frame based on its PTS vs the current audio clock.
    func decide(videoPtsMediaSeconds: Double, audioClockMediaSeconds: Double) -> Decision {
        let diff = videoPtsMediaSeconds - audioClockMediaSeconds

        if diff < -lateSeconds {
            droppedFrameCount += 1
            #if DEBUG
            if droppedFrameCount <= 5 || droppedFrameCount % 60 == 0 {
                PlaybackLog.sync(
                    String(
                        format: "[SyncController] drop #%d diff=%.1fms video=%.3f audio=%.3f",
                        droppedFrameCount, diff * 1000, videoPtsMediaSeconds, audioClockMediaSeconds
                    )
                )
            }
            #endif
            return .drop
        }

        if diff > earlySeconds {
            delayedFrameCount += 1
            // Sleep about half the excess so we re-check partway through.
            let sleepInterval = min((diff - earlySeconds * 0.5), 0.04)
            return .delay(sleepInterval)
        }

        return .enqueue
    }

    // MARK: - Legacy API (for compatibility during migration)

    func samplesToEnqueue(
        newSample: CMSampleBuffer,
        anchorMediaSeconds: Double,
        audioClockMediaSeconds: Double
    ) -> [CMSampleBuffer] {
        let pts = CMSampleBufferGetPresentationTimeStamp(newSample)
        let rel = CMTimeGetSeconds(pts)
        guard rel.isFinite else {
            return [newSample]
        }
        let videoMedia = anchorMediaSeconds + max(0, rel)
        let decision = decide(
            videoPtsMediaSeconds: videoMedia,
            audioClockMediaSeconds: audioClockMediaSeconds
        )
        switch decision {
        case .enqueue:
            return [newSample]
        case .drop:
            return []
        case .delay(let interval):
            // In the legacy single-threaded path we can't delay, so just enqueue.
            // The new multi-threaded path uses `decide()` directly.
            _ = interval
            return [newSample]
        }
    }
}

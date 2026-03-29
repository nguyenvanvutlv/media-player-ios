#if os(iOS)
import AVFoundation
import AVKit
import UIKit

/// Owns `AVPictureInPictureController` for the shared `AVSampleBufferDisplayLayer` (no changes to decode/enqueue path).
@MainActor
final class PictureInPictureCoordinator: NSObject {
    private var pipController: AVPictureInPictureController?
    private weak var playerController: PlayerController?

    init(playerController: PlayerController) {
        self.playerController = playerController
        super.init()
    }

    /// Call after `VideoDisplayView` has attached the sample buffer layer (e.g. `PlayerView.onAppear`).
    func prepareIfNeeded(displayLayer: AVSampleBufferDisplayLayer) {
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            PlaybackLog.pip("[PiP] not supported on this device/OS")
            playerController?.state.isPictureInPicturePossible = false
            return
        }
        if pipController != nil {
            refreshPictureInPicturePossible()
            return
        }

        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: displayLayer,
            playbackDelegate: self
        )
        let pip = AVPictureInPictureController(contentSource: source)
        pip.delegate = self
        pip.canStartPictureInPictureAutomaticallyFromInline = true
        pipController = pip

        PlaybackLog.pip("[PiP] initialized")
        refreshPictureInPicturePossible()
    }

    func startPictureInPicture() {
        guard let pip = pipController else {
            PlaybackLog.pip("[PiP][ERROR] cannot start — not initialized")
            return
        }
        refreshPictureInPicturePossible()
        guard pip.isPictureInPicturePossible else {
            PlaybackLog.pip("[PiP][ERROR] cannot start — isPictureInPicturePossible=false (check audio session / device)")
            return
        }
        pip.startPictureInPicture()
    }

    func refreshPictureInPicturePossible() {
        guard let pip = pipController else { return }
        let possible = pip.isPictureInPicturePossible
        playerController?.state.isPictureInPicturePossible = possible
        PlaybackLog.pip("[PiP] isPossible=\(possible)")
    }
}

// MARK: - AVPictureInPictureControllerDelegate

extension PictureInPictureCoordinator: AVPictureInPictureControllerDelegate {
    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        isPictureInPicturePossible: Bool
    ) {
        playerController?.state.isPictureInPicturePossible = isPictureInPicturePossible
        PlaybackLog.pip("[PiP] isPossible=\(isPictureInPicturePossible)")
    }

    func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {}

    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        PlaybackLog.pip("[PiP] started")
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        PlaybackLog.pip("[PiP][ERROR] cannot start — \(error.localizedDescription)")
    }

    func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {}

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        PlaybackLog.pip("[PiP] stopped")
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(true)
    }
}

// MARK: - AVPictureInPictureSampleBufferPlaybackDelegate

extension PictureInPictureCoordinator: AVPictureInPictureSampleBufferPlaybackDelegate {
    func pictureInPictureControllerTimeRangeForPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> CMTimeRange {
        guard let pc = playerController else {
            return CMTimeRange(start: .zero, duration: .positiveInfinity)
        }
        let d = pc.state.duration
        if d.isFinite, d > 0.05 {
            return CMTimeRange(
                start: .zero,
                duration: CMTime(seconds: d, preferredTimescale: 60_000)
            )
        }
        return CMTimeRange(start: .zero, duration: .positiveInfinity)
    }

    func pictureInPictureControllerIsPlaybackPaused(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
        !(playerController?.state.isPlaying ?? true)
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        playerController?.setPlaybackPlaying(playing)
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {}

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping @Sendable () -> Void
    ) {
        let sec = CMTimeGetSeconds(skipInterval)
        guard sec.isFinite, abs(sec) > 0.001 else {
            completionHandler()
            return
        }
        playerController?.skip(by: sec)
        completionHandler()
    }
}

#endif

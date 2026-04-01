import SwiftUI

/// Overlay chrome: top bar, bottom bar (play/pause, skip, progress, track actions) with a light dim when visible.
struct PlayerControlsView: View {
    @ObservedObject var state: PlayerState

    var onClose: () -> Void
    var onPictureInPicture: () -> Void
    var onPlayPause: () -> Void
    var onZoom: () -> Void
    var onScrubBegin: () -> Void
    var onScrubEnd: (Double) -> Void
    var onSkipBack: () -> Void
    var onSkipForward: () -> Void
    var onAudio: () -> Void
    var onSubtitle: () -> Void
    var onMore: () -> Void

    @State private var showChrome = true
    @State private var hideTask: Task<Void, Never>?
    @State private var scrubPreviewSeconds: Double?

    private var normalizedProgress: Double {
        let d = max(state.duration, 0.1)
        return min(1, max(0, state.currentTime / d))
    }

    private var bufferedFraction: Double {
        let d = max(state.duration, 0.1)
        return min(1, max(0, state.buffered / d))
    }

    var body: some View {
        ZStack {
            if showChrome {
                Rectangle()
                    .fill(Color.black.opacity(0.18))
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    flashChrome()
                }

            if showChrome {
                VStack(spacing: 0) {
                    topBar
                    Spacer()
                    bottomBar
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: showChrome)
        .onAppear {
            scheduleAutoHide()
        }
        .onChange(of: state.isBuffering) { _, buffering in
            if buffering {
                withAnimation {
                    showChrome = true
                }
                cancelAutoHide()
            } else {
                scheduleAutoHide()
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.white.opacity(0.12))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)

            Button(action: onPictureInPicture) {
                Image(systemName: "pip.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.white.opacity(0.12))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!state.isPictureInPicturePossible)
            .opacity(state.isPictureInPicturePossible ? 1 : 0.35)

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(state.title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(2)

            ProgressBarView(
                progress: Binding(
                    get: { normalizedProgress },
                    set: { _ in }
                ),
                duration: max(state.duration, 0.1),
                bufferedFraction: bufferedFraction,
                onSeekBegan: {
                    cancelAutoHide()
                    scrubPreviewSeconds = state.currentTime
                    onScrubBegin()
                },
                onSeekEnded: { sec in
                    scrubPreviewSeconds = nil
                    onScrubEnd(sec)
                    scheduleAutoHide()
                },
                onScrubPreview: { sec in
                    scrubPreviewSeconds = sec
                }
            )

            HStack {
                Text(Self.formatTime(scrubPreviewSeconds ?? state.currentTime))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.white)
                if state.isBuffering {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(0.85)
                }
                Spacer()
                Text(Self.formatTime(state.duration))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
            }

            HStack(spacing: 16) {
                playPauseButton
                chromeIconButton(systemName: "gobackward.10", action: onSkipBack)
                chromeIconButton(systemName: "goforward.10", action: onSkipForward)
                Spacer(minLength: 0)
                chromeIconButton(
                    systemName: state.isZoomed ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                    action: onZoom
                )
                chromeIconButton(systemName: "captions.bubble", action: onSubtitle)
                chromeIconButton(systemName: "waveform.circle", action: onAudio)
                chromeIconButton(systemName: "ellipsis", action: onMore)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private var playPauseButton: some View {
        Button(action: onPlayPause) {
            Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 20))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Color.white.opacity(0.12))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private func chromeIconButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 20))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Color.white.opacity(0.12))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private func flashChrome() {
        withAnimation {
            showChrome = true
        }
        scheduleAutoHide()
    }

    private func scheduleAutoHide() {
        cancelAutoHide()
        guard !state.isBuffering else { return }
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            guard !state.isBuffering else { return }
            withAnimation {
                showChrome = false
            }
        }
    }

    private func cancelAutoHide() {
        hideTask?.cancel()
        hideTask = nil
    }

    private static func formatTime(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "00:00" }
        let total = Int(s.rounded(.down))
        let h = total / 3600
        let m = (total % 3600) / 60
        let sec = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, sec)
        }
        return String(format: "%02d:%02d", m, sec)
    }
}

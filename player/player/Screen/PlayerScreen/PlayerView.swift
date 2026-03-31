import Combine
import SwiftUI
import SwiftData

/// Full-screen FFmpeg player: video layer + `SubtitleView` + `PlayerControlsView`, driven by `PlayerController`.
struct PlayerView: View {
    @StateObject private var controllerHolder: ControllerHolder
    @ObservedObject private var state: PlayerState

    @Environment(\.displayScale) private var displayScale
    @Environment(\.modelContext) private var modelContext
    @Query private var subtitleSettings: [SubtitleSettings]
    
    private let onClose: () -> Void

    @State private var showAudioSheet = false
    @State private var showSubtitleSheet = false
    @State private var showMoreOptions = false
    @State private var showPlaybackInfo = false

    init(url: URL, externalSubtitleURLs: [URL] = [], onClose: @escaping () -> Void = {}) {
        let holder = ControllerHolder(url: url, externalSubtitleURLs: externalSubtitleURLs)
        _controllerHolder = StateObject(wrappedValue: holder)
        _state = ObservedObject(wrappedValue: holder.controller.state)
        self.onClose = onClose
    }

    private var controller: PlayerController { controllerHolder.controller }

    private var subtitleSettingsSignature: String {
        guard let s = subtitleSettings.first else { return "none" }
        return [
            String(format: "%.3f", s.fontSize),
            s.textColor,
            s.backgroundColor,
            s.isBoldEnabled ? "1" : "0",
            String(format: "%.3f", s.position),
            s.preferredLanguage,
            s.isEnabled ? "1" : "0",
        ].joined(separator: "|")
    }

    var body: some View {
        ZStack {
            VideoDisplayView(sampleRenderer: controller.sampleRenderer)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()

            GeometryReader { geo in
                AssBitmapOverlayView(
                    image: state.subtitleOverlayImage,
                    verticalOffset: CGFloat(state.subtitleOverlayVerticalOffset),
                    fullFrame: state.subtitleOverlayIsFullFrame
                )
                    .frame(width: geo.size.width, height: geo.size.height)
                    .allowsHitTesting(false)
                    .onAppear {
                        state.subtitleLayoutWidth = geo.size.width
                        controller.invalidateSubtitleOverlayLayout()
                    }
                    .onChange(of: geo.size.width) { _, w in
                        state.subtitleLayoutWidth = w
                        controller.invalidateSubtitleOverlayLayout()
                    }
            }
            .allowsHitTesting(false)

            PlayerControlsView(
                state: state,
                onClose: { onClose() },
                onPictureInPicture: {
#if os(iOS)
                    controller.startPictureInPicture()
#endif
                },
                onPlayPause: { controller.togglePause() },
                onZoom: { controller.toggleZoom() },
                onScrubBegin: { controller.beginScrubbing() },
                onScrubEnd: { controller.endScrubbing(atSeconds: $0) },
                onSkipBack: { controller.skip(by: -10) },
                onSkipForward: { controller.skip(by: 10) },
                onAudio: { showAudioSheet = true },
                onSubtitle: { showSubtitleSheet = true },
                onMore: { showMoreOptions = true }
            )
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
        .onAppear {
            state.subtitleDisplayScale = displayScale
            controller.startPlayback()
#if os(iOS)
            controller.preparePictureInPicture(displayLayer: controller.sampleRenderer.displayLayer)
#endif
            ensureSubtitleSettingsRow()
            applySubtitleSettingsToPlayer()
            applyPreferredSubtitleLanguageIfNeeded()
        }
        .onChange(of: subtitleSettingsSignature) { _, _ in
            applySubtitleSettingsToPlayer()
            applyPreferredSubtitleLanguageIfNeeded()
        }
        .onChange(of: state.subtitleTracks) { _, _ in
            applyPreferredSubtitleLanguageIfNeeded()
        }
        .onChange(of: state.isBuffering) { _, buffering in
#if os(iOS)
            if !buffering {
                controller.refreshPictureInPictureReadiness()
            }
#endif
        }
        .onChange(of: displayScale) { _, newScale in
            state.subtitleDisplayScale = newScale
            controller.invalidateSubtitleOverlayLayout()
        }
        .onDisappear {
            controller.stopPlayback()
        }
        .sheet(isPresented: $showAudioSheet) {
            TrackSelectionSheet(
                mode: .audio,
                audioTitles: state.audioTracks.map(\.displayTitle),
                subtitleTitles: [],
                selectedAudio: state.selectedAudio,
                selectedSubtitle: state.selectedSubtitle,
                onPickAudio: { controller.selectAudioTrack($0) },
                onPickSubtitle: { _ in }
            )
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showSubtitleSheet) {
            TrackSelectionSheet(
                mode: .subtitles,
                audioTitles: [],
                subtitleTitles: state.subtitleTracks.map(\.displayTitle),
                selectedAudio: state.selectedAudio,
                selectedSubtitle: state.selectedSubtitle,
                onPickAudio: { _ in },
                onPickSubtitle: { picked in
                    // Selecting a subtitle track implies enabling subtitle rendering.
                    // Persist this to SwiftData so the controller doesn't early-return with `enabled=false`.
                    if picked > 0 {
                        ensureSubtitleSettingsRow()
                        subtitleSettings.first?.isEnabled = true
                        try? modelContext.save()
                    }
                    controller.selectSubtitle(picked)
                }
            )
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showMoreOptions) {
            SettingScreenView()
                .presentationDetents([.medium, .large])
        }
        .alert("Info", isPresented: $showPlaybackInfo) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(String(format: "Duration: %.1fs\nTime: %.1fs", state.duration, state.currentTime))
        }
        .alert("Player", isPresented: Binding(
            get: { state.alertMessage != nil },
            set: { if !$0 { state.alertMessage = nil } }
        )) {
            Button("OK") {
                state.alertMessage = nil
            }
        } message: {
            Text(state.alertMessage ?? "")
        }
    }

    private func ensureSubtitleSettingsRow() {
        if subtitleSettings.first == nil {
            modelContext.insert(SubtitleSettings())
        }
    }

    private func applySubtitleSettingsToPlayer() {
        guard let s = subtitleSettings.first else { return }

        let uiTextColor: UIColor = {
            switch s.textColor {
            case "Black": return .black
            case "OLED Yellow":
                return UIColor(red: 1.0, green: 0.87, blue: 0.32, alpha: 1)
            default: return .white
            }
        }()

        let uiBackgroundColor: UIColor? = {
            switch s.backgroundColor {
            case "Clear": return nil
            default: return UIColor.black.withAlphaComponent(0.55)
            }
        }()

        controller.applySubtitleSettings(
            fontSize: s.fontSize,
            textColor: uiTextColor,
            backgroundColor: uiBackgroundColor,
            position: s.position,
            isEnabled: s.isEnabled,
            isBoldEnabled: s.isBoldEnabled
        )
    }

    private func applyPreferredSubtitleLanguageIfNeeded() {
        guard let s = subtitleSettings.first else { return }
        let preferred = s.preferredLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !preferred.isEmpty else { return }

        // Respect explicit user selection: only auto-pick when currently "Off".
        guard state.selectedSubtitle == 0 else { return }

        // Track row 0 is "Off"; embedded/external start at 1.
        let match = state.subtitleTracks.first(where: { t in
            guard t.index > 0 else { return false }
            guard let lang = t.language?.lowercased() else { return false }
            return lang == preferred.lowercased()
        })
        guard let pick = match else { return }
        // Auto-pick implies subtitle rendering should be enabled.
        if !s.isEnabled {
            s.isEnabled = true
            try? modelContext.save()
        }
        controller.selectSubtitle(pick.index)
    }
}

/// Holds `PlayerController` so `StateObject` lifetime is stable (`@Published` satisfies `ObservableObject`).
private final class ControllerHolder: ObservableObject {
    @Published private(set) var controller: PlayerController

    init(url: URL, externalSubtitleURLs: [URL]) {
        controller = PlayerController(url: url, externalSubtitleURLs: externalSubtitleURLs)
    }
}

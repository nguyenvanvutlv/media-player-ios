import SwiftUI

struct TrackSelectionSheet: View {
    enum Mode {
        case audio
        case subtitles
    }

    let mode: Mode
    let audioTitles: [String]
    let subtitleTitles: [String]
    let selectedAudio: Int
    let selectedSubtitle: Int
    var onPickAudio: (Int) -> Void
    var onPickSubtitle: (Int) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                switch mode {
                case .audio:
                    ForEach(audioTitles.indices, id: \.self) { i in
                        Button {
                            onPickAudio(i)
                            dismiss()
                        } label: {
                            HStack {
                                Text(audioTitles[i])
                                    .foregroundStyle(.primary)
                                Spacer()
                                if i == selectedAudio {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                case .subtitles:
                    ForEach(subtitleTitles.indices, id: \.self) { i in
                        Button {
                            onPickSubtitle(i)
                            dismiss()
                        } label: {
                            HStack {
                                Text(subtitleTitles[i])
                                    .foregroundStyle(.primary)
                                Spacer()
                                if i == selectedSubtitle {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(mode == .audio ? "Audio" : "Subtitles")
            .navigationBarTitleDisplayModeInlineIfAvailable()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}

private extension View {
    @ViewBuilder
    func navigationBarTitleDisplayModeInlineIfAvailable() -> some View {
#if os(tvOS)
        self
#else
        self.navigationBarTitleDisplayMode(.inline)
#endif
    }
}

import SwiftUI

/// Bottom-centered subtitle overlay (timed text from `PlayerState.currentSubtitleText`).
struct SubtitleView: View {
    let text: String?
    /// Media seconds aligned with `PlayerState.currentTime` (for render-path logging).
    let mediaTime: Double

    var body: some View {
        VStack {
            Spacer()
            if let t = text, !t.isEmpty {
                Text(t)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .shadow(color: .black.opacity(0.92), radius: 3, x: 0, y: 1)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.black.opacity(0.45))
                    )
                    .padding(.horizontal, 20)
                    .padding(.bottom, 120)
            }
        }
        .allowsHitTesting(false)
        .onChange(of: text, initial: true) { _, new in
            if let t = new, !t.isEmpty {
                PlaybackLog.renderSubtitle(ptsMediaSeconds: mediaTime, text: t)
            }
        }
    }
}

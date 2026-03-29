import SwiftUI

/// Seekable progress: normalized playback with scrub preview.
struct ProgressBarView: View {
    @Binding var progress: Double
    var duration: Double
    var bufferedFraction: Double
    var onSeekBegan: () -> Void
    var onSeekEnded: (Double) -> Void
    var onScrubPreview: (Double) -> Void

    @State private var isScrubbing = false
    @State private var scrubValue: Double = 0

    private var displayProgress: Double {
        isScrubbing ? scrubValue : progress
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.2))
                Capsule()
                    .fill(Color.white.opacity(0.35))
                    .frame(width: max(0, geo.size.width * min(1, bufferedFraction)))
                Capsule()
                    .fill(Color.white)
                    .frame(width: max(0, geo.size.width * min(1, displayProgress)))
            }
            .frame(height: 4)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if !isScrubbing {
                            isScrubbing = true
                            scrubValue = progress
                            onSeekBegan()
                        }
                        let x = min(max(0, g.location.x), geo.size.width)
                        let t = geo.size.width > 0 ? x / geo.size.width : 0
                        scrubValue = t
                        onScrubPreview(t * max(duration, 0.1))
                    }
                    .onEnded { g in
                        let x = min(max(0, g.location.x), geo.size.width)
                        let t = geo.size.width > 0 ? x / geo.size.width : 0
                        scrubValue = t
                        isScrubbing = false
                        onSeekEnded(t * max(duration, 0.1))
                    }
            )
        }
        .frame(height: 28)
    }
}

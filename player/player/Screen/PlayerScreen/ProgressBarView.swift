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
            progressBar(in: geo)
        }
        .frame(height: 28)
    }

    @ViewBuilder
    private func progressBar(in geo: GeometryProxy) -> some View {
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
        .scrubGestureIfAvailable(
            in: geo,
            progress: progress,
            duration: duration,
            onSeekBegan: onSeekBegan,
            onSeekEnded: onSeekEnded,
            onScrubPreview: onScrubPreview,
            isScrubbing: $isScrubbing,
            scrubValue: $scrubValue
        )
    }
}

private extension View {
    @ViewBuilder
    func scrubGestureIfAvailable(
        in geo: GeometryProxy,
        progress: Double,
        duration: Double,
        onSeekBegan: @escaping () -> Void,
        onSeekEnded: @escaping (Double) -> Void,
        onScrubPreview: @escaping (Double) -> Void,
        isScrubbing: Binding<Bool>,
        scrubValue: Binding<Double>
    ) -> some View {
#if os(tvOS)
        self
#else
        self.gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { g in
                    if !isScrubbing.wrappedValue {
                        isScrubbing.wrappedValue = true
                        scrubValue.wrappedValue = progress
                        onSeekBegan()
                    }
                    let x = min(max(0, g.location.x), geo.size.width)
                    let t = geo.size.width > 0 ? x / geo.size.width : 0
                    scrubValue.wrappedValue = t
                    onScrubPreview(t * max(duration, 0.1))
                }
                .onEnded { g in
                    let x = min(max(0, g.location.x), geo.size.width)
                    let t = geo.size.width > 0 ? x / geo.size.width : 0
                    scrubValue.wrappedValue = t
                    isScrubbing.wrappedValue = false
                    onSeekEnded(t * max(duration, 0.1))
                }
        )
#endif
    }
}

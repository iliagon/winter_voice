import SwiftUI

/// The pill shown next to the caret: a live waveform while listening, a
/// spinner while transcribing, a drawn checkmark when the text lands, and a
/// short card on failure. It hugs the panel corner nearest the caret.
struct RecordingPanelView: View {
    @ObservedObject var model: RecordingPanelModel
    let levelMeter: AudioLevelMeter
    /// Renders the checkmark fully drawn instead of animating it, for
    /// offscreen snapshots where `onAppear` animations never run.
    var drawsCheckmarkInstantly = false

    private var cornerAnchor: UnitPoint { model.edge == .below ? .topLeading : .bottomLeading }
    private var cornerAlignment: Alignment { model.edge == .below ? .topLeading : .bottomLeading }

    var body: some View {
        content
            .scaleEffect(model.isPresented ? 1 : 0.8, anchor: cornerAnchor)
            .opacity(model.isPresented ? 1 : 0)
            .animation(.spring(response: 0.32, dampingFraction: 0.82), value: model.phase)
            .padding(4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: cornerAlignment)
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .listening:
            pill {
                PulsingMicDot()
                WaveformBars(levelMeter: levelMeter)
            }
            .transition(.opacity)
        case .transcribing:
            pill {
                BreathingDots()
            }
            .transition(.opacity)
        case .done:
            pill {
                CheckmarkBadge(drawsInstantly: drawsCheckmarkInstantly)
            }
            .transition(.opacity)
        case .failed(let failure):
            failureCard(failure)
                .transition(.opacity)
        }
    }

    /// One height for every pill state so switching phases only changes the
    /// width.
    private func pill(@ViewBuilder body: () -> some View) -> some View {
        HStack(spacing: 8) { body() }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(panelBackground(in: Capsule()))
    }

    private func failureCard(_ failure: DictationFailure) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            // Pinning the width and letting the text wrap keeps failures
            // readable; the line caps only guard against unbounded text.
            Text(failure.message)
                .font(.wv(11.5, .semibold))
                .foregroundStyle(.white)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Text(failure.recovery)
                .font(.wv(10))
                .foregroundStyle(.white.opacity(0.65))
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(width: 240, alignment: .leading)
        .background(panelBackground(in: RoundedRectangle(cornerRadius: 12, style: .continuous)))
    }

    /// On macOS 26+ the pill is true Liquid Glass refracting whatever is
    /// behind the panel; a dark tint keeps the fixed white content legible on
    /// any wallpaper. Older systems keep the black-over-material capsule.
    @ViewBuilder
    private func panelBackground(in shape: some InsettableShape) -> some View {
        if #available(macOS 26.0, *) {
            shape
                .fill(.clear)
                .glassEffect(.regular.tint(.black.opacity(0.5)), in: shape)
        } else {
            shape
                .fill(Color.black.opacity(0.78))
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        }
    }
}

private struct PulsingMicDot: View {
    var body: some View {
        TimelineView(.animation) { timeline in
            let phase = sin(timeline.date.timeIntervalSinceReferenceDate * 4)
            ZStack {
                Circle()
                    .fill(Color.red.opacity(0.35))
                    .frame(width: 13, height: 13)
                    .scaleEffect(1 + 0.18 * phase)
                Circle()
                    .fill(Color.red)
                    .frame(width: 7, height: 7)
            }
        }
        .frame(width: 14, height: 14)
    }
}

/// Seven-band live waveform driven by the real microphone RMS level.
private struct WaveformBars: View {
    let levelMeter: AudioLevelMeter

    private static let weights: [CGFloat] = [0.5, 0.75, 1.0, 1.15, 1.0, 0.75, 0.5]

    var body: some View {
        TimelineView(.animation) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let level = CGFloat(levelMeter.level)
            HStack(spacing: 2.5) {
                ForEach(0..<Self.weights.count, id: \.self) { index in
                    // Each bar dances on its own phase and speed so voice
                    // energy reads as a wave, not seven bars in lockstep.
                    let phase = time * (7.5 + Double(index) * 0.9) + Double(index) * 1.7
                    let wave = (CGFloat(sin(phase)) + 1) / 2
                    let energy = min(1, level * Self.weights[index])
                    // A faint idle breath keeps the pill alive between words;
                    // the real excursion is driven by the mic level.
                    let target = 0.06 + 0.1 * wave + energy * (0.35 + 0.65 * wave)
                    let height = 3 + 11 * min(1, target)
                    Capsule()
                        .fill(Color.white)
                        .frame(width: 2.5, height: max(3, height))
                        .animation(.spring(response: 0.15, dampingFraction: 0.7), value: height)
                }
            }
            .frame(height: 14)
        }
    }
}

/// The transcribing indicator: three dots breathing in a travelling wave.
private struct BreathingDots: View {
    var body: some View {
        TimelineView(.animation) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { index in
                    // Each dot peaks a third of a cycle after the previous one.
                    let wave = (sin(time * 6 - Double(index) * 0.9) + 1) / 2
                    Circle()
                        .fill(Color.white)
                        .frame(width: 5, height: 5)
                        .scaleEffect(0.7 + 0.45 * wave)
                        .opacity(0.4 + 0.6 * wave)
                }
            }
            .frame(height: 14)
        }
    }
}

/// A green disc whose white check stroke draws itself in.
private struct CheckmarkBadge: View {
    let drawsInstantly: Bool
    @State private var progress: CGFloat = 0

    var body: some View {
        ZStack {
            Circle()
                .fill(Color(red: 0.2, green: 0.78, blue: 0.4))
            CheckmarkShape()
                .trim(from: 0, to: drawsInstantly ? 1 : progress)
                .stroke(Color.white, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .padding(4.5)
        }
        .frame(width: 16, height: 16)
        .onAppear {
            guard !drawsInstantly else { return }
            withAnimation(.easeOut(duration: 0.25).delay(0.05)) { progress = 1 }
        }
    }
}

private struct CheckmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY + rect.height * 0.05))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.36, y: rect.maxY - rect.height * 0.1))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.12))
        return path
    }
}

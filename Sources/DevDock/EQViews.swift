import SwiftUI

/// Motion for the EQ. Presets and resets spring (knobs overshoot a little, then settle);
/// grabbing a knob swells it with a halo. Dragging itself is never animated, so a knob always
/// stays under the pointer.
enum EQMotion {
    static let settle = Animation.spring(response: 0.5, dampingFraction: 0.58)
    static let grab = Animation.spring(response: 0.28, dampingFraction: 0.5)
}

/// Shared measurements for the knobs and the curve. A plain enum (not a View) so the curve
/// shape's path(in:), which isn't main-actor isolated, can use it.
enum EQGeometry {
    static let knobSize: CGFloat = 12

    /// Distance from the 0 dB line to a knob's center at full boost.
    static func usableHalfHeight(for height: CGFloat) -> CGFloat {
        max(height / 2 - knobSize / 2 - 2, 1)
    }

    /// The glowing line through the knobs: a Catmull-Rom spline drawn as Bezier curves.
    static func curvePath(gains: [Double], maxGain: Double, size: CGSize) -> Path {
        guard !gains.isEmpty, maxGain > 0 else { return Path() }
        let count = CGFloat(gains.count)
        let usable = usableHalfHeight(for: size.height)
        var points = gains.enumerated().map { item in
            CGPoint(
                x: (CGFloat(item.offset) + 0.5) / count * size.width,
                y: size.height / 2 - CGFloat(item.element / maxGain) * usable
            )
        }
        guard let first = points.first, let last = points.last else { return Path() }
        points.insert(CGPoint(x: 0, y: first.y), at: 0)
        points.append(CGPoint(x: size.width, y: last.y))

        var path = Path()
        path.move(to: points[0])
        for i in 0..<(points.count - 1) {
            let p0 = points[max(i - 1, 0)]
            let p1 = points[i]
            let p2 = points[i + 1]
            let p3 = points[min(i + 2, points.count - 1)]
            let control1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let control2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: control1, control2: control2)
        }
        return path
    }
}

/// The EQ block: header with the on/off switch, the band graph, preset buttons, status line.
struct EQSection: View {
    @Environment(\.theme) private var theme
    @ObservedObject var eq: EQController
    let spectrum: SpectrumAnalyzer

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 6), count: 4)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Equalizer")
                    .font(theme.font(12, .semibold))
                    .foregroundStyle(theme.textPrimary)
                Text(eq.preset.title)
                    .font(theme.font(10, .medium))
                    .foregroundStyle(theme.accent)
                    .contentTransition(.opacity)
                Spacer()
                Toggle("Equalizer", isOn: Binding(get: { eq.isEnabled }, set: { eq.setEnabled($0) }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .tint(theme.accent)
                    .help(eq.isEnabled ? "On: all system audio runs through the EQ" : "Off: audio plays normally")
            }

            EQGraph(eq: eq, spectrum: spectrum)
                .frame(height: 128)
                .opacity(eq.isEnabled ? 1 : 0.55)

            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(EQPreset.buttons) { preset in
                    let selected = eq.preset == preset
                    Button {
                        // The knobs and the curve spring to the new preset together.
                        withAnimation(reduceMotion ? nil : EQMotion.settle) {
                            eq.select(preset)
                        }
                    } label: {
                        Text(preset.title)
                            .font(theme.font(10, .semibold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 22)
                            .foregroundStyle(selected ? Color.black : theme.textSecondary)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(selected ? theme.accent : Color.white.opacity(0.05))
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            if let message = eq.statusMessage {
                Text(message)
                    .font(theme.font(10))
                    .foregroundStyle(Color.orange.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Ten draggable bands over a live spectrum, joined by a glowing curve.
struct EQGraph: View {
    @Environment(\.theme) private var theme
    @ObservedObject var eq: EQController
    let spectrum: SpectrumAnalyzer

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geometry in
                let size = geometry.size
                ZStack {
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: size.height / 2))
                        path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                    }
                    .stroke(Color.white.opacity(0.08), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))

                    SpectrumGlow(spectrum: spectrum)

                    EQCurve(gains: eq.gains, maxGain: EQController.maxGain)

                    HStack(spacing: 0) {
                        ForEach(0..<eq.gains.count, id: \.self) { band in
                            EQBandSlider(
                                value: eq.gains[band],
                                maxGain: EQController.maxGain,
                                onChange: { eq.setGain($0, at: band) },
                                onReset: { eq.resetBand(band) }
                            )
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            HStack(spacing: 0) {
                ForEach(EQController.labels, id: \.self) { label in
                    Text(label)
                        .frame(maxWidth: .infinity)
                }
            }
            .font(theme.mono(9, .medium))
            .foregroundStyle(theme.textSecondary)
        }
    }
}

/// Ten gains SwiftUI can interpolate, so the curve springs between presets in step with the knobs.
struct AnimatableGains: VectorArithmetic {
    var values: [Double]

    static var zero: AnimatableGains { AnimatableGains(values: []) }

    static func + (lhs: AnimatableGains, rhs: AnimatableGains) -> AnimatableGains {
        combine(lhs, rhs, +)
    }

    static func - (lhs: AnimatableGains, rhs: AnimatableGains) -> AnimatableGains {
        combine(lhs, rhs, -)
    }

    mutating func scale(by rhs: Double) {
        values = values.map { $0 * rhs }
    }

    var magnitudeSquared: Double {
        values.reduce(0) { $0 + $1 * $1 }
    }

    /// Element-wise, treating a missing element as 0 (`zero` is empty).
    private static func combine(
        _ lhs: AnimatableGains,
        _ rhs: AnimatableGains,
        _ operation: (Double, Double) -> Double
    ) -> AnimatableGains {
        let count = max(lhs.values.count, rhs.values.count)
        return AnimatableGains(values: (0..<count).map { index in
            operation(
                index < lhs.values.count ? lhs.values[index] : 0,
                index < rhs.values.count ? rhs.values[index] : 0
            )
        })
    }
}

struct EQCurveShape: Shape {
    var gains: AnimatableGains
    let maxGain: Double

    var animatableData: AnimatableGains {
        get { gains }
        set { gains = newValue }
    }

    func path(in rect: CGRect) -> Path {
        EQGeometry.curvePath(gains: gains.values, maxGain: maxGain, size: rect.size)
    }
}

/// The glowing line through the knobs.
struct EQCurve: View {
    @Environment(\.theme) private var theme
    let gains: [Float]
    let maxGain: Float

    var body: some View {
        let shape = EQCurveShape(
            gains: AnimatableGains(values: gains.map { Double($0) }),
            maxGain: Double(maxGain)
        )
        ZStack {
            shape
                .stroke(theme.accent.opacity(0.7), lineWidth: 4)
                .blur(radius: 6)
            shape
                .stroke(theme.accent, lineWidth: 1.6)
        }
        .allowsHitTesting(false)
    }
}

/// The live spectrum as a soft filled glow. The only view that redraws at 30 fps.
struct SpectrumGlow: View {
    @Environment(\.theme) private var theme
    @ObservedObject var spectrum: SpectrumAnalyzer

    var body: some View {
        Canvas { context, size in
            let levels = spectrum.levels
            guard levels.count > 1 else { return }
            let step = size.width / CGFloat(levels.count - 1)
            var path = Path()
            path.move(to: CGPoint(x: 0, y: size.height))
            for (index, level) in levels.enumerated() {
                path.addLine(to: CGPoint(x: CGFloat(index) * step, y: size.height - CGFloat(level) * size.height * 0.9))
            }
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.closeSubpath()
            let gradient = Gradient(colors: [theme.accent.opacity(0.35), theme.accent.opacity(0.02)])
            context.fill(
                path,
                with: .linearGradient(gradient, startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height))
            )
        }
        .blur(radius: 1.5)
        .allowsHitTesting(false)
    }
}

/// One vertical band: drag to set (half-dB steps), double-click to spring back to 0 dB.
/// While held, the knob swells and a halo blooms around it; on release it bounces back.
struct EQBandSlider: View {
    @Environment(\.theme) private var theme
    let value: Float
    let maxGain: Float
    let onChange: (Float) -> Void
    let onReset: () -> Void

    @State private var isDragging = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            let usable = EQGeometry.usableHalfHeight(for: height)
            let middle = height / 2
            let y = middle - CGFloat(value / maxGain) * usable
            let centerX = geometry.size.width / 2
            ZStack {
                Capsule()
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 3, height: height)
                    .position(x: centerX, y: middle)
                // Fill from 0 dB to the value.
                Capsule()
                    .fill(theme.accent.opacity(0.85))
                    .frame(width: 3, height: max(abs(y - middle), 1))
                    .position(x: centerX, y: (y + middle) / 2)
                knob
                    .position(x: centerX, y: y)
            }
            .frame(width: geometry.size.width, height: height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        if !isDragging {
                            isDragging = true
                        }
                        let raw = Float((middle - drag.location.y) / usable) * maxGain
                        onChange((raw * 2).rounded() / 2)
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )
            .simultaneousGesture(
                TapGesture(count: 2).onEnded {
                    withAnimation(reduceMotion ? nil : EQMotion.settle) {
                        onReset()
                    }
                }
            )
        }
    }

    /// The `.animation` sits below `.position` (applied by the caller), so only the swell and
    /// halo animate on grab; the knob's position follows the pointer instantly.
    private var knob: some View {
        ZStack {
            Circle()
                .stroke(theme.accent.opacity(0.45), lineWidth: 1)
                .frame(width: EQGeometry.knobSize * 2.2, height: EQGeometry.knobSize * 2.2)
                .scaleEffect(isDragging ? 1 : 0.4)
                .opacity(isDragging ? 1 : 0)
            Circle()
                .fill(theme.accent)
                .frame(width: EQGeometry.knobSize, height: EQGeometry.knobSize)
                .shadow(color: theme.accent.opacity(isDragging ? 1 : 0.9), radius: isDragging ? 8 : 4)
                .scaleEffect(isDragging ? 1.35 : 1)
        }
        .animation(reduceMotion ? nil : EQMotion.grab, value: isDragging)
    }
}

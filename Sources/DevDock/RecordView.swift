import AppKit
import QuartzCore
import SwiftUI

/// A vinyl record with the album art as its label. The spin is a Core Animation layer
/// animation, so the GPU does the work and SwiftUI doesn't redraw every frame.
struct RecordView: NSViewRepresentable {
    var artwork: NSImage?
    var artworkKey: Int
    var isSpinning: Bool
    var accentHex: String

    func makeNSView(context: Context) -> RecordLayerView {
        RecordLayerView(frame: .zero)
    }

    func updateNSView(_ view: RecordLayerView, context: Context) {
        view.setArtwork(artwork, key: artworkKey)
        view.setAccent(hex: accentHex)
        view.setSpinning(isSpinning)
    }
}

final class RecordLayerView: NSView {
    /// 33⅓ rpm.
    private static let secondsPerTurn: Double = 1.8
    private static let spinUpDuration: Double = 0.6
    private static let coastDuration: Double = 0.9
    private static var angularSpeed: Double { 2 * Double.pi / secondsPerTurn }

    // Rotating parts.
    private let spinLayer = CALayer()
    private let discLayer = CAShapeLayer()
    private let grooveLayer = CAShapeLayer()
    private let labelLayer = CALayer()
    private let labelMarkLayer = CALayer() // shows the spin when there's no artwork

    // Fixed parts drawn over the spinning disc.
    private let sheenLayer = CAGradientLayer()
    private let sheenMask = CAShapeLayer()
    private let holeLayer = CAShapeLayer()
    private let rimLayer = CAShapeLayer()

    private var artworkKey = Int.min
    private var accentHex = ""
    private var spinning = false
    private var transitionToken = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setUpLayers()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Clicks go to whatever is underneath (the panel handles record clicks itself).
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        layoutLayers()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        for layer in [spinLayer, discLayer, grooveLayer, labelLayer, labelMarkLayer, sheenLayer, sheenMask, holeLayer, rimLayer] {
            layer.contentsScale = scale
        }
    }

    func setArtwork(_ image: NSImage?, key: Int) {
        guard key != artworkKey else { return }
        artworkKey = key
        let cgImage = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        let fade = CATransition()
        fade.type = .fade
        fade.duration = 0.25
        labelLayer.add(fade, forKey: "artwork")
        labelLayer.contents = cgImage
        labelMarkLayer.isHidden = cgImage != nil
    }

    /// The label (shown without artwork) and the glowing rim follow the accent color.
    func setAccent(hex: String) {
        guard hex != accentHex else { return }
        accentHex = hex
        let accent = HexColor.nsColor(hex) ?? DevDockTheme.standard.accentNS
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        labelLayer.backgroundColor = accent.withAlphaComponent(0.8).cgColor
        rimLayer.strokeColor = accent.withAlphaComponent(0.55).cgColor
        rimLayer.shadowColor = accent.cgColor
        CATransaction.commit()
    }

    func setSpinning(_ shouldSpin: Bool) {
        let target = shouldSpin && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard target != spinning else { return }
        spinning = target
        transitionToken += 1
        let token = transitionToken

        let angle = currentAngle()
        spinLayer.removeAnimation(forKey: "spin")
        setModelAngle(angle)

        // Negative angles turn clockwise, like a real turntable seen from above.
        if target {
            // Spin up with a quadratic ease-in, ending at exactly 33⅓ rpm.
            let end = angle - Self.angularSpeed * Self.spinUpDuration / 2
            CATransaction.begin()
            // Core Animation runs completion blocks on the main thread.
            CATransaction.setCompletionBlock { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.transitionToken == token else { return }
                    self.startSteadySpin(from: end)
                }
            }
            let ramp = CABasicAnimation(keyPath: "transform.rotation.z")
            ramp.fromValue = angle
            ramp.toValue = end
            ramp.duration = Self.spinUpDuration
            ramp.timingFunction = CAMediaTimingFunction(controlPoints: 0.33, 0, 0.67, 0.33)
            setModelAngle(end)
            spinLayer.add(ramp, forKey: "spin")
            CATransaction.commit()
        } else {
            // Coast to a stop with a quadratic ease-out that starts at full speed.
            let end = angle - Self.angularSpeed * Self.coastDuration / 2
            let coast = CABasicAnimation(keyPath: "transform.rotation.z")
            coast.fromValue = angle
            coast.toValue = end
            coast.duration = Self.coastDuration
            coast.timingFunction = CAMediaTimingFunction(controlPoints: 0.33, 0.67, 0.67, 1)
            setModelAngle(end)
            spinLayer.add(coast, forKey: "spin")
        }
    }

    // MARK: - Private

    private func startSteadySpin(from angle: Double) {
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = angle
        spin.toValue = angle - 2 * Double.pi
        spin.duration = Self.secondsPerTurn
        spin.repeatCount = .infinity
        setModelAngle(angle)
        spinLayer.add(spin, forKey: "spin")
    }

    private func currentAngle() -> Double {
        let source = spinLayer.presentation() ?? spinLayer
        return (source.value(forKeyPath: "transform.rotation.z") as? NSNumber)?.doubleValue ?? 0
    }

    private func setModelAngle(_ angle: Double) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        spinLayer.setValue(angle, forKeyPath: "transform.rotation.z")
        CATransaction.commit()
    }

    private func setUpLayers() {
        guard let root = layer else { return }
        root.masksToBounds = false

        discLayer.fillColor = NSColor(white: 0.06, alpha: 1).cgColor
        grooveLayer.fillColor = nil
        grooveLayer.strokeColor = NSColor(white: 1, alpha: 0.07).cgColor
        grooveLayer.lineWidth = 0.5
        labelLayer.contentsGravity = .resizeAspectFill
        labelLayer.masksToBounds = true
        labelLayer.backgroundColor = DevDockTheme.standard.accentNS.withAlphaComponent(0.8).cgColor
        labelMarkLayer.backgroundColor = NSColor(white: 1, alpha: 0.85).cgColor

        spinLayer.addSublayer(discLayer)
        spinLayer.addSublayer(grooveLayer)
        spinLayer.addSublayer(labelLayer)
        spinLayer.addSublayer(labelMarkLayer)

        // A light reflection that stays put while the disc turns underneath it.
        sheenLayer.type = .conic
        let clear = NSColor(white: 1, alpha: 0).cgColor
        sheenLayer.colors = [
            clear,
            NSColor(white: 1, alpha: 0.13).cgColor,
            clear,
            clear,
            NSColor(white: 1, alpha: 0.09).cgColor,
            clear,
        ]
        sheenLayer.locations = [0, 0.1, 0.22, 0.5, 0.6, 0.72]
        sheenLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        sheenLayer.endPoint = CGPoint(x: 0.5, y: 1)
        sheenLayer.mask = sheenMask

        holeLayer.fillColor = NSColor.black.cgColor
        holeLayer.strokeColor = NSColor(white: 1, alpha: 0.25).cgColor
        holeLayer.lineWidth = 0.5

        rimLayer.fillColor = nil
        rimLayer.strokeColor = DevDockTheme.standard.accentNS.withAlphaComponent(0.55).cgColor
        rimLayer.lineWidth = 1
        rimLayer.shadowColor = DevDockTheme.standard.accentNS.cgColor
        rimLayer.shadowOpacity = 0.75
        rimLayer.shadowRadius = 5
        rimLayer.shadowOffset = .zero

        root.addSublayer(spinLayer)
        root.addSublayer(sheenLayer)
        root.addSublayer(holeLayer)
        root.addSublayer(rimLayer)
    }

    private func layoutLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let side = min(bounds.width, bounds.height)
        guard side > 0 else { return }
        let rect = CGRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
        let local = CGRect(origin: .zero, size: rect.size)

        // Bounds and position, not frame, because spinLayer carries a rotation.
        spinLayer.bounds = local
        spinLayer.position = CGPoint(x: rect.midX, y: rect.midY)

        discLayer.frame = local
        discLayer.path = CGPath(ellipseIn: local, transform: nil)
        grooveLayer.frame = local
        grooveLayer.path = Self.groovePath(in: local)

        let labelSide = side * 0.42
        labelLayer.frame = CGRect(x: local.midX - labelSide / 2, y: local.midY - labelSide / 2, width: labelSide, height: labelSide)
        labelLayer.cornerRadius = labelSide / 2

        let mark = max(2, side * 0.04)
        labelMarkLayer.frame = CGRect(x: local.midX - mark / 2, y: local.midY + labelSide * 0.28, width: mark, height: mark)
        labelMarkLayer.cornerRadius = mark / 2

        sheenLayer.frame = rect
        sheenMask.frame = local
        sheenMask.path = CGPath(ellipseIn: local, transform: nil)

        let hole = max(3, side * 0.05)
        holeLayer.frame = rect
        holeLayer.path = CGPath(ellipseIn: CGRect(x: side / 2 - hole / 2, y: side / 2 - hole / 2, width: hole, height: hole), transform: nil)

        rimLayer.frame = rect
        rimLayer.path = CGPath(ellipseIn: local.insetBy(dx: 0.5, dy: 0.5), transform: nil)
    }

    private static func groovePath(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = rect.width * 0.47
        let step = max(1.2, rect.width * 0.022)
        var radius = rect.width * 0.24
        while radius < outer {
            path.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            radius += step
        }
        return path
    }
}

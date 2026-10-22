import AppKit
import CoreGraphics

/// The VYNL logo, a record with two pairs of groove highlights and a label, drawn in code for
/// the menu bar. It's a template image: the record is opaque and the grooves, label ring and
/// spindle gap are cut out, so macOS tints it to match the menu bar.
/// Proportions match AppIcon.icns (radius R): label 0.338, spindle 0.087, grooves at 0.545 and
/// 0.769, spanning 117°–177° and the same turned half a circle.
enum VynlLogo {
    static func menuBarImage(size: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        for scale in [1, 2, 3] {
            let pixels = Int(size) * scale
            guard let cgImage = render(pixels: pixels, points: size) else { continue }
            let representation = NSBitmapImageRep(cgImage: cgImage)
            representation.size = NSSize(width: size, height: size)
            image.addRepresentation(representation)
        }
        image.isTemplate = true
        return image
    }

    private static func render(pixels: Int, points: CGFloat) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: pixels,
            height: pixels,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let scale = CGFloat(pixels) / points
        context.scaleBy(x: scale, y: scale)

        // y points up here, so angles run counterclockwise like the math.
        let radius = points / 2 * 0.94
        let center = CGPoint(x: points / 2, y: points / 2)
        func circle(_ r: CGFloat) -> CGRect {
            CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
        }

        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fillEllipse(in: circle(radius))

        context.setBlendMode(.clear)
        // A touch thicker than in the app icon so the grooves survive at menu bar size.
        context.setLineWidth(radius * 0.1)
        context.setLineCap(.round)
        for turn in [0.0, 180.0] {
            for (fraction, start, end) in [(0.545, 118.0, 176.0), (0.769, 117.0, 177.0)] {
                context.beginPath()
                context.addArc(
                    center: center,
                    radius: radius * fraction,
                    startAngle: (turn + start) * .pi / 180,
                    endAngle: (turn + end) * .pi / 180,
                    clockwise: false
                )
                context.strokePath()
            }
        }
        context.fillEllipse(in: circle(radius * 0.338))

        context.setBlendMode(.normal)
        context.fillEllipse(in: circle(radius * 0.087))
        return context.makeImage()
    }
}

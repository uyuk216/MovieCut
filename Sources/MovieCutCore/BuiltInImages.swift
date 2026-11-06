import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - 同梱の背景・図形(コードで描く。第三者の素材は使わない)

public enum BuiltInImages {
    public struct Spec: Equatable, Sendable {
        public let id: String
        public let title: String
        /// 図形・スタンプ(透明な背景の正方形)なら true。背景・パターンは false(1280×720・不透明)。
        public let isShape: Bool
    }

    public static let backgroundSize = (w: 1280, h: 720)
    public static let shapeSize = 512

    public static let specs: [Spec] = [
        Spec(id: "bgSunset", title: "背景-夕焼け", isShape: false),
        Spec(id: "bgOcean", title: "背景-うみ", isShape: false),
        Spec(id: "bgMint", title: "背景-ミント", isShape: false),
        Spec(id: "bgNight", title: "背景-夜空", isShape: false),
        Spec(id: "bgDots", title: "背景-みずたま", isShape: false),
        Spec(id: "bgStripes", title: "背景-ストライプ", isShape: false),
        Spec(id: "shapeCircle", title: "図形-まる", isShape: true),
        Spec(id: "shapeStar", title: "図形-ほし", isShape: true),
        Spec(id: "shapeHeart", title: "図形-ハート", isShape: true),
        Spec(id: "shapeArrow", title: "図形-やじるし", isShape: true),
        Spec(id: "shapeBubble", title: "図形-ふきだし", isShape: true),
        Spec(id: "shapeHexagon", title: "図形-ろっかく", isShape: true),
    ]

    private static func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
        CGColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    private static func context(_ w: Int, _ h: Int) -> CGContext? {
        CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    private static func linear(_ c: CGContext, _ colors: [CGColor], from: CGPoint, to: CGPoint) {
        let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
        c.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    /// 1 枚の画像(未知の id は nil)。
    public static func render(_ id: String) -> CGImage? {
        guard let spec = specs.first(where: { $0.id == id }) else { return nil }
        if spec.isShape { return renderShape(id) }
        let w = backgroundSize.w, h = backgroundSize.h
        guard let c = context(w, h) else { return nil }
        let W = Double(w), H = Double(h)
        switch id {
        case "bgSunset":
            linear(c, [rgb(0.99, 0.80, 0.45), rgb(0.97, 0.45, 0.45), rgb(0.45, 0.25, 0.60)], from: CGPoint(x: 0, y: H), to: CGPoint(x: 0, y: 0))
        case "bgOcean":
            linear(c, [rgb(0.55, 0.85, 0.95), rgb(0.10, 0.45, 0.80), rgb(0.03, 0.15, 0.40)], from: CGPoint(x: 0, y: H), to: CGPoint(x: W * 0.3, y: 0))
        case "bgMint":
            linear(c, [rgb(0.88, 1.00, 0.93), rgb(0.55, 0.88, 0.75), rgb(0.30, 0.70, 0.65)], from: CGPoint(x: 0, y: H), to: CGPoint(x: W, y: 0))
        case "bgNight":
            c.setFillColor(rgb(0.04, 0.05, 0.14)); c.fill(CGRect(x: 0, y: 0, width: W, height: H))
            let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [rgb(0.25, 0.20, 0.55), rgb(0.04, 0.05, 0.14)] as CFArray, locations: nil)!
            c.drawRadialGradient(g, startCenter: CGPoint(x: W * 0.5, y: H * 0.35), startRadius: 0, endCenter: CGPoint(x: W * 0.5, y: H * 0.35), endRadius: W * 0.7, options: [.drawsAfterEndLocation])
            var s: UInt64 = 12345   // 星(固定の種)
            c.setFillColor(rgb(1, 1, 0.9, 0.9))
            for _ in 0..<90 {
                s = s &* 6364136223846793005 &+ 1442695040888963407; let x = Double((s >> 33) % UInt64(w))
                s = s &* 6364136223846793005 &+ 1442695040888963407; let y = Double((s >> 33) % UInt64(h))
                s = s &* 6364136223846793005 &+ 1442695040888963407; let r = 1 + Double((s >> 33) % 3)
                c.fillEllipse(in: CGRect(x: x, y: y, width: r, height: r))
            }
        case "bgDots":
            c.setFillColor(rgb(1.0, 0.93, 0.80)); c.fill(CGRect(x: 0, y: 0, width: W, height: H))
            c.setFillColor(rgb(1.0, 0.72, 0.55))
            let step = 64.0
            var row = 0
            var y = 0.0
            while y < H + step { var x = (row % 2 == 0) ? 0.0 : step / 2
                while x < W + step { c.fillEllipse(in: CGRect(x: x - 12, y: y - 12, width: 24, height: 24)); x += step }
                y += step / 2; row += 1 }
        case "bgStripes":
            c.setFillColor(rgb(0.93, 0.96, 1.0)); c.fill(CGRect(x: 0, y: 0, width: W, height: H))
            c.setFillColor(rgb(0.72, 0.82, 0.97))
            var x = -H
            while x < W {
                c.move(to: CGPoint(x: x, y: 0)); c.addLine(to: CGPoint(x: x + 40, y: 0))
                c.addLine(to: CGPoint(x: x + 40 + H, y: H)); c.addLine(to: CGPoint(x: x + H, y: H)); c.closePath()
                c.fillPath(); x += 80
            }
        default: return nil
        }
        return c.makeImage()
    }

    private static func renderShape(_ id: String) -> CGImage? {
        let n = shapeSize
        guard let c = context(n, n) else { return nil }
        let S = Double(n), m = S * 0.08
        let fill: CGColor, line = rgb(1, 1, 1)
        let path = CGMutablePath()
        let ctr = CGPoint(x: S / 2, y: S / 2), R = S / 2 - m
        switch id {
        case "shapeCircle":
            fill = rgb(0.95, 0.35, 0.40)
            path.addEllipse(in: CGRect(x: m, y: m, width: S - 2 * m, height: S - 2 * m))
        case "shapeStar":
            fill = rgb(1.0, 0.80, 0.20)
            for i in 0..<10 {
                let a = Double.pi / 2 + Double(i) * Double.pi / 5
                let r = i % 2 == 0 ? R : R * 0.42
                let p = CGPoint(x: ctr.x + r * cos(a), y: ctr.y + r * sin(a))
                if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            path.closeSubpath()
        case "shapeHeart":
            fill = rgb(0.96, 0.30, 0.50)
            path.move(to: CGPoint(x: S / 2, y: m))
            path.addCurve(to: CGPoint(x: m, y: S * 0.62), control1: CGPoint(x: S * 0.30, y: S * 0.22), control2: CGPoint(x: m, y: S * 0.40))
            path.addCurve(to: CGPoint(x: S / 2, y: S * 0.72), control1: CGPoint(x: m, y: S * 0.86), control2: CGPoint(x: S * 0.40, y: S * 0.90))
            path.addCurve(to: CGPoint(x: S - m, y: S * 0.62), control1: CGPoint(x: S * 0.60, y: S * 0.90), control2: CGPoint(x: S - m, y: S * 0.86))
            path.addCurve(to: CGPoint(x: S / 2, y: m), control1: CGPoint(x: S - m, y: S * 0.40), control2: CGPoint(x: S * 0.70, y: S * 0.22))
            path.closeSubpath()
        case "shapeArrow":
            fill = rgb(0.25, 0.60, 0.95)
            let pts = [(m, S * 0.38), (S * 0.55, S * 0.38), (S * 0.55, S * 0.18), (S - m, S / 2), (S * 0.55, S * 0.82), (S * 0.55, S * 0.62), (m, S * 0.62)]
            for (i, p) in pts.enumerated() { let q = CGPoint(x: p.0, y: p.1); if i == 0 { path.move(to: q) } else { path.addLine(to: q) } }
            path.closeSubpath()
        case "shapeBubble":
            fill = rgb(0.98, 0.98, 1.0)
            path.addRoundedRect(in: CGRect(x: m, y: S * 0.28, width: S - 2 * m, height: S * 0.60), cornerWidth: S * 0.18, cornerHeight: S * 0.18)
            path.move(to: CGPoint(x: S * 0.28, y: S * 0.30)); path.addLine(to: CGPoint(x: S * 0.20, y: m)); path.addLine(to: CGPoint(x: S * 0.48, y: S * 0.30)); path.closeSubpath()
        case "shapeHexagon":
            fill = rgb(0.35, 0.80, 0.55)
            for i in 0..<6 {
                let a = Double(i) * Double.pi / 3
                let p = CGPoint(x: ctr.x + R * cos(a), y: ctr.y + R * sin(a))
                if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            path.closeSubpath()
        default: return nil
        }
        c.setFillColor(fill); c.setStrokeColor(line); c.setLineWidth(S * 0.025); c.setLineJoin(.round)
        c.addPath(path); c.drawPath(using: .fillStroke)
        return c.makeImage()
    }

    public static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}

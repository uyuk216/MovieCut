import Foundation
import CoreGraphics
import ImageIO

// アプリアイコンの絵を 1 枚描く。
// 使い方: swift Scripts/icon-draw.swift <一辺px> <出力.png>
// macOS のアイコングリッド(1024 の中に 824 の本体)に沿い、外部素材は使わない。
// 絵柄: 青→藍のグラデーションの角丸四角 + 白い再生三角 + タイムラインの帯 2 本
//       + 再生ヘッド(タイムラインの選択色 #FFD84F の小さな印)。
let args = CommandLine.arguments
guard args.count == 3, let size = Double(args[1]), size > 0 else {
    FileHandle.standardError.write("usage: icon-draw <size> <out.png>\n".data(using: .utf8)!)
    exit(2)
}
let S = CGFloat(size)
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
func rgba(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat) -> CGColor {
    CGColor(colorSpace: cs, components: [r, g, b, a])!
}
guard let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8,
                          bytesPerRow: 0, space: cs,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }

// 本体(角丸の四角)
let body = 824.0 / 1024.0 * S
let bx = (S - body) / 2, by = (S - body) / 2
let bodyRect = CGRect(x: bx, y: by, width: body, height: body)
let bodyPath = CGPath(roundedRect: bodyRect, cornerWidth: body * 0.2245, cornerHeight: body * 0.2245, transform: nil)

// グラデーション(上が明るい青、下が藍)
let grad = CGGradient(colorsSpace: cs, colors: [rgba(0.36, 0.58, 1.0, 1), rgba(0.18, 0.27, 0.80, 1)] as CFArray, locations: [0, 1])!
ctx.saveGState()
ctx.addPath(bodyPath)
ctx.clip()
ctx.drawLinearGradient(grad, start: CGPoint(x: bx, y: by + body), end: CGPoint(x: bx + body, y: by), options: [])
ctx.restoreGState()

// 再生ボタン(白い三角。角は丸める)
let tw = 0.30 * S, th = 0.34 * S
let cx = S * 0.525, cy = S * 0.585
let tri = CGMutablePath()
tri.move(to: CGPoint(x: cx - tw / 2, y: cy - th / 2))
tri.addLine(to: CGPoint(x: cx - tw / 2, y: cy + th / 2))
tri.addLine(to: CGPoint(x: cx + tw / 2, y: cy))
tri.closeSubpath()
ctx.saveGState()
ctx.addPath(tri)
ctx.setFillColor(rgba(1, 1, 1, 1))
ctx.setStrokeColor(rgba(1, 1, 1, 1))
ctx.setLineWidth(0.035 * S)
ctx.setLineJoin(.round)
ctx.drawPath(using: .fillStroke)
ctx.restoreGState()

// タイムラインの帯(2 本)
func bar(y: CGFloat, w: CGFloat, alpha: CGFloat) {
    let h = 0.042 * S
    let r = CGRect(x: bx + 0.105 * S, y: y, width: w, height: h)
    ctx.addPath(CGPath(roundedRect: r, cornerWidth: h / 2, cornerHeight: h / 2, transform: nil))
    ctx.setFillColor(rgba(1, 1, 1, alpha))
    ctx.fillPath()
}
bar(y: S * 0.265, w: 0.50 * S, alpha: 0.95)
bar(y: S * 0.185, w: 0.36 * S, alpha: 0.55)

// 再生ヘッド(帯を横切る黄色い小さな印)
let hx = bx + 0.105 * S + 0.30 * S
let hr = CGRect(x: hx, y: S * 0.235, width: 0.016 * S, height: 0.105 * S)
ctx.addPath(CGPath(roundedRect: hr, cornerWidth: 0.008 * S, cornerHeight: 0.008 * S, transform: nil))
ctx.setFillColor(rgba(1.0, 0.847, 0.31, 1))
ctx.fillPath()

guard let img = ctx.makeImage() else { exit(1) }
let url = URL(fileURLWithPath: args[2]) as CFURL
guard let dest = CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil) else { exit(1) }
CGImageDestinationAddImage(dest, img, nil)
guard CGImageDestinationFinalize(dest) else { exit(1) }

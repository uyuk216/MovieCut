import Foundation
import CoreGraphics
import CoreText
import CoreImage

// MARK: - 色

/// "#rrggbb" / "#rgb"(先頭の # は省略可)を sRGB の CGColor に。
public func parseHexColor(_ s: String) -> CGColor? {
    var h = s.trimmingCharacters(in: .whitespaces)
    if h.hasPrefix("#") { h.removeFirst() }
    if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
    guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
    return CGColor(srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
}

private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
private let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
/// CoreImage は sRGB(ガンマ空間)で処理して、CSS の blur() と同じ見た目にする。共有してコンテキスト作成コストを避ける。
private let ciContext = CIContext(options: [.workingColorSpace: sRGB, .outputColorSpace: sRGB])

// MARK: - Renderer

/// 時刻 t のフレームを描く(renderer.js draw() と同じ)。座標は左上原点、ctx は project.width × project.height。
public struct Renderer {
    public let project: Project
    public let assets: RenderAssets

    public init(project: Project, assets: RenderAssets) {
        self.project = project
        self.assets = assets
    }

    public func renderImage(t: Double) -> CGImage? {
        guard let ctx = Renderer.makeContext(width: project.width, height: project.height) else { return nil }
        render(t: t, into: ctx)
        return ctx.makeImage()
    }

    /// BGRA / premultipliedFirst の CGContext(書き出しの CVPixelBuffer と同じ並び)。
    static func makeContext(width: Int, height: Int) -> CGContext? {
        let c = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB, bitmapInfo: bitmapInfo)
        c?.interpolationQuality = .high
        return c
    }

    public func render(t: Double, into ctx: CGContext) {
        let W = Double(project.width), H = Double(project.height)
        ctx.saveGState()
        defer { ctx.restoreGState() }
        // 左上原点にする(画像や文字は描くときに局所的に上下を戻す)
        ctx.translateBy(x: 0, y: CGFloat(ctx.height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high

        ctx.setFillColor(parseHexColor(project.bg) ?? CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))

        var speaking: [String: Clip] = [:]  // charId -> 最後に見つかったボイス
        var subtitles: [Clip] = []

        for tr in project.tracks where !tr.isHidden {
            for c in tr.clips where t >= c.start && t < c.start + c.duration {
                switch c.type {
                case .blur:
                    drawBlurRegion(c, ctx: ctx, W: W, H: H)
                case .image, .video, .text:
                    if c.blurOrDefault > 0 {
                        drawBlurredClip(c, t: t, ctx: ctx, W: W, H: H)
                    } else {
                        ctx.saveGState()
                        ctx.setAlpha(CGFloat(c.opacityOrDefault))
                        drawClipContent(c, t: t, ctx: ctx, W: W, H: H)
                        ctx.restoreGState()
                    }
                case .voice:
                    if let id = c.charId { speaking[id] = c }
                    if c.subtitle != false { subtitles.append(c) }
                default:
                    break  // audio と未知の type は描かない
                }
            }
        }

        // 立ち絵(しゃべっている間は口パク)
        for ch in project.characters {
            let v = speaking[ch.id]
            if v == nil && !ch.alwaysShow { continue }
            let open = v.map { mouthOpen($0, t: t) } ?? false
            let path = (open && ch.imgOpen != nil) ? ch.imgOpen : ch.imgClosed
            guard let p = path, let img = assets.image(at: p), img.height > 0 else { continue }
            let h = H * 0.6 * ch.scale
            let w = Double(img.width) * (h / Double(img.height))
            ctx.saveGState()
            ctx.translateBy(x: CGFloat(ch.x * W), y: CGFloat(ch.y * H))
            if ch.flip { ctx.scaleBy(x: -1, y: 1) }
            drawCG(ctx, img, CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
            ctx.restoreGState()
        }

        // 字幕(キャラの色で縁取り)
        for c in subtitles {
            let ch = project.characters.first { $0.id == c.charId }
            drawText(c.text ?? "", x: W / 2, y: H * 0.88, size: c.fontSize ?? 64, color: "#ffffff", font: c.fontOrDefault, outline: ch?.color ?? "#000000", ctx: ctx)
        }
    }

    // MARK: 口パク

    func mouthOpen(_ clip: Clip, t: Double) -> Bool {
        guard let src = clip.src, let env = assets.mouthEnvelope(for: src) else { return false }
        let i = Int(floor((t - clip.start + clip.offset) * 60))
        return i >= 0 && i < env.count && env[i] > 0.03
    }

    // MARK: クリップ本体

    /// 上下反転した ctx(左上原点)に CGImage を rect へ描く。
    func drawCG(_ ctx: CGContext, _ img: CGImage, _ rect: CGRect) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        ctx.restoreGState()
    }

    /// image / video / text を現在の alpha で描く。
    func drawClipContent(_ c: Clip, t: Double, ctx: CGContext, W: Double, H: Double) {
        switch c.type {
        case .image, .video:
            var img: CGImage?
            if let src = c.src {
                img = c.type == .image ? assets.image(at: src) : assets.videoFrame(path: src, time: t - c.start + c.offset)
            }
            guard let im = img, im.width > 0, im.height > 0 else { return }
            let w0 = Double(im.width), h0 = Double(im.height)
            let fit = min(W / w0, H / h0) * c.scaleOrDefault
            let w = w0 * fit, h = h0 * fit
            drawCG(ctx, im, CGRect(x: c.xOrDefault * W - w / 2, y: c.yOrDefault * H - h / 2, width: w, height: h))
        case .text:
            drawText(c.text ?? "", x: c.xOrDefault * W, y: c.yOrDefault * H, size: c.fontSize ?? 80, color: c.colorOrDefault, font: c.fontOrDefault, outline: c.outlineOrDefault, ctx: ctx)
        default:
            break
        }
    }

    /// クリップごとのぼかし: 透明なビットマップに描いてぼかし、不透明度をかけて合成する。
    func drawBlurredClip(_ c: Clip, t: Double, ctx: CGContext, W: Double, H: Double) {
        let sigma = min(300, c.blurOrDefault)
        guard let off = Renderer.makeContext(width: Int(W), height: Int(H)) else { return }
        off.translateBy(x: 0, y: CGFloat(off.height))
        off.scaleBy(x: 1, y: -1)
        drawClipContent(c, t: t, ctx: off, W: W, H: H)
        guard let snap = off.makeImage() else { return }
        // 範囲を σ の3倍ぶん広げて、縁が自然に薄れるようにする(透明部分は透明のまま)
        let ci = CIImage(cgImage: snap)
        let blurred = ci.applyingGaussianBlur(sigma: sigma)
        let rect = CGRect(x: 0, y: 0, width: W, height: H)
        guard let out = ciContext.createCGImage(blurred, from: rect, format: .BGRA8, colorSpace: sRGB) else { return }
        ctx.saveGState()
        ctx.setAlpha(CGFloat(c.opacityOrDefault))
        drawCG(ctx, out, rect)
        ctx.restoreGState()
    }

    /// ぼかし範囲: ここまでに描いたキャンバスを、四角/楕円の内側だけぼかして描き直す。
    func drawBlurRegion(_ c: Clip, ctx: CGContext, W: Double, H: Double) {
        let bw = c.wOrDefault * W, bh = c.hOrDefault * H
        let bx = c.xOrDefault * W, by = c.yOrDefault * H
        let sigma = max(0, c.strengthOrDefault)
        let shapeRect = CGRect(x: bx - bw / 2, y: by - bh / 2, width: bw, height: bh)
        let canvas = CGRect(x: 0, y: 0, width: W, height: H)
        // 画素に揃えた取得範囲(キャンバス内)
        let area = shapeRect.integral.intersection(canvas)
        guard sigma > 0, !area.isNull, area.width >= 1, area.height >= 1,
              let snap = ctx.makeImage() else { return }
        // CoreImage は左下原点
        let ciRect = CGRect(x: area.minX, y: H - area.maxY, width: area.width, height: area.height)
        let blurred = CIImage(cgImage: snap).clampedToExtent().applyingGaussianBlur(sigma: sigma)
        guard let out = ciContext.createCGImage(blurred, from: ciRect, format: .BGRA8, colorSpace: sRGB) else { return }
        ctx.saveGState()
        if c.shapeOrDefault == "ellipse" { ctx.addEllipse(in: shapeRect) } else { ctx.addRect(shapeRect) }
        ctx.clip()
        drawCG(ctx, out, area)
        ctx.restoreGState()
    }

    // MARK: 文字

    /// renderer.js drawText と同じ: 中央寄せ・複数行(行間 size*1.2)・縁(0.22)→白(0.1)→塗り。
    func drawText(_ text: String, x: Double, y: Double, size: Double, color: String, font: String, outline: String, ctx: CGContext) {
        guard size > 0 else { return }
        let lines = text.components(separatedBy: "\n")
        let fillC = parseHexColor(color) ?? parseHexColor("#ffffff")!
        let outC = parseHexColor(outline) ?? parseHexColor("#000000")!
        let white = parseHexColor("#ffffff")!
        let f = TextFont(name: font, size: size)
        for (i, ln) in lines.enumerated() {
            let yy = y + (Double(i) - Double(lines.count - 1) / 2) * size * 1.2
            let line = f.layout(ln)
            // textBaseline = middle: 基準線は (ascent - descent) / 2 だけ下
            let baseline = yy + (f.ascent - f.descent) / 2
            ctx.saveGState()
            ctx.translateBy(x: CGFloat(x - line.width / 2), y: CGFloat(baseline))
            ctx.scaleBy(x: 1, y: -1)  // グリフは y 上向きなので戻す
            ctx.setLineJoin(.round)
            // 疑似ボールドは輪郭を太らせる(各パスの線幅に extra を足す)
            let extra = f.syntheticBoldExtra
            ctx.addPath(line.path)
            ctx.setLineWidth(CGFloat(size * 0.22 + extra)); ctx.setStrokeColor(outC); ctx.strokePath()
            ctx.addPath(line.path)
            ctx.setLineWidth(CGFloat(size * 0.1 + extra)); ctx.setStrokeColor(white); ctx.strokePath()
            ctx.addPath(line.path)
            ctx.setFillColor(fillC); ctx.fillPath()
            if extra > 0 {
                ctx.addPath(line.path)
                ctx.setLineWidth(CGFloat(extra)); ctx.setStrokeColor(fillC); ctx.strokePath()
            }
            ctx.restoreGState()
        }
    }
}

// MARK: - フォント

/// CoreText のフォント。太字が無い書体(ヒラギノ丸ゴ ProN は W4 のみ)は、Chrome と同じ疑似ボールドで太らせる。
struct TextFont {
    let ct: CTFont
    let size: Double
    let synthetic: Bool
    var ascent: Double { CTFontGetAscent(ct) }
    var descent: Double { CTFontGetDescent(ct) }

    init(name: String, size: Double) {
        self.size = size
        let base = CTFontCreateWithName(name as CFString, CGFloat(size), nil)
        if let bold = CTFontCreateCopyWithSymbolicTraits(base, CGFloat(size), nil, .traitBold, .traitBold),
           CTFontGetSymbolicTraits(bold).contains(.traitBold) {
            ct = bold; synthetic = false
        } else {
            ct = base; synthetic = true
        }
    }

    /// Skia の疑似ボールドと同じ: サイズ 9 以下で 1/24、36 以上で 1/32、間は線形補間。
    var syntheticBoldExtra: Double {
        guard synthetic else { return 0 }
        let r: Double
        if size <= 9 { r = 1.0 / 24 } else if size >= 36 { r = 1.0 / 32 } else { r = 1.0 / 24 + (1.0 / 32 - 1.0 / 24) * (size - 9) / 27 }
        return size * r
    }

    /// 1 行ぶんのグリフ輪郭(y 上向き、原点 = 基準線の左端)と幅。
    func layout(_ s: String) -> (path: CGPath, width: Double) {
        let attr = NSAttributedString(string: s, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): ct, NSAttributedString.Key(kCTKernAttributeName as String): 0])
        let line = CTLineCreateWithAttributedString(attr)
        let path = CGMutablePath()
        let runs = CTLineGetGlyphRuns(line) as? [CTRun] ?? []
        for run in runs {
            let n = CTRunGetGlyphCount(run)
            guard n > 0 else { continue }
            let attrs = CTRunGetAttributes(run) as NSDictionary
            let rf = (attrs[kCTFontAttributeName as String] as! CTFont?) ?? ct
            var glyphs = [CGGlyph](repeating: 0, count: n)
            var pos = [CGPoint](repeating: .zero, count: n)
            CTRunGetGlyphs(run, CFRange(location: 0, length: n), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: n), &pos)
            for i in 0..<n {
                if let gp = CTFontCreatePathForGlyph(rf, glyphs[i], nil) {
                    path.addPath(gp, transform: CGAffineTransform(translationX: pos[i].x, y: pos[i].y))
                }
            }
        }
        let w = CTLineGetTypographicBounds(line, nil, nil, nil)
        return (path, w)
    }
}

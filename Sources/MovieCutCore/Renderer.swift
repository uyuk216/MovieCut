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

// MARK: - クリップの動く値

/// 時刻 t(プロジェクトの時刻)でのクリップの位置・拡大・回転・不透明度・ぼかし。キーがなければ設定値そのまま(従来と同じ速さ)。
struct ClipPose {
    var x: Double, y: Double, scale: Double, rotation: Double, opacity: Double, blur: Double
    /// トランジションで位置・大きさ・回転が動いている(文字のビットマップキャッシュを使えない)。
    var transitionMoves = false

    init(_ c: Clip, at t: Double) {
        if c.keyframes.isEmpty {
            x = c.xOrDefault; y = c.yOrDefault; scale = c.scaleOrDefault
            rotation = c.rotationOrDefault; opacity = c.opacityOrDefault; blur = c.blurOrDefault
        } else {
            let r = t - c.start
            x = Animation.value(of: "x", in: c, at: r); y = Animation.value(of: "y", in: c, at: r)
            scale = Animation.value(of: "scale", in: c, at: r); rotation = Animation.value(of: "rotation", in: c, at: r)
            opacity = min(max(Animation.value(of: "opacity", in: c, at: r), 0), 1); blur = max(0, Animation.value(of: "blur", in: c, at: r))
        }
    }

    /// トランジションの補正を上から重ねる(不透明度は掛け算、拡大は掛け算、位置はキャンバスの割合で足す、回転・ぼかしは足す)。
    /// ぼかしは 1920×1080 での px なので、`blurScale` で解像度に合わせる。
    mutating func apply(_ s: TransitionState, blurScale: Double) {
        x += s.offsetX; y += s.offsetY
        scale *= s.scaleMul
        rotation += s.rotationAdd
        opacity = min(max(opacity * s.opacityMul, 0), 1)
        blur += s.blurAdd * blurScale
        transitionMoves = s.movesGeometry
    }

    /// 回転・反転が無い(切り抜きは絵そのものを切るので関係ない)。文字は拡大・切り抜きも「無し」のとき。
    func isPlain(_ c: Clip) -> Bool {
        if rotation != 0 || c.flipHOrDefault || c.flipVOrDefault { return false }
        if c.type == .text { return scale == 1 && (c.crop?.isEmpty ?? true) }
        return true
    }

    /// (x, y) へ移して、反転 → 回転(時計回り)をかける。拡大は大きさに含めてあるので、文字のときだけここで掛ける。
    func concat(_ c: Clip, ctx: CGContext, W: Double, H: Double) {
        ctx.translateBy(x: CGFloat(x * W), y: CGFloat(y * H))
        if rotation != 0 { ctx.rotate(by: CGFloat(rotation * .pi / 180)) }
        if c.flipHOrDefault || c.flipVOrDefault { ctx.scaleBy(x: c.flipHOrDefault ? -1 : 1, y: c.flipVOrDefault ? -1 : 1) }
        if c.type == .text, scale != 1 { ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale)) }
    }
}

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
                    drawBlurRegion(c, t: t, ctx: ctx, W: W, H: H)
                case .image, .video, .text:
                    var pose = ClipPose(c, at: t)
                    var mask: TransitionMask?
                    if c.hasTransition {
                        // トランジション: キーフレームの値の上に重ねる(効く時間の外では何も変わらない)
                        let st = transitionState(c, pose: pose, t: t, W: W, H: H)
                        if !st.isIdentity {
                            pose.apply(st, blurScale: (W * H / (1920.0 * 1080.0)).squareRoot())
                            mask = st.mask
                            if pose.opacity <= 0 || (mask?.isEmpty ?? false) { continue }
                        }
                    }
                    if let m = mask {
                        ctx.saveGState()
                        Renderer.clip(ctx, mask: m, W: W, H: H)
                    }
                    if pose.blur > 0 {
                        drawBlurredClip(c, pose: pose, t: t, ctx: ctx, W: W, H: H)
                    } else {
                        ctx.saveGState()
                        ctx.setAlpha(CGFloat(pose.opacity))
                        drawClipContent(c, pose: pose, t: t, ctx: ctx, W: W, H: H)
                        ctx.restoreGState()
                    }
                    if mask != nil { ctx.restoreGState() }
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

    // MARK: トランジション

    /// 時刻 t のクリップのトランジション補正。スライドのときだけ、クリップの枠の大きさ(画面の外へ出し切る移動量)を測る。
    func transitionState(_ c: Clip, pose: ClipPose, t: Double, W: Double, H: Double) -> TransitionState {
        var size: (w: Double, h: Double) = (0, 0)
        let needsSize = (c.transitionIn?.known?.isSlide ?? false) || (c.transitionOut?.known?.isSlide ?? false)
        if needsSize, let s = objectSize(of: c, at: t), W > 0, H > 0 { size = (s.width / W, s.height / H) }
        return TransitionMath.apply(c, t: t, center: (pose.x, pose.y), size: size)
    }

    /// 左上原点の ctx を、トランジションの形で切り抜く(この後の描画はその内側だけ)。
    static func clip(_ ctx: CGContext, mask: TransitionMask, W: Double, H: Double) {
        switch mask {
        case .rect(let x, let y, let w, let h):
            ctx.clip(to: CGRect(x: x * W, y: y * H, width: w * W, height: h * H))
        case .circle(let r):
            let R = r * (W * W + H * H).squareRoot() / 2
            ctx.addEllipse(in: CGRect(x: W / 2 - R, y: H / 2 - R, width: 2 * R, height: 2 * R))
            ctx.clip()
        case .clock(let f):
            guard f < 1 else { return }
            // 12 時から時計回り(画面では角度が増える向き)に f 周ぶんの扇形。半径は四隅に届く大きさ
            let R = (W * W + H * H).squareRoot()
            let cx = W / 2, cy = H / 2
            let sweep = min(max(f, 0), 1) * 2 * Double.pi
            let steps = max(2, Int((sweep / (Double.pi / 180)).rounded(.up)))
            let a0 = -Double.pi / 2
            let path = CGMutablePath()
            path.move(to: CGPoint(x: cx, y: cy))
            for i in 0...steps {
                let a = a0 + sweep * Double(i) / Double(steps)
                path.addLine(to: CGPoint(x: cx + R * cos(a), y: cy + R * sin(a)))
            }
            path.closeSubpath()
            ctx.addPath(path)
            ctx.clip()
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
    /// 順序: 切り抜き → 反転 → 拡大 → (クリップの中心まわりに)回転 → (x, y) へ移動。何も変形しないクリップは従来と同じ描き方。
    func drawClipContent(_ c: Clip, pose: ClipPose, t: Double, ctx: CGContext, W: Double, H: Double) {
        switch c.type {
        case .image, .video:
            var img: CGImage?
            if let src = c.src {
                img = c.type == .image ? assets.image(at: src) : assets.videoFrame(path: src, time: t - c.start + c.offset)
            }
            guard var im = img, im.width > 0, im.height > 0 else { return }
            let w0 = Double(im.width), h0 = Double(im.height)
            let fit = min(W / w0, H / h0) * pose.scale
            if let crop = c.crop, !crop.isEmpty, let cut = Renderer.cropped(im, crop) { im = cut }
            let w = Double(im.width) * fit, h = Double(im.height) * fit
            if pose.isPlain(c) {
                drawCG(ctx, im, CGRect(x: pose.x * W - w / 2, y: pose.y * H - h / 2, width: w, height: h))
            } else {
                ctx.saveGState()
                pose.concat(c, ctx: ctx, W: W, H: H)
                drawCG(ctx, im, CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
                ctx.restoreGState()
            }
        case .text:
            let size = c.fontSize ?? 80
            let blurred = pose.blur > 0
            // 位置・拡大・回転が動く文字は、位置ごとにキャッシュしても使い回せないので直接描く
            let geometryAnimated = c.hasKeyframes && ["x", "y", "scale", "rotation"].contains { Animation.isAnimated($0, in: c) }
            if pose.isPlain(c) {
                drawText(c.text ?? "", x: pose.x * W, y: pose.y * H, size: size, color: c.colorOrDefault, font: c.fontOrDefault, outline: c.outlineOrDefault, ctx: ctx,
                         cacheable: !geometryAnimated && !pose.transitionMoves && (pose.opacity >= 1 || blurred))
            } else {
                ctx.saveGState()
                pose.concat(c, ctx: ctx, W: W, H: H)
                var ox = 0.0, oy = 0.0
                if let crop = c.crop, !crop.isEmpty {
                    // 切り抜きは、描いた文字の枠(幅 = 一番長い行、高さ = 行数 × 行間)に対して
                    let box = textBlockSize(c.text ?? "", size: size, font: c.fontOrDefault)
                    let kw = box.width * crop.keptWidth, kh = box.height * crop.keptHeight
                    ctx.clip(to: CGRect(x: -kw / 2, y: -kh / 2, width: kw, height: kh))
                    ox = -(crop.l - crop.r) / 2 * box.width
                    oy = -(crop.t - crop.b) / 2 * box.height
                }
                drawText(c.text ?? "", x: ox, y: oy, size: size, color: c.colorOrDefault, font: c.fontOrDefault, outline: c.outlineOrDefault, ctx: ctx, cacheable: false)
                ctx.restoreGState()
            }
        default:
            break
        }
    }

    /// 切り抜き(画素に丸める)。範囲が空になるときは nil。
    static func cropped(_ im: CGImage, _ crop: Crop) -> CGImage? {
        let w = Double(im.width), h = Double(im.height)
        let x0 = (crop.l * w).rounded(), y0 = (crop.t * h).rounded()
        let x1 = max(x0 + 1, (w - crop.r * w).rounded()), y1 = max(y0 + 1, (h - crop.b * h).rounded())
        return im.cropping(to: CGRect(x: x0, y: y0, width: min(x1, w) - x0, height: min(y1, h) - y0))
    }

    /// 文字の枠(幅 = 一番長い行の幅、高さ = 行数 × 文字の大きさ × 1.2)。
    func textBlockSize(_ text: String, size: Double, font: String) -> CGSize {
        let lines = text.components(separatedBy: "\n")
        let f = TextCache.font(name: font, size: size)
        let w = lines.map { TextCache.layout(f, font: font, line: $0).width }.max() ?? 0
        return CGSize(width: w, height: Double(lines.count) * size * 1.2)
    }

    /// 画面に置いたときの、クリップの枠の大きさ(拡大を反映、回転は含まない)。素材が読めなければ nil。プレビューの取っ手用。
    public func objectSize(of c: Clip, at t: Double) -> CGSize? {
        let W = Double(project.width), H = Double(project.height)
        let pose = ClipPose(c, at: t)
        switch c.type {
        case .image, .video:
            guard let src = c.src else { return nil }
            let size: CGSize?
            if c.type == .image { size = assets.image(at: src).map { CGSize(width: $0.width, height: $0.height) } }
            else { size = assets.knownVideoSize(path: src) ?? assets.videoFrame(path: src, time: t - c.start + c.offset).map { CGSize(width: $0.width, height: $0.height) } }
            guard let s = size, s.width > 0, s.height > 0 else { return nil }
            let fit = min(W / s.width, H / s.height) * pose.scale
            let crop = c.cropOrDefault
            return CGSize(width: s.width * crop.keptWidth * fit, height: s.height * crop.keptHeight * fit)
        case .text:
            let box = textBlockSize(c.text ?? "", size: c.fontSize ?? 80, font: c.fontOrDefault)
            let crop = c.cropOrDefault
            return CGSize(width: box.width * crop.keptWidth * pose.scale, height: box.height * crop.keptHeight * pose.scale)
        default:
            return nil
        }
    }

    /// クリップごとのぼかし: 透明なビットマップに描いてぼかし、不透明度をかけて合成する。
    func drawBlurredClip(_ c: Clip, pose: ClipPose, t: Double, ctx: CGContext, W: Double, H: Double) {
        let sigma = min(300, pose.blur)
        guard let off = Renderer.makeContext(width: Int(W), height: Int(H)) else { return }
        off.translateBy(x: 0, y: CGFloat(off.height))
        off.scaleBy(x: 1, y: -1)
        drawClipContent(c, pose: pose, t: t, ctx: off, W: W, H: H)
        guard let snap = off.makeImage() else { return }
        // 範囲を σ の3倍ぶん広げて、縁が自然に薄れるようにする(透明部分は透明のまま)
        let ci = CIImage(cgImage: snap)
        let blurred = ci.applyingGaussianBlur(sigma: sigma)
        let rect = CGRect(x: 0, y: 0, width: W, height: H)
        guard let out = ciContext.createCGImage(blurred, from: rect, format: .BGRA8, colorSpace: sRGB) else { return }
        ctx.saveGState()
        ctx.setAlpha(CGFloat(pose.opacity))
        drawCG(ctx, out, rect)
        ctx.restoreGState()
    }

    /// ぼかし範囲: ここまでに描いたキャンバスを、四角/楕円の内側だけぼかして描き直す。
    func drawBlurRegion(_ c: Clip, t: Double, ctx: CGContext, W: Double, H: Double) {
        let r = t - c.start
        let bw = Animation.value(of: "w", in: c, at: r) * W, bh = Animation.value(of: "h", in: c, at: r) * H
        let bx = Animation.value(of: "x", in: c, at: r) * W, by = Animation.value(of: "y", in: c, at: r) * H
        let sigma = max(0, Animation.value(of: "strength", in: c, at: r))
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
    /// cacheable(不透明度 1)のときは、行ごとにビットマップへ一度だけ描いて、以後はそれを貼る(書き出しの高速化)。
    /// ビットマップには小数部の位置も含めて描くので、直接描いたときと同じ見た目になる。
    func drawText(_ text: String, x: Double, y: Double, size: Double, color: String, font: String, outline: String, ctx: CGContext, cacheable: Bool = true) {
        guard size > 0 else { return }
        let lines = text.components(separatedBy: "\n")
        let fillC = parseHexColor(color) ?? parseHexColor("#ffffff")!
        let outC = parseHexColor(outline) ?? parseHexColor("#000000")!
        let f = TextCache.font(name: font, size: size)
        for (i, ln) in lines.enumerated() {
            let yy = y + (Double(i) - Double(lines.count - 1) / 2) * size * 1.2
            let line = TextCache.layout(f, font: font, line: ln)
            // textBaseline = middle: 基準線は (ascent - descent) / 2 だけ下
            let baseline = yy + (f.ascent - f.descent) / 2
            let ox = x - line.width / 2
            if cacheable, !line.path.isEmpty {
                let ix = floor(ox), iy = floor(baseline)
                let fx = ox - ix, fy = baseline - iy
                let key = "\(font)|\(size)|\(ln)|\(color)|\(outline)|\(fx)|\(fy)"
                if let bm = TextCache.bitmap(key: key, build: { Renderer.rasterizeLine(line, f, size: size, fill: fillC, outline: outC, fx: fx, fy: fy) }) {
                    drawCG(ctx, bm.image, CGRect(x: ix + bm.x, y: iy + bm.y, width: Double(bm.image.width), height: Double(bm.image.height)))
                    continue
                }
            }
            ctx.saveGState()
            ctx.translateBy(x: CGFloat(ox), y: CGFloat(baseline))
            Renderer.paintLine(line, f, size: size, fill: fillC, outline: outC, ctx: ctx)
            ctx.restoreGState()
        }
    }

    /// 原点(基準線の左端)に移動済みの ctx(左上原点)へ 1 行を描く。
    static func paintLine(_ line: (path: CGPath, width: Double), _ f: TextFont, size: Double, fill: CGColor, outline: CGColor, ctx: CGContext) {
        let white = parseHexColor("#ffffff")!
        ctx.saveGState()
        ctx.scaleBy(x: 1, y: -1)  // グリフは y 上向きなので戻す
        ctx.setLineJoin(.round)
        // 疑似ボールドは輪郭を太らせる(各パスの線幅に extra を足す)
        let extra = f.syntheticBoldExtra
        ctx.addPath(line.path)
        ctx.setLineWidth(CGFloat(size * 0.22 + extra)); ctx.setStrokeColor(outline); ctx.strokePath()
        ctx.addPath(line.path)
        ctx.setLineWidth(CGFloat(size * 0.1 + extra)); ctx.setStrokeColor(white); ctx.strokePath()
        ctx.addPath(line.path)
        ctx.setFillColor(fill); ctx.fillPath()
        if extra > 0 {
            ctx.addPath(line.path)
            ctx.setLineWidth(CGFloat(extra)); ctx.setStrokeColor(fill); ctx.strokePath()
        }
        ctx.restoreGState()
    }

    /// 1 行を透明なビットマップに描く。原点(基準線の左端)から小数部 (fx, fy) ずれた位置で描き、
    /// 戻り値の x, y は「整数化した原点からのビットマップ左上のずれ」。
    static func rasterizeLine(_ line: (path: CGPath, width: Double), _ f: TextFont, size: Double, fill: CGColor, outline: CGColor, fx: Double, fy: Double) -> (image: CGImage, x: Double, y: Double)? {
        let bb = line.path.boundingBoxOfPath
        guard !bb.isNull, !bb.isInfinite else { return nil }
        let pad = (size * 0.22 + f.syntheticBoldExtra) / 2 + 3
        // y 下向きの局所座標(原点 = 基準線の左端)
        let minX = floor(bb.minX - pad + fx), maxX = ceil(bb.maxX + pad + fx)
        let minY = floor(-bb.maxY - pad + fy), maxY = ceil(-bb.minY + pad + fy)
        let w = Int(maxX - minX), h = Int(maxY - minY)
        guard w > 0, h > 0, w * h <= 16_000_000,
              let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB, bitmapInfo: bitmapInfo) else { return nil }
        c.interpolationQuality = .high
        c.translateBy(x: 0, y: CGFloat(h))
        c.scaleBy(x: 1, y: -1)
        c.translateBy(x: CGFloat(-minX + fx), y: CGFloat(-minY + fy))
        paintLine(line, f, size: size, fill: fill, outline: outline, ctx: c)
        guard let img = c.makeImage() else { return nil }
        return (img, minX, minY)
    }
}

// MARK: - 文字のキャッシュ

/// フォントとグリフ輪郭のキャッシュ。書き出しでは同じ文字を毎コマ描くので、CoreText のレイアウトを使い回す。
enum TextCache {
    private static let lock = NSLock()
    private static var fonts: [String: TextFont] = [:]
    private static var layouts: [String: (path: CGPath, width: Double)] = [:]

    private static var bitmaps: [String: (image: CGImage, x: Double, y: Double)] = [:]

    static func bitmap(key: String, build: () -> (image: CGImage, x: Double, y: Double)?) -> (image: CGImage, x: Double, y: Double)? {
        lock.lock()
        if let b = bitmaps[key] { lock.unlock(); return b }
        lock.unlock()
        guard let b = build() else { return nil }
        lock.lock()
        if bitmaps.count >= 48 { bitmaps.removeAll() }  // 編集中に位置や文字が変わり続けても増えすぎないように
        bitmaps[key] = b
        lock.unlock()
        return b
    }

    static func font(name: String, size: Double) -> TextFont {
        let key = "\(name)|\(size)"
        lock.lock(); defer { lock.unlock() }
        if let f = fonts[key] { return f }
        let f = TextFont(name: name, size: size)
        fonts[key] = f
        return f
    }

    static func layout(_ f: TextFont, font: String, line: String) -> (path: CGPath, width: Double) {
        let key = "\(font)|\(f.size)|\(line)"
        lock.lock()
        if let l = layouts[key] { lock.unlock(); return l }
        lock.unlock()
        let l = f.layout(line)
        lock.lock()
        if layouts.count > 512 { layouts.removeAll() }  // 編集で文字が変わり続けても増えすぎないように
        layouts[key] = l
        lock.unlock()
        return l
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

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
let ciContext = CIContext(options: [.workingColorSpace: sRGB, .outputColorSpace: sRGB])

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
    /// 複合クリップが、キャンバスいっぱいに・変形なし・不透明度 100%・ぼかしなし(中身を親の画面に直接描ける)。
    var isFullCanvasCompound: Bool {
        x == 0.5 && y == 0.5 && scale == 1 && rotation == 0 && opacity >= 1 && blur <= 0
    }

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
    /// プレビュー用。手ぶれ補正の解析が無いとき、待たずに補正なしのコマを出し、解析が終わったらこれを呼ぶ(主スレッドへの送りは呼び出し側)。
    /// nil(既定・書き出し・CLI)のときは解析が終わるまで待つので、結果は常に同じ。
    public let onStabilized: (() -> Void)?
    /// 複合クリップの中身を描くとき(`compoundFrame`)の状態。通常の描画では既定のまま。
    /// 祖先の複合クリップの id(循環を描かないため)・背景を塗るか・人物の立ち絵を描くか(中身では描かない)。
    /// プレビュー用。素材が見つからない画像・動画を、黙って飛ばさず「メディアが見つかりません」の札で描く。
    /// 既定 false(書き出しは従来どおり。書き出し前の確認で止める)。
    public var missingMediaPlaceholder = false
    var compoundStack: [String] = []
    var drawsBackground = true
    var drawsPortraits = true

    public init(project: Project, assets: RenderAssets, onStabilized: (() -> Void)? = nil, missingMediaPlaceholder: Bool = false) {
        self.project = project
        self.assets = assets
        self.onStabilized = onStabilized
        self.missingMediaPlaceholder = missingMediaPlaceholder
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

        if drawsBackground {
            ctx.setFillColor(parseHexColor(project.bg) ?? CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        }
        drawFrame(t: t, into: ctx)
    }

    /// 左上原点の ctx に、時刻 t の中身(背景は除く)を描く。複合クリップの中身を、親の画面にそのまま描くときにも使う。
    func drawFrame(t: Double, into ctx: CGContext) {
        let W = Double(project.width), H = Double(project.height)
        var speaking: [String: Clip] = [:]  // charId -> 最後に見つかったボイス
        var subtitles: [Clip] = []
        // 合成音声の音量(ビジュアライザが初めて要る時に 1 回だけ作る。無いプロジェクトでは作らない)
        var mixEnv: [Float]? = nil
        var mixLoaded = false

        for tr in project.tracks where !tr.isHidden {
            for c in tr.clips where t >= c.start && t < c.start + c.duration {
                switch c.type {
                case .blur:
                    drawBlurRegion(c, t: t, ctx: ctx, W: W, H: H)
                case .adjustment:
                    applyAdjustment(c, t: t, ctx: ctx, W: W, H: H)
                case .visualizer:
                    if !mixLoaded { mixEnv = assets.mixEnvelope(for: project); mixLoaded = true }
                    drawVisualizer(c, t: t, env: mixEnv, ctx: ctx, W: W, H: H)
                case .shape:
                    drawShape(c, t: t, ctx: ctx, W: W, H: H)
                case .image, .video, .text, .compound:
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
                    // 複合クリップで、キャンバスいっぱいに・効果なし・不透明度 100% なら、中身を親の画面に直接描く(中間の画像を作らない)。
                    // 直接描くので、まとめる前のクリップを描いたときと画素が完全に一致する
                    if c.type == .compound, mask == nil, c.mask == nil, pose.isFullCanvasCompound, !c.hasActiveEffects, let child = compoundRenderer(c) {
                        ctx.saveGState()
                        child.drawFrame(t: t - c.start + c.offset, into: ctx)
                        ctx.restoreGState()
                        continue
                    }
                    // エフェクトは、クリップ自身の画素(変形まで済み)にかけてから、不透明度・マスクで重ねる。無いクリップは従来の速い道
                    let fx = c.hasActiveEffects ? EffectPipeline.resolve(c, atClipTime: t - c.start) : []
                    if !fx.isEmpty || c.mask != nil {
                        drawEffectedClip(c, pose: pose, effects: fx, t: t, ctx: ctx, W: W, H: H)
                    } else if pose.blur > 0 {
                        drawBlurredClip(c, pose: pose, t: t, ctx: ctx, W: W, H: H)
                    } else {
                        ctx.saveGState()
                        ctx.setAlpha(CGFloat(pose.opacity))
                        drawClipContent(c, pose: pose, t: t, ctx: ctx, W: W, H: H, fastFade: mask == nil, fadeAlpha: pose.opacity)
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
        for ch in (drawsPortraits ? project.characters : []) {
            let v = speaking[ch.id]
            if v == nil && !ch.alwaysShow { continue }
            var open = v.map { mouthOpen($0, t: t) } ?? false
            // あいうえお口パク(母音画像が 1 つでもあるとき): 口の形はセリフの読みと音量から決める。ん・っ・無音は閉じる
            var vowelPath: String? = nil
            if let v, let vs = ch.imgVowels, !vs.isEmpty, let shape = lipShape(v, t: t) {
                open = shape != .closed
                if let k = shape.vowelKey, let p = vs[k], !p.isEmpty { vowelPath = p }
            }
            // 目: まばたき中は imgBlink(無ければ通常)。瞬きの種はしゃべっているクリップ、無ければキャラ。
            let blinking = ch.imgBlink != nil && Blink.isClosed(seed: v?.id ?? ch.id, t: t - (v?.start ?? 0))
            // 口: 開いていれば imgOpen。閉じていれば、その行の表情(タグ)か通常の立ち絵。
            let expr = v.flatMap { ExpressionTag.imagePath(for: $0.text ?? "", in: ch.expressions) }
            let path: String?
            if open, let vp = vowelPath { path = vp }
            else if open, let o = ch.imgOpen { path = o }
            else if blinking, let b = ch.imgBlink { path = b }
            else { path = expr ?? ch.imgClosed }
            guard let p = path, let img = assets.image(at: p), img.height > 0 else { continue }
            let h = H * 0.6 * ch.scale
            let w = Double(img.width) * (h / Double(img.height))
            // 話し中バウンス(オプション): 音量に比例して上へ揺れる
            var lift = 0.0
            if let v, ch.bounce == true { lift = Bounce.lift(level: mouthLevel(v, t: t)) }
            ctx.saveGState()
            // バウンスは 1 ピクセル単位に丸める(小数位置の描画は拡大・補間の遅い経路になるため。バウンスなしは従来どおり)
            let cy = lift > 0 ? ((ch.y * H - lift * H).rounded()) : ch.y * H
            ctx.translateBy(x: CGFloat(ch.x * W), y: CGFloat(cy))
            if ch.flip { ctx.scaleBy(x: -1, y: 1) }
            drawCG(ctx, img, CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
            ctx.restoreGState()
        }

        // 字幕(キャラの色で縁取り)
        for c in subtitles {
            let ch = project.characters.first { $0.id == c.charId }
            drawText(ExpressionTag.body(c.text ?? ""), x: W / 2, y: H * 0.88, size: c.fontSize ?? 64, color: "#ffffff", font: c.fontOrDefault, outline: ch?.color ?? "#000000", ctx: ctx, style: c.textStyle)
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
        guard let src = clip.src, let st = assets.mouthStates(for: src) else { return false }
        let i = Int(floor((t - clip.start + clip.offset) * 60))
        return i >= 0 && i < st.count && st[i]
    }

    /// あいうえお口パク: 時刻 t の口の形。セリフの文字か音声が無いときは nil(従来の開閉に戻す)。
    func lipShape(_ clip: Clip, t: Double) -> Viseme? {
        guard let src = clip.src, let text = clip.text,
              let vis = assets.visemes(src: src, text: text, offset: clip.offset, duration: clip.duration) else { return nil }
        let i = Int(floor((t - clip.start + clip.offset) * 60))
        return i >= 0 && i < vis.count ? vis[i] : .closed
    }

    /// 話しているクリップの、時刻 t での音量(RMS)。素材が無ければ 0。
    func mouthLevel(_ clip: Clip, t: Double) -> Float {
        guard let src = clip.src, let env = assets.mouthEnvelope(for: src) else { return 0 }
        let i = Int(floor((t - clip.start + clip.offset) * 60))
        return i >= 0 && i < env.count ? env[i] : 0
    }

    // MARK: クリップ本体

    /// 動画クリップの、時刻 t(プロジェクトの時刻)に出すコマ。速度・逆再生・フリーズは `ClipTiming` で素材の時刻に直す
    /// (速度 1・順再生は従来と同じ `t − start + offset`)。
    func videoFrame(_ c: Clip, src: String, at t: Double) -> CGImage? {
        // フレームブレンド(速度 1 未満のとき): 素材の時刻を、コマの間隔(プロジェクトの fps の格子)で隣り合う 2 コマに分けて混ぜる
        if ClipTiming.blendsFrames(c, atClipTime: t - c.start) {
            let grid = project.fps
            let idx = ClipTiming.sourceTime(of: c, atClipTime: t - c.start) * grid
            let i0 = floor(idx), w = idx - i0
            guard let a = assets.videoFrame(path: src, time: i0 / grid, reverse: false, exact: true) else { return nil }
            if w < 1e-6 { return a }
            guard let b = assets.videoFrame(path: src, time: (i0 + 1) / grid, reverse: false, exact: true) else { return a }
            // オプティカルフロー補間: 動きに沿った中間のコマ。求められなければ従来のフレームブレンドへ戻す
            if c.opticalFlowOn,
               let f = OpticalFlowInterpolator.frame(a, b, weight: w, key: "\(src)|\(Int(i0))|\(grid)", cache: assets.flowCache) { return f }
            return FrameBlend.mix(a, b, weight: w) ?? a
        }
        let remap = c.hasTimeRemap
        let st = remap ? ClipTiming.frameSourceTime(of: c, atClipTime: t - c.start, fps: project.fps) : t - c.start + c.offset
        return assets.videoFrame(path: src, time: st, reverse: c.effectiveReverse, exact: remap)
    }

    /// 上下反転した ctx(左上原点)に CGImage を rect へ描く。
    func drawCG(_ ctx: CGContext, _ img: CGImage, _ rect: CGRect) {
        ctx.saveGState()
        if ProcessInfo.processInfo.environment["MCQ"] == "none" { ctx.interpolationQuality = .none }
        if ProcessInfo.processInfo.environment["MCQ"] == "low" { ctx.interpolationQuality = .low }
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        ctx.restoreGState()
    }

    /// image / video / text を現在の alpha で描く。
    /// 順序: 切り抜き → 反転 → 拡大 → (クリップの中心まわりに)回転 → (x, y) へ移動。何も変形しないクリップは従来と同じ描き方。
    func drawClipContent(_ c: Clip, pose: ClipPose, t: Double, ctx: CGContext, W: Double, H: Double, fastFade: Bool = false, fadeAlpha: Double = 1) {
        switch c.type {
        case .image, .video, .compound:
            var img: CGImage?
            if c.type == .compound {
                img = compoundFrame(c, t: t)
            } else if let src = c.src {
                img = c.type == .image ? assets.image(at: src) : videoFrame(c, src: src, at: t)
            }
            // 手ぶれ補正(映像のみ): 解析は素材ごとに 1 回だけ(キャッシュ)。切り抜き・拡大より前に、コマそのものを補正する
            if c.type == .video, c.stabilizeStrength > 0, let src = c.src, let raw = img {
                img = stabilized(c, src: src, frame: raw, t: t)
            }
            guard var im = img, im.width > 0, im.height > 0 else {
                // 画像が取れなかったとき、素材ファイルが無ければ札を出す(プレビューのみ。存在確認はここでだけ)
                if missingMediaPlaceholder, c.type != .compound, MissingMediaPlaceholder.isMissing(c) {
                    drawMissingPlaceholder(c, pose: pose, ctx: ctx, W: W, H: H)
                }
                return
            }
            let w0 = Double(im.width), h0 = Double(im.height)
            let fit = min(W / w0, H / h0) * pose.scale
            if let crop = c.crop, !crop.isEmpty, let cut = Renderer.cropped(im, crop) { im = cut }
            let w = Double(im.width) * fit, h = Double(im.height) * fit
            if pose.isPlain(c) {
                let r = CGRect(x: pose.x * W - w / 2, y: pose.y * H - h / 2, width: w, height: h)
                if fadeAlpha > 0, fadeAlpha < 1, fastFade {
                    if FastBlend.drawFaded(ctx, im, rect: r, alpha: fadeAlpha) { return }
                    if drawFadedViaTemp(ctx, im, rect: r, alpha: fadeAlpha, W: W, H: H) { return }
                }
                drawCG(ctx, im, r)
            } else {
                ctx.saveGState()
                pose.concat(c, ctx: ctx, W: W, H: H)
                drawCG(ctx, im, CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
                ctx.restoreGState()
            }
        case .text:
            let size = c.fontSize ?? 80
            let blurred = pose.blur > 0
            let style = c.textStyle
            // カウントダウンの文字(無ければ text そのもの)
            let shown = c.displayText(at: t, in: project)
            // 文字のアニメーション(頭の数秒だけ。終わったあとは静止した文字と同じ速い道)
            var pose = pose
            var visible: Int?
            var animating = false
            var restoreAlpha = false
            defer { if restoreAlpha { ctx.restoreGState() } }
            if let a = c.textAnim {
                let st = TextAnimMath.state(a, text: shown, rel: t - c.start, size: size)
                if st.active {
                    animating = true
                    visible = st.visible
                    if st.scale != 1 { pose.scale *= st.scale }
                    if st.alpha != 1 {
                        // 文字全体の濃さ(フェードイン): 呼び出し側の濃さ(fadeAlpha)に掛ける
                        ctx.saveGState(); ctx.setAlpha(CGFloat(fadeAlpha * st.alpha)); restoreAlpha = true
                    }
                    if st.dx != 0 || st.dy != 0 { pose.x += st.dx / W; pose.y += st.dy / H }
                    if st.shiftX != 0 || st.shiftY != 0 { pose.x += st.shiftX; pose.y += st.shiftY }
                }
            }
            // 吹き出し(任意): 文字の後ろに、キャンバス基準で描く(文字の回転には従わない)
            if c.bubble != nil { drawBubble(c, x: pose.x * W, y: pose.y * H, scale: pose.scale, W: W, H: H, ctx: ctx) }
            // 位置・拡大・回転が動く文字は、位置ごとにキャッシュしても使い回せないので直接描く
            let geometryAnimated = c.hasKeyframes && ["x", "y", "scale", "rotation"].contains { Animation.isAnimated($0, in: c) }
            // カラオケ字幕: 話している部分(先頭から)を色を変えて重ね描きする。終わったあとは全部その色。
            let hlVisible = style?.highlight.map { min(KaraokeMath.coloredCount(text: shown, highlight: $0, rel: t - c.start, duration: c.duration), visible ?? Int.max) }
            let hlStyle = Renderer.highlightPassStyle(style)
            if pose.isPlain(c) {
                let plainCacheable = !geometryAnimated && !pose.transitionMoves && !animating && (pose.opacity >= 1 || blurred)
                drawText(shown, x: pose.x * W, y: pose.y * H, size: size, color: c.colorOrDefault, font: c.fontOrDefault, outline: c.outlineOrDefault, ctx: ctx,
                         cacheable: plainCacheable, style: style, visible: visible)
                if let n = hlVisible, n > 0, let hl = style?.highlight {
                    drawText(shown, x: pose.x * W, y: pose.y * H, size: size, color: hl.colorOrDefault, font: c.fontOrDefault, outline: c.outlineOrDefault, ctx: ctx,
                             cacheable: plainCacheable, style: hlStyle, visible: n)
                }
            } else {
                ctx.saveGState()
                pose.concat(c, ctx: ctx, W: W, H: H)
                var ox = 0.0, oy = 0.0
                if let crop = c.crop, !crop.isEmpty {
                    // 切り抜きは、描いた文字の枠(幅 = 一番長い行、高さ = 行数 × 行間)に対して
                    let box = textBlockSize(shown, size: size, font: c.fontOrDefault, style: style)
                    let kw = box.width * crop.keptWidth, kh = box.height * crop.keptHeight
                    ctx.clip(to: CGRect(x: -kw / 2, y: -kh / 2, width: kw, height: kh))
                    ox = -(crop.l - crop.r) / 2 * box.width
                    oy = -(crop.t - crop.b) / 2 * box.height
                }
                drawText(shown, x: ox, y: oy, size: size, color: c.colorOrDefault, font: c.fontOrDefault, outline: c.outlineOrDefault, ctx: ctx, cacheable: false, style: style, visible: visible)
                if let n = hlVisible, n > 0, let hl = style?.highlight {
                    drawText(shown, x: ox, y: oy, size: size, color: hl.colorOrDefault, font: c.fontOrDefault, outline: c.outlineOrDefault, ctx: ctx, cacheable: false, style: hlStyle, visible: n)
                }
                ctx.restoreGState()
            }
        default:
            break
        }
    }

    /// 素材が見つからないクリップの札(暗い赤の角丸 + タイトル + ファイル名)。
    func drawMissingPlaceholder(_ c: Clip, pose: ClipPose, ctx: CGContext, W: Double, H: Double) {
        let name = ((c.src ?? "") as NSString).lastPathComponent
        let l = MissingMediaPlaceholder.layout(canvasWidth: W, canvasHeight: H, fileName: name, centerX: pose.x, centerY: pose.y)
        MissingMediaPlaceholder.drawCard(l, in: ctx)
        let cx = l.card.midX
        drawText(MissingMediaPlaceholder.title, x: cx, y: l.titleY, size: l.titleSize, color: MissingMediaPlaceholder.textHex,
                 font: c.fontOrDefault, outline: "#000000", ctx: ctx, cacheable: false)
        drawText(l.nameText, x: cx, y: l.nameY, size: l.nameSize, color: "#ffd0d0",
                 font: c.fontOrDefault, outline: "#000000", ctx: ctx, cacheable: false)
    }

    /// カラオケの色つけの重ね描き用の装飾。字形と字間に関わる項目だけ残し、影・箱・グラデーションは最初の描きに任せる(二重に濃くしない)。
    static func highlightPassStyle(_ s: TextStyle?) -> TextStyle? {
        guard var st = s else { return nil }
        st.shadow = nil; st.box = nil; st.gradient = nil; st.highlight = nil
        return st
    }

    /// 等倍・整数位置でない画像の不透明度つき描画: 枠の範囲だけの透明なビットマップに不透明で描いてから、直接重ねる(CoreGraphics の不透明度つき汎用経路より速い)。
    func drawFadedViaTemp(_ ctx: CGContext, _ im: CGImage, rect r: CGRect, alpha: Double, W: Double, H: Double) -> Bool {
        let area = r.insetBy(dx: -1, dy: -1).integral.intersection(CGRect(x: 0, y: 0, width: W, height: H))
        guard !area.isNull, area.width >= 1, area.height >= 1, let tmp = Renderer.makeContext(width: Int(area.width), height: Int(area.height)) else { return false }
        tmp.translateBy(x: 0, y: CGFloat(tmp.height))
        tmp.scaleBy(x: 1, y: -1)
        tmp.translateBy(x: CGFloat(-area.minX), y: CGFloat(-area.minY))
        drawCG(tmp, im, r)
        guard let snap = tmp.makeImage() else { return false }
        return FastBlend.drawFaded(ctx, snap, rect: area, alpha: alpha)
    }

    /// 切り抜き(画素に丸める)。範囲が空になるときは nil。
    static func cropped(_ im: CGImage, _ crop: Crop) -> CGImage? {
        let w = Double(im.width), h = Double(im.height)
        let x0 = (crop.l * w).rounded(), y0 = (crop.t * h).rounded()
        let x1 = max(x0 + 1, (w - crop.r * w).rounded()), y1 = max(y0 + 1, (h - crop.b * h).rounded())
        return im.cropping(to: CGRect(x: x0, y: y0, width: min(x1, w) - x0, height: min(y1, h) - y0))
    }

    /// 文字の枠(幅 = 一番長い行の幅、高さ = 行数 × 文字の大きさ × 1.2)。
    func textBlockSize(_ text: String, size: Double, font: String, style: TextStyle? = nil) -> CGSize {
        let lines = text.components(separatedBy: "\n")
        let f = TextCache.font(name: font, size: size, bold: style?.boldOrDefault ?? true)
        let sp = style?.letterSpacingOrDefault ?? 0, it = style?.italicOrDefault ?? false
        let w = lines.map { TextCache.layout(f, font: font, line: $0, spacing: sp, italic: it).width }.max() ?? 0
        return CGSize(width: w, height: Double(lines.count) * size * (style?.lineHeightOrDefault ?? TextStyle.defaultLineHeight))
    }

    /// 画面に置いたときの、クリップの枠の大きさ(拡大を反映、回転は含まない)。素材が読めなければ nil。プレビューの取っ手用。
    public func objectSize(of c: Clip, at t: Double) -> CGSize? {
        let W = Double(project.width), H = Double(project.height)
        let pose = ClipPose(c, at: t)
        switch c.type {
        case .compound:
            // 中身はキャンバスと同じ大きさ(枠は全体)
            let crop = c.cropOrDefault
            return CGSize(width: W * crop.keptWidth * pose.scale, height: H * crop.keptHeight * pose.scale)
        case .image, .video:
            guard let src = c.src else { return nil }
            let size: CGSize?
            if c.type == .image { size = assets.image(at: src).map { CGSize(width: $0.width, height: $0.height) } }
            else { size = assets.knownVideoSize(path: src) ?? videoFrame(c, src: src, at: t).map { CGSize(width: $0.width, height: $0.height) } }
            guard let s = size, s.width > 0, s.height > 0 else { return nil }
            let fit = min(W / s.width, H / s.height) * pose.scale
            let crop = c.cropOrDefault
            return CGSize(width: s.width * crop.keptWidth * fit, height: s.height * crop.keptHeight * fit)
        case .text:
            let box = textBlockSize(c.text ?? "", size: c.fontSize ?? 80, font: c.fontOrDefault, style: c.textStyle)
            let crop = c.cropOrDefault
            return CGSize(width: box.width * crop.keptWidth * pose.scale, height: box.height * crop.keptHeight * pose.scale)
        default:
            return nil
        }
    }

    /// クリップの枠(回転も含めて囲む四角)。キャンバスの画素・左上原点。素材が読めなければ nil。
    func contentBounds(_ c: Clip, pose: ClipPose, t: Double) -> CGRect? {
        // スクロールする文字は、どこまで流れるか枠では決まらないので、キャンバス全体を作業範囲にする
        if c.type == .text, c.textAnim?.known?.isScroll == true { return CGRect(x: 0, y: 0, width: Double(project.width), height: Double(project.height)) }
        guard let size = objectSize(of: c, at: t) else { return nil }
        // objectSize は設定・キーの拡大で測るので、トランジションの拡大ぶんを掛ける
        let base = ClipPose(c, at: t).scale
        let k = base > 0 ? pose.scale / base : 1
        let w = size.width * k, h = size.height * k
        let a = pose.rotation * .pi / 180
        let bw = abs(w * cos(a)) + abs(h * sin(a)), bh = abs(w * sin(a)) + abs(h * cos(a))
        // 文字は縁が枠の外へ出る
        let pad = c.type == .text ? (c.fontSize ?? 80) * 0.2 + (c.textStyle?.overflow ?? 0) + (c.textAnim == nil ? 0 : (c.fontSize ?? 80) * 0.15) : 0
        return CGRect(x: pose.x * Double(project.width) - bw / 2 - pad, y: pose.y * Double(project.height) - bh / 2 - pad, width: bw + 2 * pad, height: bh + 2 * pad)
    }

    /// エフェクト付きのクリップ: 作業用の範囲(枠 + はみ出しの余白、キャンバス内)だけ透明なビットマップに描き、
    /// CIFilter の連なりをかけ(`EffectPipeline`)、クリップごとのぼかしがあればその後にかけて、不透明度で重ねる。
    func drawEffectedClip(_ c: Clip, pose: ClipPose, effects fx: [ResolvedEffect], t: Double, ctx: CGContext, W: Double, H: Double) {
        // 形のマスク(クリップの `mask`)は、エフェクトとぼかしの後にかける。マスクの外は透明にして、不透明度で重ねる
        let canvas = CGRect(x: 0, y: 0, width: W, height: H)
        let resScale = (W * H / (1920.0 * 1080.0)).squareRoot()
        let blurSigma = min(300, pose.blur)
        let bounds = contentBounds(c, pose: pose, t: t) ?? canvas
        let margin = EffectPipeline.margin(of: fx, scale: resScale) + 3 * blurSigma
        let work = bounds.insetBy(dx: -margin, dy: -margin).integral.intersection(canvas)
        guard !work.isNull, work.width >= 1, work.height >= 1 else { return }
        let ww = Int(work.width), wh = Int(work.height)
        guard let off = Renderer.makeContext(width: ww, height: wh) else { return }
        off.translateBy(x: 0, y: CGFloat(wh))
        off.scaleBy(x: 1, y: -1)
        off.translateBy(x: CGFloat(-work.minX), y: CGFloat(-work.minY))
        drawClipContent(c, pose: pose, t: t, ctx: off, W: W, H: H)
        guard let snap = off.makeImage() else { return }
        // 枠を作業範囲の座標(左下原点)へ
        let localBounds = CGRect(x: bounds.minX - work.minX, y: Double(wh) - (bounds.minY - work.minY) - bounds.height, width: bounds.width, height: bounds.height)
        let rect = CGRect(x: 0, y: 0, width: ww, height: wh)
        // 顔ぼかし: 作業範囲の画像から顔の枠を求める(同じ時刻・配置は検出を再利用)。調整レイヤーには効かない
        // 追従(track)がオンの顔ぼかしがあれば、時間方向に平滑化した枠を使う(その時刻に枠が無ければ何もぼかさない)
        let tracking = fx.contains { $0.kind == .faceBlur && ($0.values["track"] ?? 0) >= 0.5 }
        var faces: [CGRect] = []
        if tracking {
            if let canvasRect = trackedFaceRect(c, t: t, W: W, H: H), work.width > 0, work.height > 0 {
                // キャンバスの画素(左上原点)→ 作業範囲の正規化(左上原点・0〜1)
                faces = [CGRect(x: (canvasRect.minX - work.minX) / work.width, y: (canvasRect.minY - work.minY) / work.height,
                                width: canvasRect.width / work.width, height: canvasRect.height / work.height)]
            }
        } else if fx.contains(where: { $0.kind == .faceBlur }) {
            faces = faceRects(for: c, t: t, pose: pose, image: snap)
        }
        var ci = EffectPipeline.apply(CIImage(cgImage: snap), effects: fx, bounds: localBounds, scale: resScale, faces: faces)
        if blurSigma > 0 { ci = ci.applyingGaussianBlur(sigma: blurSigma) }
        if let m = c.mask { ci = ShapeMask.apply(ci, mask: m, canvasWidth: W, canvasHeight: H, originX: work.minX, originY: work.minY) }
        guard let out = EffectPipeline.makeImage(ci, from: rect) else { return }
        ctx.saveGState()
        ctx.setAlpha(CGFloat(pose.opacity))
        drawCG(ctx, out, work)
        ctx.restoreGState()
    }

    /// 複合クリップの中身を、その頭からの時刻で、キャンバスと同じ大きさの透明な画像に描く。
    /// 中身は同じ `Renderer` で描く(トランジション・効果・入れ子の複合もそのまま)。循環・深すぎる入れ子・中身が無いときは nil(何も描かない)。
    func compoundFrame(_ c: Clip, t: Double) -> CGImage? {
        guard let child = compoundRenderer(c) else { return nil }
        return child.renderImage(t: t - c.start + c.offset)
    }

    /// 複合クリップの中身を描く `Renderer`(背景・人物の立ち絵は描かない。祖先の id を引き継ぐ)。描けない(循環・深すぎる・中身なし)なら nil。
    func compoundRenderer(_ c: Clip) -> Renderer? {
        guard let kids = c.tracks, !kids.isEmpty, !compoundStack.contains(c.id), compoundStack.count < CompoundEditing.maxDepth else { return nil }
        var sub = project
        sub.tracks = kids
        var child = Renderer(project: sub, assets: assets, onStabilized: onStabilized, missingMediaPlaceholder: missingMediaPlaceholder)
        child.compoundStack = compoundStack + [c.id]
        child.drawsBackground = false
        child.drawsPortraits = false
        return child
    }

    /// 手ぶれ補正: 解析結果(キャッシュ)の時刻の補正量で、コマを動かして拡大する。解析できなければ元のコマ。
    /// 解析は素材の全体を一度に読む(初回だけ時間がかかる。以後はキャッシュ)。
    func stabilized(_ c: Clip, src: String, frame: CGImage, t: Double) -> CGImage {
        let key = c.stabilizeCacheKey(src: src)
        let build = { () -> Stabilization? in
            Stabilizer.analyze(duration: c.duration, strength: c.stabilizeStrength,
                               frame: { r in self.videoFrame(c, src: src, at: c.start + r) },
                               estimator: VisionMotionEstimator())
        }
        let st: Stabilization?
        if let onStabilized {
            st = StabilizationCache.shared.lazyValue(key: key, build: build, onReady: onStabilized)
        } else {
            st = StabilizationCache.shared.value(key: key, build: build)
        }
        guard let s = st else { return frame }
        let (dx, dy) = s.correction(atClipTime: t - c.start)
        return Stabilizer.warp(frame, dx: dx, dy: dy, zoom: s.zoom) ?? frame
    }

    /// 顔の検出枠(0〜1・左上原点)。鍵は クリップ・時刻(ms)・配置・素材・画像の大きさ。配置や素材が変われば別の鍵になる。
    func faceRects(for c: Clip, t: Double, pose: ClipPose, image: CGImage) -> [CGRect] {
        let key = "\(c.id)|\(c.src ?? "")|\(Int((t * 1000).rounded()))|\(pose)|\(image.width)x\(image.height)"
        return FaceDetectionCache.shared.rects(key: key, image: image)
    }

    /// 顔の追従: クリップの中の一定間隔(`FaceTrack.interval`)で顔を検出し(結果はキャッシュ)、いまの時刻の枠を返す。
    /// 枠はキャンバスの画素・左上原点。検出が途切れていれば nil。検出の間隔ごとに、その時刻の全画面の絵を 1 枚ずつ描く(初回だけ重い)。
    func trackedFaceRect(_ c: Clip, t: Double, W: Double, H: Double) -> CGRect? {
        let rel = t - c.start
        let dets: [(time: Double, faces: [CGRect])] = FaceTrack.sampleTimes(duration: c.duration).map { s in
            let at = c.start + s
            let pose = ClipPose(c, at: at)
            let key = "track|\(c.id)|\(c.src ?? "")|\(Int((s * 1000).rounded()))|\(pose)|\(Int(W))x\(Int(H))"
            let normalized = FaceDetectionCache.shared.rects(key: key) { () -> CGImage? in
                guard let ctx = Renderer.makeContext(width: Int(W), height: Int(H)) else { return nil }
                ctx.translateBy(x: 0, y: CGFloat(H))
                ctx.scaleBy(x: 1, y: -1)
                drawClipContent(c, pose: pose, t: at, ctx: ctx, W: W, H: H)
                return ctx.makeImage()
            }
            // 検出は正規化(0〜1・左上原点)なので、キャンバスの画素に直す
            return (s, normalized.map { CGRect(x: $0.minX * W, y: $0.minY * H, width: $0.width * W, height: $0.height * H) })
        }
        let track = FaceTrack.build(detections: dets)
        return FaceTrack.rect(at: rel, in: track)
    }

    /// 調整レイヤー: いまキャンバスに描いてある全部(背景と、それより前のレイヤー・クリップ)の合成結果に、
    /// クリップのエフェクトを一度かける。不透明度は元の絵との混ぜ具合(0 で何もしない)。プレビューと書き出しで同じ道。
    func applyAdjustment(_ c: Clip, t: Double, ctx: CGContext, W: Double, H: Double) {
        let fx = c.hasActiveEffects ? EffectPipeline.resolve(c, atClipTime: t - c.start) : []
        guard !fx.isEmpty else { return }
        let opacity = ClipPose(c, at: t).opacity
        guard opacity > 0, let snap = ctx.makeImage() else { return }
        let canvas = CGRect(x: 0, y: 0, width: W, height: H)
        let resScale = (W * H / (1920.0 * 1080.0)).squareRoot()
        let ci = EffectPipeline.apply(CIImage(cgImage: snap), effects: fx, bounds: canvas, scale: resScale)
        guard let out = EffectPipeline.makeImage(ci, from: canvas) else { return }
        ctx.saveGState()
        ctx.setAlpha(CGFloat(opacity))
        drawCG(ctx, out, canvas)
        ctx.restoreGState()
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
        let mosaic = c.blurModeOrDefault == "mosaic"
        let bokeh = c.blurModeOrDefault == "bokeh"
        let shapeRect = CGRect(x: bx - bw / 2, y: by - bh / 2, width: bw, height: bh)
        let canvas = CGRect(x: 0, y: 0, width: W, height: H)
        // 画素に揃えた取得範囲(キャンバス内)
        let area = shapeRect.integral.intersection(canvas)
        // モザイクは強さ(σ)を使わず、ブロックの大きさ(mosaicSize・1080p 基準)で決まる
        guard mosaic || sigma > 0, !area.isNull, area.width >= 1, area.height >= 1,
              let snap = ctx.makeImage() else { return }
        // CoreImage は左下原点
        let ciRect = CGRect(x: area.minX, y: H - area.maxY, width: area.width, height: area.height)
        let blurred: CIImage
        if mosaic {
            let resScale = (W * H / (1920.0 * 1080.0)).squareRoot()
            let block = max(2, c.mosaicSizeOrDefault * resScale)
            blurred = CIImage(cgImage: snap).applyingFilter("CIPixellate", parameters: [
                "inputCenter": CIVector(x: 0, y: 0), "inputScale": block,
            ])
        } else if bokeh {
            // 絞りぼかし: 強さ(σ 相当)から、同じ見えかたの円盤の半径(R ≈ 2σ)を決め、選んだ形でぼかす
            blurred = Bokeh.apply(CIImage(cgImage: snap), radius: 2 * sigma, shape: c.bokehShapeOrDefault, highlight: Bokeh.regionHighlight)
        } else {
            blurred = CIImage(cgImage: snap).clampedToExtent().applyingGaussianBlur(sigma: sigma)
        }
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
    /// `style`(影・箱・グラデーション・字間・行間・揃え・太字・斜体)が無ければ従来と同じ描き方。
    /// `visible` は見せる文字数(改行を除く。タイプライター)。位置は全文字ぶんで決めるので、文字が増えても動かない。
    /// 吹き出し(B-2): 文字の枠に余白を足した大きさで、形・塗り・縁・尾を描く(文字の後ろ)。縁は外側の半分が見えるように、2 倍の太さで塗ってから塗りで上書きする。
    func drawBubble(_ c: Clip, x: Double, y: Double, scale: Double, W: Double, H: Double, ctx: CGContext) {
        guard let b = c.bubble?.normalized, let fill = parseHexColor(b.fill), let stroke = parseHexColor(b.stroke) else { return }
        let size = c.fontSize ?? 80
        let block = textBlockSize(ExpressionTag.body(c.text ?? ""), size: size, font: c.fontOrDefault, style: c.textStyle)
        let s = max(0, scale)
        let w = block.width + size * 1.4 * s, h = block.height + size * 0.9 * s
        guard w > 0, h > 0 else { return }
        let target = b.tail ? BubbleTarget.point(b, characters: project.characters, width: W, height: H) : nil
        let path = BubbleGeometry.path(shape: b.shape, center: CGPoint(x: x, y: y), size: CGSize(width: w, height: h), tail: target)
        ctx.saveGState()
        if b.strokeWidth > 0 {
            ctx.addPath(path)
            ctx.setStrokeColor(stroke)
            ctx.setLineWidth(CGFloat(b.strokeWidth * 2))
            ctx.setLineJoin(.round)
            ctx.strokePath()
        }
        ctx.addPath(path)
        ctx.setFillColor(fill)
        ctx.fillPath()
        ctx.restoreGState()
    }

    func drawText(_ text: String, x: Double, y: Double, size: Double, color: String, font: String, outline: String, ctx: CGContext, cacheable: Bool = true,
                  style: TextStyle? = nil, visible: Int? = nil) {
        guard size > 0 else { return }
        let lines = text.components(separatedBy: "\n")
        let fillC = parseHexColor(color) ?? parseHexColor("#ffffff")!
        let outC = parseHexColor(outline) ?? parseHexColor("#000000")!
        let f = TextCache.font(name: font, size: size, bold: style?.boldOrDefault ?? true)
        let spacing = style?.letterSpacingOrDefault ?? 0, italic = style?.italicOrDefault ?? false
        let pitch = size * (style?.lineHeightOrDefault ?? TextStyle.defaultLineHeight)
        let full = lines.map { TextCache.layout(f, font: font, line: $0, spacing: spacing, italic: italic) }
        let blockW = full.map(\.width).max() ?? 0
        let align = style?.alignOrDefault ?? .center
        if let b = style?.box, let bc = parseHexColor(b.color), b.opacity > 0 {
            let bw = blockW + 2 * b.paddingX, bh = Double(lines.count) * pitch + 2 * b.paddingY
            let r = min(b.cornerRadius, bw / 2, bh / 2)
            let rect = CGRect(x: x - bw / 2, y: y - bh / 2, width: bw, height: bh)
            ctx.saveGState()
            ctx.setFillColor(bc.copy(alpha: CGFloat(b.opacity)) ?? bc)
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil))
            ctx.fillPath()
            ctx.restoreGState()
        }
        let lineStyled = style?.affectsLine ?? false
        var remaining = visible
        for (i, ln) in lines.enumerated() {
            var shown = ln
            if let rem = remaining {
                let n = ln.count
                if rem >= n { remaining = rem - n } else { shown = String(ln.prefix(rem)); remaining = 0 }
            }
            let yy = y + (Double(i) - Double(lines.count - 1) / 2) * pitch
            let line = shown == ln ? full[i] : TextCache.layout(f, font: font, line: shown, spacing: spacing, italic: italic)
            // textBaseline = middle: 基準線は (ascent - descent) / 2 だけ下
            let baseline = yy + (f.ascent - f.descent) / 2
            let ox: Double
            switch align {
            case .center: ox = x - full[i].width / 2
            case .left: ox = x - blockW / 2
            case .right: ox = x + blockW / 2 - full[i].width
            }
            if lineStyled, let st = style {
                guard !line.path.isEmpty else { continue }
                let ix = floor(ox), iy = floor(baseline)
                let fx = ox - ix, fy = baseline - iy
                let k = cacheable ? 1.0 : min(4, max(1, Double(hypot(ctx.ctm.a, ctx.ctm.b))))
                let build = { Renderer.rasterizeLine(line, f, size: size, fill: fillC, outline: outC, fx: fx, fy: fy, style: st, k: k) }
                let key = "\(font)|\(size)|\(shown)|\(color)|\(outline)|\(fx)|\(fy)|\(st.lineKey)"
                if let bm = cacheable ? TextCache.bitmap(key: key, build: build) : build() {
                    drawCG(ctx, bm.image, CGRect(x: ix + bm.x, y: iy + bm.y, width: Double(bm.image.width) / bm.k, height: Double(bm.image.height) / bm.k))
                }
                continue
            }
            if cacheable, !line.path.isEmpty {
                let ix = floor(ox), iy = floor(baseline)
                let fx = ox - ix, fy = baseline - iy
                let key = "\(font)|\(size)|\(shown)|\(color)|\(outline)|\(fx)|\(fy)"
                if let bm = TextCache.bitmap(key: key, build: { Renderer.rasterizeLine(line, f, size: size, fill: fillC, outline: outC, fx: fx, fy: fy) }) {
                    drawCG(ctx, bm.image, CGRect(x: ix + bm.x, y: iy + bm.y, width: Double(bm.image.width), height: Double(bm.image.height)))
                    continue
                }
            }
            // 絵文字は輪郭が取れない(カラー字形)ので、CoreText で字形どおりに描く
            if line.path.isEmpty, shown.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation }) {
                Renderer.drawColorGlyphs(shown, f: f, spacing: spacing, italic: italic, x: ox, baseline: baseline, ctx: ctx)
                continue
            }
            ctx.saveGState()
            ctx.translateBy(x: CGFloat(ox), y: CGFloat(baseline))
            Renderer.paintLine(line, f, size: size, fill: fillC, outline: outC, ctx: ctx)
            ctx.restoreGState()
        }
    }

    /// 字形の輪郭が無い文字(絵文字)を、CoreText で直接描く。ctx は y 下向きなので、文字の行列を上下反転して合わせる。
    static func drawColorGlyphs(_ text: String, f: TextFont, spacing: Double, italic: Bool, x: Double, baseline: Double, ctx: CGContext) {
        let attr = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): f.ct,
                                                                 NSAttributedString.Key(kCTKernAttributeName as String): spacing])
        let line = CTLineCreateWithAttributedString(attr)
        ctx.saveGState()
        ctx.translateBy(x: CGFloat(x), y: CGFloat(baseline))
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    /// 原点(基準線の左端)に移動済みの ctx(左上原点)へ 1 行を描く。
    /// `style` があれば、影(縁・白・塗りをまとめた形の影)とグラデーションの塗りを足す。
    static func paintLine(_ line: (path: CGPath, width: Double), _ f: TextFont, size: Double, fill: CGColor, outline: CGColor, ctx: CGContext, style: TextStyle? = nil) {
        let white = parseHexColor("#ffffff")!
        ctx.saveGState()
        ctx.scaleBy(x: 1, y: -1)  // グリフは y 上向きなので戻す
        ctx.setLineJoin(.round)
        var layer = false
        if let sh = style?.shadow, sh.opacity > 0, let sc = parseHexColor(sh.color) {
            // 影の向き: 呼び出し側の ctx は y 下向きに直してあるので、画面で「下」= ctx の +y。setShadow はビットマップ素の向き(y 上向き)なので反転する。
            ctx.setShadow(offset: CGSize(width: sh.dx, height: -sh.dy), blur: CGFloat(sh.blur), color: sc.copy(alpha: CGFloat(sh.opacity)))
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            layer = true
        }
        // 疑似ボールドは輪郭を太らせる(各パスの線幅に extra を足す)
        let extra = f.syntheticBoldExtra
        ctx.addPath(line.path)
        ctx.setLineWidth(CGFloat(size * 0.22 + extra)); ctx.setStrokeColor(outline); ctx.strokePath()
        ctx.addPath(line.path)
        ctx.setLineWidth(CGFloat(size * 0.1 + extra)); ctx.setStrokeColor(white); ctx.strokePath()
        if let g = style?.gradient, let c1 = parseHexColor(g.color1), let c2 = parseHexColor(g.color2),
           let grad = CGGradient(colorsSpace: sRGB, colors: [c1, c2] as CFArray, locations: [0, 1]) {
            let bb = line.path.boundingBoxOfPath
            let a = g.angle * .pi / 180
            // 画面の向き(y 下向き)の (cos, sin) を、グリフの座標(y 上向き)では (cos, −sin) にする
            let dx = cos(a), dy = -sin(a)
            let len = abs(bb.width * cos(a)) + abs(bb.height * sin(a))
            let cx = bb.midX, cy = bb.midY
            let p0 = CGPoint(x: cx - dx * len / 2, y: cy - dy * len / 2), p1 = CGPoint(x: cx + dx * len / 2, y: cy + dy * len / 2)
            func paintGradient() { ctx.drawLinearGradient(grad, start: p0, end: p1, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]) }
            ctx.saveGState(); ctx.addPath(line.path); ctx.clip(); paintGradient(); ctx.restoreGState()
            if extra > 0 {
                ctx.saveGState(); ctx.addPath(line.path); ctx.setLineWidth(CGFloat(extra)); ctx.setLineJoin(.round)
                ctx.replacePathWithStrokedPath(); ctx.clip(); paintGradient(); ctx.restoreGState()
            }
        } else {
            ctx.addPath(line.path)
            ctx.setFillColor(fill); ctx.fillPath()
            if extra > 0 {
                ctx.addPath(line.path)
                ctx.setLineWidth(CGFloat(extra)); ctx.setStrokeColor(fill); ctx.strokePath()
            }
        }
        if layer { ctx.endTransparencyLayer() }
        ctx.restoreGState()
    }

    /// 1 行を透明なビットマップに描く。原点(基準線の左端)から小数部 (fx, fy) ずれた位置で描き、
    /// 戻り値の x, y は「整数化した原点からのビットマップ左上のずれ」(点単位)。`k` は画素/点の倍率(拡大して描く文字を鮮明にする)。
    static func rasterizeLine(_ line: (path: CGPath, width: Double), _ f: TextFont, size: Double, fill: CGColor, outline: CGColor, fx: Double, fy: Double,
                              style: TextStyle? = nil, k: Double = 1) -> (image: CGImage, x: Double, y: Double, k: Double)? {
        let bb = line.path.boundingBoxOfPath
        guard !bb.isNull, !bb.isInfinite else { return nil }
        var pad = (size * 0.22 + f.syntheticBoldExtra) / 2 + 3
        if let sh = style?.shadow, sh.opacity > 0 { pad += max(abs(sh.dx), abs(sh.dy)) + sh.blur * 2 }
        // y 下向きの局所座標(原点 = 基準線の左端)
        let minX = floor(bb.minX - pad + fx), maxX = ceil(bb.maxX + pad + fx)
        let minY = floor(-bb.maxY - pad + fy), maxY = ceil(-bb.minY + pad + fy)
        let w = Int((maxX - minX) * k), h = Int((maxY - minY) * k)
        guard w > 0, h > 0, w * h <= 16_000_000,
              let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB, bitmapInfo: bitmapInfo) else { return nil }
        c.interpolationQuality = .high
        c.translateBy(x: 0, y: CGFloat(h))
        c.scaleBy(x: CGFloat(k), y: CGFloat(-k))
        c.translateBy(x: CGFloat(-minX + fx), y: CGFloat(-minY + fy))
        paintLine(line, f, size: size, fill: fill, outline: outline, ctx: c, style: style)
        guard let img = c.makeImage() else { return nil }
        return (img, minX, minY, k)
    }
}

// MARK: - 文字のキャッシュ

/// フォントとグリフ輪郭のキャッシュ。書き出しでは同じ文字を毎コマ描くので、CoreText のレイアウトを使い回す。
enum TextCache {
    private static let lock = NSLock()
    private static var fonts: [String: TextFont] = [:]
    private static var layouts: [String: (path: CGPath, width: Double)] = [:]

    private static var bitmaps: [String: (image: CGImage, x: Double, y: Double, k: Double)] = [:]

    static func bitmap(key: String, build: () -> (image: CGImage, x: Double, y: Double, k: Double)?) -> (image: CGImage, x: Double, y: Double, k: Double)? {
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

    static func font(name: String, size: Double, bold: Bool = true) -> TextFont {
        let key = bold ? "\(name)|\(size)" : "\(name)|\(size)|regular"
        lock.lock(); defer { lock.unlock() }
        if let f = fonts[key] { return f }
        let f = TextFont(name: name, size: size, bold: bold)
        fonts[key] = f
        return f
    }

    static func layout(_ f: TextFont, font: String, line: String, spacing: Double = 0, italic: Bool = false) -> (path: CGPath, width: Double) {
        let key = "\(font)|\(f.size)|\(f.regular ? "r" : "b")|\(spacing)|\(italic)|\(line)"
        lock.lock()
        if let l = layouts[key] { lock.unlock(); return l }
        lock.unlock()
        let l = f.layout(line, spacing: spacing, italic: italic)
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
    /// 太字にしない(標準の太さ)。
    let regular: Bool
    var ascent: Double { CTFontGetAscent(ct) }
    var descent: Double { CTFontGetDescent(ct) }

    init(name: String, size: Double, bold wantBold: Bool = true) {
        self.size = size
        regular = !wantBold
        let base = CTFontCreateWithName(name as CFString, CGFloat(size), nil)
        if !wantBold {
            ct = base; synthetic = false
        } else if let bold = CTFontCreateCopyWithSymbolicTraits(base, CGFloat(size), nil, .traitBold, .traitBold),
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
    func layout(_ s: String, spacing: Double = 0, italic: Bool = false) -> (path: CGPath, width: Double) {
        let attr = NSAttributedString(string: s, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): ct, NSAttributedString.Key(kCTKernAttributeName as String): spacing])
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
        // 字間は各文字の後ろに入るので、行の最後の分は幅から引く(揃えが字間のぶんずれないように)
        var w = CTLineGetTypographicBounds(line, nil, nil, nil)
        if spacing != 0, !s.isEmpty { w -= spacing }
        if italic {
            // 12 度の斜体(x を y に応じてずらす。グリフは y 上向き)
            var shear = CGAffineTransform(a: 1, b: 0, c: CGFloat(tan(12.0 * .pi / 180)), d: 1, tx: 0, ty: 0)
            if let sheared = path.copy(using: &shear) { return (sheared, w) }
        }
        return (path, w)
    }
}

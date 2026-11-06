import Foundation
import CoreGraphics

// 立ち絵クリップ(`ClipType.tachie`)の描画。口・まばたき・表情・バウンスは `Clip.mouthDrive` で選んだ声に連動する。
// 旧形式(Character が立ち絵を持つ)の描画(`Renderer.drawFrame` の「立ち絵」の段)と同じ選び方・同じ置き方で、
// 移行したプロジェクトは画素まで一致する(`TachieMigrationTests`)。旧経路はそのまま残してある(読み込み時に移行するまでの互換)。
extension Renderer {
    /// 時刻 t に出ているボイスクリップ(表示中のレイヤー、トラックの順)。
    func activeVoices(at t: Double) -> [Clip] {
        var out: [Clip] = []
        for tr in project.tracks where !tr.isHidden {
            for c in tr.clips where c.type == .voice && t >= c.start && t < c.start + c.duration { out.append(c) }
        }
        return out
    }

    /// 時刻 t の立ち絵 1 枚(高さ `height` 画素に合成)と、バウンスで持ち上げる量(画面の高さに対する割合)。描かないとき(素材なし・声が出ていない speakingOnly など)は nil。
    func tachieFrame(_ c: Clip, t: Double, height h: Double) -> (image: CGImage, lift: Double)? {
        guard let tachie = project.tachie(c.tachieId) else { return nil }
        let drive = c.mouthDriveOrDefault
        let v: Clip? = drive == .none ? nil : drive.driver(among: activeVoices(at: t))
        if v == nil && c.speakingOnly == true { return nil }
        var seedBase = c.id
        if case .character(let id) = drive { seedBase = id }

        var open = v.map { mouthOpen($0, t: t) } ?? false
        // あいうえお口パク(母音画像が 1 つでもあるとき): 口の形はセリフの読みと音量から決める。ん・っ・無音は閉じる
        var vowelPath: String? = nil
        if let v, let vs = tachie.imgVowels, !vs.isEmpty, let shape = lipShape(v, t: t) {
            open = shape != .closed
            if let k = shape.vowelKey, let p = vs[k], !p.isEmpty { vowelPath = p }
        }
        // 目: まばたき中は imgBlink(無ければ通常)。瞬きの種はしゃべっているクリップ、無ければ連動先のキャラ(無ければこのクリップ)。
        let blinking = tachie.imgBlink != nil && Blink.isClosed(seed: v?.id ?? seedBase, t: t - (v?.start ?? 0))
        let expr = v.flatMap { ExpressionTag.imagePath(for: $0.text ?? "", in: tachie.expressions) }
        let path: String?
        if open, let vp = vowelPath { path = vp }
        else if open, let o = tachie.imgOpen { path = o }
        else if blinking, let b = tachie.imgBlink { path = b }
        else { path = expr ?? tachie.imgClosed }
        let img: CGImage
        if let rig = tachie.rig, rig.hasParts {
            // パーツ式: 表情 → 口 → まばたきを重ねた組み合わせで 1 枚に合成(組み合わせごとにキャッシュ)
            var mouth: RigMouth = .closed
            if v != nil {
                if let vv = v, let vs = rig.vowels, !vs.isEmpty, let shape = lipShape(vv, t: t) {
                    mouth = shape.vowelKey.map { .vowel($0) } ?? .closed
                } else { mouth = open ? .open : .closed }
            }
            let isBlink = rig.blink != nil && Blink.isClosed(seed: v?.id ?? seedBase, t: t - (v?.start ?? 0))
            let tag = v.flatMap { ExpressionTag.split($0.text ?? "").tag }
            let active = rig.resolvedActive(expression: tag, mouth: mouth, blinking: isBlink)
            let paths = rig.paths(active: active)
            guard let f = assets.rigCache.frame(paths: paths, height: max(16, Int(h.rounded())), offsets: rig.offsets(for: paths)) else { return nil }
            img = f
        } else {
            guard let p = path, let i = assets.image(at: p), i.height > 0 else { return nil }
            img = i
        }
        guard img.height > 0 else { return nil }
        // 話し中バウンス(オプション): 音量に比例して上へ揺れる
        var lift = 0.0
        if let v, tachie.bounce == true { lift = Bounce.lift(level: mouthLevel(v, t: t)) }
        return (img, lift)
    }

    /// 立ち絵クリップを描く。高さは画面の 0.6 倍 × 拡大。(x, y) が立ち絵の中心。
    func drawTachie(_ c: Clip, pose: ClipPose, t: Double, ctx: CGContext, W: Double, H: Double) {
        let h = H * 0.6 * pose.scale
        guard h > 0, let (img, lift) = tachieFrame(c, t: t, height: h) else { return }
        let w = Double(img.width) * (h / Double(img.height))
        ctx.saveGState()
        // バウンスは 1 ピクセル単位に丸める(小数位置の描画は拡大・補間の遅い経路になるため。バウンスなしはそのまま)
        let cy = lift > 0 ? ((pose.y * H - lift * H).rounded()) : pose.y * H
        ctx.translateBy(x: CGFloat(pose.x * W), y: CGFloat(cy))
        if pose.rotation != 0 { ctx.rotate(by: CGFloat(pose.rotation * .pi / 180)) }
        if c.flipHOrDefault || c.flipVOrDefault { ctx.scaleBy(x: c.flipHOrDefault ? -1 : 1, y: c.flipVOrDefault ? -1 : 1) }
        drawCG(ctx, img, CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
        ctx.restoreGState()
    }

    /// 立ち絵クリップの枠の大きさ(画素、回転は含まない)。描かないとき・素材が読めないときは nil。
    func tachieSize(_ c: Clip, at t: Double) -> CGSize? {
        let H = Double(project.height)
        let pose = ClipPose(c, at: t)
        let h = H * 0.6 * pose.scale
        guard h > 0, let (img, _) = tachieFrame(c, t: t, height: h) else { return nil }
        return CGSize(width: Double(img.width) * (h / Double(img.height)), height: h)
    }
}

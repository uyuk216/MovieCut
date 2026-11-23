import Foundation

// MARK: - 登場/退場プリセット(#61)
//
// YMM4 の登場/退場アニメーションのプリセット群を、MovieCut のトランジション
// (transitionIn / transitionOut)の「名前付きの組み合わせ」として提供する。
// プリセットは「種類・長さ・進み方」の組で、適用すると通常のトランジションになる
// (ファイル形式は従来どおり。プリセット自体は保存されない)。
// 位置・拡大・回転・不透明度・ぼかしで表せるものは、キーフレーム列への変換もできる
// (適用後にキーフレームとして手で直せるようにするため)。

/// 登場/退場プリセット 1 件。
public struct EntrancePreset: Equatable, Sendable, Identifiable {
    public var id: String
    /// 画面に出す名前(YMM4 の呼び名に合わせる)。
    public var label: String
    /// 実体のトランジションの種類。
    public var kind: TransitionKind
    /// 推奨の長さ(秒)。登場・退場で別々に持つ。
    public var durationIn: Double
    public var durationOut: Double
    /// 推奨の進み方。
    public var easeIn: Ease
    public var easeOut: Ease
    /// 一言の説明。
    public var note: String

    public init(id: String, label: String, kind: TransitionKind, durationIn: Double, durationOut: Double, easeIn: Ease, easeOut: Ease, note: String) {
        self.id = id; self.label = label; self.kind = kind
        self.durationIn = durationIn; self.durationOut = durationOut
        self.easeIn = easeIn; self.easeOut = easeOut; self.note = note
    }

    /// その端での推奨の長さ・進み方。
    public func duration(for edge: TransitionEdge) -> Double { edge == .in ? durationIn : durationOut }
    public func ease(for edge: TransitionEdge) -> Ease { edge == .in ? easeIn : easeOut }

    /// キーフレーム列に変換できるか(マスク・モザイク・傾斜などは変換できない)。
    public var supportsKeyframes: Bool { EntrancePresets.keyframeKeys(for: kind) != nil }
}

/// プリセットの一覧と適用・変換。
public enum EntrancePresets {
    /// 全プリセット(画面の並び順)。
    public static let all: [EntrancePreset] = [
        EntrancePreset(id: "fade", label: "フェード", kind: .fade, durationIn: 0.5, durationOut: 0.5, easeIn: .easeInOut, easeOut: .easeInOut, note: "徐々に透明度が変化する"),
        EntrancePreset(id: "bubbleFade", label: "吹き出しフェード", kind: .fade, durationIn: 0.4, durationOut: 0.4, easeIn: .easeInOut, easeOut: .easeInOut, note: "吹き出し付き文字用のフェード"),
        EntrancePreset(id: "fadeZoom", label: "フェードズーム", kind: .fadeZoom, durationIn: 0.5, durationOut: 0.5, easeIn: .easeOut, easeOut: .easeIn, note: "少し拡大しながら現れる"),
        EntrancePreset(id: "screenLeft", label: "画面外から（左）", kind: .slideLeft, durationIn: 0.5, durationOut: 0.5, easeIn: .easeOut, easeOut: .easeIn, note: "画面の外から滑り込む"),
        EntrancePreset(id: "screenRight", label: "画面外から（右）", kind: .slideRight, durationIn: 0.5, durationOut: 0.5, easeIn: .easeOut, easeOut: .easeIn, note: "画面の外から滑り込む"),
        EntrancePreset(id: "screenUp", label: "画面外から（上）", kind: .slideUp, durationIn: 0.5, durationOut: 0.5, easeIn: .easeOut, easeOut: .easeIn, note: "画面の外から滑り込む"),
        EntrancePreset(id: "screenDown", label: "画面外から（下）", kind: .slideDown, durationIn: 0.5, durationOut: 0.5, easeIn: .easeOut, easeOut: .easeIn, note: "画面の外から滑り込む"),
        EntrancePreset(id: "regionLeft", label: "領域外から（左）", kind: .regionLeft, durationIn: 0.45, durationOut: 0.45, easeIn: .easeOut, easeOut: .easeIn, note: "自分の領域のすぐ外から現れる"),
        EntrancePreset(id: "regionRight", label: "領域外から（右）", kind: .regionRight, durationIn: 0.45, durationOut: 0.45, easeIn: .easeOut, easeOut: .easeIn, note: "自分の領域のすぐ外から現れる"),
        EntrancePreset(id: "regionUp", label: "領域外から（上）", kind: .regionUp, durationIn: 0.45, durationOut: 0.45, easeIn: .easeOut, easeOut: .easeIn, note: "自分の領域のすぐ外から現れる"),
        EntrancePreset(id: "regionDown", label: "領域外から（下）", kind: .regionDown, durationIn: 0.45, durationOut: 0.45, easeIn: .easeOut, easeOut: .easeIn, note: "自分の領域のすぐ外から現れる"),
        EntrancePreset(id: "driftLeft", label: "移動しながら（左）", kind: .driftLeft, durationIn: 0.5, durationOut: 0.5, easeIn: .easeOut, easeOut: .easeIn, note: "移動しながら現れる"),
        EntrancePreset(id: "driftRight", label: "移動しながら（右）", kind: .driftRight, durationIn: 0.5, durationOut: 0.5, easeIn: .easeOut, easeOut: .easeIn, note: "移動しながら現れる"),
        EntrancePreset(id: "driftUp", label: "移動しながら（上）", kind: .driftUp, durationIn: 0.5, durationOut: 0.5, easeIn: .easeOut, easeOut: .easeIn, note: "移動しながら現れる"),
        EntrancePreset(id: "driftDown", label: "移動しながら（下）", kind: .driftDown, durationIn: 0.5, durationOut: 0.5, easeIn: .easeOut, easeOut: .easeIn, note: "移動しながら現れる"),
        EntrancePreset(id: "zoom", label: "拡大しながら", kind: .zoom, durationIn: 0.4, durationOut: 0.4, easeIn: .easeOut, easeOut: .easeIn, note: "小さい状態から拡大する"),
        EntrancePreset(id: "pop", label: "ポップ拡大", kind: .pop, durationIn: 0.35, durationOut: 0.35, easeIn: .easeOut, easeOut: .easeIn, note: "弾むように拡大して登場"),
        EntrancePreset(id: "spin", label: "回転しながら", kind: .spin, durationIn: 0.5, durationOut: 0.5, easeIn: .easeOut, easeOut: .easeIn, note: "回転を伴いながら現れる"),
        EntrancePreset(id: "blur", label: "ぼかしながら", kind: .blur, durationIn: 0.5, durationOut: 0.5, easeIn: .easeOut, easeOut: .easeIn, note: "ぼかしとフェードが同時にかかる"),
        EntrancePreset(id: "blurRelease", label: "ぼかし解除", kind: .blurRelease, durationIn: 0.5, durationOut: 0.5, easeIn: .easeOut, easeOut: .easeIn, note: "ぼやけた状態から鮮明に"),
        EntrancePreset(id: "mosaicRelease", label: "モザイク解除", kind: .mosaicRelease, durationIn: 0.5, durationOut: 0.5, easeIn: .linear, easeOut: .linear, note: "粗いモザイクが徐々に晴れる"),
        EntrancePreset(id: "edgeBlurRelease", label: "境界ぼかし解除", kind: .edgeBlurRelease, durationIn: 0.5, durationOut: 0.5, easeIn: .easeOut, easeOut: .easeIn, note: "輪郭のぼかしが消えていく"),
        EntrancePreset(id: "skewIn", label: "傾斜変形しながら", kind: .skewIn, durationIn: 0.45, durationOut: 0.45, easeIn: .easeOut, easeOut: .easeIn, note: "斜めに傾きながら現れる"),
        EntrancePreset(id: "shatter", label: "砕け散りながら", kind: .shatter, durationIn: 0.7, durationOut: 0.7, easeIn: .easeOut, easeOut: .easeIn, note: "破片が集まり形を成す(ブロック単位)"),
        EntrancePreset(id: "bounceIn", label: "跳ねながら", kind: .bounceIn, durationIn: 0.6, durationOut: 0.6, easeIn: .easeOut, easeOut: .easeIn, note: "バウンドしながら登場する"),
        EntrancePreset(id: "riseIn", label: "起き上がりながら", kind: .riseIn, durationIn: 0.5, durationOut: 0.5, easeIn: .easeOut, easeOut: .easeIn, note: "倒れた状態から起き上がる"),
        EntrancePreset(id: "ruleHorizontal", label: "ルールワイプ（横）", kind: .ruleHorizontal, durationIn: 0.5, durationOut: 0.5, easeIn: .linear, easeOut: .linear, note: "横方向に切り替わる"),
        EntrancePreset(id: "ruleVertical", label: "ルールワイプ（縦）", kind: .ruleVertical, durationIn: 0.5, durationOut: 0.5, easeIn: .linear, easeOut: .linear, note: "縦方向に切り替わる"),
        EntrancePreset(id: "ruleDiagonal", label: "ルールワイプ（斜め）", kind: .ruleDiagonal, durationIn: 0.5, durationOut: 0.5, easeIn: .linear, easeOut: .linear, note: "斜め方向に切り替わる"),
        EntrancePreset(id: "ruleCircle", label: "ルールワイプ（円）", kind: .ruleCircle, durationIn: 0.5, durationOut: 0.5, easeIn: .easeInOut, easeOut: .easeInOut, note: "円形に広がり現れる"),
        EntrancePreset(id: "ruleSquare", label: "ルールワイプ（四角）", kind: .ruleSquare, durationIn: 0.5, durationOut: 0.5, easeIn: .easeInOut, easeOut: .easeInOut, note: "四角形に広がり現れる"),
        EntrancePreset(id: "ruleDiamond", label: "ルールワイプ（菱形）", kind: .ruleDiamond, durationIn: 0.5, durationOut: 0.5, easeIn: .easeInOut, easeOut: .easeInOut, note: "菱形に広がり現れる"),
        EntrancePreset(id: "ruleClock", label: "ルールワイプ（時計回り）", kind: .ruleClock, durationIn: 0.6, durationOut: 0.6, easeIn: .linear, easeOut: .linear, note: "時計回りに回転し現れる"),
        EntrancePreset(id: "ruleChecker", label: "ルールワイプ（市松）", kind: .ruleChecker, durationIn: 0.6, durationOut: 0.6, easeIn: .linear, easeOut: .linear, note: "市松模様状に切り替わる"),
        EntrancePreset(id: "ruleStripesH", label: "ルールワイプ（横縞）", kind: .ruleStripesH, durationIn: 0.5, durationOut: 0.5, easeIn: .linear, easeOut: .linear, note: "横縞模様で切り替わる"),
        EntrancePreset(id: "ruleStripesV", label: "ルールワイプ（縦縞）", kind: .ruleStripesV, durationIn: 0.5, durationOut: 0.5, easeIn: .linear, easeOut: .linear, note: "縦縞模様で切り替わる"),
        EntrancePreset(id: "ruleSpiral", label: "ルールワイプ（渦巻き）", kind: .ruleSpiral, durationIn: 0.7, durationOut: 0.7, easeIn: .easeInOut, easeOut: .easeInOut, note: "渦を巻きながら現れる"),
    ]

    /// id から探す。
    public static func preset(id: String) -> EntrancePreset? { all.first { $0.id == id } }

    // MARK: 適用(トランジションとして)

    /// プリセットをクリップの頭/終わりのトランジションとして付ける。変えたときだけ true。
    /// 長さはクリップの半分までに収める(通常のトランジションと同じ規則)。
    @discardableResult
    public static func apply(_ preset: EntrancePreset, edge: TransitionEdge, to clip: inout Clip, duration: Double? = nil) -> Bool {
        guard TransitionEditing.supportsVideo(clip.type) else { return false }
        let d = Transition.clampedDuration(duration ?? preset.duration(for: edge), clipDuration: clip.duration)
        let tr = Transition(kind: preset.kind.rawValue, duration: (d * 1000).rounded() / 1000, ease: preset.ease(for: edge))
        let before = edge == .in ? clip.transitionIn : clip.transitionOut
        guard before != tr else { return false }
        if edge == .in { clip.transitionIn = tr } else { clip.transitionOut = tr }
        return true
    }

    /// プリセットをキーフレームとしてクリップに書く(既存の AnimationPreset と同じ流儀)。
    /// 変換できない種類は false。書いた項目は、既存のキー列を置き換える。
    @discardableResult
    public static func applyAsKeyframes(_ preset: EntrancePreset, edge: TransitionEdge, to clip: inout Clip, size: (w: Double, h: Double) = (0, 0)) -> Bool {
        guard TransitionEditing.supportsVideo(clip.type), let ks = keyframes(preset, edge: edge, clip: clip, size: size) else { return false }
        for (k, v) in ks { clip.keyframes[k] = v }
        return true
    }

    // MARK: キーフレームへの変換

    /// その種類がキーフレームで表せる項目(無い種類は nil = トランジション専用)。
    public static func keyframeKeys(for kind: TransitionKind) -> [String]? {
        switch kind {
        case .fade: return ["opacity"]
        case .fadeZoom: return ["opacity", "scale"]
        case .zoom: return ["scale"]
        case .pop: return ["scale", "opacity"]
        case .spin: return ["rotation", "opacity"]
        case .slideLeft, .slideRight, .regionLeft, .regionRight: return ["x"]
        case .slideUp, .slideDown, .regionUp, .regionDown: return ["y"]
        case .driftLeft, .driftRight: return ["x", "opacity"]
        case .driftUp, .driftDown: return ["y", "opacity"]
        case .blur: return ["blur", "opacity"]
        case .blurRelease: return ["blur"]
        case .bounceIn: return ["y"]
        case .riseIn: return ["rotation", "y", "opacity"]
        default: return nil
        }
    }

    /// プリセットをキーフレーム列に変換する(クリップの頭からの秒)。
    /// 変換できない種類・マスク系は nil。`size` はクリップの枠の大きさ(キャンバスに対する割合、
    /// スライドの移動量に使う)。値はすべて項目の範囲に収め、端の値はクリップの現在の設定値に一致する。
    public static func keyframes(_ preset: EntrancePreset, edge: TransitionEdge, clip: Clip, size: (w: Double, h: Double) = (0, 0)) -> [String: [Keyframe]]? {
        guard keyframeKeys(for: preset.kind) != nil else { return nil }
        let d = Transition.clampedDuration(preset.duration(for: edge), clipDuration: clip.duration)
        guard d > 0 else { return nil }
        let ease = preset.ease(for: edge)
        // 基準値(現在の設定値)
        let bx = clip.xOrDefault, by = clip.yOrDefault
        let bs = clip.scaleOrDefault, br = clip.rotationOrDefault
        let bo = clip.opacityOrDefault, bb = clip.blurOrDefault
        // 始点の値(登場の始点 = 退場の終点)。TransitionMath.state の u=0 と同じ意味になるよう作る
        var start: [String: Double] = [:]
        var mid: [(key: String, at: Double, v: Double)] = []
        switch preset.kind {
        case .fade:
            start["opacity"] = 0
        case .fadeZoom:
            start["opacity"] = 0; start["scale"] = bs * 0.9
        case .zoom:
            start["scale"] = 0.05
        case .pop:
            start["scale"] = 0.05; start["opacity"] = 0
            mid.append(("scale", 0.7, bs * 1.08)); mid.append(("opacity", 0.5, bo))
        case .spin:
            start["rotation"] = br + (edge == .in ? -90 : 90); start["opacity"] = 0
        case .slideLeft: start["x"] = -size.w / 2
        case .slideRight: start["x"] = 1 + size.w / 2
        case .slideUp: start["y"] = -size.h / 2
        case .slideDown: start["y"] = 1 + size.h / 2
        case .regionLeft: start["x"] = bx - (size.w + 0.02)
        case .regionRight: start["x"] = bx + (size.w + 0.02)
        case .regionUp: start["y"] = by - (size.h + 0.02)
        case .regionDown: start["y"] = by + (size.h + 0.02)
        case .driftLeft: start["x"] = bx - 0.25; start["opacity"] = 0
        case .driftRight: start["x"] = bx + 0.25; start["opacity"] = 0
        case .driftUp: start["y"] = by - 0.25; start["opacity"] = 0
        case .driftDown: start["y"] = by + 0.25; start["opacity"] = 0
        case .blur: start["blur"] = bb + 60; start["opacity"] = 0
        case .blurRelease: start["blur"] = bb + 60
        case .bounceIn:
            // 跳ね: 5 点で easeOutBounce の軌跡をなぞる(キーのイージングは一定)。
            // 登場は u: 0→1、退場はその逆向きに同じ軌跡をたどる。
            var ys: [Keyframe] = []
            for i in 0...4 {
                let f = Double(i) / 4
                let u = edge == .in ? f : 1 - f
                let v = Animation.clamp("y", by + (1 - TransitionMath.easeOutBounce(u)) * 0.45, in: clip)
                let t = edge == .in ? f * d : clip.duration - d + f * d
                ys.append(Keyframe(t: t, v: v, ease: .linear))
            }
            return ["y": ys]
        case .riseIn:
            start["rotation"] = br + (edge == .in ? -75 : 75); start["y"] = by + 0.18; start["opacity"] = 0
        default:
            return nil
        }
        let base: [String: Double] = ["x": bx, "y": by, "scale": bs, "rotation": br, "opacity": bo, "blur": bb]
        var out: [String: [Keyframe]] = [:]
        for (key, sv) in start {
            guard let bv = base[key] else { continue }
            let s = Animation.clamp(key, sv, in: clip), e = Animation.clamp(key, bv, in: clip)
            if edge == .in {
                var ks = [Keyframe(t: 0, v: s, ease: ease), Keyframe(t: d, v: e)]
                for m in mid where m.key == key { ks.append(Keyframe(t: m.at * d, v: Animation.clamp(key, m.v, in: clip), ease: ease)) }
                out[key] = Animation.normalized(ks)
            } else {
                var ks = [Keyframe(t: clip.duration - d, v: e, ease: ease), Keyframe(t: clip.duration, v: s)]
                for m in mid where m.key == key { ks.append(Keyframe(t: clip.duration - d + (1 - m.at) * d, v: Animation.clamp(key, m.v, in: clip), ease: ease)) }
                out[key] = Animation.normalized(ks)
            }
        }
        return out
    }
}

import Foundation

/// エフェクトの編集の純粋な計算(UI にも Undo にも依存しない)。変えたときだけ true を返す(何も変わらない編集は Undo に登録しない)。
/// 引数のキーフレームは項目名に番号("fx.<番号>.<引数>")を含むので、追加・削除・並べ替えのたびに番号を付け替える。
public enum EffectEditing {
    public static func supports(_ type: ClipType) -> Bool { Clip.supportsEffects(type) }

    // MARK: キーの付け替え

    /// 番号を `map` で付け替える(nil を返した番号のキーは消す)。エフェクト以外のキーはそのまま。
    static func remapKeyframes(_ c: inout Clip, _ map: (Int) -> Int?) {
        guard !c.keyframes.isEmpty else { return }
        var out: [String: [Keyframe]] = [:]
        for (key, list) in c.keyframes {
            if let (i, p) = EffectKey.parse(key) {
                if let j = map(i) { out[EffectKey.make(j, p)] = list }
            } else {
                out[key] = list
            }
        }
        c.keyframes = out
    }

    // MARK: 追加・削除・並べ替え

    /// 末尾に足す(既定値)。
    @discardableResult
    public static func add(_ c: inout Clip, _ kind: EffectKind) -> Bool {
        guard supports(c.type) else { return false }
        c.effects.append(Effect(kind))
        return true
    }

    /// すでにあるエフェクトを末尾に足す(貼り付け・プリセット)。
    @discardableResult
    public static func append(_ c: inout Clip, _ list: [Effect]) -> Bool {
        guard supports(c.type), !list.isEmpty else { return false }
        c.effects.append(contentsOf: list)
        return true
    }

    @discardableResult
    public static func remove(_ c: inout Clip, at index: Int) -> Bool {
        guard c.effects.indices.contains(index) else { return false }
        c.effects.remove(at: index)
        remapKeyframes(&c) { $0 == index ? nil : ($0 > index ? $0 - 1 : $0) }
        return true
    }

    /// すべて外す(その引数のキーも)。
    @discardableResult
    public static func clear(_ c: inout Clip) -> Bool {
        guard !c.effects.isEmpty else { return false }
        remapKeyframes(&c) { _ in nil }
        c.effects = []
        return true
    }

    /// 1 つ上(-1)・下(+1)へ。端なら何もしない。
    @discardableResult
    public static func move(_ c: inout Clip, at index: Int, by delta: Int) -> Bool {
        let j = index + delta
        guard c.effects.indices.contains(index), c.effects.indices.contains(j), j != index else { return false }
        c.effects.swapAt(index, j)
        remapKeyframes(&c) { $0 == index ? j : ($0 == j ? index : $0) }
        return true
    }

    // MARK: 有効・引数・色

    @discardableResult
    public static func setEnabled(_ c: inout Clip, at index: Int, _ on: Bool) -> Bool {
        guard c.effects.indices.contains(index), c.effects[index].enabled != on else { return false }
        c.effects[index].enabled = on
        return true
    }

    @discardableResult
    public static func setColor(_ c: inout Clip, at index: Int, _ hex: String) -> Bool {
        guard c.effects.indices.contains(index), c.effects[index].known?.defaultColor != nil, c.effects[index].color != hex else { return false }
        c.effects[index].color = hex
        return true
    }

    /// LUT のファイルを決める。LUT が無ければ足し、あれば最初の LUT のファイルを差し替える(同じなら何もしない)。
    @discardableResult
    public static func setLUTPath(_ c: inout Clip, _ path: String) -> Bool {
        guard supports(c.type), !path.isEmpty else { return false }
        if let i = c.effects.firstIndex(where: { $0.kind == EffectKind.lut.rawValue }) {
            guard c.effects[i].path != path else { return false }
            c.effects[i].path = path
        } else {
            var e = Effect(.lut)
            e.path = path
            c.effects.append(e)
        }
        return true
    }

    /// 初期値に戻す(引数・色。有効/無効と並びはそのまま。その引数のキーは消す)。
    @discardableResult
    public static func reset(_ c: inout Clip, at index: Int) -> Bool {
        guard c.effects.indices.contains(index), let kind = c.effects[index].known else { return false }
        let before = c
        var fresh = Effect(kind)
        fresh.enabled = c.effects[index].enabled
        fresh.extra = c.effects[index].extra
        fresh.path = c.effects[index].path
        c.effects[index] = fresh
        for s in kind.params { c.keyframes[EffectKey.make(index, s.key)] = nil }
        return c != before
    }
}

// MARK: - プリセット

/// クリップ ▸ エフェクト ▸ プリセット。いまのエフェクトの後ろに足す(1 回の Undo)。
public enum EffectPreset: String, CaseIterable, Sendable {
    case vintage, noirFilm, dreamy, punchy, mosaicAll

    public var title: String {
        switch self {
        case .vintage: return "ビンテージ"
        case .noirFilm: return "白黒映画"
        case .dreamy: return "夢のような"
        case .punchy: return "強調"
        case .mosaicAll: return "モザイク全体"
        }
    }

    public var undoName: String { "エフェクトのプリセット: " + title }

    /// 足すエフェクト(値は仕様の範囲内)。
    public var effects: [Effect] {
        func e(_ k: EffectKind, _ v: [String: Double]) -> Effect {
            var fx = Effect(k)
            for (key, val) in v { fx.params[key] = k.spec(key)?.clamp(val) ?? val }
            return fx
        }
        switch self {
        case .vintage: return [e(.sepia, ["amount": 0.8]), e(.vignette, ["intensity": 1.0, "radius": 1.0]), e(.contrast, ["amount": 1.15])]
        case .noirFilm: return [e(.mono, ["amount": 1]), e(.contrast, ["amount": 1.4]), e(.vignette, ["intensity": 1.2, "radius": 0.9])]
        case .dreamy: return [e(.glow, ["radius": 24, "intensity": 0.8]), e(.brightness, ["amount": 0.08])]
        case .punchy: return [e(.sharpen, ["amount": 1.2]), e(.saturation, ["amount": 1.4])]
        case .mosaicAll: return [e(.pixelate, ["size": 24])]
        }
    }

    @discardableResult
    public func apply(to c: inout Clip) -> Bool { EffectEditing.append(&c, effects) }
}

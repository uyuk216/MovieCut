import Foundation
import CoreImage

/// ノード式グレーディングの 1 ノード。クリップが「ノードの直列リスト」(`Clip.gradeNodes`)を持ち、上から順に評価する。
///
/// 中身は既存のカード式エフェクト(`Effect`)をそのまま再利用する(ホイール・カーブ・HSL・LUT・ホワイトバランスなど)。
/// 引数の意味・範囲・描き方は `EffectKind` / `EffectPipeline` と同一で、ノード専用の色補正は持たない。
/// ノードの中身のエフェクトにはキーフレームを付けない(固定値)。
public struct GradeNode: Codable, Equatable, Identifiable, Sendable {
    public var id: String = UUID().uuidString
    public var name: String = ""
    /// false のノードは素通し(書くのは false のときだけ)。
    public var enabled: Bool = true
    /// 0...1。補正結果と入力の混合比(0 = 入力のまま、1 = 補正結果そのまま)。
    public var opacity: Double = 1
    /// 中身(直列に適用)。
    public var effects: [Effect] = []
    public var extra: [String: JSONValue] = [:]

    static let knownKeys: Set<String> = ["id", "name", "enabled", "opacity", "effects"]

    /// ノードの中で使えるエフェクトの種類(色補正のうち、絵の外へはみ出さず画素ごとに決まるもの)。
    public static let allowedKinds: Set<EffectKind> = [
        .brightness, .contrast, .saturation, .hue, .exposure, .mono, .sepia, .lut, .colorTransfer,
        .whiteBalance, .colorWheels, .colorCurves, .hslSecondary, .highlightRolloff, .invert, .posterize,
    ]

    public init(name: String = "", enabled: Bool = true, opacity: Double = 1, effects: [Effect] = []) {
        self.name = name; self.enabled = enabled; self.opacity = opacity; self.effects = effects
    }

    /// 1 つのエフェクトから作る(インスペクタの「ノードを追加」)。名前は種類の名前。
    public init(_ kind: EffectKind) {
        self.init(name: kind.label, effects: [Effect(kind)])
    }

    public var clampedOpacity: Double { opacity.isFinite ? min(max(opacity, 0), 1) : 1 }

    public init(from decoder: Decoder) throws {
        let l = Lenient(c: try decoder.container(keyedBy: AnyKey.self), known: Self.knownKeys)
        id = l.string("id") ?? UUID().uuidString
        name = l.string("name") ?? ""
        enabled = l.bool("enabled") ?? true
        if let o: Double = l.value("opacity"), o.isFinite { opacity = min(max(o, 0), 1) }
        effects = l.value("effects") ?? []
        extra = l.extra()
    }

    /// enabled は true のとき、opacity は 1 のときは書かない。
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        for (k, v) in extra { try c.encode(v, forKey: AnyKey(k)) }
        try c.encode(id, forKey: AnyKey("id"))
        if !name.isEmpty { try c.encode(name, forKey: AnyKey("name")) }
        if !enabled { try c.encode(false, forKey: AnyKey("enabled")) }
        if opacity != 1 { try c.encode(opacity, forKey: AnyKey("opacity")) }
        if !effects.isEmpty { try c.encode(effects, forKey: AnyKey("effects")) }
    }
}

/// 解決済みのノード(描くエフェクトの列と、混合の不透明度)。
public struct ResolvedGradeNode: Equatable, Sendable {
    public var effects: [ResolvedEffect]
    public var opacity: Double
}

extension GradeNode {
    /// ノードを描く形に解決する。無効・不透明度 0・何もしない中身なら nil(素通し)。
    public func resolved() -> ResolvedGradeNode? {
        guard enabled, clampedOpacity > 0 else { return nil }
        var tmp = Clip()
        tmp.effects = effects.filter { e in e.known.map(Self.allowedKinds.contains) ?? false }
        let fx = EffectPipeline.resolve(tmp, atClipTime: 0)
        guard !fx.isEmpty else { return nil }
        return ResolvedGradeNode(effects: fx, opacity: clampedOpacity)
    }
}

extension Clip {
    /// 描くノードが 1 つでもあるか。ノード無しのクリップは false で、描画は従来の道のまま。
    public var hasActiveGradeNodes: Bool { (gradeNodes ?? []).contains { $0.resolved() != nil } }

    /// 描く順に解決したノード(無効・何もしないノードは除く)。
    public func resolvedGradeNodes() -> [ResolvedClipEffect] {
        (gradeNodes ?? []).compactMap { $0.resolved().map { .gradeNode($0) } }
    }
}

extension EffectPipeline {
    /// ノード 1 つを適用: 中身を直列にかけ、不透明度 < 1 なら入力との線形混合(アルファも同じ比率)。
    static func applyNode(_ n: ResolvedGradeNode, _ img: CIImage, bounds: CGRect, scale: Double) -> CIImage {
        let rect = img.extent
        var out = img
        for e in n.effects { out = applyOne(e, out, rect: rect, bounds: bounds, scale: scale) }
        guard n.opacity < 1 else { return out }
        return mix(img, out, amount: n.opacity).cropped(to: rect)
    }

    /// `from`(入力)と `to`(補正結果)を amount で混ぜる(事前乗算の RGBA をそのまま線形補間。アルファも同じ比率)。
    static func mix(_ from: CIImage, _ to: CIImage, amount: Double) -> CIImage {
        from.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: to, kCIInputTimeKey: amount])
    }
}

/// ノードの編集(UI にも Undo にも依存しない純粋な変更。変わらなければ false)。
public enum GradeNodeEditing {
    /// ノード 1 つを末尾へ足す(下ほど後に評価される)。
    @discardableResult
    public static func add(_ c: inout Clip, _ node: GradeNode) -> Bool {
        guard Clip.supportsEffects(c.type) else { return false }
        c.gradeNodes = (c.gradeNodes ?? []) + [node]
        return true
    }

    @discardableResult
    public static func remove(_ c: inout Clip, id: String) -> Bool {
        guard var list = c.gradeNodes, let i = list.firstIndex(where: { $0.id == id }) else { return false }
        list.remove(at: i)
        c.gradeNodes = list.isEmpty ? nil : list
        return true
    }

    /// `delta` だけ位置をずらす(範囲外は端に止める)。動かなければ false。
    @discardableResult
    public static func move(_ c: inout Clip, id: String, by delta: Int) -> Bool {
        guard var list = c.gradeNodes, let i = list.firstIndex(where: { $0.id == id }) else { return false }
        let j = min(max(i + delta, 0), list.count - 1)
        guard j != i else { return false }
        list.insert(list.remove(at: i), at: j)
        c.gradeNodes = list
        return true
    }

    @discardableResult
    public static func update(_ c: inout Clip, id: String, _ change: (inout GradeNode) -> Void) -> Bool {
        guard var list = c.gradeNodes, let i = list.firstIndex(where: { $0.id == id }) else { return false }
        let before = list[i]
        change(&list[i])
        guard list[i] != before else { return false }
        c.gradeNodes = list
        return true
    }

    @discardableResult
    public static func setEnabled(_ c: inout Clip, id: String, _ on: Bool) -> Bool { update(&c, id: id) { $0.enabled = on } }

    @discardableResult
    public static func setOpacity(_ c: inout Clip, id: String, _ v: Double) -> Bool {
        let o = v.isFinite ? min(max(v, 0), 1) : 1
        return update(&c, id: id) { $0.opacity = o }
    }

    /// ノード中身の `index` 番目のエフェクトの引数を、仕様の範囲に収めて書く。
    @discardableResult
    public static func setParam(_ c: inout Clip, id: String, effectIndex: Int = 0, key: String, _ v: Double) -> Bool {
        update(&c, id: id) { n in
            guard n.effects.indices.contains(effectIndex) else { return }
            let spec = n.effects[effectIndex].known?.spec(key)
            n.effects[effectIndex].params[key] = spec?.clamp(v) ?? v
        }
    }

    @discardableResult
    public static func setLUTPath(_ c: inout Clip, id: String, effectIndex: Int = 0, _ path: String) -> Bool {
        update(&c, id: id) { n in
            guard n.effects.indices.contains(effectIndex), n.effects[effectIndex].known == .lut else { return }
            n.effects[effectIndex].path = path
        }
    }
}

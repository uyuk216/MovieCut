import Foundation

// MARK: - 文字の装飾(B1)

/// 文字クリップ(と字幕)の装飾。どの項目も任意で、無いものは既定どおりに描く。ファイルには設定した項目だけを書く。
/// px の値はキャンバスの画素そのまま(文字の大きさ `fontSize` と同じ扱い)。
public struct TextStyle: Codable, Equatable, Sendable {
    /// 影。色・ずれ(右下が正)・ぼかし・濃さ。
    public struct Shadow: Codable, Equatable, Sendable {
        public var color: String = "#000000"
        public var dx: Double = 4
        public var dy: Double = 4
        public var blur: Double = 6
        public var opacity: Double = 0.7
        public init() {}
        public init(color: String = "#000000", dx: Double = 4, dy: Double = 4, blur: Double = 6, opacity: Double = 0.7) {
            self.color = color; self.dx = dx; self.dy = dy; self.blur = blur; self.opacity = opacity
        }
        public init(from decoder: Decoder) throws {
            let l = Lenient(c: try decoder.container(keyedBy: AnyKey.self), known: [])
            self.init(color: l.string("color") ?? "#000000", dx: l.double("dx") ?? 4, dy: l.double("dy") ?? 4, blur: l.double("blur") ?? 6, opacity: l.double("opacity") ?? 0.7)
            self = normalized
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: AnyKey.self)
            try c.encode(color, forKey: AnyKey("color")); try c.encode(dx, forKey: AnyKey("dx")); try c.encode(dy, forKey: AnyKey("dy"))
            try c.encode(blur, forKey: AnyKey("blur")); try c.encode(opacity, forKey: AnyKey("opacity"))
        }
        public var normalized: Shadow {
            var s = self
            s.dx = TextStyle.clamp(dx, -200...200, 4); s.dy = TextStyle.clamp(dy, -200...200, 4)
            s.blur = TextStyle.clamp(blur, 0...100, 6); s.opacity = TextStyle.clamp(opacity, 0...1, 0.7)
            if parseHexColor(color) == nil { s.color = "#000000" }
            return s
        }
    }

    /// 文字の後ろの箱。色・濃さ・左右/上下の余白・角の丸み。
    public struct Box: Codable, Equatable, Sendable {
        public var color: String = "#000000"
        public var opacity: Double = 0.6
        public var paddingX: Double = 24
        public var paddingY: Double = 12
        public var cornerRadius: Double = 12
        public init() {}
        public init(color: String = "#000000", opacity: Double = 0.6, paddingX: Double = 24, paddingY: Double = 12, cornerRadius: Double = 12) {
            self.color = color; self.opacity = opacity; self.paddingX = paddingX; self.paddingY = paddingY; self.cornerRadius = cornerRadius
        }
        public init(from decoder: Decoder) throws {
            let l = Lenient(c: try decoder.container(keyedBy: AnyKey.self), known: [])
            self.init(color: l.string("color") ?? "#000000", opacity: l.double("opacity") ?? 0.6, paddingX: l.double("paddingX") ?? 24,
                      paddingY: l.double("paddingY") ?? 12, cornerRadius: l.double("cornerRadius") ?? 12)
            self = normalized
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: AnyKey.self)
            try c.encode(color, forKey: AnyKey("color")); try c.encode(opacity, forKey: AnyKey("opacity"))
            try c.encode(paddingX, forKey: AnyKey("paddingX")); try c.encode(paddingY, forKey: AnyKey("paddingY")); try c.encode(cornerRadius, forKey: AnyKey("cornerRadius"))
        }
        public var normalized: Box {
            var b = self
            b.opacity = TextStyle.clamp(opacity, 0...1, 0.6)
            b.paddingX = TextStyle.clamp(paddingX, 0...400, 24); b.paddingY = TextStyle.clamp(paddingY, 0...400, 12)
            b.cornerRadius = TextStyle.clamp(cornerRadius, 0...400, 12)
            if parseHexColor(color) == nil { b.color = "#000000" }
            return b
        }
    }

    /// グラデーションの塗り。角度は 0° = 左 → 右、90° = 上 → 下。
    public struct Gradient: Codable, Equatable, Sendable {
        public var color1: String = "#ffffff"
        public var color2: String = "#ff7043"
        public var angle: Double = 90
        public init() {}
        public init(color1: String = "#ffffff", color2: String = "#ff7043", angle: Double = 90) {
            self.color1 = color1; self.color2 = color2; self.angle = angle
        }
        public init(from decoder: Decoder) throws {
            let l = Lenient(c: try decoder.container(keyedBy: AnyKey.self), known: [])
            self.init(color1: l.string("color1") ?? "#ffffff", color2: l.string("color2") ?? "#ff7043", angle: l.double("angle") ?? 90)
            self = normalized
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: AnyKey.self)
            try c.encode(color1, forKey: AnyKey("color1")); try c.encode(color2, forKey: AnyKey("color2")); try c.encode(angle, forKey: AnyKey("angle"))
        }
        public var normalized: Gradient {
            var g = self
            g.angle = TextStyle.clamp(angle, -360...360, 90)
            if parseHexColor(color1) == nil { g.color1 = "#ffffff" }
            if parseHexColor(color2) == nil { g.color2 = "#ff7043" }
            return g
        }
    }

    public enum Align: String, CaseIterable, Sendable {
        case left, center, right
        public var label: String { switch self { case .left: return "左"; case .center: return "中央"; case .right: return "右" } }
    }

    public var shadow: Shadow?
    public var box: Box?
    public var gradient: Gradient?
    /// 字間(px)。未設定 = 0。
    public var letterSpacing: Double?
    /// 行間(文字の大きさに対する倍率)。未設定 = 1.2。
    public var lineHeight: Double?
    /// 行の揃え。未設定 = 中央。
    public var align: String?
    /// 太字。未設定 = 太字(従来どおり。書体に太字が無ければ疑似ボールド)。false = 標準の太さ。
    public var bold: Bool?
    /// 斜体(斜めに傾ける)。未設定 = しない。
    public var italic: Bool?
    /// カラオケ字幕(話している部分の色つけ)。未設定 = しない。文字クリップの装飾の一部なので、保存したスタイルにも入る。
    public var highlight: Highlight?
    public var extra: [String: JSONValue] = [:]

    static let knownKeys: Set<String> = ["shadow", "box", "gradient", "letterSpacing", "lineHeight", "align", "bold", "italic", "highlight"]
    public static let defaultLineHeight = 1.2

    public init() {}

    static func clamp(_ v: Double, _ r: ClosedRange<Double>, _ def: Double) -> Double {
        guard v.isFinite else { return def }
        return min(max(v, r.lowerBound), r.upperBound)
    }

    public init(from decoder: Decoder) throws {
        let l = Lenient(c: try decoder.container(keyedBy: AnyKey.self), known: Self.knownKeys)
        shadow = l.value("shadow"); box = l.value("box"); gradient = l.value("gradient")
        letterSpacing = l.double("letterSpacing"); lineHeight = l.double("lineHeight"); align = l.string("align")
        bold = l.bool("bold"); italic = l.bool("italic")
        highlight = l.value("highlight")
        extra = l.extra()
        // 読めなかった項目は捨てずに、そのまま書き戻す
        for key in ["shadow", "box", "gradient", "letterSpacing", "lineHeight", "align", "bold", "italic", "highlight"] {
            guard let raw: JSONValue = l.value(key), raw != .null else { continue }
            let ok: Bool
            switch key {
            case "shadow": ok = shadow != nil
            case "box": ok = box != nil
            case "gradient": ok = gradient != nil
            case "letterSpacing": ok = letterSpacing != nil
            case "lineHeight": ok = lineHeight != nil
            case "align": ok = align != nil
            case "bold": ok = bold != nil
            case "highlight": ok = highlight != nil
            default: ok = italic != nil
            }
            if !ok { extra[key] = raw }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        for (k, v) in extra { try c.encode(v, forKey: AnyKey(k)) }
        try c.encodeIfPresent(shadow, forKey: AnyKey("shadow"))
        try c.encodeIfPresent(box, forKey: AnyKey("box"))
        try c.encodeIfPresent(gradient, forKey: AnyKey("gradient"))
        try c.encodeIfPresent(letterSpacing, forKey: AnyKey("letterSpacing"))
        try c.encodeIfPresent(lineHeight, forKey: AnyKey("lineHeight"))
        try c.encodeIfPresent(align, forKey: AnyKey("align"))
        try c.encodeIfPresent(bold, forKey: AnyKey("bold"))
        try c.encodeIfPresent(italic, forKey: AnyKey("italic"))
        try c.encodeIfPresent(highlight, forKey: AnyKey("highlight"))
    }

    /// 何も設定していない(知らない項目も無い)。
    public var isEmpty: Bool {
        shadow == nil && box == nil && gradient == nil && letterSpacing == nil && lineHeight == nil && align == nil && bold == nil && italic == nil && highlight == nil && extra.isEmpty
    }

    public var letterSpacingOrDefault: Double { Self.clamp(letterSpacing ?? 0, -50...200, 0) }
    public var lineHeightOrDefault: Double { Self.clamp(lineHeight ?? Self.defaultLineHeight, 0.6...3, Self.defaultLineHeight) }
    public var alignOrDefault: Align { align.flatMap(Align.init(rawValue:)) ?? .center }
    public var boldOrDefault: Bool { bold ?? true }
    public var italicOrDefault: Bool { italic ?? false }

    /// 1 行の画素(影・グラデーション・字形)に関わる設定がある(行のビットマップを別の道で作る)。箱・揃え・行間は行の絵に関係しない。
    var affectsLine: Bool {
        (shadow?.opacity ?? 0) > 0 || gradient != nil || letterSpacingOrDefault != 0 || italicOrDefault || !boldOrDefault
    }

    /// 行のビットマップのキャッシュ鍵に足す文字列(`affectsLine` に関わる項目だけ)。
    var lineKey: String {
        var s = "\(letterSpacingOrDefault)|\(italicOrDefault)|\(boldOrDefault)"
        if let sh = shadow { s += "|s\(sh.color),\(sh.dx),\(sh.dy),\(sh.blur),\(sh.opacity)" }
        if let g = gradient { s += "|g\(g.color1),\(g.color2),\(g.angle)" }
        return s
    }

    /// 範囲に収めた写し。
    public var normalized: TextStyle {
        var s = self
        s.shadow = shadow?.normalized; s.box = box?.normalized; s.gradient = gradient?.normalized
        if let v = letterSpacing { s.letterSpacing = Self.clamp(v, -50...200, 0) }
        if let v = lineHeight { s.lineHeight = Self.clamp(v, 0.6...3, Self.defaultLineHeight) }
        if let a = align, Align(rawValue: a) == nil { s.align = nil }
        s.highlight = highlight?.normalized
        return s
    }

    /// 文字の枠の外へ描きがはみ出す大きさ(影・箱)。プレビューの取っ手や、エフェクトの作業範囲の余白に使う。
    public var overflow: Double {
        var m = 0.0
        if let sh = shadow, sh.opacity > 0 { m = max(m, max(abs(sh.dx), abs(sh.dy)) + sh.blur * 2) }
        if let b = box { m = max(m, max(b.paddingX, b.paddingY)) }
        return m
    }
}

// MARK: - 編集

/// 文字の装飾の編集の純粋な計算。変えたときだけ true を返す(何も変わらない編集は Undo に登録しない)。
public enum TextStyleEditing {
    public static func supports(_ type: ClipType) -> Bool { type == .text || type == .voice }

    /// 装飾を書き換える。範囲に収め、空になったら項目ごと消す。
    @discardableResult
    public static func update(_ c: inout Clip, _ change: (inout TextStyle) -> Void) -> Bool {
        guard supports(c.type) else { return false }
        var s = c.textStyle ?? TextStyle()
        change(&s)
        s = s.normalized
        let new: TextStyle? = s.isEmpty ? nil : s
        guard new != c.textStyle else { return false }
        c.textStyle = new
        return true
    }

    @discardableResult
    public static func clear(_ c: inout Clip) -> Bool {
        guard c.textStyle != nil else { return false }
        c.textStyle = nil
        return true
    }

    /// 文字のアニメーションを設定する(kind が none なら外す)。
    @discardableResult
    public static func setAnim(_ c: inout Clip, kind: TextAnimKind, duration: Double? = nil, speed: Double? = nil) -> Bool {
        guard c.type == .text else { return false }
        let new: TextAnim?
        if kind == .none { new = nil } else {
            var a = c.textAnim ?? TextAnim(kind: kind.rawValue)
            a.kind = kind.rawValue
            if let d = duration { a.duration = TextAnim.clampDuration(d) }
            // 速さは既定の値なら書かない(任意項目)
            if let v = speed { let s = TextAnim.clampSpeed(v); a.speed = s == TextAnim.defaultSpeed ? nil : s }
            new = a
        }
        guard new != c.textAnim else { return false }
        c.textAnim = new
        return true
    }
}

// MARK: - 文字のアニメーション

public enum TextAnimKind: String, CaseIterable, Sendable {
    case none, typewriter, pop, shake, scrollUp, scrollLeft, fadeIn

    public var label: String {
        switch self {
        case .none: return "なし"
        case .typewriter: return "タイプライター"
        case .pop: return "ポップ"
        case .shake: return "シェイク"
        case .fadeIn: return "フェードイン"
        case .scrollUp: return "スクロール（上へ）"
        case .scrollLeft: return "スクロール（左へ）"
        }
    }

    /// クレジット(上へ流す)・テロップ帯(左へ流す)。長さではなく速さで動き、クリップの終わりまで流れ続ける。
    public var isScroll: Bool { self == .scrollUp || self == .scrollLeft }
}

/// 文字クリップの頭から `duration` 秒かけて動くアニメーション(スクロールは速さで、クリップの終わりまで)。知らない種類は文字列のまま残し、描くときは何もしない。
public struct TextAnim: Codable, Equatable, Sendable {
    public var kind: String
    public var duration: Double?
    /// スクロールの速さ(画面の高さ・幅に対する割合 / 秒)。無ければ既定値。スクロールの種類だけ使う。
    public var speed: Double?
    public var extra: [String: JSONValue] = [:]
    static let knownKeys: Set<String> = ["kind", "duration", "speed"]
    public static let defaultDuration = 1.0
    public static let defaultSpeed = 0.1

    public init(kind: String, duration: Double? = nil, speed: Double? = nil) { self.kind = kind; self.duration = duration; self.speed = speed }

    public init(from decoder: Decoder) throws {
        let l = Lenient(c: try decoder.container(keyedBy: AnyKey.self), known: Self.knownKeys)
        kind = l.string("kind") ?? "none"
        duration = l.double("duration")
        speed = l.double("speed")
        extra = l.extra()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        for (k, v) in extra { try c.encode(v, forKey: AnyKey(k)) }
        try c.encode(kind, forKey: AnyKey("kind"))
        try c.encodeIfPresent(duration, forKey: AnyKey("duration"))
        try c.encodeIfPresent(speed, forKey: AnyKey("speed"))
    }

    public var known: TextAnimKind? { TextAnimKind(rawValue: kind) }
    public var durationOrDefault: Double { Self.clampDuration(duration ?? Self.defaultDuration) }
    public var speedOrDefault: Double { Self.clampSpeed(speed ?? Self.defaultSpeed) }
    public static func clampDuration(_ d: Double) -> Double { TextStyle.clamp(d, 0.1...30, defaultDuration) }
    public static func clampSpeed(_ v: Double) -> Double { TextStyle.clamp(v, 0.01...1, defaultSpeed) }
}

/// ある時刻でのアニメーションの状態。
public struct TextAnimState: Equatable, Sendable {
    /// 見せる文字数(改行を除く)。nil = 全部。
    public var visible: Int?
    public var scale = 1.0
    /// 文字全体の濃さ(フェードイン)。1 = そのまま。
    public var alpha = 1.0
    public var dx = 0.0
    public var dy = 0.0
    /// スクロールによる位置のずれ(キャンバスの幅・高さに対する割合。基準の位置へ足す)。
    public var shiftX = 0.0
    public var shiftY = 0.0
    /// まだ動いている(描画のキャッシュを使えない)。
    public var active = false
}

/// アニメーションの計算(画面にも描画にも依存しない)。`rel` はクリップの頭からの秒。
public enum TextAnimMath {
    /// タイプライター: 時間に比例して文字を出す。`duration` 秒で全部。
    public static func visibleCount(total: Int, rel: Double, duration: Double) -> Int {
        guard total > 0 else { return 0 }
        guard duration > 0, rel.isFinite else { return total }
        let u = min(max(rel / duration, 0), 1)
        return min(total, Int((Double(total) * u).rounded(.down)))
    }

    /// ポップ: 0.6 倍から始まり、60% の時点で 1.1 倍まで膨らみ(ゆっくり止まる)、1 倍に落ち着く。
    public static func popScale(rel: Double, duration: Double) -> Double {
        guard duration > 0, rel.isFinite else { return 1 }
        let u = min(max(rel / duration, 0), 1)
        func easeOut(_ x: Double) -> Double { 1 - pow(1 - x, 3) }
        func easeInOut(_ x: Double) -> Double { x < 0.5 ? 2 * x * x : 1 - pow(-2 * x + 2, 2) / 2 }
        if u < 0.6 { return 0.6 + 0.5 * easeOut(u / 0.6) }
        return 1.1 - 0.1 * easeInOut((u - 0.6) / 0.4)
    }

    /// シェイク: 30 コマ/秒の刻みごとに決まった(乱数ではない)ずれ。振れ幅は終わりに向けて 0 になる。
    public static func shakeOffset(rel: Double, duration: Double, amplitude: Double) -> (dx: Double, dy: Double) {
        guard duration > 0, rel.isFinite, rel >= 0, rel < duration else { return (0, 0) }
        let n = (rel * 30).rounded(.down)
        let amp = amplitude * max(0, 1 - n / 30 / duration)  // 振れ幅も刻みごと(同じ刻みは同じ絵)
        let step = UInt64(bitPattern: Int64(n))
        func unit(_ salt: UInt64) -> Double {
            var z = (step &+ 0x9E37_79B9_7F4A_7C15) &* (salt | 1)
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            return Double(z % 20_001) / 10_000 - 1  // −1…1
        }
        return (amp * unit(0x1234_5671), amp * unit(0x7654_3211))
    }

    public static func state(_ a: TextAnim, text: String, rel: Double, size: Double) -> TextAnimState {
        guard let kind = a.known, kind != .none else { return TextAnimState() }
        var s = TextAnimState()
        if kind.isScroll {
            // 基準の位置(0.5 ぶん下・右の外)から、速さで流れる。長さは使わず、クリップの終わりまで続く
            guard rel.isFinite, rel >= 0 else { return s }
            s.active = true
            let offset = 0.5 - a.speedOrDefault * rel
            if kind == .scrollUp { s.shiftY = offset } else { s.shiftX = offset }
            return s
        }
        let d = a.durationOrDefault
        guard rel < d else { return s }
        s.active = true
        switch kind {
        case .typewriter:
            s.visible = visibleCount(total: text.filter { $0 != "\n" }.count, rel: rel, duration: d)
        case .pop:
            s.scale = popScale(rel: rel, duration: d)
        case .fadeIn:
            s.alpha = min(max(rel / d, 0), 1)
        case .shake:
            let o = shakeOffset(rel: rel, duration: d, amplitude: size * 0.08)
            s.dx = o.dx; s.dy = o.dy
        case .none, .scrollUp, .scrollLeft:
            s.active = false
        }
        return s
    }
}

// MARK: - 保存したスタイル

/// 「見た目」: 色・縁の色・書体と、文字の装飾。大きさと文字そのものは含まない。
public struct TextLook: Codable, Equatable, Sendable {
    public var color: String?
    public var outline: String?
    public var font: String?
    public var style: TextStyle?
    /// 吹き出し(B-2)。無いときは吹き出しを外す(装飾と同じく丸ごと入れ替え)。
    public var bubble: Bubble?
    /// 登場アニメーション(フェードイン・タイプライター・ポップなど)。無いときは今のアニメーションを変えない。
    public var anim: TextAnim?
    public init(color: String? = nil, outline: String? = nil, font: String? = nil, style: TextStyle? = nil, bubble: Bubble? = nil, anim: TextAnim? = nil) {
        self.color = color; self.outline = outline; self.font = font; self.style = style; self.bubble = bubble; self.anim = anim
    }

    /// クリップの、いまの見た目。
    public init(of c: Clip) {
        self.init(color: c.color, outline: c.outline, font: c.font, style: c.textStyle, bubble: c.bubble, anim: c.textAnim)
    }

    /// クリップへ当てる(色・縁は上書き、書体は指定があるときだけ、装飾は丸ごと入れ替え)。変えたときだけ true。
    @discardableResult
    public func apply(to c: inout Clip) -> Bool {
        guard c.type == .text else { return false }
        let before = c
        c.color = color; c.outline = outline
        if let f = font { c.font = f }
        let s = style?.normalized
        c.textStyle = (s?.isEmpty ?? true) ? nil : s
        c.bubble = bubble?.normalized
        if let a = anim { c.textAnim = a }
        return c != before
    }
}

public struct SavedTextStyle: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var look: TextLook
    public init(id: String, name: String, look: TextLook) { self.id = id; self.name = name; self.look = look }
    public var isBuiltin: Bool { id.hasPrefix(TextStyleLibrary.builtinPrefix) }
}

/// アプリ全体の文字スタイル(組み込み 16 つ(うちアニメ付きタイトル 7 つ) + 保存したもの)。保存先は UserDefaults(JSON)。壊れていたら空として扱う。
public enum TextStyleLibrary {
    public static let defaultsKey = "textStyles.v1"
    public static let builtinPrefix = "builtin."
    public static let maxUserStyles = 100

    public static let builtins: [SavedTextStyle] = [
        SavedTextStyle(id: "builtin.standard", name: "標準", look: TextLook()),
        SavedTextStyle(id: "builtin.classic", name: "ゆっくり風", look: TextLook(
            color: "#ffffff", outline: "#000000", style: style { $0.shadow = .init(color: "#000000", dx: 4, dy: 4, blur: 4, opacity: 0.8) })),
        SavedTextStyle(id: "builtin.news", name: "ニュース帯", look: TextLook(
            color: "#ffffff", outline: "#0d2a6b", style: style { $0.box = .init(color: "#0d2a6b", opacity: 0.92, paddingX: 48, paddingY: 14, cornerRadius: 0) })),
        SavedTextStyle(id: "builtin.heading", name: "見出し", look: TextLook(
            color: "#ffffff", outline: "#3e2723", style: style {
                $0.gradient = .init(color1: "#fff176", color2: "#ff7043", angle: 90)
                $0.shadow = .init(color: "#000000", dx: 3, dy: 5, blur: 6, opacity: 0.6)
            })),
        SavedTextStyle(id: "builtin.bubble", name: "吹き出し風", look: TextLook(
            color: "#222222", outline: "#ffffff", style: nil,
            bubble: Bubble(shape: "rounded", fill: "#ffffff", stroke: "#222222", strokeWidth: 4, tail: true, tailX: 0.5, tailY: 0.92))),
        SavedTextStyle(id: "builtin.warning", name: "注意", look: TextLook(
            color: "#e53935", outline: "#ffffff", style: style {
                $0.bold = true
                $0.shadow = .init(color: "#000000", dx: 3, dy: 3, blur: 5, opacity: 0.7)
            })),
        SavedTextStyle(id: "builtin.fadein", name: "フェードイン", look: TextLook(anim: TextAnim(kind: TextAnimKind.fadeIn.rawValue, duration: 0.8))),
        SavedTextStyle(id: "builtin.typewriter", name: "タイプライター", look: TextLook(anim: TextAnim(kind: TextAnimKind.typewriter.rawValue, duration: 1.5))),
        SavedTextStyle(id: "builtin.pop", name: "ポップ", look: TextLook(anim: TextAnim(kind: TextAnimKind.pop.rawValue, duration: 0.5))),
    ] + animatedTitles

    /// アニメ付きタイトルのテンプレート(見た目 + 登場アニメーションの組)。id は `builtin.title.` で始まる。
    public static let titlePrefix = "builtin.title."
    public static let animatedTitles: [SavedTextStyle] = [
        SavedTextStyle(id: titlePrefix + "pop", name: "タイトル・ポップ", look: TextLook(
            color: "#ffffff", outline: "#3e2723", style: style {
                $0.gradient = .init(color1: "#fff176", color2: "#ff7043", angle: 90)
                $0.shadow = .init(color: "#000000", dx: 3, dy: 5, blur: 6, opacity: 0.6)
            }, anim: TextAnim(kind: TextAnimKind.pop.rawValue, duration: 0.5))),
        SavedTextStyle(id: titlePrefix + "typewriter", name: "タイトル・タイプライター", look: TextLook(
            color: "#ffffff", outline: "#0d2a6b", style: style { $0.box = .init(color: "#0d2a6b", opacity: 0.92, paddingX: 48, paddingY: 14, cornerRadius: 0) },
            anim: TextAnim(kind: TextAnimKind.typewriter.rawValue, duration: 1.5))),
        SavedTextStyle(id: titlePrefix + "fade", name: "タイトル・フェード", look: TextLook(
            color: "#ffffff", outline: "#000000", style: style { $0.shadow = .init(color: "#000000", dx: 2, dy: 3, blur: 8, opacity: 0.7) },
            anim: TextAnim(kind: TextAnimKind.fadeIn.rawValue, duration: 1.2))),
        SavedTextStyle(id: titlePrefix + "shake", name: "タイトル・シェイク", look: TextLook(
            color: "#e53935", outline: "#ffffff", style: style {
                $0.bold = true
                $0.shadow = .init(color: "#000000", dx: 3, dy: 3, blur: 5, opacity: 0.7)
            }, anim: TextAnim(kind: TextAnimKind.shake.rawValue, duration: 1.0))),
        SavedTextStyle(id: titlePrefix + "credits", name: "タイトル・エンドロール", look: TextLook(
            color: "#ffffff", outline: "#000000", style: style { $0.shadow = .init(color: "#000000", dx: 2, dy: 2, blur: 4, opacity: 0.8) },
            anim: TextAnim(kind: TextAnimKind.scrollUp.rawValue, speed: 0.08))),
        SavedTextStyle(id: titlePrefix + "ticker", name: "タイトル・ニュース速報", look: TextLook(
            color: "#ffffff", outline: "#8b0000", style: style { $0.box = .init(color: "#b71c1c", opacity: 0.92, paddingX: 40, paddingY: 12, cornerRadius: 0) },
            anim: TextAnim(kind: TextAnimKind.scrollLeft.rawValue, speed: 0.12))),
        SavedTextStyle(id: titlePrefix + "bubblepop", name: "タイトル・吹き出しポップ", look: TextLook(
            color: "#222222", outline: "#ffffff", style: nil,
            bubble: Bubble(shape: "rounded", fill: "#ffffff", stroke: "#222222", strokeWidth: 4, tail: true, tailX: 0.5, tailY: 0.92),
            anim: TextAnim(kind: TextAnimKind.pop.rawValue, duration: 0.5))),
    ]

    private static func style(_ f: (inout TextStyle) -> Void) -> TextStyle {
        var s = TextStyle(); f(&s); return s.normalized
    }

    private struct Failable: Decodable {
        let value: SavedTextStyle?
        init(from decoder: Decoder) throws { value = try? SavedTextStyle(from: decoder) }
    }

    /// 保存したスタイルを読む。形が違う・壊れているものは捨てる(組み込みと同じ id・重複 id も捨てる)。
    public static func loadUser(from defaults: UserDefaults) -> [SavedTextStyle] {
        guard let data = defaults.data(forKey: defaultsKey), let list = try? JSONDecoder().decode([Failable].self, from: data) else { return [] }
        var seen = Set<String>()
        var out: [SavedTextStyle] = []
        for item in list.compactMap(\.value) where !item.id.isEmpty && !item.id.hasPrefix(builtinPrefix) && seen.insert(item.id).inserted {
            var s = item
            s.name = sanitizedName(s.name) ?? "スタイル"
            if let st = s.look.style?.normalized { s.look.style = st.isEmpty ? nil : st }
            out.append(s)
            if out.count >= maxUserStyles { break }
        }
        return out
    }

    public static func saveUser(_ list: [SavedTextStyle], to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    /// 名前を整える(前後の空白を除く、改行は空白に、40 文字まで)。空なら nil。
    public static func sanitizedName(_ s: String) -> String? {
        let t = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : String(t.prefix(40))
    }

    /// 組み込み + 保存したもの。
    public static func all(user: [SavedTextStyle]) -> [SavedTextStyle] { builtins + user }

    public static func find(_ id: String, user: [SavedTextStyle]) -> SavedTextStyle? { all(user: user).first { $0.id == id } }

    /// 末尾に足す(同じ名前があっても足せる)。足した id を返す。名前が空・上限なら nil。
    @discardableResult
    public static func add(_ list: inout [SavedTextStyle], name: String, look: TextLook) -> String? {
        guard let n = sanitizedName(name), list.count < maxUserStyles else { return nil }
        let id = "user." + newId()
        list.append(SavedTextStyle(id: id, name: n, look: look))
        return id
    }

    /// 名前を変える(組み込みは変えられない)。変えたときだけ true。
    @discardableResult
    public static func rename(_ list: inout [SavedTextStyle], id: String, to name: String) -> Bool {
        guard let n = sanitizedName(name), let i = list.firstIndex(where: { $0.id == id }), list[i].name != n else { return false }
        list[i].name = n
        return true
    }

    @discardableResult
    public static func delete(_ list: inout [SavedTextStyle], id: String) -> Bool {
        guard let i = list.firstIndex(where: { $0.id == id }) else { return false }
        list.remove(at: i)
        return true
    }
}

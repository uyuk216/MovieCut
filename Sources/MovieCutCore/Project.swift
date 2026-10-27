import Foundation

public let defaultAquesTalkCommand = "/Applications/AquesTalkPlayer.app/Contents/MacOS/AquesTalkPlayer -P {voice} -T {text} -W {out}"
public let defaultFonts = ["Hiragino Maru Gothic ProN", "Hiragino Sans", "Hiragino Mincho ProN", "YuGothic", "YuMincho", "Klee", "Toppan Bunkyu Gothic"]

// MARK: - Project

public struct Project: Codable, Equatable {
    public var width: Int = 1920
    public var height: Int = 1080
    /// 1 秒あたりのコマ数(1〜240。29.97 のような小数も可)。ファイルでは整数なら整数、そうでなければ小数で書く。
    public var fps: Double = 60
    /// 正確な分数のレート(時刻とコマの変換はこれを使う)。
    public var frameRate: FrameRate { FrameRate.from(fps) }
    public var bg: String = "#000000"
    public var codec: String = "h264"
    public var voicevoxUrl: String = "http://127.0.0.1:50021"
    public var aquestalkCommand: String = defaultAquesTalkCommand
    public var characters: [Character] = Character.defaults()
    public var tracks: [Track] = Track.defaultLayers()
    /// タイムライン上のマーカー(M7)。空のときはファイルに書かない。
    public var markers: [Marker] = []
    /// 知らないキー(保持して書き戻す)
    public var extra: [String: JSONValue] = [:]

    static let knownKeys: Set<String> = ["width", "height", "fps", "bg", "codec", "voicevoxUrl", "aquestalkCommand", "characters", "tracks", "markers"]

    public init() {}

    /// Electron 版 newProject() と同じ。
    public static func new() -> Project { Project() }

    public init(from decoder: Decoder) throws {
        let l = Lenient(c: try decoder.container(keyedBy: AnyKey.self), known: Self.knownKeys)
        width = l.int("width") ?? width
        height = l.int("height") ?? height
        fps = Self.decodeFps(l)
        bg = l.string("bg") ?? bg
        codec = l.string("codec") ?? codec
        voicevoxUrl = l.string("voicevoxUrl") ?? voicevoxUrl
        aquestalkCommand = l.string("aquestalkCommand") ?? aquestalkCommand
        // Electron 版: 空配列・欠落のときは既定に戻す
        if let v: [Character] = l.value("characters"), !v.isEmpty { characters = v }
        if let v: [Track] = l.value("tracks"), !v.isEmpty { tracks = v }
        markers = l.value("markers") ?? []
        extra = l.extra()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        for (k, v) in extra { try c.encode(v, forKey: AnyKey(k)) }
        try c.encode(width, forKey: AnyKey("width"))
        try c.encode(height, forKey: AnyKey("height"))
        // 整数のレートは整数で書く(ファイルを読みやすく保つ)
        let f = FrameRate.canonical(fps)
        if f == f.rounded() { try c.encode(Int(f), forKey: AnyKey("fps")) } else { try c.encode(f, forKey: AnyKey("fps")) }
        try c.encode(bg, forKey: AnyKey("bg"))
        try c.encode(codec, forKey: AnyKey("codec"))
        try c.encode(voicevoxUrl, forKey: AnyKey("voicevoxUrl"))
        try c.encode(aquestalkCommand, forKey: AnyKey("aquestalkCommand"))
        try c.encode(characters, forKey: AnyKey("characters"))
        try c.encode(tracks, forKey: AnyKey("tracks"))
        if !markers.isEmpty { try c.encode(markers, forKey: AnyKey("markers")) }
    }

    /// fps を Int / Double / "29.97" / "30000/1001" のどれからでも読む。読めない・欠けているときは 60、範囲外は 1〜240 に収める。
    static func decodeFps(_ l: Lenient) -> Double {
        if let d: Double = l.value("fps") { return FrameRate.clamp(d) }
        if let s: String = l.value("fps"), let v = FrameRateInput.rawValue(s) { return FrameRate.clamp(v) }
        return FrameRate.defaultValue
    }

    public var allClips: [Clip] { tracks.flatMap { $0.clips } }
}

// MARK: - Character

public struct Character: Codable, Equatable, Identifiable {
    public var id: String = newId()
    public var name: String = ""
    public var engine: String = "voicevox"   // "voicevox" | "aquestalk"
    public var speaker: Int? = nil
    public var voice: String? = nil
    public var speed: Double? = nil
    public var pitch: Double? = nil
    public var intonation: Double? = nil
    public var color: String = "#4f8cff"
    public var imgClosed: String? = nil
    public var imgOpen: String? = nil
    public var x: Double = 0.5
    public var y: Double = 0.72
    public var scale: Double = 1
    public var flip: Bool = false
    public var alwaysShow: Bool = true
    public var extra: [String: JSONValue] = [:]

    static let knownKeys: Set<String> = ["id", "name", "engine", "speaker", "voice", "speed", "pitch", "intonation", "color", "imgClosed", "imgOpen", "x", "y", "scale", "flip", "alwaysShow"]

    public init() {}

    /// Electron 版 charDefaults(i)
    static func charDefaults(_ i: Int) -> (x: Double, flip: Bool) {
        ([0.18, 0.82, 0.82].indices.contains(i) ? [0.18, 0.82, 0.82][i] : 0.5, i == 0)
    }

    public static func defaults() -> [Character] {
        func make(_ i: Int, _ configure: (inout Character) -> Void) -> Character {
            var c = Character()
            let d = charDefaults(i)
            c.x = d.x; c.flip = d.flip
            configure(&c)
            return c
        }
        return [
            make(0) { $0.name = "霊夢"; $0.engine = "aquestalk"; $0.voice = "れいむ"; $0.speed = 100; $0.color = "#e8384f" },
            make(1) { $0.name = "魔理沙"; $0.engine = "aquestalk"; $0.voice = "まりさ"; $0.speed = 100; $0.color = "#f2c53d" },
            make(2) { $0.name = "ずんだもん"; $0.engine = "voicevox"; $0.speaker = 3; $0.speed = 1; $0.pitch = 0; $0.intonation = 1; $0.color = "#7ac943" },
        ]
    }

    public init(from decoder: Decoder) throws {
        let l = Lenient(c: try decoder.container(keyedBy: AnyKey.self), known: Self.knownKeys)
        id = l.string("id") ?? id
        name = l.string("name") ?? name
        engine = l.string("engine") ?? engine
        speaker = l.int("speaker")
        voice = l.string("voice")
        speed = l.double("speed")
        pitch = l.double("pitch")
        intonation = l.double("intonation")
        color = l.string("color") ?? color
        imgClosed = l.string("imgClosed")
        imgOpen = l.string("imgOpen")
        x = l.double("x") ?? x
        y = l.double("y") ?? y
        scale = l.double("scale") ?? scale
        flip = l.bool("flip") ?? flip
        alwaysShow = l.bool("alwaysShow") ?? alwaysShow
        extra = l.extra()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        for (k, v) in extra { try c.encode(v, forKey: AnyKey(k)) }
        try c.encode(id, forKey: AnyKey("id"))
        try c.encode(name, forKey: AnyKey("name"))
        try c.encode(engine, forKey: AnyKey("engine"))
        try c.encodeIfPresent(speaker, forKey: AnyKey("speaker"))
        try c.encodeIfPresent(voice, forKey: AnyKey("voice"))
        try c.encodeIfPresent(speed, forKey: AnyKey("speed"))
        try c.encodeIfPresent(pitch, forKey: AnyKey("pitch"))
        try c.encodeIfPresent(intonation, forKey: AnyKey("intonation"))
        try c.encode(color, forKey: AnyKey("color"))
        // Electron 版は未設定を null で書く
        if let s = imgClosed { try c.encode(s, forKey: AnyKey("imgClosed")) } else { try c.encodeNil(forKey: AnyKey("imgClosed")) }
        if let s = imgOpen { try c.encode(s, forKey: AnyKey("imgOpen")) } else { try c.encodeNil(forKey: AnyKey("imgOpen")) }
        try c.encode(x, forKey: AnyKey("x"))
        try c.encode(y, forKey: AnyKey("y"))
        try c.encode(scale, forKey: AnyKey("scale"))
        try c.encode(flip, forKey: AnyKey("flip"))
        try c.encode(alwaysShow, forKey: AnyKey("alwaysShow"))
    }
}

// MARK: - Track

public struct Track: Codable, Equatable, Identifiable {
    public var id: String = newId()
    public var name: String = ""
    public var hidden: Bool? = nil
    public var muted: Bool? = nil
    public var clips: [Clip] = []
    public var extra: [String: JSONValue] = [:]

    static let knownKeys: Set<String> = ["id", "name", "hidden", "muted", "clips"]

    public init() {}
    public init(name: String) { self.name = name }

    public static func defaultLayers() -> [Track] { (1...5).map { Track(name: "レイヤー\($0)") } }

    public var isHidden: Bool { hidden ?? false }
    public var isMuted: Bool { muted ?? false }

    public init(from decoder: Decoder) throws {
        let l = Lenient(c: try decoder.container(keyedBy: AnyKey.self), known: Self.knownKeys)
        id = l.string("id") ?? id
        name = l.string("name") ?? name
        hidden = l.bool("hidden")
        muted = l.bool("muted")
        clips = l.value("clips") ?? []
        extra = l.extra()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        for (k, v) in extra { try c.encode(v, forKey: AnyKey(k)) }
        try c.encode(id, forKey: AnyKey("id"))
        try c.encode(name, forKey: AnyKey("name"))
        try c.encodeIfPresent(hidden, forKey: AnyKey("hidden"))
        try c.encodeIfPresent(muted, forKey: AnyKey("muted"))
        try c.encode(clips, forKey: AnyKey("clips"))
    }
}

// MARK: - Clip

/// 知らない type 文字列も `.unknown` で受けて、元の文字列のまま書き戻す。
public struct ClipType: RawRepresentable, Codable, Hashable, Sendable {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let image = ClipType(rawValue: "image")
    public static let video = ClipType(rawValue: "video")
    public static let audio = ClipType(rawValue: "audio")
    public static let text = ClipType(rawValue: "text")
    public static let voice = ClipType(rawValue: "voice")
    public static let blur = ClipType(rawValue: "blur")
    public static let known: [ClipType] = [.image, .video, .audio, .text, .voice, .blur]
    public var isKnown: Bool { Self.known.contains(self) }

    public init(from decoder: Decoder) throws {
        rawValue = (try? decoder.singleValueContainer().decode(String.self)) ?? "unknown"
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

/// クリップ。種類ごとの項目は optional で、Electron 版と同じく使う場所で既定値を当てる(下の *OrDefault)。
public struct Clip: Codable, Equatable, Identifiable {
    public var id: String = newId()
    public var type: ClipType = .image
    public var start: Double = 0
    public var duration: Double = 0
    public var offset: Double = 0
    public var src: String? = nil
    public var srcDuration: Double? = nil
    public var x: Double? = nil
    public var y: Double? = nil
    public var scale: Double? = nil
    public var opacity: Double? = nil
    public var volume: Double? = nil
    public var blur: Double? = nil
    // text / voice
    public var text: String? = nil
    public var fontSize: Double? = nil
    public var color: String? = nil
    public var outline: String? = nil
    public var font: String? = nil
    // voice
    public var charId: String? = nil
    public var subtitle: Bool? = nil
    // blur region
    public var w: Double? = nil
    public var h: Double? = nil
    public var strength: Double? = nil
    public var shape: String? = nil
    // 変形(画像・動画・文字)。どれも未設定が既定(0 度・反転なし・切り抜きなし)。ファイルには既定でないときだけ書く。
    public var rotation: Double? = nil
    public var flipH: Bool? = nil
    public var flipV: Bool? = nil
    public var crop: Crop? = nil
    /// キーフレーム: 項目名("x" "y" "scale" "rotation" "opacity" "blur" / ぼかし範囲は "x" "y" "w" "h" "strength")→ キー列。
    /// 空のときはファイルに書かない。時刻はクリップの頭からの秒。
    public var keyframes: [String: [Keyframe]] = [:]
    /// 映像のトランジション(画像・動画・文字)。頭(in)と終わり(out)。無いときはファイルに書かない。
    public var transitionIn: Transition? = nil
    public var transitionOut: Transition? = nil
    /// 映像のエフェクト(画像・動画・文字)。リストの順にかかる。無いときはファイルに書かない。
    public var effects: [Effect] = []
    /// 音声のフェード(音声・ボイス・動画)。秒。未設定 = なし。`fadeCurve` は "linear"(既定)/ "equalPower"。
    public var fadeIn: Double? = nil
    public var fadeOut: Double? = nil
    public var fadeCurve: String? = nil
    public var extra: [String: JSONValue] = [:]

    static let knownKeys: Set<String> = ["id", "type", "start", "duration", "offset", "src", "srcDuration", "x", "y", "scale", "opacity", "volume", "blur", "text", "fontSize", "color", "outline", "font", "charId", "subtitle", "w", "h", "strength", "shape", "rotation", "flipH", "flipV", "crop", "keyframes", "transitionIn", "transitionOut", "effects", "fadeIn", "fadeOut", "fadeCurve"]

    public init() {}

    // Electron 版 draw() / プロパティ欄の `?? 既定` と同じ値
    public var xOrDefault: Double { x ?? 0.5 }
    public var yOrDefault: Double { y ?? 0.5 }
    public var scaleOrDefault: Double { scale ?? 1 }
    public var opacityOrDefault: Double { opacity ?? 1 }
    public var volumeOrDefault: Double { volume ?? 1 }
    public var blurOrDefault: Double { blur ?? 0 }
    public var wOrDefault: Double { w ?? 0.3 }
    public var hOrDefault: Double { h ?? 0.3 }
    public var strengthOrDefault: Double { strength ?? 24 }
    public var shapeOrDefault: String { shape ?? "rect" }
    public var fontOrDefault: String { font ?? defaultFonts[0] }
    public var colorOrDefault: String { color ?? "#ffffff" }
    public var outlineOrDefault: String { outline ?? "#000000" }
    /// text は 80、voice(字幕)は 64
    public var fontSizeOrDefault: Double { fontSize ?? (type == .voice ? 64 : 80) }
    public var subtitleOrDefault: Bool { subtitle ?? false }
    public var rotationOrDefault: Double { rotation ?? 0 }
    public var flipHOrDefault: Bool { flipH ?? false }
    public var flipVOrDefault: Bool { flipV ?? false }
    public var cropOrDefault: Crop { crop ?? Crop() }
    /// キーが 1 つでもあるか(描画の速い道の判定)。
    public var hasKeyframes: Bool { !keyframes.isEmpty }
    /// トランジションが 1 つでもあるか(描画の速い道の判定)。
    public var hasTransition: Bool { transitionIn != nil || transitionOut != nil }
    public var fadeInOrDefault: Double { max(0, fadeIn ?? 0) }
    public var fadeOutOrDefault: Double { max(0, fadeOut ?? 0) }
    public var fadeIsEqualPower: Bool { fadeCurve == "equalPower" }
    public var hasAudioFade: Bool { fadeInOrDefault > 0 || fadeOutOrDefault > 0 }

    /// 項目名で読む、いまの設定値(キーを見ない)。未設定は既定値。
    public func staticValue(of key: String) -> Double {
        switch key {
        case "x": return xOrDefault
        case "y": return yOrDefault
        case "scale": return scaleOrDefault
        case "opacity": return opacityOrDefault
        case "rotation": return rotationOrDefault
        case "blur": return blurOrDefault
        case "w": return wOrDefault
        case "h": return hOrDefault
        case "strength": return strengthOrDefault
        default:
            if let (i, p) = EffectKey.parse(key), effects.indices.contains(i) { return effects[i].value(p) }
            return 0
        }
    }

    /// 項目名で設定値を書く(rotation = 0 は未設定に戻す)。範囲は呼び出し側で整える。
    public mutating func setStaticValue(_ v: Double, of key: String) {
        switch key {
        case "x": x = v
        case "y": y = v
        case "scale": scale = v
        case "opacity": opacity = v
        case "rotation": rotation = v == 0 ? nil : v
        case "blur": blur = v
        case "w": w = v
        case "h": h = v
        case "strength": strength = v
        default:
            if let (i, p) = EffectKey.parse(key), effects.indices.contains(i) { effects[i].params[p] = v }
        }
    }

    /// 時刻 t(プロジェクトの時刻)での、項目の値。
    public func value(of key: String, atProjectTime t: Double) -> Double {
        Animation.value(of: key, in: self, at: t - start)
    }

    public init(from decoder: Decoder) throws {
        let l = Lenient(c: try decoder.container(keyedBy: AnyKey.self), known: Self.knownKeys)
        id = l.string("id") ?? id
        type = l.value("type") ?? .image
        start = l.double("start") ?? 0
        duration = l.double("duration") ?? 0
        offset = l.double("offset") ?? 0
        src = l.string("src")
        srcDuration = l.double("srcDuration")
        x = l.double("x"); y = l.double("y"); scale = l.double("scale")
        opacity = l.double("opacity"); volume = l.double("volume"); blur = l.double("blur")
        text = l.string("text"); fontSize = l.double("fontSize")
        color = l.string("color"); outline = l.string("outline"); font = l.string("font")
        charId = l.string("charId"); subtitle = l.bool("subtitle")
        w = l.double("w"); h = l.double("h"); strength = l.double("strength"); shape = l.string("shape")
        rotation = l.double("rotation"); flipH = l.bool("flipH"); flipV = l.bool("flipV")
        crop = l.value("crop")
        fadeIn = l.double("fadeIn"); fadeOut = l.double("fadeOut"); fadeCurve = l.string("fadeCurve")
        extra = l.extra()
        // 読めなかったトランジションも捨てずに、そのまま書き戻す
        for (key, set) in [("transitionIn", \Clip.transitionIn), ("transitionOut", \Clip.transitionOut)] as [(String, WritableKeyPath<Clip, Transition?>)] {
            if let raw: JSONValue = l.value(key) {
                if let tr: Transition = l.value(key) { self[keyPath: set] = tr } else { extra[key] = raw }
            }
        }
        // 読めなかったエフェクトの列も捨てずに、そのまま書き戻す
        if let raw: JSONValue = l.value("effects") {
            if let fx: [Effect] = l.value("effects") { effects = fx } else { extra["effects"] = raw }
        }
        // 読めなかったキーフレームは捨てずに、そのまま書き戻す(extra に回す)
        if let raw: JSONValue = l.value("keyframes") {
            if let ks: [String: [Keyframe]] = l.value("keyframes") {
                keyframes = ks.filter { !$0.value.isEmpty }
            } else {
                extra["keyframes"] = raw
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        for (k, v) in extra { try c.encode(v, forKey: AnyKey(k)) }
        try c.encode(id, forKey: AnyKey("id"))
        try c.encode(type, forKey: AnyKey("type"))
        try c.encode(start, forKey: AnyKey("start"))
        try c.encode(duration, forKey: AnyKey("duration"))
        try c.encode(offset, forKey: AnyKey("offset"))
        try c.encodeIfPresent(src, forKey: AnyKey("src"))
        try c.encodeIfPresent(srcDuration, forKey: AnyKey("srcDuration"))
        try c.encodeIfPresent(x, forKey: AnyKey("x"))
        try c.encodeIfPresent(y, forKey: AnyKey("y"))
        try c.encodeIfPresent(scale, forKey: AnyKey("scale"))
        try c.encodeIfPresent(opacity, forKey: AnyKey("opacity"))
        try c.encodeIfPresent(volume, forKey: AnyKey("volume"))
        try c.encodeIfPresent(blur, forKey: AnyKey("blur"))
        try c.encodeIfPresent(text, forKey: AnyKey("text"))
        try c.encodeIfPresent(fontSize, forKey: AnyKey("fontSize"))
        try c.encodeIfPresent(color, forKey: AnyKey("color"))
        try c.encodeIfPresent(outline, forKey: AnyKey("outline"))
        try c.encodeIfPresent(font, forKey: AnyKey("font"))
        try c.encodeIfPresent(charId, forKey: AnyKey("charId"))
        try c.encodeIfPresent(subtitle, forKey: AnyKey("subtitle"))
        try c.encodeIfPresent(w, forKey: AnyKey("w"))
        try c.encodeIfPresent(h, forKey: AnyKey("h"))
        try c.encodeIfPresent(strength, forKey: AnyKey("strength"))
        try c.encodeIfPresent(shape, forKey: AnyKey("shape"))
        try c.encodeIfPresent(rotation, forKey: AnyKey("rotation"))
        try c.encodeIfPresent(flipH, forKey: AnyKey("flipH"))
        try c.encodeIfPresent(flipV, forKey: AnyKey("flipV"))
        try c.encodeIfPresent(crop, forKey: AnyKey("crop"))
        let ks = keyframes.filter { !$0.value.isEmpty }
        if !ks.isEmpty { try c.encode(ks, forKey: AnyKey("keyframes")) }
        try c.encodeIfPresent(transitionIn, forKey: AnyKey("transitionIn"))
        try c.encodeIfPresent(transitionOut, forKey: AnyKey("transitionOut"))
        if !effects.isEmpty { try c.encode(effects, forKey: AnyKey("effects")) }
        try c.encodeIfPresent(fadeIn, forKey: AnyKey("fadeIn"))
        try c.encodeIfPresent(fadeOut, forKey: AnyKey("fadeOut"))
        try c.encodeIfPresent(fadeCurve, forKey: AnyKey("fadeCurve"))
    }
}

/// 切り抜き: 元の画像(文字は描いた文字の枠)の左・上・右・下を、それぞれ何割切り落とすか。各 0〜0.95、左+右 < 1、上+下 < 1。
public struct Crop: Codable, Equatable, Sendable {
    public var l: Double = 0
    public var t: Double = 0
    public var r: Double = 0
    public var b: Double = 0
    public static let maxEdge = 0.95
    public init() {}
    public init(l: Double, t: Double, r: Double, b: Double) { self.l = l; self.t = t; self.r = r; self.b = b }

    enum CodingKeys: String, CodingKey { case l, t, r, b }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = Crop(l: (try? c.decodeIfPresent(Double.self, forKey: .l)) ?? 0, t: (try? c.decodeIfPresent(Double.self, forKey: .t)) ?? 0,
                       r: (try? c.decodeIfPresent(Double.self, forKey: .r)) ?? 0, b: (try? c.decodeIfPresent(Double.self, forKey: .b)) ?? 0)
        self = raw.normalized
    }

    public var isEmpty: Bool { l == 0 && t == 0 && r == 0 && b == 0 }

    /// 範囲(各辺 0〜0.95、向かい合う辺の和が 1 未満)に収める。
    public var normalized: Crop {
        func e(_ v: Double) -> Double { v.isFinite ? min(max(v, 0), Crop.maxEdge) : 0 }
        var o = Crop(l: e(l), t: e(t), r: e(r), b: e(b))
        if o.l + o.r > 0.99 { let k = 0.99 / (o.l + o.r); o.l *= k; o.r *= k }
        if o.t + o.b > 0.99 { let k = 0.99 / (o.t + o.b); o.t *= k; o.b *= k }
        return o
    }

    /// 残る部分の大きさ(元に対する割合)。
    public var keptWidth: Double { 1 - l - r }
    public var keptHeight: Double { 1 - t - b }
}

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
    public var extra: [String: JSONValue] = [:]

    static let knownKeys: Set<String> = ["id", "type", "start", "duration", "offset", "src", "srcDuration", "x", "y", "scale", "opacity", "volume", "blur", "text", "fontSize", "color", "outline", "font", "charId", "subtitle", "w", "h", "strength", "shape"]

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
        extra = l.extra()
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
    }
}

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
    /// 書き出し範囲のイン点 / アウト点(秒)。設定したときだけファイルに書く。
    public var rangeIn: Double? = nil
    public var rangeOut: Double? = nil
    /// 知らないキー(保持して書き戻す)
    public var extra: [String: JSONValue] = [:]

    static let knownKeys: Set<String> = ["width", "height", "fps", "bg", "codec", "voicevoxUrl", "aquestalkCommand", "characters", "tracks", "markers", "rangeIn", "rangeOut"]

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
        rangeIn = l.value("rangeIn"); rangeOut = l.value("rangeOut")
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
        try c.encodeIfPresent(rangeIn, forKey: AnyKey("rangeIn"))
        try c.encodeIfPresent(rangeOut, forKey: AnyKey("rangeOut"))
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
    /// B-7: まばたき(目を閉じた画像)。未設定なら瞬きしない。
    public var imgBlink: String? = nil
    /// B-7: 表情名 → 画像(口を閉じた状態の代わりに使う)。セリフの `[表情名]` で切り替える。未設定・空は書かない。
    public var expressions: [String: String]? = nil
    /// B-7: 話している間に上下へ揺れる。オンのときだけ書く。
    public var bounce: Bool? = nil
    /// 話し手ごとの字幕の文字色(#rrggbb)。字幕の自動生成でこのキャラのセリフの字幕に使う。未設定 = 文字スタイルの色。
    public var subtitleColor: String? = nil
    public var x: Double = 0.5
    public var y: Double = 0.72
    public var scale: Double = 1
    public var flip: Bool = false
    public var alwaysShow: Bool = true
    public var extra: [String: JSONValue] = [:]

    static let knownKeys: Set<String> = ["id", "name", "engine", "speaker", "voice", "speed", "pitch", "intonation", "color", "imgClosed", "imgOpen", "imgBlink", "expressions", "bounce", "subtitleColor", "x", "y", "scale", "flip", "alwaysShow"]

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
        imgBlink = l.string("imgBlink")
        expressions = l.value("expressions").flatMap { (d: [String: String]) in d.isEmpty ? nil : d }
        bounce = l.bool("bounce")
        subtitleColor = l.string("subtitleColor").flatMap(SpeakerSubtitleColor.normalized)
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
        try c.encodeIfPresent(imgBlink, forKey: AnyKey("imgBlink"))
        if let e = expressions, !e.isEmpty { try c.encode(e, forKey: AnyKey("expressions")) }
        if bounce == true { try c.encode(true, forKey: AnyKey("bounce")) }
        if let s = subtitleColor { try c.encode(s, forKey: AnyKey("subtitleColor")) }
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
    /// A6: ロック(このレイヤーのクリップは編集・移動・削除できない)。オン以外は書かない。
    public var locked: Bool? = nil
    /// A6: ソロ(どれかのレイヤーがソロなら、ソロのレイヤーだけ音が出る)。オン以外は書かない。
    public var solo: Bool? = nil
    /// A6: 行の高さ("small" / "large")。標準は書かない。知らない値は標準として読む(値そのものは書き戻す)。
    public var height: String? = nil
    public var clips: [Clip] = []
    public var extra: [String: JSONValue] = [:]

    static let knownKeys: Set<String> = ["id", "name", "hidden", "muted", "locked", "solo", "height", "clips"]

    public init() {}
    public init(name: String) { self.name = name }

    public static func defaultLayers() -> [Track] { (1...5).map { Track(name: "レイヤー\($0)") } }

    public var isHidden: Bool { hidden ?? false }
    public var isMuted: Bool { muted ?? false }
    public var isLocked: Bool { locked ?? false }
    public var isSolo: Bool { solo ?? false }

    public init(from decoder: Decoder) throws {
        let l = Lenient(c: try decoder.container(keyedBy: AnyKey.self), known: Self.knownKeys)
        id = l.string("id") ?? id
        name = l.string("name") ?? name
        hidden = l.bool("hidden")
        muted = l.bool("muted")
        locked = l.bool("locked")
        solo = l.bool("solo")
        height = l.string("height")
        clips = l.value("clips") ?? []
        extra = l.extra()
        // 型が違って読めなかった A6 の項目は、捨てずにそのまま書き戻す
        for (key, ok) in [("locked", locked != nil), ("solo", solo != nil), ("height", height != nil)] where !ok {
            if let raw: JSONValue = l.value(key) { extra[key] = raw }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        for (k, v) in extra { try c.encode(v, forKey: AnyKey(k)) }
        try c.encode(id, forKey: AnyKey("id"))
        try c.encode(name, forKey: AnyKey("name"))
        try c.encodeIfPresent(hidden, forKey: AnyKey("hidden"))
        try c.encodeIfPresent(muted, forKey: AnyKey("muted"))
        try c.encodeIfPresent(locked, forKey: AnyKey("locked"))
        try c.encodeIfPresent(solo, forKey: AnyKey("solo"))
        try c.encodeIfPresent(height, forKey: AnyKey("height"))
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
    /// 調整レイヤー: 素材を持たず、それより下(前に描いた全部)の合成結果に、自分のエフェクトを一度かける。
    public static let adjustment = ClipType(rawValue: "adjustment")
    /// 音声ビジュアライザ: 素材を持たず、プロジェクトの合成音声の大きさで棒・波を描く(`Visualizer`)。
    public static let visualizer = ClipType(rawValue: "visualizer")
    /// 複合クリップ: 素材を持たず、中のレイヤー(`Clip.tracks`)を 1 つの映像・音声として扱う(`CompoundEditing`)。
    public static let compound = ClipType(rawValue: "compound")
    public static let known: [ClipType] = [.image, .video, .audio, .text, .voice, .blur, .adjustment, .visualizer, .compound]
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
    /// 速度(動画・音声)。0.25〜4、未設定 = 1(等倍)。タイムラインの長さ `duration` はそのままで、使う素材の長さ = duration × speed。
    public var speed: Double? = nil
    /// 逆再生(動画・音声)。未設定 = しない。
    public var reverse: Bool? = nil
    /// 速度を変えたときに音程を保つか(動画・音声)。未設定 = 保つ。false は再生速度どおりに音程も変わる。
    public var keepPitch: Bool? = nil
    /// フリーズフレーム(動画だけ)。素材の `offset` の1コマを止めて出す静止画のクリップ。音は無音。未設定 = しない。
    public var freeze: Bool? = nil
    /// 速度ランプ(動画・音声)。時刻と速度の点の列(`SpeedRamp`)。無いときはファイルに書かない。あるときは `speed` と `reverse` は使わない。
    public var speedRamp: [SpeedKey]? = nil
    /// フレームブレンド(動画だけ。速度が 1 未満のとき、隣り合う 2 コマを時間で混ぜる)。true のときだけ書く。
    public var frameBlend: Bool? = nil
    /// 音声エフェクト(EQ・コンプレッサー・リバーブ・ノーマライズ。音声・ボイス・動画)。無いときはファイルに書かない。
    public var audioFx: AudioFx? = nil
    /// 左右の振り分け(−1〜1、等パワー)。未設定 = 中央。
    public var pan: Double? = nil
    /// 文字(と字幕)の装飾: 影・箱・グラデーション・字間・行間・揃え・太字・斜体。無いときはファイルに書かない。
    public var textStyle: TextStyle? = nil
    /// 文字のアニメーション(タイプライター・ポップ・シェイク)。無いときはファイルに書かない。
    public var textAnim: TextAnim? = nil
    /// 吹き出し(文字クリップ)。無いときはファイルに書かない(B-2)。
    public var bubble: Bubble? = nil
    /// カウントダウン(文字クリップ)。無いときはファイルに書かない。`text` の後ろに残りの数を続ける。
    public var counter: TextCounter? = nil
    /// BGM の自動ダッキング(音声クリップ。声があるときに下げる)。無いときはファイルに書かない。
    public var duck: Duck? = nil
    /// 音声ビジュアライザの見た目(visualizer クリップ)。無いときは既定。ファイルには設定した項目だけ書く。
    public var visualizer: Visualizer? = nil
    /// 手ぶれ補正の強さ(映像クリップ。0〜1)。無い・0 のときはファイルに書かない(オフ)。
    public var stabilize: Double? = nil
    /// 複合クリップの中のレイヤー(type が compound のときだけ。無いときは書かない)。子の `start` は複合クリップの頭からの秒。
    public var tracks: [Track]? = nil
    public var extra: [String: JSONValue] = [:]

    static let knownKeys: Set<String> = ["id", "type", "start", "duration", "offset", "src", "srcDuration", "x", "y", "scale", "opacity", "volume", "blur", "text", "fontSize", "color", "outline", "font", "charId", "subtitle", "w", "h", "strength", "shape", "rotation", "flipH", "flipV", "crop", "keyframes", "transitionIn", "transitionOut", "effects", "fadeIn", "fadeOut", "fadeCurve", "speed", "reverse", "keepPitch", "freeze", "speedRamp", "frameBlend", "audioFx", "pan", "textStyle", "textAnim", "bubble", "counter", "duck", "visualizer", "stabilize", "tracks"]

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
        case "volume": return volumeOrDefault
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
        case "volume": volume = v
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
        speed = l.double("speed"); reverse = l.bool("reverse"); keepPitch = l.bool("keepPitch"); freeze = l.bool("freeze")
        speedRamp = l.value("speedRamp"); frameBlend = l.bool("frameBlend") == true ? true : nil
        pan = l.double("pan"); audioFx = l.value("audioFx")
        extra = l.extra()
        // 速度まわりの項目が読めない型だったら、捨てずにそのまま書き戻す
        for key in ["speed", "reverse", "keepPitch", "freeze", "speedRamp", "pan", "audioFx"] {
            guard let raw: JSONValue = l.value(key) else { continue }
            let typedOK: Bool
            switch key {
            case "speed": typedOK = speed != nil
            case "reverse": typedOK = reverse != nil
            case "keepPitch": typedOK = keepPitch != nil
            case "freeze": typedOK = freeze != nil
            case "speedRamp": typedOK = speedRamp != nil
            case "pan": typedOK = pan != nil
            default: typedOK = audioFx != nil
            }
            if !typedOK { extra[key] = raw }
        }
        // 読めなかった文字の装飾・アニメーションも、そのまま書き戻す
        if let raw: JSONValue = l.value("textStyle") {
            if let v: TextStyle = l.value("textStyle") { textStyle = v } else { extra["textStyle"] = raw }
        }
        if let raw: JSONValue = l.value("textAnim") {
            if let v: TextAnim = l.value("textAnim") { textAnim = v } else { extra["textAnim"] = raw }
        }
        if let raw: JSONValue = l.value("bubble") {
            if let v: Bubble = l.value("bubble") { bubble = v } else { extra["bubble"] = raw }
        }
        if let raw: JSONValue = l.value("counter") {
            if let v: TextCounter = l.value("counter") { counter = v } else { extra["counter"] = raw }
        }
        if let raw: JSONValue = l.value("duck") {
            if let v: Duck = l.value("duck") { duck = v } else { extra["duck"] = raw }
        }
        if let raw: JSONValue = l.value("stabilize") {
            if let v: Double = l.value("stabilize"), v.isFinite { stabilize = v > 0 ? min(v, 1) : nil } else { extra["stabilize"] = raw }
        }
        // 複合クリップの中身: 読めなければ捨てずにそのまま書き戻す
        if let raw: JSONValue = l.value("tracks") {
            if let v: [Track] = l.value("tracks") { tracks = v } else { extra["tracks"] = raw }
        }
        if let raw: JSONValue = l.value("visualizer") {
            if let v: Visualizer = l.value("visualizer") { visualizer = v } else { extra["visualizer"] = raw }
        }
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
        try c.encodeIfPresent(speed, forKey: AnyKey("speed"))
        try c.encodeIfPresent(reverse, forKey: AnyKey("reverse"))
        try c.encodeIfPresent(keepPitch, forKey: AnyKey("keepPitch"))
        try c.encodeIfPresent(freeze, forKey: AnyKey("freeze"))
        try c.encodeIfPresent(speedRamp, forKey: AnyKey("speedRamp"))
        try c.encodeIfPresent(frameBlend == true ? true : nil, forKey: AnyKey("frameBlend"))
        if let fx = audioFx, !fx.isEmpty { try c.encode(fx, forKey: AnyKey("audioFx")) }
        try c.encodeIfPresent(pan, forKey: AnyKey("pan"))
        try c.encodeIfPresent(textStyle, forKey: AnyKey("textStyle"))
        try c.encodeIfPresent(textAnim, forKey: AnyKey("textAnim"))
        try c.encodeIfPresent(bubble, forKey: AnyKey("bubble"))
        try c.encodeIfPresent(counter, forKey: AnyKey("counter"))
        try c.encodeIfPresent(duck, forKey: AnyKey("duck"))
        try c.encodeIfPresent(visualizer, forKey: AnyKey("visualizer"))
        if let t = tracks { try c.encode(t, forKey: AnyKey("tracks")) }
        if let s = stabilize, s > 0 { try c.encode(min(s, 1), forKey: AnyKey("stabilize")) }
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

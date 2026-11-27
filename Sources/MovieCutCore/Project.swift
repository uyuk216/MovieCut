import Foundation

public let defaultAquesTalkCommand = "/Applications/AquesTalkPlayer.app/Contents/MacOS/AquesTalkPlayer -P {voice} -T {text} -W {out}"
public let defaultFonts = ["Hiragino Maru Gothic ProN", "Hiragino Sans", "Hiragino Mincho ProN", "YuGothic", "YuMincho", "Klee", "Toppan Bunkyu Gothic"]

// MARK: - Project

/// 素材の目印: プロジェクトのフォルダからの相対パス(あれば)と、保存時のファイルサイズ(あれば)。
public struct MediaHint: Codable, Equatable {
    public var relative: String?
    public var size: Int64?
    public init(relative: String? = nil, size: Int64? = nil) { self.relative = relative; self.size = size }
}

public struct Project: Codable, Equatable {
    public var width: Int = 1920
    public var height: Int = 1080
    /// 1 秒あたりのコマ数(1〜240。29.97 のような小数も可)。ファイルでは整数なら整数、そうでなければ小数で書く。
    public var fps: Double = 60
    /// 正確な分数のレート(時刻とコマの変換はこれを使う)。
    public var frameRate: FrameRate { FrameRate.from(fps) }
    public var bg: String = "#000000"
    /// 背景を透明にする指定(`bg` が "transparent")。ProRes 4444・APNG・PNG は透明のまま書き出し、他の形式は黒になる。
    public static let transparentBackground = "transparent"
    public var hasTransparentBackground: Bool { bg.lowercased() == Self.transparentBackground }
    public var codec: String = "h264"
    public var voicevoxUrl: String = "http://127.0.0.1:50021"
    public var aquestalkCommand: String = defaultAquesTalkCommand
    public var characters: [Character] = Character.defaults()
    public var tracks: [Track] = Track.defaultLayers()
    /// タイムライン上のマーカー(M7)。空のときはファイルに書かない。
    public var markers: [Marker] = []
    /// レビューコメント(タイムコード付きの指摘)。空のときはファイルに書かない(使っていないプロジェクトは従来と完全一致)。定義は ReviewComments.swift。
    public var reviewComments: [ReviewComment] = []
    /// 書き出し範囲のイン点 / アウト点(秒)。設定したときだけファイルに書く。
    public var rangeIn: Double? = nil
    public var rangeOut: Double? = nil
    /// 素材の探し直し用の目印(キーは元の素材のパス)。パッケージ保存のときだけ入る。空のときは書かない。
    public var mediaHints: [String: MediaHint] = [:]
    /// 素材のフィンガープリント(キーは元の素材のパス)。再リンクで中身まで確かめるために使う。空のときは書かない(無いプロジェクトもそのまま読める)。
    public var mediaFingerprints: [String: MediaFingerprint] = [:]
    /// 外部プロキシの関連付け(キー=元の素材のパス、値=外部プロキシのパス)。プレビュー専用で、書き出しは常に原本。設定したときだけ書く(空なら従来のファイルと完全一致)。
    public var proxyLinks: [String: String] = [:]
    /// 取り込んだ素材のパス(順番どおり)。クリップを消しても残り、「未使用の素材」で整理する。空のときは書かない。
    public var mediaPool: [String] = []
    /// 素材のメタデータ(キーは素材の参照文字列 Clip.src / mediaPool の値)。キーワード・評価・メモ・ラベル色を持つ。
    /// 空のとき・中身がすべて空のときは書かない(使っていないプロジェクトは従来と完全一致)。定義は MediaMetadata.swift。
    public var mediaMetadata: [String: MediaMetadata] = [:]
    /// スマートコレクション(名前付きの絞り込み条件)。条件に合う素材を自動で集めるビューで、素材そのものは持たない。
    /// 空のときは書かない(使っていないプロジェクトは従来と完全一致)。
    public var smartCollections: [SmartCollection] = []
    /// トラックターゲット: 新しく足すクリップの行き先のレイヤー(`Track.id`)。1 つだけ。設定したときだけファイルに書く。
    public var targetTrackId: String? = nil
    /// マルチカメラのグループ(使ったときだけ。空のときはファイルに書かない)。切り替えた結果は普通のクリップで、ここには角度と同期のずれだけを持つ。
    public var multicams: [MulticamGroup] = []
    /// 立ち絵素材(キャラクターの声・字幕とは別の「素材」。タイムラインの立ち絵クリップ `Clip.tachieId` から参照する)。空のときはファイルに書かない。
    public var tachies: [Tachie] = []
    /// 読み辞書(表記 → 読み)。台本から声を作るとき、読み上げ文に適用する。使ったときだけ書く。
    public var readingDictionary: [ReadingEntry] = []
    /// シーン(W3-01): 名前付きの独立タイムライン(レイヤーとクリップの集合)。タイムライン上のシーケンスクリップ
    /// (`ClipType.scene` + `Clip.sceneId`)から参照され、複数箇所で再利用できる。空のときはファイルに書かない
    /// (シーンを使わない既存プロジェクトは従来と完全一致)。定義は `SceneDefinition` / 編集計算は `SceneEditing`(SceneNesting.swift)。
    public var scenes: [SceneDefinition] = []
    /// ボイス字幕の表示位置(画面の高さに対する割合)。未設定 = 従来の 0.88。設定したときだけ書く。
    public var subtitleY: Double? = nil
    /// 字幕位置の既定値(従来ハードコードされていた値)。
    public static let defaultSubtitleY = 0.88
    /// 実際に使う字幕位置。未設定・不正値なら既定、範囲外は 0〜1 に収める。
    public var subtitleYOrDefault: Double {
        guard let v = subtitleY, v.isFinite else { return Self.defaultSubtitleY }
        return min(max(v, 0), 1)
    }
    /// カメラ(W3-02 / 監査 #54)。未設定・既定値のときはファイルに書かず、描画も従来と完全一致する。
    public var camera: CameraSettings? = nil
    /// 左の台本欄の文字。空のときはファイルに書かない(古い版は知らないキーとして保持して書き戻す)。
    public var scriptText: String = ""
    /// ファイルから読んだ形式の版(`formatVersion`。無ければ 0)。書くときは `ProjectFormat.current` 以上を書く。`==` には入らない。
    public var sourceFormat = SourceFormatVersion()
    public var isNewerFormat: Bool { ProjectFormat.isNewer(sourceFormat.value) }
    /// 知らないキー(保持して書き戻す)
    public var extra: [String: JSONValue] = [:]

    static let knownKeys: Set<String> = ["formatVersion", "scriptText", "width", "height", "fps", "bg", "codec", "voicevoxUrl", "aquestalkCommand", "characters", "tracks", "markers", "reviewComments", "rangeIn", "rangeOut", "mediaHints", "mediaFingerprints", "proxyLinks", "mediaPool", "mediaMetadata", "smartCollections", "targetTrackId", "multicams", "tachies", "readingDictionary", "subtitleY", "scenes", "camera"]

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
        reviewComments = l.value("reviewComments") ?? []
        rangeIn = l.value("rangeIn"); rangeOut = l.value("rangeOut")
        mediaHints = l.value("mediaHints") ?? [:]
        mediaFingerprints = l.value("mediaFingerprints") ?? [:]
        proxyLinks = l.value("proxyLinks") ?? [:]
        mediaPool = l.value("mediaPool") ?? []
        mediaMetadata = (l.value("mediaMetadata") ?? [:]).filter { !$0.value.isEmpty }
        smartCollections = l.value("smartCollections") ?? []
        targetTrackId = l.string("targetTrackId")
        multicams = l.value("multicams") ?? []
        tachies = l.value("tachies") ?? []
        readingDictionary = l.value("readingDictionary") ?? []
        scenes = l.value("scenes") ?? []
        subtitleY = l.double("subtitleY")
        camera = l.value("camera")
        scriptText = l.string("scriptText") ?? ""
        sourceFormat = SourceFormatVersion(ProjectFormat.version(from: l.value("formatVersion") as JSONValue?))
        extra = l.extra()
        // 型が違って読めなかったときは、捨てずにそのまま書き戻す
        if targetTrackId == nil, let raw: JSONValue = l.value("targetTrackId") { extra["targetTrackId"] = raw }
        if multicams.isEmpty, let raw: JSONValue = l.value("multicams"), raw != .array([]) { extra["multicams"] = raw }
        if tachies.isEmpty, let raw: JSONValue = l.value("tachies"), raw != .array([]) { extra["tachies"] = raw }
        if camera == nil, let raw: JSONValue = l.value("camera") { extra["camera"] = raw }
        if mediaMetadata.isEmpty, let raw: JSONValue = l.value("mediaMetadata"), raw != .object([:]) { extra["mediaMetadata"] = raw }
        if smartCollections.isEmpty, let raw: JSONValue = l.value("smartCollections"), raw != .array([]) { extra["smartCollections"] = raw }
        if readingDictionary.isEmpty, let raw: JSONValue = l.value("readingDictionary"), raw != .array([]) { extra["readingDictionary"] = raw }
        if scenes.isEmpty, let raw: JSONValue = l.value("scenes"), raw != .array([]) { extra["scenes"] = raw }
        if reviewComments.isEmpty, let raw: JSONValue = l.value("reviewComments"), raw != .array([]) { extra["reviewComments"] = raw }
        if scriptText.isEmpty, let raw: JSONValue = l.value("scriptText"), raw != .string("") { extra["scriptText"] = raw }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        for (k, v) in extra { try c.encode(v, forKey: AnyKey(k)) }
        try c.encode(max(sourceFormat.value, ProjectFormat.current), forKey: AnyKey(ProjectFormat.key))
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
        if !reviewComments.isEmpty { try c.encode(reviewComments, forKey: AnyKey("reviewComments")) }
        try c.encodeIfPresent(rangeIn, forKey: AnyKey("rangeIn"))
        try c.encodeIfPresent(rangeOut, forKey: AnyKey("rangeOut"))
        if !mediaHints.isEmpty { try c.encode(mediaHints, forKey: AnyKey("mediaHints")) }
        if !mediaFingerprints.isEmpty { try c.encode(mediaFingerprints, forKey: AnyKey("mediaFingerprints")) }
        if !proxyLinks.isEmpty { try c.encode(proxyLinks, forKey: AnyKey("proxyLinks")) }
        if !mediaPool.isEmpty { try c.encode(mediaPool, forKey: AnyKey("mediaPool")) }
        let effectiveMediaMetadata = mediaMetadata.filter { !$0.value.isEmpty }
        if !effectiveMediaMetadata.isEmpty { try c.encode(effectiveMediaMetadata, forKey: AnyKey("mediaMetadata")) }
        if !smartCollections.isEmpty { try c.encode(smartCollections, forKey: AnyKey("smartCollections")) }
        try c.encodeIfPresent(targetTrackId, forKey: AnyKey("targetTrackId"))
        if !multicams.isEmpty { try c.encode(multicams, forKey: AnyKey("multicams")) }
        if !tachies.isEmpty { try c.encode(tachies, forKey: AnyKey("tachies")) }
        if !readingDictionary.isEmpty { try c.encode(readingDictionary, forKey: AnyKey("readingDictionary")) }
        if !scenes.isEmpty { try c.encode(scenes, forKey: AnyKey("scenes")) }
        try c.encodeIfPresent(subtitleY, forKey: AnyKey("subtitleY"))
        if let cam = camera, !cam.isDefault { try c.encode(cam, forKey: AnyKey("camera")) }
        if !scriptText.isEmpty { try c.encode(scriptText, forKey: AnyKey("scriptText")) }
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
    /// VOICEVOX の間: 文頭の無音(秒)。未設定 = VoicevoxClient の既定(0.03)。設定したときだけ書く。
    public var prePhonemeLength: Double? = nil
    /// VOICEVOX の間: 文末の無音(秒)。未設定 = 既定(0.03)。
    public var postPhonemeLength: Double? = nil
    /// VOICEVOX の間: 息継ぎ(音素の切れ目)の長さの倍率。未設定 = 既定(0.65)。
    public var pauseLengthScale: Double? = nil
    public var color: String = "#4f8cff"
    public var imgClosed: String? = nil
    public var imgOpen: String? = nil
    /// B-7: まばたき(目を閉じた画像)。未設定なら瞬きしない。
    public var imgBlink: String? = nil
    /// B-7: あいうえお口パク。キー "a" "i" "u" "e" "o" → 口の形ごとの画像。未設定・空は書かない。1 つでもあればリップシンクを使い、無い母音は `imgOpen` で代用する。
    public var imgVowels: [String: String]? = nil
    /// B-7: 表情名 → 画像(口を閉じた状態の代わりに使う)。セリフの `[表情名]` で切り替える。未設定・空は書かない。
    public var expressions: [String: String]? = nil
    /// B-7: 話している間に上下へ揺れる。オンのときだけ書く。
    public var bounce: Bool? = nil
    /// パーツ式立ち絵(`CharacterRig`)。あるときは `imgClosed` などの代わりに、パーツを重ねた 1 枚を使う。無ければ書かない。
    public var rig: CharacterRig? = nil
    /// 話し手ごとの字幕の文字色(#rrggbb)。字幕の自動生成でこのキャラのセリフの字幕に使う。未設定 = 文字スタイルの色。
    public var subtitleColor: String? = nil
    public var x: Double = 0.5
    public var y: Double = 0.72
    public var scale: Double = 1
    public var flip: Bool = false
    public var alwaysShow: Bool = true
    /// 旧形式の立ち絵まわりの項目(imgClosed・imgOpen・x・y・scale・flip・alwaysShow)のうち、ファイルに書く(または読んだ)キー。
    /// 新しく作ったキャラ・旧ファイルは全部(従来どおり全部書く = バイト一致)。立ち絵素材への移行(`TachieMigration`)のあとは空
    /// (値が既定でないものだけ書く。x・y は吹き出しの尾の向き先に使われるので残す)。項目が無いファイルを読んだときは、ある項目だけ。
    public var legacyKeys: Set<String> = Character.legacyPoseKeys

    public var extra: [String: JSONValue] = [:]

    static let legacyPoseKeys: Set<String> = ["imgClosed", "imgOpen", "x", "y", "scale", "flip", "alwaysShow"]
    static let knownKeys: Set<String> = ["id", "name", "engine", "speaker", "voice", "speed", "pitch", "intonation", "prePhonemeLength", "postPhonemeLength", "pauseLengthScale", "color", "imgClosed", "imgOpen", "imgBlink", "imgVowels", "expressions", "bounce", "rig", "subtitleColor", "x", "y", "scale", "flip", "alwaysShow"]

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
            make(0) { $0.name = "キャラ1"; $0.color = "#e8384f" },
            make(1) { $0.name = "キャラ2"; $0.color = "#f2c53d" },
            make(2) { $0.name = "キャラ3"; $0.color = "#7ac943" },
        ]
    }

    public init(from decoder: Decoder) throws {
        let l = Lenient(c: try decoder.container(keyedBy: AnyKey.self), known: Self.knownKeys)
        id = l.string("id") ?? id
        name = l.string("name") ?? name
        engine = l.string("engine") ?? engine
        speaker = l.int("speaker")
        voice = AquesTalkPresets.canonicalVoice(l.string("voice"))
        speed = l.double("speed")
        pitch = l.double("pitch")
        intonation = l.double("intonation")
        prePhonemeLength = l.double("prePhonemeLength")
        postPhonemeLength = l.double("postPhonemeLength")
        pauseLengthScale = l.double("pauseLengthScale")
        color = l.string("color") ?? color
        imgClosed = l.string("imgClosed")
        imgOpen = l.string("imgOpen")
        imgBlink = l.string("imgBlink")
        imgVowels = l.value("imgVowels").flatMap { (d: [String: String]) in d.isEmpty ? nil : d }
        expressions = l.value("expressions").flatMap { (d: [String: String]) in d.isEmpty ? nil : d }
        bounce = l.bool("bounce")
        rig = l.value("rig")
        subtitleColor = l.string("subtitleColor").flatMap(SpeakerSubtitleColor.normalized)
        x = l.double("x") ?? x
        y = l.double("y") ?? y
        scale = l.double("scale") ?? scale
        flip = l.bool("flip") ?? flip
        alwaysShow = l.bool("alwaysShow") ?? alwaysShow
        legacyKeys = Set(l.c.allKeys.map(\.stringValue)).intersection(Self.legacyPoseKeys)
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
        try c.encodeIfPresent(prePhonemeLength, forKey: AnyKey("prePhonemeLength"))
        try c.encodeIfPresent(postPhonemeLength, forKey: AnyKey("postPhonemeLength"))
        try c.encodeIfPresent(pauseLengthScale, forKey: AnyKey("pauseLengthScale"))
        try c.encode(color, forKey: AnyKey("color"))
        // Electron 版は未設定を null で書く(旧形式のまま持っているときだけ。移行後は書かない)
        if let s = imgClosed { try c.encode(s, forKey: AnyKey("imgClosed")) } else if legacyKeys.contains("imgClosed") { try c.encodeNil(forKey: AnyKey("imgClosed")) }
        if let s = imgOpen { try c.encode(s, forKey: AnyKey("imgOpen")) } else if legacyKeys.contains("imgOpen") { try c.encodeNil(forKey: AnyKey("imgOpen")) }
        try c.encodeIfPresent(imgBlink, forKey: AnyKey("imgBlink"))
        if let v = imgVowels, !v.isEmpty { try c.encode(v, forKey: AnyKey("imgVowels")) }
        if let e = expressions, !e.isEmpty { try c.encode(e, forKey: AnyKey("expressions")) }
        if bounce == true { try c.encode(true, forKey: AnyKey("bounce")) }
        if let r = rig { try c.encode(r, forKey: AnyKey("rig")) }
        if let s = subtitleColor { try c.encode(s, forKey: AnyKey("subtitleColor")) }
        if legacyKeys.contains("x") || x != 0.5 { try c.encode(x, forKey: AnyKey("x")) }
        if legacyKeys.contains("y") || y != 0.72 { try c.encode(y, forKey: AnyKey("y")) }
        if legacyKeys.contains("scale") || scale != 1 { try c.encode(scale, forKey: AnyKey("scale")) }
        if legacyKeys.contains("flip") || flip { try c.encode(flip, forKey: AnyKey("flip")) }
        if legacyKeys.contains("alwaysShow") || !alwaysShow { try c.encode(alwaysShow, forKey: AnyKey("alwaysShow")) }
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
    /// トラックミキサー: レイヤーの音量(線形 0〜2)。標準(1.0)は書かない。
    public var volume: Double? = nil
    /// トラックミキサー: レイヤーのパン(-1〜1。-1 が左いっぱい)。標準(0=中央)は書かない。
    public var pan: Double? = nil
    public var clips: [Clip] = []
    public var extra: [String: JSONValue] = [:]

    static let knownKeys: Set<String> = ["id", "name", "hidden", "muted", "locked", "solo", "height", "volume", "pan", "clips"]

    public init() {}
    public init(name: String) { self.name = name }

    public static func defaultLayers() -> [Track] { (1...5).map { Track(name: "レイヤー\($0)") } }

    public var isHidden: Bool { hidden ?? false }
    public var isMuted: Bool { muted ?? false }
    public var isLocked: Bool { locked ?? false }
    public var isSolo: Bool { solo ?? false }
    /// レイヤーの音量(線形)。未設定・有限でない値は 1、0〜2 に丸める。
    public var trackVolumeOrDefault: Double {
        guard let v = volume, v.isFinite else { return 1 }
        return min(max(v, 0), 2)
    }
    /// レイヤーのパン。未設定・有限でない値は 0(中央)、-1〜1 に丸める。
    public var trackPanOrDefault: Double {
        guard let p = pan, p.isFinite else { return 0 }
        return min(max(p, -1), 1)
    }
    /// 音量かパンが標準でないか(トラックミキサーの設定があるか)。
    public var hasTrackMix: Bool { trackVolumeOrDefault != 1 || trackPanOrDefault != 0 }

    public init(from decoder: Decoder) throws {
        let l = Lenient(c: try decoder.container(keyedBy: AnyKey.self), known: Self.knownKeys)
        id = l.string("id") ?? id
        name = l.string("name") ?? name
        hidden = l.bool("hidden")
        muted = l.bool("muted")
        locked = l.bool("locked")
        solo = l.bool("solo")
        height = l.string("height")
        volume = l.double("volume")
        pan = l.double("pan")
        clips = l.value("clips") ?? []
        extra = l.extra()
        // 型が違って読めなかった A6・トラックミキサーの項目は、捨てずにそのまま書き戻す
        for (key, ok) in [("locked", locked != nil), ("solo", solo != nil), ("height", height != nil), ("volume", volume != nil), ("pan", pan != nil)] where !ok {
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
        try c.encodeIfPresent(volume, forKey: AnyKey("volume"))
        try c.encodeIfPresent(pan, forKey: AnyKey("pan"))
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
    /// シーンクリップ: 素材を持たず、プロジェクトのシーン(`Clip.sceneId` → `Project.scenes`)を参照して、その中身を 1 つの映像・音声として扱う(`SceneEditing`)。
    public static let scene = ClipType(rawValue: "scene")
    /// 図形: 素材を持たず、四角・楕円・線・矢印・星を描く(`Figure`)。位置・大きさは x・y・w・h でキーフレームにできる。
    public static let shape = ClipType(rawValue: "shape")
    /// 立ち絵クリップ: 立ち絵素材(`Clip.tachieId`)を、口・まばたき・表情・バウンスを声に連動させて描く。位置・大きさ・キーフレーム・トランジション・エフェクトは普通のクリップと同じ。
    public static let tachie = ClipType(rawValue: "tachie")
    public static let known: [ClipType] = [.image, .video, .audio, .text, .voice, .blur, .adjustment, .visualizer, .compound, .scene, .shape, .tachie]
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
    /// ぼかし範囲の方式("blur" / "mosaic" / "bokeh")。無いときは "blur"(ファイルには既定のときは書かない)。
    public var blurMode: String? = nil
    /// 絞りぼかし("bokeh")の形(`ApertureShape.name`: triangle / square / pentagon / hexagon / octagon / star / heart)。無いときは円(ファイルには円のときは書かない)。
    public var bokehShape: String? = nil
    /// モザイクのブロックの大きさ(1080p 基準の px)。無いときは 12。モザイクのときだけ使う。
    public var mosaicSize: Double? = nil
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
    /// オプティカルフロー補間(動画だけ。フレームブレンドの代わりに、隣り合う 2 コマの間の動きを推定して中間のコマを作る)。true のときだけ書く。
    /// `frameBlend` とは同時に使わない(両方あれば、こちらを優先する)。
    public var frameFlow: Bool? = nil
    /// 音声エフェクト(EQ・コンプレッサー・リバーブ・ノーマライズ。音声・ボイス・動画)。無いときはファイルに書かない。
    public var audioFx: AudioFx? = nil
    /// 左右の振り分け(−1〜1、等パワー)。未設定 = 中央。
    public var pan: Double? = nil
    /// 素材チャンネルの使い方(マルチチャンネル素材用。`SourceChannelMode`)。未設定 = ダウンミックス(ファイルには既定のときは書かない)。
    public var channelMode: SourceChannelMode? = nil
    /// 文字(と字幕)の装飾: 影・箱・グラデーション・字間・行間・揃え・太字・斜体。無いときはファイルに書かない。
    public var textStyle: TextStyle? = nil
    /// 文字のアニメーション(タイプライター・ポップ・シェイク)。無いときはファイルに書かない。
    public var textAnim: TextAnim? = nil
    /// 吹き出し(文字クリップ)。無いときはファイルに書かない(B-2)。
    public var bubble: Bubble? = nil
    /// カウントダウン(文字クリップ)。無いときはファイルに書かない。`text` の後ろに残りの数を続ける。
    public var counter: TextCounter? = nil
    /// 他のクリップの値の表示(文字クリップ)。`text` の後ろに参照先の項目の値を続ける。無いときはファイルに書かない。
    public var valueRef: ValueRef? = nil
    /// BGM の自動ダッキング(音声クリップ。声があるときに下げる)。無いときはファイルに書かない。
    public var duck: Duck? = nil
    /// 音声ビジュアライザの見た目(visualizer クリップ)。無いときは既定。ファイルには設定した項目だけ書く。
    public var visualizer: Visualizer? = nil
    /// 手ぶれ補正の強さ(映像クリップ。0〜1)。無い・0 のときはファイルに書かない(オフ)。
    public var stabilize: Double? = nil
    /// 手ぶれ補正で傾き・拡大縮小も直す(true のときだけ書く。`stabilize` がオンのときだけ働く)。
    public var stabilizeRoll: Bool? = nil
    /// 複合クリップの中のレイヤー(type が compound のときだけ。無いときは書かない)。子の `start` は複合クリップの頭からの秒。
    public var tracks: [Track]? = nil
    /// シーンクリップの参照先(type が scene のときだけ。`Project.scenes` の `SceneDefinition.id`)。無いときは書かない。
    /// `offset` はシーン内時刻の窓の頭(複合クリップと同じ扱い)。参照先が無い・循環する場合は描画も音声も出ない。
    public var sceneId: String? = nil
    /// マルチカムクリップの情報(アングル一覧・有効アングル・音声アングル。`MulticamClipInfo`)。クリップ自体は普通の動画クリップで、
    /// `src`/`offset`/`srcDuration` は常に有効アングルから導出した具体値を持つ(描画・書き出しは新しい経路なし)。無いときはファイルに書かない。
    /// 形のマスク(キャンバスの矩形・楕円。省いたときは何もしない)。
    public var mask: ClipMask? = nil
    /// メッシュ変形(格子の制御点をずらす変形。`MeshPuppet`)。無いとき・全点が元の位置のときは描画不変。設定したときだけ書く。
    public var meshWarp: MeshWarp? = nil
    /// パペット変形(ピンを打って関節のように曲げる変形。`MeshPuppet`)。無いとき・全ピン元の位置のときは描画不変。設定したときだけ書く。
    public var puppetWarp: PuppetWarp? = nil
    /// ブレンドモード(下のレイヤーとの合成方法)。無いときは通常。設定したときだけ書く。
    public var blendMode: ClipBlendMode? = nil
    /// 入力色空間(撮影ガンマ・色域。`InputColorSpace`)。無いとき(nil)は Rec.709 で、描画は従来と完全に同じ。Rec.709 以外のときだけ書く。
    public var inputColorSpace: InputColorSpace? = nil
    /// グレーディングノードの直列リスト(`GradeNode`)。無い・空のときはノード無しで、描画は従来と完全に同じ。ノードがあるときだけ書く。
    public var gradeNodes: [GradeNode]? = nil
    /// グループ ID(同じ値のクリップをまとめて扱う。`ClipGrouping`)。無いときはグループ無し。設定したときだけ書く。
    public var group: String? = nil
    /// ルビ(ふりがな)。`text` の中の親文字と読みの対応(`RubyText`)。空のときはファイルに書かない。
    public var ruby: [RubySpan] = []
    /// 図形の見た目(shape クリップ)。無いときは既定。設定した項目だけ書く。
    public var figure: Figure? = nil
    /// 作業メモ(クリップの注記)。書き出しには出ない。空・未設定のときは書かない。
    public var note: String? = nil
    /// クリップ単位のロック。true のときだけファイルに書く(移動・トリム・分割・削除・プロパティ編集を断る。`LayerEditing`)。
    public var locked: Bool? = nil
    /// クリップ単位の消音。true のときだけファイルに書く(書き出し・再生・ラウドネスで鳴らさない。映像・波形は変えない)。
    public var muted: Bool? = nil
    /// クリップ単位の無効化。true のときだけファイルに書く(描画・音声の両方に出ない。消音は音だけ、レイヤーの非表示は行全体が対象で、これはクリップ単体)。
    /// グループ制御の「まとめて有効/無効」はこの値をグループ全員分まとめて切り替える(`ClipGrouping`)。
    public var disabled: Bool? = nil
    /// 録音した音声クリップを「声」として扱う指定(BGM の自動ダッキングの引き金になる)。true のときだけファイルに書く。
    public var treatAsVoice: Bool? = nil
    /// エッセンシャルサウンドの種別(会話 / ミュージック / 効果音 / アンビエンス)。無いときは未分類(ファイルに書かない)。
    public var audioCategory: AudioCategory? = nil
    /// 字幕に出す文(ボイスクリップ)。無いときは読み上げる文 `text` が字幕。空文字は「字幕なし」。読み上げ(口パクの母音判定を含む)は常に `text`。
    public var subtitleText: String? = nil
    /// 立ち絵クリップの素材(`Project.tachies` の id)。
    public var tachieId: String? = nil
    /// 立ち絵クリップの「口を動かす声」。無いときは `.all`(ファイルには書かない)。
    public var mouthDrive: MouthDrive? = nil
    /// 立ち絵クリップ: true のとき、連動する声が出ている間だけ描く(旧キャラクターの「常に表示」オフの移行用)。true のときだけ書く。
    public var speakingOnly: Bool? = nil
    /// 立ち絵クリップ: true のとき、終わりをプロジェクトの終わり(ほかのクリップの終わりの最大)に合わせ続ける(後から足した声にも届く)。true のときだけ書く。
    public var followsProjectEnd: Bool? = nil
    /// アニメーション画像素材(連番画像を取り込んだ APNG など): true のとき、素材のアニメーションを再生する。true のときだけ書く。
    public var playsAnimation: Bool? = nil
    /// VOICEVOX のアクセント編集(ボイスクリップ)。アクセント句の列。無い・空のときはファイルに書かない(従来どおりの合成)。
    public var voicevoxAccent: [VoicevoxAccentPhrase]? = nil
    /// オブジェクトトラッキングの結果(W3-03 / 監査 #53)。無いときはファイルに書かない。追従は `keyframes` にも焼き込まれている(再適用・解除の基準として保持する)。
    public var tracking: ObjectTrack? = nil
    /// オブジェクトマスク(対象の輪郭マスク+追跡伝播。Premiere の AI オブジェクトマスク等価)。無いときはファイルに書かない。形のマスク(`mask`)とは別に、両方あれば両方かかる。
    public var objectMask: ObjectMask? = nil
    /// HSL マスク(色相・彩度・輝度で選んだ範囲だけ残すマスク。Premiere 27.0「HSL マスキング」等価)。無いときはファイルに書かない。形のマスク(`mask`)・オブジェクトマスクとは別に、全部あれば全部かかる。
    public var hslMask: HSLMask? = nil
    public var extra: [String: JSONValue] = [:]

    static let knownKeys: Set<String> = ["id", "type", "voicevoxAccent", "subtitleText", "tachieId", "mouthDrive", "speakingOnly", "followsProjectEnd", "playsAnimation", "start", "duration", "offset", "src", "srcDuration", "x", "y", "scale", "opacity", "volume", "blur", "text", "fontSize", "color", "outline", "font", "charId", "subtitle", "w", "h", "strength", "shape", "blurMode", "bokehShape", "mosaicSize", "rotation", "flipH", "flipV", "crop", "keyframes", "transitionIn", "transitionOut", "effects", "fadeIn", "fadeOut", "fadeCurve", "speed", "reverse", "keepPitch", "freeze", "speedRamp", "frameBlend", "frameFlow", "audioFx", "pan", "channelMode", "textStyle", "textAnim", "bubble", "counter", "valueRef", "duck", "visualizer", "stabilize", "stabilizeRoll", "tracks", "sceneId", "mask", "meshWarp", "puppetWarp", "blendMode", "group", "ruby", "figure", "note", "locked", "muted", "disabled", "treatAsVoice", "audioCategory", "tracking", "objectMask", "hslMask", "inputColorSpace", "gradeNodes"]

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
    public var blurModeOrDefault: String { blurMode ?? "blur" }
    /// 絞りぼかしの形(知らない名前・無いときは円)。
    public var bokehShapeOrDefault: ApertureShape { ApertureShape(name: bokehShape) }
    public var mosaicSizeOrDefault: Double { mosaicSize ?? 12 }
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
    /// このクリップ自身がロックされているか(レイヤーのロックとは別)。
    public var isClipLocked: Bool { locked == true }
    /// このクリップ自身が消音されているか(レイヤーの消音とは別)。
    public var isMuted: Bool { muted ?? false }
    /// このクリップ自身が無効化されているか(描画・音声の両方に出ない)。
    public var isDisabled: Bool { disabled ?? false }
    /// 声として扱う指定があるか(音声クリップ向け)。
    public var isTreatedAsVoice: Bool { treatAsVoice ?? false }
    /// エッセンシャルサウンドの種別が付いているか(未分類でない)。
    public var hasAudioCategory: Bool { audioCategory != nil }
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
            if let (kind, axis) = WarpKey.parse(key) {
                switch kind {
                case .mesh(let i):
                    guard let m = meshWarp, m.points.indices.contains(i) else { return 0 }
                    return axis == .x ? m.points[i].x : m.points[i].y
                case .pin(let i):
                    guard let p = puppetWarp, p.pins.indices.contains(i) else { return 0 }
                    return axis == .x ? p.pins[i].x : p.pins[i].y
                }
            }
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
            if let (kind, axis) = WarpKey.parse(key) {
                switch kind {
                case .mesh(let i):
                    if let m = meshWarp, m.points.indices.contains(i) {
                        let p = m.points[i]
                        _ = WarpEditing.setMeshPoint(&self, index: i, x: axis == .x ? v : p.x, y: axis == .y ? v : p.y)
                    }
                case .pin(let i):
                    if let pw = puppetWarp, pw.pins.indices.contains(i) {
                        let pin = pw.pins[i]
                        _ = WarpEditing.movePin(&self, index: i, x: axis == .x ? v : pin.x, y: axis == .y ? v : pin.y)
                    }
                }
            } else if let (i, p) = EffectKey.parse(key), effects.indices.contains(i) { effects[i].params[p] = v }
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
        blurMode = l.string("blurMode"); bokehShape = l.string("bokehShape"); mosaicSize = l.double("mosaicSize")
        rotation = l.double("rotation"); flipH = l.bool("flipH"); flipV = l.bool("flipV")
        crop = l.value("crop")
        fadeIn = l.double("fadeIn"); fadeOut = l.double("fadeOut"); fadeCurve = l.string("fadeCurve")
        speed = l.double("speed"); reverse = l.bool("reverse"); keepPitch = l.bool("keepPitch"); freeze = l.bool("freeze")
        speedRamp = l.value("speedRamp"); frameBlend = l.bool("frameBlend") == true ? true : nil; frameFlow = l.bool("frameFlow") == true ? true : nil
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
        if let raw: JSONValue = l.value("valueRef") {
            if let v: ValueRef = l.value("valueRef") { valueRef = v } else { extra["valueRef"] = raw }
        }
        if let raw: JSONValue = l.value("duck") {
            if let v: Duck = l.value("duck") { duck = v } else { extra["duck"] = raw }
        }
        if let raw: JSONValue = l.value("stabilize") {
            if let v: Double = l.value("stabilize"), v.isFinite { stabilize = v > 0 ? min(v, 1) : nil } else { extra["stabilize"] = raw }
        }
        if let raw: JSONValue = l.value("stabilizeRoll") {
            if let v: Bool = l.value("stabilizeRoll") { stabilizeRoll = v ? true : nil } else { extra["stabilizeRoll"] = raw }
        }
        // 入力色空間: 知らない値は捨てずにそのまま書き戻す(Rec.709 は書かない)
        if let raw: JSONValue = l.value("inputColorSpace") {
            if let name: String = l.value("inputColorSpace"), let v = InputColorSpace(rawValue: name) { inputColorSpace = v == .rec709 ? nil : v } else { extra["inputColorSpace"] = raw }
        }
        // グレーディングノード: 読めない形は捨てずにそのまま書き戻す(空配列は nil)
        if let raw: JSONValue = l.value("gradeNodes") {
            if let v: [GradeNode] = l.value("gradeNodes") { gradeNodes = v.isEmpty ? nil : v } else { extra["gradeNodes"] = raw }
        }
        if let raw: JSONValue = l.value("mask") {
            if let v: ClipMask = l.value("mask") { mask = v } else { extra["mask"] = raw }
        }
        // メッシュ/パペット変形: 読めない型は捨てずにそのまま書き戻す
        if let raw: JSONValue = l.value("meshWarp") {
            if let v: MeshWarp = l.value("meshWarp") { meshWarp = v } else { extra["meshWarp"] = raw }
        }
        if let raw: JSONValue = l.value("puppetWarp") {
            if let v: PuppetWarp = l.value("puppetWarp") { puppetWarp = v } else { extra["puppetWarp"] = raw }
        }
        // 複合クリップの中身: 読めなければ捨てずにそのまま書き戻す
        if let raw: JSONValue = l.value("tracks") {
            if let v: [Track] = l.value("tracks") { tracks = v } else { extra["tracks"] = raw }
        }
        // シーンクリップの参照先: 型が違って読めなければ捨てずに書き戻す
        sceneId = l.string("sceneId")
        if sceneId == nil, let raw: JSONValue = l.value("sceneId") { extra["sceneId"] = raw }
        note = l.string("note").flatMap { Clip.cleanNote($0) }
        if let raw: JSONValue = l.value("locked") {
            if l.bool("locked") == true { locked = true } else { extra["locked"] = raw }   // true 以外は捨てずに書き戻す
        }
        if let raw: JSONValue = l.value("muted") {
            if l.bool("muted") == true { muted = true } else { extra["muted"] = raw }   // true 以外は捨てずに書き戻す
        }
        if let raw: JSONValue = l.value("disabled") {
            if l.bool("disabled") == true { disabled = true } else { extra["disabled"] = raw }   // true 以外は捨てずに書き戻す
        }
        if let raw: JSONValue = l.value("treatAsVoice") {
            if l.bool("treatAsVoice") == true { treatAsVoice = true } else { extra["treatAsVoice"] = raw }   // true 以外は捨てずに書き戻す
        }
        // エッセンシャルサウンドの種別: 知らない種別・型が違う値は捨てずに書き戻す(blendMode と同じ作法)
        if let raw: JSONValue = l.value("audioCategory") {
            if let name: String = l.value("audioCategory"), let cat = AudioCategory(rawValue: name) { audioCategory = cat } else { extra["audioCategory"] = raw }
        }
        // 素材チャンネルの使い方: 知らない値・型が違う値は捨てずに書き戻す(audioCategory と同じ作法)。既定(downmix)は未設定と同じ
        if let raw: JSONValue = l.value("channelMode") {
            if let name: String = l.value("channelMode"), let m = SourceChannelMode(rawValue: name) { channelMode = m == .downmix ? nil : m } else { extra["channelMode"] = raw }
        }
        // アクセント編集: 読めない型は捨てずに書き戻す。空は未設定と同じ
        if let raw: JSONValue = l.value("voicevoxAccent") {
            if let v: [VoicevoxAccentPhrase] = l.value("voicevoxAccent") { voicevoxAccent = v.isEmpty ? nil : v } else { extra["voicevoxAccent"] = raw }
        }
        // トラッキング結果: 読めない型は捨てずに書き戻す。空(有効サンプルなし)は未設定と同じ
        if let raw: JSONValue = l.value("tracking") {
            if let v: ObjectTrack = l.value("tracking") { tracking = v.hasValidSamples ? v.normalized : nil } else { extra["tracking"] = raw }
        }
        // オブジェクトマスク: 読めない型は捨てずに書き戻す。空(有効サンプルなし)は未設定と同じ
        if let raw: JSONValue = l.value("objectMask") {
            if let v: ObjectMask = l.value("objectMask") { objectMask = v.hasValidSamples ? v.normalized : nil } else { extra["objectMask"] = raw }
        }
        // HSL マスク: 読めない型は捨てずに書き戻す
        if let raw: JSONValue = l.value("hslMask") {
            if let v: HSLMask = l.value("hslMask") { hslMask = v } else { extra["hslMask"] = raw }
        }
        if let raw: JSONValue = l.value("figure") {
            if let v: Figure = l.value("figure") { figure = v } else { extra["figure"] = raw }
        }
        // 字幕の文・立ち絵クリップの項目: 型が違って読めなければ捨てずに書き戻す
        subtitleText = l.string("subtitleText")
        tachieId = l.string("tachieId")
        if let raw: JSONValue = l.value("mouthDrive") {
            if let s: String = l.value("mouthDrive"), let d = MouthDrive(raw: s) { mouthDrive = d == .all ? nil : d }
            else { extra["mouthDrive"] = raw }
        }
        if let raw: JSONValue = l.value("speakingOnly") {
            if l.bool("speakingOnly") == true { speakingOnly = true } else { extra["speakingOnly"] = raw }
        }
        if let raw: JSONValue = l.value("followsProjectEnd") {
            if l.bool("followsProjectEnd") == true { followsProjectEnd = true } else { extra["followsProjectEnd"] = raw }
        }
        if let raw: JSONValue = l.value("playsAnimation") {
            if l.bool("playsAnimation") == true { playsAnimation = true } else { extra["playsAnimation"] = raw }
        }
        for (key, ok) in [("subtitleText", subtitleText != nil), ("tachieId", tachieId != nil)] where !ok {
            if let raw: JSONValue = l.value(key) { extra[key] = raw }
        }
        // ブレンドモード: 知らない名前は捨てずに書き戻す
        if let raw: JSONValue = l.value("blendMode") {
            if let name: String = l.value("blendMode"), let m = ClipBlendMode(rawValue: name) { blendMode = m }
            else { extra["blendMode"] = raw }
        }
        group = l.string("group")
        if group == nil, let raw: JSONValue = l.value("group") { extra["group"] = raw }
        // ルビ: 読めない型の値は捨てずに書き戻す
        if let raw: JSONValue = l.value("ruby") {
            if let v: [RubySpan] = l.value("ruby") { ruby = v.filter { !$0.base.isEmpty && !$0.reading.isEmpty } } else { extra["ruby"] = raw }
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
        try c.encodeIfPresent(blurMode, forKey: AnyKey("blurMode"))
        try c.encodeIfPresent(bokehShape, forKey: AnyKey("bokehShape"))
        try c.encodeIfPresent(mosaicSize, forKey: AnyKey("mosaicSize"))
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
        try c.encodeIfPresent(frameFlow == true ? true : nil, forKey: AnyKey("frameFlow"))
        if let fx = audioFx, !fx.isEmpty { try c.encode(fx, forKey: AnyKey("audioFx")) }
        try c.encodeIfPresent(pan, forKey: AnyKey("pan"))
        if let m = channelMode, m != .downmix { try c.encode(m.rawValue, forKey: AnyKey("channelMode")) }
        try c.encodeIfPresent(textStyle, forKey: AnyKey("textStyle"))
        try c.encodeIfPresent(textAnim, forKey: AnyKey("textAnim"))
        try c.encodeIfPresent(bubble, forKey: AnyKey("bubble"))
        try c.encodeIfPresent(counter, forKey: AnyKey("counter"))
        try c.encodeIfPresent(valueRef, forKey: AnyKey("valueRef"))
        try c.encodeIfPresent(duck, forKey: AnyKey("duck"))
        try c.encodeIfPresent(visualizer, forKey: AnyKey("visualizer"))
        if let f = figure?.normalized { try c.encode(f, forKey: AnyKey("figure")) }
        if let n = note, !n.isEmpty { try c.encode(n, forKey: AnyKey("note")) }
        if locked == true { try c.encode(true, forKey: AnyKey("locked")) }
        if muted == true { try c.encode(true, forKey: AnyKey("muted")) }
        if disabled == true { try c.encode(true, forKey: AnyKey("disabled")) }
        if treatAsVoice == true { try c.encode(true, forKey: AnyKey("treatAsVoice")) }
        if let cat = audioCategory { try c.encode(cat.rawValue, forKey: AnyKey("audioCategory")) }
        if let a = voicevoxAccent, !a.isEmpty { try c.encode(a, forKey: AnyKey("voicevoxAccent")) }
        if let tr = tracking, tr.hasValidSamples { try c.encode(tr, forKey: AnyKey("tracking")) }
        if let om = objectMask, om.hasValidSamples { try c.encode(om, forKey: AnyKey("objectMask")) }
        try c.encodeIfPresent(hslMask, forKey: AnyKey("hslMask"))
        try c.encodeIfPresent(subtitleText, forKey: AnyKey("subtitleText"))
        try c.encodeIfPresent(tachieId, forKey: AnyKey("tachieId"))
        if let d = mouthDrive, d != .all { try c.encode(d.raw, forKey: AnyKey("mouthDrive")) }
        if speakingOnly == true { try c.encode(true, forKey: AnyKey("speakingOnly")) }
        if followsProjectEnd == true { try c.encode(true, forKey: AnyKey("followsProjectEnd")) }
        if playsAnimation == true { try c.encode(true, forKey: AnyKey("playsAnimation")) }
        if let t = tracks { try c.encode(t, forKey: AnyKey("tracks")) }
        try c.encodeIfPresent(sceneId, forKey: AnyKey("sceneId"))
        try c.encodeIfPresent(mask, forKey: AnyKey("mask"))
        if let g = gradeNodes, !g.isEmpty { try c.encode(g, forKey: AnyKey("gradeNodes")) }
        if let cs = inputColorSpace, cs != .rec709 { try c.encode(cs.rawValue, forKey: AnyKey("inputColorSpace")) }
        try c.encodeIfPresent(meshWarp, forKey: AnyKey("meshWarp"))
        try c.encodeIfPresent(puppetWarp, forKey: AnyKey("puppetWarp"))
        if let m = blendMode { try c.encode(m.rawValue, forKey: AnyKey("blendMode")) }
        try c.encodeIfPresent(group, forKey: AnyKey("group"))
        if !ruby.isEmpty { try c.encode(ruby, forKey: AnyKey("ruby")) }
        if let s = stabilize, s > 0 { try c.encode(min(s, 1), forKey: AnyKey("stabilize")) }
        if stabilizeRoll == true { try c.encode(true, forKey: AnyKey("stabilizeRoll")) }
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

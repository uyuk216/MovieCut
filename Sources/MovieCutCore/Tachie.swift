import Foundation

// 立ち絵(素材)とキャラクター(声・字幕)の分離。
// - 立ち絵素材 `Tachie`: 画像・パーツ式リグ・口/まばたき/表情の画像・バウンス。`Project.tachies` に持つ。
// - 立ち絵クリップ(`ClipType.tachie`): タイムライン上の普通のクリップ。素材 `Clip.tachieId` と、口を動かす声 `Clip.mouthDrive`。
// - キャラクター `Character`: 声(エンジン・話者・速度・高さ・抑揚)と字幕(色)だけ。
// 画面を持たない純粋な部分(モデル・編集・旧形式からの移行)。描画は `Renderer`、UI は別。

// MARK: - 口を動かす声

/// 立ち絵クリップが「どの声に合わせて口・まばたき・表情・バウンスを動かすか」。
public enum MouthDrive: Equatable, Hashable, Sendable {
    /// その時刻に出ている全部の声(複数なら最後に見つかったもの)。既定。
    case all
    /// 動かさない(静止。まばたきは時間で動く)。
    case none
    /// 特定のキャラクターの声。
    case character(String)
    /// 特定の声クリップ。
    case voiceClip(String)

    /// ファイルでの書き方: "all" / "none" / "character:ID" / "voice:ID"。
    public var raw: String {
        switch self {
        case .all: return "all"
        case .none: return "none"
        case .character(let id): return "character:" + id
        case .voiceClip(let id): return "voice:" + id
        }
    }

    public init?(raw: String) {
        switch raw {
        case "all": self = .all
        case "none": self = .none
        default:
            if raw.hasPrefix("character:"), raw.count > "character:".count { self = .character(String(raw.dropFirst("character:".count))) }
            else if raw.hasPrefix("voice:"), raw.count > "voice:".count { self = .voiceClip(String(raw.dropFirst("voice:".count))) }
            else { return nil }
        }
    }

    /// 時刻 t に出ている声クリップ(トラックの順)から、この指定が連動する声を選ぶ。無ければ nil。
    public func driver(among voices: [Clip]) -> Clip? {
        switch self {
        case .all: return voices.last
        case .none: return nil
        case .character(let id): return voices.last { $0.charId == id }
        case .voiceClip(let id): return voices.first { $0.id == id }
        }
    }

    /// 日本語の説明(インスペクタ用)。
    public func label(characters: [Character]) -> String {
        switch self {
        case .all: return "すべての声"
        case .none: return "動かさない"
        case .character(let id): return "「\(characters.first { $0.id == id }?.name ?? "(削除されたキャラ)")」の声"
        case .voiceClip: return "指定した声クリップ"
        }
    }
}

// MARK: - 立ち絵素材

public struct Tachie: Codable, Equatable, Identifiable {
    public var id: String = newId()
    public var name: String = ""
    public var imgClosed: String? = nil
    public var imgOpen: String? = nil
    /// まばたき(目を閉じた画像)。未設定なら瞬きしない。
    public var imgBlink: String? = nil
    /// あいうえお口パク。キー "a" "i" "u" "e" "o" → 画像。空は書かない。
    public var imgVowels: [String: String]? = nil
    /// 表情名 → 画像。セリフの `[表情名]` で切り替える。空は書かない。
    public var expressions: [String: String]? = nil
    /// 話している間に上下へ揺れる。オンのときだけ書く。
    public var bounce: Bool? = nil
    /// パーツ式立ち絵。あるときは画像の代わりに、パーツを重ねた 1 枚を使う。パーツごとの位置の補正は `rig.partOffsets`。
    public var rig: CharacterRig? = nil
    public var extra: [String: JSONValue] = [:]

    static let knownKeys: Set<String> = ["id", "name", "imgClosed", "imgOpen", "imgBlink", "imgVowels", "expressions", "bounce", "rig"]

    public init() {}
    public init(name: String) { self.name = name }

    public init(from decoder: Decoder) throws {
        let l = Lenient(c: try decoder.container(keyedBy: AnyKey.self), known: Self.knownKeys)
        id = l.string("id") ?? id
        name = l.string("name") ?? name
        imgClosed = l.string("imgClosed")
        imgOpen = l.string("imgOpen")
        imgBlink = l.string("imgBlink")
        imgVowels = l.value("imgVowels").flatMap { (d: [String: String]) in d.isEmpty ? nil : d }
        expressions = l.value("expressions").flatMap { (d: [String: String]) in d.isEmpty ? nil : d }
        bounce = l.bool("bounce") == true ? true : nil
        extra = l.extra()
        if let raw: JSONValue = l.value("rig") {
            if let r: CharacterRig = l.value("rig") { rig = r } else { extra["rig"] = raw }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        for (k, v) in extra { try c.encode(v, forKey: AnyKey(k)) }
        try c.encode(id, forKey: AnyKey("id"))
        try c.encode(name, forKey: AnyKey("name"))
        try c.encodeIfPresent(imgClosed, forKey: AnyKey("imgClosed"))
        try c.encodeIfPresent(imgOpen, forKey: AnyKey("imgOpen"))
        try c.encodeIfPresent(imgBlink, forKey: AnyKey("imgBlink"))
        if let v = imgVowels, !v.isEmpty { try c.encode(v, forKey: AnyKey("imgVowels")) }
        if let e = expressions, !e.isEmpty { try c.encode(e, forKey: AnyKey("expressions")) }
        if bounce == true { try c.encode(true, forKey: AnyKey("bounce")) }
        if let r = rig { try c.encode(r, forKey: AnyKey("rig")) }
    }

    /// 描ける画像があるか(リグのパーツ、または通常・口開き・まばたき・母音・表情のどれか)。
    public var hasImages: Bool {
        if let r = rig, r.hasParts { return true }
        return imgClosed != nil || imgOpen != nil || imgBlink != nil || !(imgVowels ?? [:]).isEmpty || !(expressions ?? [:]).isEmpty
    }

    /// 使っている画像のパス(未使用素材・欠落の判定用)。
    public var allPaths: [String] {
        var out: [String] = []
        out += [imgClosed, imgOpen, imgBlink].compactMap { $0 }
        out += (imgVowels ?? [:]).values.sorted()
        out += (expressions ?? [:]).values.sorted()
        out += rig?.allPaths ?? []
        return out
    }
}

public extension Project {
    func tachie(_ id: String?) -> Tachie? { id.flatMap { i in tachies.first { $0.id == i } } }
}

public extension Clip {
    /// 立ち絵クリップの、口を動かす声(無ければすべての声)。
    var mouthDriveOrDefault: MouthDrive { mouthDrive ?? .all }

    /// 字幕に出す文(ボイスクリップ)。`subtitleText` があればそれ、無ければ読み上げる文。表情タグ `[表情]` は除く。空 = 字幕なし。
    var subtitleBody: String {
        ExpressionTag.body(subtitleText ?? text ?? "")
    }
}

// MARK: - 編集(値を返す純粋関数。変わらなければ入力と同じ値)

public enum TachieEditing {
    /// 立ち絵素材を足す。同じ id が既にあれば変えない。
    public static func add(_ project: Project, tachie: Tachie) -> Project {
        guard !project.tachies.contains(where: { $0.id == tachie.id }) else { return project }
        var p = project; p.tachies.append(tachie); return p
    }

    /// 素材を書き換える。無い id・同じ値のときは変えない。
    public static func update(_ project: Project, id: String, _ change: (inout Tachie) -> Void) -> Project {
        guard let i = project.tachies.firstIndex(where: { $0.id == id }) else { return project }
        var t = project.tachies[i]
        change(&t)
        guard t != project.tachies[i] else { return project }
        var p = project; p.tachies[i] = t; return p
    }

    public static func rename(_ project: Project, id: String, to name: String) -> Project {
        update(project, id: id) { $0.name = name }
    }

    /// 素材を消す。その素材を使う立ち絵クリップも一緒に消す(描けないクリップを残さない)。無い id は変えない。
    public static func remove(_ project: Project, id: String) -> Project {
        guard project.tachies.contains(where: { $0.id == id }) else { return project }
        var p = project
        p.tachies.removeAll { $0.id == id }
        for ti in p.tracks.indices { p.tracks[ti].clips.removeAll { $0.type == .tachie && $0.tachieId == id } }
        return p
    }

    /// パーツの位置の補正を決める(ゼロは外す)。リグが無い・パスがリグに無い・同じ値のときは変えない。
    public static func setPartOffset(_ project: Project, tachieId: String, path: String, offset: PartOffset) -> Project {
        update(project, id: tachieId) { t in
            guard var rig = t.rig, rig.allPaths.contains(path), offset.dx.isFinite, offset.dy.isFinite else { return }
            var o = rig.partOffsets ?? [:]
            if offset.isZero { o.removeValue(forKey: path) } else { o[path] = offset }
            rig.partOffsets = o.isEmpty ? nil : o
            t.rig = rig
        }
    }

    /// 大きさが違うパーツの位置を推測して入れる(手で決めた補正は残す)。`base` はリグの基準キャンバスの大きさ。
    public static func autoAlignParts(_ project: Project, tachieId: String, base: (w: Int, h: Int),
                                      canvas: (String) -> (w: Int, h: Int)? = RigFolderImporter.imageSize,
                                      opaque: (String) -> CGRect? = { RigHeuristics.opaqueFraction($0) }) -> Project {
        update(project, id: tachieId) { t in
            guard let rig = t.rig else { return }
            t.rig = RigAlignment.applySuggestions(rig, base: base, canvas: canvas, opaque: opaque)
        }
    }

    /// 立ち絵クリップを作る(置き場所はまだ決めない)。素材が無ければ nil。
    public static func makeClip(_ project: Project, tachieId: String, start: Double, duration: Double, drive: MouthDrive = .all, followsProjectEnd: Bool = false) -> Clip? {
        guard project.tachies.contains(where: { $0.id == tachieId }), start.isFinite, duration.isFinite, duration > 0 else { return nil }
        var c = Clip()
        c.type = .tachie
        c.tachieId = tachieId
        c.start = max(0, start)
        c.duration = duration
        c.x = 0.5; c.y = 0.72
        c.mouthDrive = drive == .all ? nil : drive
        if followsProjectEnd { c.followsProjectEnd = true }
        return c
    }

    /// 立ち絵クリップの「口を動かす声」を変える。立ち絵クリップ以外・同じ値は変えない。`.all` は未設定に戻す。
    public static func setMouthDrive(_ project: Project, clipId: String, drive: MouthDrive) -> Project {
        mutateClip(project, clipId: clipId) { c in
            guard c.type == .tachie else { return }
            c.mouthDrive = drive == .all ? nil : drive
        }
    }

    /// 立ち絵クリップの素材を差し替える。素材が無い・立ち絵クリップでない・同じ値は変えない。
    public static func setClipTachie(_ project: Project, clipId: String, tachieId: String) -> Project {
        guard project.tachies.contains(where: { $0.id == tachieId }) else { return project }
        return mutateClip(project, clipId: clipId) { c in
            guard c.type == .tachie else { return }
            c.tachieId = tachieId
        }
    }

    /// ボイスの字幕の文を変える。nil = 読み上げる文と同じ(未設定に戻す)、空 = 字幕なし。ボイス以外・同じ値は変えない。
    public static func setSubtitleText(_ project: Project, clipId: String, text: String?) -> Project {
        mutateClip(project, clipId: clipId) { c in
            guard c.type == .voice else { return }
            // 読み上げる文と同じ字幕は「未設定」と同じなので書かない
            if let t = text, t == c.text { c.subtitleText = nil } else { c.subtitleText = text }
        }
    }

    private static func mutateClip(_ project: Project, clipId: String, _ change: (inout Clip) -> Void) -> Project {
        for ti in project.tracks.indices {
            guard let ci = project.tracks[ti].clips.firstIndex(where: { $0.id == clipId }) else { continue }
            var c = project.tracks[ti].clips[ci]
            change(&c)
            guard c != project.tracks[ti].clips[ci] else { return project }
            var p = project; p.tracks[ti].clips[ci] = c; return p
        }
        return project
    }
}

// MARK: - 旧形式(Character が立ち絵を持つ)からの移行

/// 旧形式のプロジェクトを読んだときに、キャラクターの画像・リグ・位置を「立ち絵素材 + 立ち絵クリップ」へ移す。
///
/// 1 キャラクターにつき、素材 1 つと、全時間(0〜プロジェクトの終わり)の立ち絵クリップ 1 つ(新しいレイヤーを最上段に足してそこへ置く。
/// 旧形式は立ち絵を全レイヤーの上・字幕の下に描いていたので、同じ重なり順になる)。クリップは元の x・y・拡大・左右反転を持ち、
/// `mouthDrive = .character(そのキャラ)`。「常に表示」がオフだったキャラは `speakingOnly`。
/// 描画は旧経路と画素まで一致する(`TachieMigrationTests`)。一致しない点は DESIGN.md に書いてある。
public enum TachieMigration {
    /// 移行が必要なキャラか(画像・リグを持つ)。
    public static func needsMigration(_ ch: Character) -> Bool {
        ch.imgClosed != nil || ch.imgOpen != nil || ch.imgBlink != nil
            || !(ch.imgVowels ?? [:]).isEmpty || !(ch.expressions ?? [:]).isEmpty || ch.rig != nil
    }

    public static func needsMigration(_ project: Project) -> Bool { project.characters.contains(where: needsMigration) }

    /// 移行した結果。移行が要らなければ入力と同じ値。何度かけても同じ(2 回目は何もしない)。
    public static func migrated(_ project: Project) -> Project {
        guard needsMigration(project) else { return project }
        var p = project
        var end = 0.0
        for tr in p.tracks { for c in tr.clips { end = max(end, c.start + c.duration) } }
        let length = end > 0 ? end : 5
        for i in p.characters.indices where needsMigration(p.characters[i]) {
            let ch = p.characters[i]
            var t = Tachie(name: ch.name)
            t.id = unique("tachie-" + ch.id, taken: Set(p.tachies.map(\.id)))
            t.imgClosed = ch.imgClosed; t.imgOpen = ch.imgOpen; t.imgBlink = ch.imgBlink
            t.imgVowels = ch.imgVowels; t.expressions = ch.expressions
            t.bounce = ch.bounce == true ? true : nil
            t.rig = ch.rig
            p.tachies.append(t)

            var c = Clip()
            c.type = .tachie
            c.id = unique("tclip-" + ch.id, taken: Set(p.allClips.map(\.id)))
            c.tachieId = t.id
            c.start = 0; c.duration = length
            if ch.x != 0.5 { c.x = ch.x }
            if ch.y != 0.5 { c.y = ch.y }
            if ch.scale != 1 { c.scale = ch.scale }
            if ch.flip { c.flipH = true }
            c.mouthDrive = .character(ch.id)
            if !ch.alwaysShow { c.speakingOnly = true }
            c.followsProjectEnd = true   // 後から足した声にも届くよう、プロジェクトの終わりに合わせ続ける
            var tr = Track(name: "立ち絵: " + (ch.name.isEmpty ? "キャラ" : ch.name))
            tr.id = unique("tlayer-" + ch.id, taken: Set(p.tracks.map(\.id)))   // 同じ入力からは同じ結果にする
            tr.clips = [c]
            p.tracks.append(tr)

            // キャラクターは声と字幕だけにする。x・y は吹き出しの尾の向き先に使うので残す
            var n = ch
            n.imgClosed = nil; n.imgOpen = nil; n.imgBlink = nil; n.imgVowels = nil; n.expressions = nil; n.bounce = nil; n.rig = nil
            n.scale = 1; n.flip = false; n.alwaysShow = true
            n.legacyKeys = []
            p.characters[i] = n
        }
        return p
    }

    private static func unique(_ base: String, taken: Set<String>) -> String {
        var id = base, n = 2
        while taken.contains(id) { id = base + "-\(n)"; n += 1 }
        return id
    }
}

public extension Project {
    /// 旧形式のキャラクターの立ち絵を、立ち絵素材 + 立ち絵クリップへ移して読む(アプリが書類を開くときに使う)。
    /// `decode(from:)` は旧ファイルをバイト一致で書き戻すために移行しない。
    static func decodeMigrating(from data: Data) throws -> Project {
        TachieMigration.migrated(try decode(from: data))
    }
}

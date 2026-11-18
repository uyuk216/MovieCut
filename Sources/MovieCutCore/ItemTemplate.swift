import Foundation

// MARK: - アイテムテンプレート(#8)
//
// クリップ 1 個分の「設定一式」を名前つきで保存し、別のクリップへ当てる / 新しいクリップの土台にする。
// プロジェクト全体のテンプレート(`ProjectTemplate`)・文字だけの見た目(`TextStyleLibrary`)とは別物で、
// こちらは種類(ボイス・文字・画像・ぼかし等)を問わずクリップ単位で扱う(YMM4 のアイテムテンプレート相当)。
//
// 当て方には 2 通りあり、どちらも「中身」は壊さない:
// - 既存クリップへ適用(`apply(to:)`): 見た目・振る舞いの項目だけを写す。素材パス・セリフ・字幕文・
//   話すキャラ・位置(開始時刻)・長さ・素材の切り出し位置は、適用先のものをそのまま残す。
// - 新規作成(`makeClip()`): 保存したクリップを丸ごと土台にする(素材パス・セリフも含む)。id だけ付け替える。
//
// 保存先はアプリ全体(`Application Support/MovieCut/Templates/item-templates.json`)で、プロジェクトには入らない。
// そのためプロジェクトファイルの形式・互換には影響しない。壊れた項目はその 1 件だけ捨てる(読み込みで落ちない)。

/// アイテムテンプレート 1 件。`clip` は保存したクリップの写し(開始時刻は 0 にそろえたもの)。
public struct ItemTemplate: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var clip: Clip

    public init(id: String, name: String, clip: Clip) {
        self.id = id; self.name = name; self.clip = clip
    }

    public var clipType: ClipType { clip.type }

    /// クリップからテンプレートを作る。開始時刻は 0 にそろえ、メモ・ロック・消音・グループ・
    /// 知らないキー(`extra`)は持ち込まない(テンプレートは「設定」だけを持つ)。
    public static func capture(name: String, from clip: Clip) -> ItemTemplate? {
        guard let n = ItemTemplateLibrary.sanitizedName(name) else { return nil }
        var c = clip
        c.start = 0
        c.note = nil
        c.locked = nil
        c.muted = nil
        c.group = nil
        c.extra = [:]
        return ItemTemplate(id: "user." + newId(), name: n, clip: c)
    }

    /// 既存クリップへ当てる(見た目・振る舞いだけ)。種類が違うクリップには当てない。
    /// 変えたときだけ true。当てない項目: id・開始・長さ・素材の位置と切り出し・セリフ・字幕文・
    /// 話すキャラ・立ち絵素材・複合クリップの中身・メモ・グループ・ロック・消音・声として扱う指定・
    /// VOICEVOX アクセント・ルビ・他クリップ参照(`valueRef`)・知らないキー。
    @discardableResult
    public func apply(to target: inout Clip) -> Bool {
        guard target.type == clip.type else { return false }
        let before = target
        let s = clip
        target.x = s.x; target.y = s.y; target.scale = s.scale
        target.opacity = s.opacity; target.volume = s.volume; target.blur = s.blur
        target.fontSize = s.fontSize; target.color = s.color; target.outline = s.outline; target.font = s.font
        target.subtitle = s.subtitle
        target.w = s.w; target.h = s.h; target.strength = s.strength; target.shape = s.shape
        target.blurMode = s.blurMode; target.bokehShape = s.bokehShape; target.mosaicSize = s.mosaicSize
        target.rotation = s.rotation; target.flipH = s.flipH; target.flipV = s.flipV; target.crop = s.crop
        target.keyframes = s.keyframes
        target.transitionIn = s.transitionIn; target.transitionOut = s.transitionOut
        target.effects = s.effects
        target.fadeIn = s.fadeIn; target.fadeOut = s.fadeOut; target.fadeCurve = s.fadeCurve
        target.speed = s.speed; target.reverse = s.reverse; target.keepPitch = s.keepPitch; target.freeze = s.freeze
        target.speedRamp = s.speedRamp; target.frameBlend = s.frameBlend; target.frameFlow = s.frameFlow
        target.audioFx = s.audioFx; target.pan = s.pan
        target.textStyle = s.textStyle; target.textAnim = s.textAnim; target.bubble = s.bubble
        target.counter = s.counter; target.duck = s.duck; target.visualizer = s.visualizer
        target.figure = s.figure; target.mask = s.mask; target.blendMode = s.blendMode
        target.stabilize = s.stabilize; target.stabilizeRoll = s.stabilizeRoll
        target.mouthDrive = s.mouthDrive; target.speakingOnly = s.speakingOnly; target.followsProjectEnd = s.followsProjectEnd
        return target != before
    }

    /// テンプレートから新しいクリップを作る土台(保存した写しそのまま。id だけ新しいものにする)。
    /// 長さが 0 以下のテンプレートは 2 秒にする(タイムラインで見える最低限の長さ)。
    public func makeClip() -> Clip {
        var c = clip
        c.id = newId()
        c.start = 0
        if !(c.duration > 0) { c.duration = 2 }
        return c
    }
}

/// アイテムテンプレートの組み込み分と、名前の整理・一覧の決まり。
public enum ItemTemplateLibrary {
    public static let builtinPrefix = "builtin."
    public static let maxUserTemplates = 100
    public static let maxNameLength = 60

    /// 組み込みテンプレート(アプリに同梱。消せない・変えられない)。
    public static let builtins: [ItemTemplate] = [
        ItemTemplate(id: "builtin.voiceSubtitle", name: "字幕・標準(ボイス)", clip: {
            var c = Clip(); c.type = .voice; c.duration = 2
            c.fontSize = 64; c.color = "#ffffff"; c.outline = "#000000"
            c.font = defaultFonts[0]; c.subtitle = true; c.volume = 1
            return c
        }()),
        ItemTemplate(id: "builtin.headingText", name: "見出し(文字)", clip: {
            var c = Clip(); c.type = .text; c.duration = 2
            c.fontSize = 120; c.color = "#ffffff"; c.outline = "#3e2723"
            c.font = defaultFonts[0]; c.opacity = 1; c.x = 0.5; c.y = 0.2
            var s = TextStyle()
            s.gradient = .init(color1: "#fff176", color2: "#ff7043", angle: 90)
            s.shadow = .init(color: "#000000", dx: 3, dy: 5, blur: 6, opacity: 0.6)
            c.textStyle = s.normalized
            c.textAnim = TextAnim(kind: TextAnimKind.pop.rawValue, duration: 0.5)
            return c
        }()),
        ItemTemplate(id: "builtin.blurStandard", name: "ぼかし・標準", clip: {
            var c = Clip(); c.type = .blur; c.duration = 2
            c.x = 0.5; c.y = 0.5; c.w = 0.5; c.h = 0.25
            c.strength = 30; c.shape = "rect"
            return c
        }()),
    ]

    /// 名前を整える(前後の空白を除く、改行は空白に、最大の長さまで)。空なら nil。
    public static func sanitizedName(_ s: String) -> String? {
        let t = s.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : String(t.prefix(maxNameLength))
    }

    /// 組み込み + 保存したもの。
    public static func all(user: [ItemTemplate]) -> [ItemTemplate] { builtins + user }

    public static func find(_ id: String, user: [ItemTemplate]) -> ItemTemplate? {
        all(user: user).first { $0.id == id }
    }

    /// 名前で探す(メニューから選ぶとき用。大文字小文字は区別しない)。
    public static func find(name: String, user: [ItemTemplate]) -> ItemTemplate? {
        all(user: user).first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// 末尾に足す。足した id を返す。名前が空・上限・組み込みと同じ id なら nil。同じ名前は「名前 2」のように避ける。
    @discardableResult
    public static func add(_ list: inout [ItemTemplate], _ template: ItemTemplate) -> String? {
        guard list.count < maxUserTemplates, !template.id.hasPrefix(builtinPrefix) else { return nil }
        var t = template
        let existing = all(user: list).map(\.name)
        t.name = ProjectTemplate.uniqueName(base: t.name, existing: existing)
        list.append(t)
        return t.id
    }

    @discardableResult
    public static func delete(_ list: inout [ItemTemplate], id: String) -> Bool {
        guard let i = list.firstIndex(where: { $0.id == id }) else { return false }
        list.remove(at: i)
        return true
    }
}

/// アイテムテンプレートの保存先(Templates フォルダの中の JSON 1 ファイル)。
/// 形式は `{"version":1,"templates":[...]}`。読むときは寛容に(壊れた項目は捨てる)、書くときは決まった形で。
public struct ItemTemplateStore {
    public static let fileName = "item-templates.json"

    public let directory: URL
    public init(directory: URL) { self.directory = directory }

    public var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    /// 既定の保存先(プロジェクトテンプレートと同じ Templates フォルダ)。
    public static func standard() -> ItemTemplateStore? {
        let dir = DataLocations.current.templates
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return ItemTemplateStore(directory: dir)
    }

    private struct Failable: Decodable {
        let value: ItemTemplate?
        init(from decoder: Decoder) throws { value = try? ItemTemplate(from: decoder) }
    }
    private struct FileBody: Decodable { var templates: [Failable]? }

    /// 保存したテンプレートを読む。ファイルが無い・壊れているときは空。組み込みと同じ id・重複 id は捨てる。
    public func load() -> [ItemTemplate] {
        guard let data = try? Data(contentsOf: fileURL),
              let body = try? JSONDecoder().decode(FileBody.self, from: data),
              let items = body.templates else { return [] }
        var seen = Set<String>()
        var out: [ItemTemplate] = []
        for item in items.compactMap(\.value) {
            guard !item.id.isEmpty, !item.id.hasPrefix(ItemTemplateLibrary.builtinPrefix),
                  seen.insert(item.id).inserted,
                  let n = ItemTemplateLibrary.sanitizedName(item.name) else { continue }
            var t = item; t.name = n
            out.append(t)
            if out.count >= ItemTemplateLibrary.maxUserTemplates { break }
        }
        return out
    }

    /// 保存(一時ファイルを経由して置き換える)。
    public func save(_ templates: [ItemTemplate]) throws {
        struct Body: Encodable { var version = 1; var templates: [ItemTemplate] }
        let data = try JSONEncoder().encode(Body(templates: Array(templates.prefix(ItemTemplateLibrary.maxUserTemplates))))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }

    /// クリップからテンプレートを作って保存する。保存したテンプレート(名前の重なりを避けたあと)を返す。
    @discardableResult
    public func save(clip: Clip, as rawName: String) throws -> ItemTemplate? {
        guard let t = ItemTemplate.capture(name: rawName, from: clip) else { return nil }
        var list = load()
        guard ItemTemplateLibrary.add(&list, t) != nil else { return nil }
        try save(list)
        return list.last
    }
}

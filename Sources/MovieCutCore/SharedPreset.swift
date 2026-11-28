import Foundation

// MARK: - プリセット共有ファイル(.mcpreset)
//
// 種別をまたいで使える共通の共有ファイル形式。JSON(データのみ。コード・スクリプト・実行要素は持たない)。
// 本体(payload)は既存の型(CustomExportPreset / VoicePreset / ItemTemplate / Effect / GradeNode)の
// 既存の検査経路を通して読むので、変換のための二重の型は持たない。既存の保存形式・保存先は変えない。
// 仕様: docs/プリセット共有ファイル.md

/// 共有できる種別。rawValue がファイルの `kind`。
public enum SharedPresetKind: String, CaseIterable, Sendable {
    case exportPreset = "export-preset"
    case voicePreset = "voice-preset"
    case itemTemplate = "item-template"
    case colorCorrection = "color-correction"
    case gradeNodes = "grade-nodes"

    public var label: String {
        switch self {
        case .exportPreset: return "書き出しプリセット"
        case .voicePreset: return "音声プリセット"
        case .itemTemplate: return "アイテムテンプレート"
        case .colorCorrection: return "色補正(ホイール/カーブ)"
        case .gradeNodes: return "グレーディングノード"
        }
    }
}

/// 読み込んだ中身。
public enum SharedPresetContent: Equatable, Sendable {
    case exportPreset(CustomExportPreset)
    case voicePreset(VoicePreset)
    case itemTemplate(ItemTemplate)
    case colorCorrection(Effect)
    case gradeNodes([GradeNode])

    public var kind: SharedPresetKind {
        switch self {
        case .exportPreset: return .exportPreset
        case .voicePreset: return .voicePreset
        case .itemTemplate: return .itemTemplate
        case .colorCorrection: return .colorCorrection
        case .gradeNodes: return .gradeNodes
        }
    }
}

extension VoicePreset: @unchecked Sendable {}

/// 共有ファイル 1 件(メタ情報 + 中身)。
public struct SharedPreset: Equatable, Sendable {
    public var name: String
    public var author: String?
    public var description: String?
    public var content: SharedPresetContent
    public init(name: String, author: String? = nil, description: String? = nil, content: SharedPresetContent) {
        self.name = name; self.author = author; self.description = description; self.content = content
    }
    public var kind: SharedPresetKind { content.kind }
}

public enum SharedPresetFormat {
    public static let fileExtension = "mcpreset"
    /// このアプリが読める形式バージョン(これより大きいものは断る)。
    public static let currentFormatVersion = 1
    public static let maxBytes = 1_048_576
    public static let maxNameLength = 80
    public static let maxAuthorLength = 80
    public static let maxDescriptionLength = 500
    public static let maxGradeNodes = 32
    public static let appName = "MovieCut"

    /// 読み込めなかった理由(表示用の日本語つき)。
    public enum Failure: Error, Equatable, LocalizedError {
        case tooLarge
        case broken
        case missingField(String)
        case newerFormat(Int)
        case unknownKind(String)
        case invalidPayload(String)
        case notThisApp(String)
        public var errorDescription: String? {
            switch self {
            case .tooLarge: return "共有ファイルが大きすぎます(上限 1 MB)。"
            case .broken: return "共有ファイルとして読めませんでした(JSON が壊れているか、形が違います)。"
            case .missingField(let f): return "共有ファイルに必須項目「\(f)」がありません。"
            case .newerFormat(let v): return "この共有ファイルは新しい形式(バージョン \(v))です。Movie Cut を最新版にしてください。"
            case .unknownKind(let k): return "対応していない種別「\(k)」の共有ファイルです。"
            case .invalidPayload(let why): return "共有ファイルの中身を読み込めませんでした: \(why)"
            case .notThisApp(let a): return "別のアプリ(\(a))用の共有ファイルです。"
            }
        }
    }

    // MARK: 書き出し

    /// 共有ファイルの JSON(整形・キー順固定)。
    public static func encode(_ preset: SharedPreset, appVersion: String? = nil) -> Data {
        var root: [String: JSONValue] = [
            "formatVersion": .number(Double(currentFormatVersion)),
            "kind": .string(preset.kind.rawValue),
            "name": .string(String(preset.name.prefix(maxNameLength))),
            "payload": payload(of: preset.content),
        ]
        if let a = preset.author, !a.isEmpty { root["author"] = .string(String(a.prefix(maxAuthorLength))) }
        if let d = preset.description, !d.isEmpty { root["description"] = .string(String(d.prefix(maxDescriptionLength))) }
        var compat: [String: JSONValue] = ["app": .string(appName), "minFormatVersion": .number(Double(currentFormatVersion))]
        if let v = appVersion, !v.isEmpty { compat["appVersion"] = .string(v) }
        root["compat"] = .object(compat)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? enc.encode(JSONValue.object(root))) ?? Data("{}".utf8)
    }

    public static func write(_ preset: SharedPreset, to url: URL, appVersion: String? = nil) throws {
        try encode(preset, appVersion: appVersion).write(to: url, options: .atomic)
    }

    // MARK: 読み込み(互換検査つき)

    public static func decode(_ data: Data) throws -> SharedPreset {
        guard data.count <= maxBytes else { throw Failure.tooLarge }
        guard InputLimits.jsonDepthWithinLimit(data),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw Failure.broken }
        // 1) 形式バージョン(新しすぎるものを、種別の検査より先に断る)
        guard let vNum = obj["formatVersion"] as? NSNumber, CFGetTypeID(vNum) != CFBooleanGetTypeID() else { throw Failure.missingField("formatVersion") }
        let version = vNum.intValue
        guard version >= 1 else { throw Failure.broken }
        if version > currentFormatVersion { throw Failure.newerFormat(version) }
        // 2) 互換情報(あれば検査。無くてもよい)
        if let compat = obj["compat"] as? [String: Any] {
            if let app = compat["app"] as? String, app != appName { throw Failure.notThisApp(app) }
            if let m = (compat["minFormatVersion"] as? NSNumber)?.intValue, m > currentFormatVersion { throw Failure.newerFormat(m) }
        }
        // 3) 必須項目
        guard let kindRaw = obj["kind"] as? String, !kindRaw.isEmpty else { throw Failure.missingField("kind") }
        guard let rawName = obj["name"] as? String else { throw Failure.missingField("name") }
        guard obj["payload"] != nil else { throw Failure.missingField("payload") }
        let name = String(rawName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxNameLength))
        guard !name.isEmpty else { throw Failure.missingField("name") }
        guard let kind = SharedPresetKind(rawValue: kindRaw) else { throw Failure.unknownKind(kindRaw) }
        // 4) 本体
        guard let all = try? JSONDecoder().decode(JSONValue.self, from: data), case .object(let top) = all,
              let payload = top["payload"] else { throw Failure.broken }
        let content = try content(kind: kind, payload: payload)
        func opt(_ k: String, _ max: Int) -> String? {
            guard let s = (obj[k] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
            return String(s.prefix(max))
        }
        return SharedPreset(name: name, author: opt("author", maxAuthorLength),
                            description: opt("description", maxDescriptionLength), content: content)
    }

    /// ファイルから読む(通常のファイルのみ。パスやファイル名は中身の判断に使わない)。
    public static func read(from url: URL) throws -> SharedPreset {
        let data: Data
        do { data = try InputLimits.readFile(url, limit: maxBytes, what: "共有ファイル") }
        catch InputLimits.Failure.tooLarge { throw Failure.tooLarge }
        return try decode(data)
    }

    // MARK: 種別ごとの変換(既存の型・既存の検査経路を使う)

    private static func toValue<T: Encodable>(_ v: T) -> JSONValue {
        guard let d = try? JSONEncoder().encode(v), let j = try? JSONDecoder().decode(JSONValue.self, from: d) else { return .null }
        return j
    }
    private static func valueData(_ v: JSONValue) -> Data? { try? JSONEncoder().encode(v) }

    static func payload(of content: SharedPresetContent) -> JSONValue {
        switch content {
        case .exportPreset(let p):
            // 既存の保存形式(`{"version":1,"presets":[...]}`)をそのまま入れる
            return (try? JSONDecoder().decode(JSONValue.self, from: CustomExportPresetStore.encode([p]))) ?? .null
        case .voicePreset(let p):
            var d: [String: JSONValue] = ["id": .string(p.id), "name": .string(p.name), "engine": .string(p.engine)]
            if let n = p.note { d["note"] = .string(n) }
            if let v = p.voice { d["voice"] = .string(v) }
            if let s = p.speaker { d["speaker"] = .number(Double(s)) }
            if let v = p.speed { d["speed"] = .number(v) }
            if let v = p.pitch { d["pitch"] = .number(v) }
            if let v = p.intonation { d["intonation"] = .number(v) }
            if let v = p.volume { d["volume"] = .number(v) }
            return .object(d)
        case .itemTemplate(let t): return toValue(t)
        case .colorCorrection(let e): return toValue(sanitizedColorEffect(e))
        case .gradeNodes(let n): return toValue(n.map(sanitizedNode))
        }
    }

    public static let colorKinds: Set<String> = [EffectKind.colorWheels.rawValue, EffectKind.colorCurves.rawValue]

    /// ファイルの場所は共有しない(他人の PC のパスは意味がなく、危険にもなる)。
    private static func sanitizedColorEffect(_ e: Effect) -> Effect { var x = e; x.path = nil; return x }
    private static func sanitizedNode(_ n: GradeNode) -> GradeNode {
        var x = n
        x.effects = n.effects.map(sanitizedColorEffect)
        return x
    }

    static func content(kind: SharedPresetKind, payload: JSONValue) throws -> SharedPresetContent {
        func bad(_ s: String) -> Failure { .invalidPayload(s) }
        guard let data = valueData(payload) else { throw bad("本体を読めません") }
        switch kind {
        case .exportPreset:
            guard case .object = payload else { throw bad("書き出しプリセットの形が違います") }
            let list = CustomExportPresetStore.decode(data)
            guard list.count == 1, let p = list.first else { throw bad("解像度・コーデックなどの値が範囲外か、名前が使えません") }
            return .exportPreset(p)
        case .voicePreset:
            guard case .object = payload,
                  let wrapped = try? JSONEncoder().encode(JSONValue.object(["schemaVersion": .number(1), "presets": .array([payload])])),
                  let cat = try? VoicePresetCatalog.decode(wrapped), cat.presets.count == 1, let p = cat.presets.first
            else { throw bad("エンジンや名前などが読めません") }
            return .voicePreset(p)
        case .itemTemplate:
            guard var t = try? JSONDecoder().decode(ItemTemplate.self, from: data) else { throw bad("テンプレートの形が違います") }
            guard let n = ItemTemplateLibrary.sanitizedName(t.name) else { throw bad("テンプレート名が空です") }
            t.name = n
            t.slots = ItemTemplate.normalizedSlots(t.slots, for: t.clip)
            // 読み込み側で新しい id を付ける(組み込み・既存と衝突させない)
            t.id = UUID().uuidString
            return .itemTemplate(t)
        case .colorCorrection:
            guard var e = try? JSONDecoder().decode(Effect.self, from: data) else { throw bad("エフェクトの形が違います") }
            guard colorKinds.contains(e.kind) else { throw bad("色補正(ホイール/カーブ)ではありません: \(e.kind)") }
            e.path = nil
            return .colorCorrection(e)
        case .gradeNodes:
            guard var nodes = try? JSONDecoder().decode([GradeNode].self, from: data) else { throw bad("ノード列の形が違います") }
            guard !nodes.isEmpty, nodes.count <= maxGradeNodes else { throw bad("ノードの数が 1〜\(maxGradeNodes) ではありません") }
            for i in nodes.indices {
                for j in nodes[i].effects.indices {
                    guard let k = nodes[i].effects[j].known, GradeNode.allowedKinds.contains(k) else {
                        throw bad("ノードで使えないエフェクトがあります: \(nodes[i].effects[j].kind)")
                    }
                    nodes[i].effects[j].path = nil
                }
                nodes[i].id = UUID().uuidString
            }
            return .gradeNodes(nodes)
        }
    }

    // MARK: 既存の適用経路へ渡す

    /// 色補正をクリップのエフェクト列の末尾へ足す(既存の `EffectEditing.append`)。
    @discardableResult
    public static func apply(colorCorrection e: Effect, to clip: inout Clip) -> Bool { EffectEditing.append(&clip, [e]) }

    /// ノード列をクリップへ足す(既存の `GradeNodeEditing.add`)。
    @discardableResult
    public static func apply(gradeNodes nodes: [GradeNode], to clip: inout Clip) -> Bool {
        var ok = false
        for n in nodes { ok = GradeNodeEditing.add(&clip, n) || ok }
        return ok
    }
}

// MARK: - 読み込んだ中身を既存の一覧へ入れる(既存の保存形式・保存先のまま)

public enum SharedPresetLibrary {
    /// 書き出しプリセットの一覧(export-presets.json)へ入れる。同名は置き換え。上限なら nil。
    @discardableResult
    public static func add(_ p: CustomExportPreset, toExportPresetsAt url: URL) -> Bool {
        let current = CustomExportPresetStore.load(from: url)
        guard let merged = CustomExportPresetStore.upserting(p, into: current) else { return false }
        return (try? CustomExportPresetStore.save(merged, to: url)) != nil
    }

    /// アイテムテンプレートの一覧(item-templates.json)へ入れる。同名は「名前 2」に避ける。
    @discardableResult
    public static func add(_ t: ItemTemplate, to store: ItemTemplateStore) -> Bool {
        var list = store.load()
        guard ItemTemplateLibrary.add(&list, t) != nil else { return false }
        return (try? store.save(list)) != nil
    }
}

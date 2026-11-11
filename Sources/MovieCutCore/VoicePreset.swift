import Foundation

/// おすすめ音声設定 1 件。声のパラメータだけを持つ(キャラの名前・色・画像などは持たない)。
public struct VoicePreset: Equatable, Identifiable {
    public var id: String
    public var name: String
    public var note: String?
    public var engine: String          // "voicevox" | "aquestalk"
    public var voice: String?
    public var speaker: Int?
    public var speed: Double?
    public var pitch: Double?
    public var intonation: Double?
    /// 読み込んで範囲に収めるだけ。キャラクターには音量の項目が無いので、適用では使わない。
    public var volume: Double?
}

/// おすすめ音声設定の一覧(配布用 JSON)。形式は docs/おすすめ音声設定の配布.md。
public struct VoicePresetCatalog: Equatable {
    public static let maxBytes = 256 * 1024
    public static let maxPresets = 200
    public static let maxNameLength = 40
    public static let maxNoteLength = 200
    public static let supportedSchemaVersion = 1

    public var presets: [VoicePreset]

    public enum Failure: Error, Equatable, LocalizedError {
        case tooLarge
        case invalid
        case newerVersion(Int)
        public var errorDescription: String? {
            switch self {
            case .tooLarge: return "おすすめ音声設定のファイルが大きすぎます(上限 256 KB)。"
            case .invalid: return "おすすめ音声設定として読めませんでした。ファイルの形式を確認してください。"
            case .newerVersion: return "このおすすめ音声設定は新しい形式です。Movie Cut を最新版にしてください。"
            }
        }
    }

    public static func decode(_ data: Data) throws -> VoicePresetCatalog {
        guard data.count <= maxBytes else { throw Failure.tooLarge }
        guard InputLimits.jsonDepthWithinLimit(data),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw Failure.invalid }
        let version = (root["schemaVersion"] as? NSNumber)?.intValue ?? 1
        if version > supportedSchemaVersion { throw Failure.newerVersion(version) }
        guard let raw = root["presets"] as? [Any] else { throw Failure.invalid }
        var out: [VoicePreset] = []
        var seen = Set<String>()
        for item in raw.prefix(maxPresets) {
            guard let d = item as? [String: Any], let p = preset(from: d), seen.insert(p.id).inserted else { continue }
            out.append(p)
        }
        return VoicePresetCatalog(presets: out)
    }

    private static func string(_ d: [String: Any], _ k: String) -> String? { d[k] as? String }
    private static func number(_ d: [String: Any], _ k: String) -> Double? {
        guard let n = d[k] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let v = n.doubleValue
        return v.isFinite ? v : nil
    }

    private static func preset(from d: [String: Any]) -> VoicePreset? {
        let name = String((string(d, "name") ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxNameLength))
        guard !name.isEmpty else { return nil }
        let engine = string(d, "engine") ?? "voicevox"
        guard engine == "voicevox" || engine == "aquestalk" else { return nil }
        let idRaw = (string(d, "id") ?? name).trimmingCharacters(in: .whitespacesAndNewlines)
        let note = string(d, "note").map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxNoteLength)) }.flatMap { $0.isEmpty ? nil : $0 }
        var speaker: Int?
        if let s = number(d, "speaker") { speaker = Int(max(0, min(100000, s.rounded()))) }
        let voice = string(d, "voice").map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxNameLength)) }.flatMap { $0.isEmpty ? nil : $0 }
        let voiceCanon = AquesTalkPresets.canonicalVoice(voice)
        func f(_ k: String, _ field: CharacterField) -> Double? { number(d, k).map { field.clamp($0, engine: engine) } }
        return VoicePreset(id: String(idRaw.prefix(80)), name: name, note: note, engine: engine, voice: voiceCanon, speaker: speaker,
                           speed: f("speed", .speed), pitch: f("pitch", .pitch), intonation: f("intonation", .intonation),
                           volume: number(d, "volume").map { min(max($0, 0), 2) })
    }

    /// 声に関する項目だけを書き換える。名前・色・立ち絵などはそのまま。
    public static func applying(_ preset: VoicePreset, to character: Character) -> Character {
        var c = character
        c.engine = preset.engine
        c.voice = preset.voice
        c.speaker = preset.speaker
        c.speed = preset.speed
        c.pitch = preset.pitch
        c.intonation = preset.intonation
        CharacterEditing.switchEngine(&c, to: preset.engine)   // 足りない項目を標準値で埋める
        return c
    }
}

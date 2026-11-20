import Foundation

/// YMM4(ゆっくりMovieMaker4)のプロジェクトファイル `.ymmp` を、MovieCut の `Project` へ変換するインポーター(プロトタイプ)。
///
/// ## 形式の根拠(2026-11-17 調査)
/// - YMM4 の `.ymmp` は **JSON 形式**。YMM3 の `.ymmp` は XML 形式で互換性はない(形式が違うので、この読み込みではエラーになる)。
///   出典: FileInfo「.YMMP File Extension」、SIOS 技術ブログ「動画生成できないClaudeに『ゆっくり解説動画』を作らせてみた」、
///   Zenn「Anatomy of the YMMP File Format」、迷惑堂本舗「ゆっくりMovieMaker4βのymmpファイルを作成する」。
/// - 公開されていた実ファイル(UTF-8 BOM 付き JSON)を実物確認した。最上位は `Timelines`(配列)/ `Characters` / `SelectedTimelineIndex`、
///   タイムラインは `VideoInfo`(`FPS` / `Hz` / `Width` / `Height`)と `Items` を持つ。
/// - ファイル先頭に `_` が 1 文字付く場合がある(Zenn の記事)。実物サンプルでは付いていなかったため、付いていても受け付ける。
/// - アイテム共通: `$type`(例: `YukkuriMovieMaker.Project.Items.VoiceItem, YukkuriMovieMaker`)、`Frame`(開始フレーム)、
///   `Length`(長さフレーム)、`Layer`、`Group`、`IsLocked`、`IsHidden`。秒への換算は `VideoInfo.FPS` で割る。
/// - `VoiceItem`: `CharacterName`、`Serif`(字幕に出る文字)、`Hatsuon`(発音)を確認済み。
/// - `ImageItem`: `FilePath` を確認済み(迷惑堂本舗の作成スクリプト)。
///
/// ## 推測を含む箇所(実物で未確認。実ファイルが手に入ったら要検証)
/// - `TextItem` の本文キー `Text`、`VideoItem` / `AudioItem` の `FilePath` は、`ImageItem` との設計の一貫性からの推定。
/// - `FadeIn` / `FadeOut` は秒として扱う(YMM4 の UI 表示が秒単位のため)。
/// - 音量(`Volume`)は換算基準(何 % が等倍か)が実物だけでは確定できないため、プロトタイプでは引き継がない(レポートに注記する)。
/// - 位置(`X` / `Y`、ピクセル・Y は上向き正)は画面比へ近似換算する。基準点(BasePoint)の違いで表示位置がずれる場合がある。
///
/// ## 変換の方針
/// - 読み取り専用。元の `.ymmp` は変更しない。
/// - ファイル全体の構造が壊れている場合は、部分変換でごまかさず `Failure` を投げる。
/// - 個別のアイテムで対応できないもの(未対応の種類・エフェクト・キーフレーム等)は、変換レポートの「読み飛ばし一覧」に残す。
public enum YmmpImporter {

    // MARK: - レポート

    /// 変換できなかったアイテム 1 件分。
    public struct Skipped: Equatable {
        /// アイテムの種類名(例: `TachieItem`)。読めなかったときは空文字。
        public var typeName: String
        /// 人が識別するための短いラベル(セリフ・本文・ファイル名など)。
        public var label: String
        /// 読み飛ばした理由。
        public var reason: String
        public init(typeName: String, label: String, reason: String) {
            self.typeName = typeName; self.label = label; self.reason = reason
        }
    }

    /// 変換レポート。何が変換できて、何が落ちたかを呼び出し側(UI / CLI)が利用者に見せるためのもの。
    public struct Report: Equatable {
        /// 変換元のタイムラインの FPS。
        public var sourceFPS: Double = 0
        /// 変換したタイムラインの名前。
        public var timelineName: String = ""
        /// 変換元にあったタイムラインの総数(変換するのは選択中の 1 つだけ)。
        public var timelineCount: Int = 1
        /// 種類ごとの変換件数(キーは `voice` / `text` / `image` / `video` / `audio`)。
        public var convertedCounts: [String: Int] = [:]
        /// 変換できなかったアイテムの一覧。
        public var skipped: [Skipped] = []
        /// 落ちたエフェクトの総数(対応する MovieCut の表現が無いため)。
        public var droppedEffectCount: Int = 0
        /// キーフレーム / アニメーションが落ちたアイテムの件数。
        public var droppedKeyframeItemCount: Int = 0
        /// 変換時の注記(近似・未引き継ぎの項目など)。
        public var notes: [String] = []
        public init() {}
        /// 変換できたアイテムの総数。
        public var convertedCount: Int { convertedCounts.values.reduce(0, +) }
    }

    /// 変換結果。
    public struct Output {
        public var project: Project
        public var report: Report
        public init(project: Project, report: Report) { self.project = project; self.report = report }
    }

    /// ファイル全体を変換できない理由。
    public enum Failure: Error, Equatable {
        /// JSON として読めない(YMM3 の XML 形式など)。
        case notJSON
        /// JSON ではあるが、最上位の構造がプロジェクトではない。
        case notProject
        /// タイムライン(`Timelines` / `Timeline`)が無い。
        case noTimeline
        /// `VideoInfo.FPS` が正の数でない。
        case invalidFPS
        /// `Items` が配列でない。
        case malformedItems
    }

    // MARK: - 入口

    /// `.ymmp` のデータ(JSON)を変換する。元のデータは変更しない。
    public static func convert(data: Data) throws -> Output {
        let root = try parseRoot(data)
        let timelines = try pickTimelines(root)
        let timeline = timelines.selected
        var report = Report()
        report.timelineCount = timelines.all.count
        if timelines.all.count > 1 {
            report.notes.append("タイムラインが \(timelines.all.count) 個あります。選択中の 1 つだけを変換しました")
        }
        report.timelineName = timeline["Name"] as? String ?? ""

        // 映像の基本情報
        let info = timeline["VideoInfo"] as? [String: Any] ?? [:]
        let fps: Double
        if let raw = info["FPS"] {
            guard let v = number(raw), v > 0, v.isFinite else { throw Failure.invalidFPS }
            fps = v
        } else {
            fps = 60
            report.notes.append("VideoInfo.FPS が無いため 60fps として変換しました")
        }
        report.sourceFPS = fps
        let width = int(info["Width"]) ?? 1920
        let height = int(info["Height"]) ?? 1080

        // アイテム
        let rawItems: [Any]
        if let v = timeline["Items"] {
            guard let arr = v as? [Any] else { throw Failure.malformedItems }
            rawItems = arr
        } else {
            rawItems = []
            report.notes.append("タイムラインに Items がありません")
        }

        var conv = Converter(fps: fps, width: width, height: height, characters: root["Characters"] as? [Any] ?? [])
        var clipsByLayer: [Int: [Clip]] = [:]
        for raw in rawItems {
            guard let item = raw as? [String: Any] else {
                report.skipped.append(Skipped(typeName: "", label: "", reason: "アイテムがオブジェクトではありません"))
                continue
            }
            if let placed = conv.convert(item, report: &report) {
                clipsByLayer[placed.layer, default: []].append(placed.clip)
            }
        }

        // プロジェクトの組み立て
        var project = Project()
        project.width = min(max(width, 16), 16384)
        project.height = min(max(height, 16), 16384)
        project.fps = min(max(fps, 1), 240)
        if fps > 240 { report.notes.append("FPS が 240 を超えていたため 240 に丸めました") }
        if !conv.characters.isEmpty { project.characters = conv.characters }
        if !clipsByLayer.isEmpty {
            // YMM4 はレイヤー番号が大きいほど手前、MovieCut は後のトラックほど手前に描く。昇順で並べれば一致する。
            project.tracks = clipsByLayer.keys.sorted().map { layer in
                var t = Track(name: "レイヤー\(layer + 1)")
                t.clips = clipsByLayer[layer]!.sorted { $0.start < $1.start }
                return t
            }
        }
        project.mediaPool = conv.mediaPool
        report.notes.append(contentsOf: conv.notes)
        return Output(project: project, report: report)
    }

    /// `.ymmp` ファイルを読んで変換する(読み取り専用。ファイルは変更しない)。
    public static func load(fileAt url: URL) throws -> Output {
        try convert(data: InputLimits.readFile(url, limit: InputLimits.maxYmmpBytes, what: ".ymmp ファイル"))
    }

    /// 変換元ファイル名から、変換後の保存先 URL を作る。拡張子は `ProjectFileExtension.current` を使う(1 箇所で管理)。
    public static func outputURL(forSourceFile url: URL, in directory: URL) -> URL {
        directory.appendingPathComponent(ProjectFileExtension.fileName(replacingExtensionOf: url.lastPathComponent))
    }

    // MARK: - JSON の下ごしらえ

    /// BOM と先頭の `_` を取り除いて、最上位オブジェクトを取り出す。
    private static func parseRoot(_ data: Data) throws -> [String: Any] {
        var bytes = [UInt8](data)
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }  // UTF-8 BOM
        var i = 0
        while i < bytes.count, bytes[i] == 0x20 || bytes[i] == 0x09 || bytes[i] == 0x0D || bytes[i] == 0x0A { i += 1 }
        if i < bytes.count, bytes[i] == 0x5F { bytes.remove(at: i) }  // 先頭の "_" (Zenn の記事で報告あり)
        let obj: Any
        do {
            obj = try JSONSerialization.jsonObject(with: Data(bytes))
        } catch {
            throw Failure.notJSON
        }
        guard let root = obj as? [String: Any] else { throw Failure.notProject }
        return root
    }

    /// `Timelines`(現行形式)から選択中のものを、無ければ `Timeline`(β 期の単数形式)を取る。
    private static func pickTimelines(_ root: [String: Any]) throws -> (selected: [String: Any], all: [[String: Any]]) {
        if let arr = root["Timelines"] as? [Any] {
            let dicts = arr.compactMap { $0 as? [String: Any] }
            guard let first = dicts.first else { throw Failure.noTimeline }
            var idx = int(root["SelectedTimelineIndex"]) ?? 0
            if !dicts.indices.contains(idx) { idx = 0 }
            return (dicts[idx], dicts)
        }
        if let single = root["Timeline"] as? [String: Any] {
            return (single, [single])
        }
        throw Failure.noTimeline
    }

    // MARK: - 値の取り出し(JSONSerialization の型に寛容に)

    /// 数値(Bool は除く)。
    static func number(_ v: Any?) -> Double? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n.doubleValue
    }
    static func int(_ v: Any?) -> Int? { number(v).map { Int($0) } }
    static func string(_ v: Any?) -> String? { v as? String }
    static func bool(_ v: Any?) -> Bool? {
        if let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue }
        return nil
    }

    /// YMM4 のアニメーション可能な値: `{ "Values": [{ "Value": x }], "Span": ..., "AnimationType": ... }`(現行形式)、
    /// または `{ "From": x, "To": y, ... }`(β 期の形式)、または素の数値。先頭の値を取る。
    static func animValue(_ v: Any?) -> Double? {
        if let d = number(v) { return d }
        guard let dict = v as? [String: Any] else { return nil }
        if let values = dict["Values"] as? [Any], let first = values.first as? [String: Any] {
            return number(first["Value"])
        }
        return number(dict["From"])
    }

    /// アニメーション(キーフレーム的な動き)が付いているか。
    static func animHasMotion(_ v: Any?) -> Bool {
        guard let dict = v as? [String: Any] else { return false }
        if let values = dict["Values"] as? [Any], values.count > 1 { return true }
        if let type = dict["AnimationType"] as? String, type != "なし" { return true }
        if let from = number(dict["From"]), let to = number(dict["To"]), from != to { return true }
        return false
    }

    /// .NET の TimeSpan 文字列(`[d.]hh:mm:ss[.fffffff]`)を秒にする。
    static func timeSpanSeconds(_ s: String) -> Double? {
        var t = s.trimmingCharacters(in: .whitespaces)
        var sign = 1.0
        if t.hasPrefix("-") { sign = -1; t.removeFirst() }
        let parts = t.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3 else { return nil }
        var days = 0.0
        var hourPart = parts[0]
        if let dot = hourPart.firstIndex(of: ".") {
            guard let d = Double(String(hourPart[..<dot])) else { return nil }
            days = d
            hourPart = String(hourPart[hourPart.index(after: dot)...])
        }
        guard let h = Double(hourPart), let m = Double(parts[1]), let sec = Double(parts[2]) else { return nil }
        return sign * (days * 86400 + h * 3600 + m * 60 + sec)
    }

    /// `#AARRGGBB` / `#RRGGBB` を MovieCut の `#rrggbb` にする。
    static func rgb(_ s: String?) -> String? {
        guard var hex = s?.trimmingCharacters(in: .whitespaces), hex.hasPrefix("#") else { return nil }
        hex.removeFirst()
        if hex.count == 8 { hex.removeFirst(2) }  // アルファを落とす
        guard hex.count == 6, hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        return "#" + hex.lowercased()
    }

    /// Windows のパス区切りを `/` にそろえる(素材の探し直しが効くように)。
    static func normalizedPath(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "/")
    }

    // MARK: - 変換の本体

    private struct Converter {
        var fps: Double
        var width: Int
        var height: Int
        /// 変換元のキャラクター定義(名前引き用)。
        var rawCharacters: [String: [String: Any]] = [:]
        /// MovieCut 側のキャラクター(変換済み)。
        var characters: [Character] = []
        var charIdByName: [String: String] = [:]
        var mediaPool: [String] = []
        var notes: [String] = []
        private var notedWindowsPath = false
        private var notedPosition = false
        private var notedVolume = false

        init(fps: Double, width: Int, height: Int, characters raw: [Any]) {
            self.fps = fps; self.width = width; self.height = height
            for case let dict as [String: Any] in raw {
                guard let name = YmmpImporter.string(dict["Name"]), !name.isEmpty else { continue }
                rawCharacters[name] = dict
                let c = Self.convertCharacter(name: name, dict: dict, notes: &notes)
                characters.append(c)
                charIdByName[name] = c.id
            }
        }

        /// YMM4 のキャラクター定義を MovieCut の `Character` にする。
        private static func convertCharacter(name: String, dict: [String: Any], notes: inout [String]) -> Character {
            var c = Character()
            c.name = name
            let voice = dict["Voice"] as? [String: Any]
            let api = (voice?["API"] as? String ?? "").lowercased()
            let param = dict["VoiceParameter"] as? [String: Any]
            let paramType = param?["$type"] as? String ?? ""
            if api == "voicevox" {
                c.engine = "voicevox"
                if paramType.contains("VOICEVOXVoiceParameter"), let style = YmmpImporter.int(param?["StyleID"]) {
                    c.speaker = style
                }
            } else if api.contains("aquestalk") {
                c.engine = "aquestalk"
            } else if !api.isEmpty {
                notes.append("キャラクター「\(name)」の音声エンジン(\(api))は未対応のため、VOICEVOX として読み込みました")
                c.engine = "voicevox"
            }
            if let color = YmmpImporter.rgb(dict["Color"] as? String) { c.color = color }
            if let sub = YmmpImporter.rgb(dict["FontColor"] as? String) { c.subtitleColor = sub }
            return c
        }

        /// キャラクター名から charId を引く。定義が無ければ、その場で作る。
        mutating func charId(for name: String?) -> String? {
            guard let name, !name.isEmpty else { return nil }
            if let id = charIdByName[name] { return id }
            var c = Character()
            c.name = name
            characters.append(c)
            charIdByName[name] = c.id
            notes.append("キャラクター「\(name)」の定義が無いため、既定の声で作りました")
            return c.id
        }

        /// アイテム 1 件を変換する。変換できないものはレポートに積んで nil を返す。
        mutating func convert(_ item: [String: Any], report: inout Report) -> (clip: Clip, layer: Int)? {
            let typeName = Self.typeName(of: item)
            let label = Self.label(of: item, typeName: typeName)
            guard let typeName else {
                report.skipped.append(Skipped(typeName: "", label: label, reason: "$type が無いため種類を判定できません"))
                return nil
            }
            guard let frame = YmmpImporter.int(item["Frame"]), let length = YmmpImporter.int(item["Length"]) else {
                report.skipped.append(Skipped(typeName: typeName, label: label, reason: "Frame / Length が読めません"))
                return nil
            }
            guard length > 0 else {
                report.skipped.append(Skipped(typeName: typeName, label: label, reason: "長さ(Length)が 0 以下です"))
                return nil
            }
            let layer = YmmpImporter.int(item["Layer"]) ?? 0

            var clip = Clip()
            clip.start = max(0, Double(frame) / fps)
            clip.duration = Double(length) / fps
            if YmmpImporter.bool(item["IsLocked"]) == true { clip.locked = true }

            switch typeName {
            case "VoiceItem":
                guard convertVoice(item, into: &clip, report: &report) else { return nil }
            case "TextItem":
                guard let text = YmmpImporter.string(item["Text"]), !text.isEmpty else {
                    report.skipped.append(Skipped(typeName: typeName, label: label, reason: "本文(Text)がありません"))
                    return nil
                }
                clip.type = .text
                clip.text = text
                applyTextStyle(item, into: &clip)
                applyPosition(item, into: &clip)
            case "ImageItem", "VideoItem", "AudioItem":
                guard let path = YmmpImporter.string(item["FilePath"]), !path.isEmpty else {
                    report.skipped.append(Skipped(typeName: typeName, label: label, reason: "ファイルパス(FilePath)がありません"))
                    return nil
                }
                clip.type = typeName == "ImageItem" ? .image : (typeName == "VideoItem" ? .video : .audio)
                clip.src = YmmpImporter.normalizedPath(path)
                if let src = clip.src, !mediaPool.contains(src) { mediaPool.append(src) }
                if path.contains("\\") || path.contains(":") {
                    if !notedWindowsPath {
                        notes.append("素材のパスは変換元の環境(Windows)のものです。開けない素材は「素材の探し直し」で指定し直してください")
                        notedWindowsPath = true
                    }
                }
                if let offsetText = YmmpImporter.string(item["ContentOffset"]), let sec = YmmpImporter.timeSpanSeconds(offsetText) {
                    clip.offset = sec
                }
                if let rate = YmmpImporter.number(item["PlaybackRate"]), rate > 0, abs(rate - 100) > 0.001 {
                    clip.speed = rate / 100
                }
                if typeName != "AudioItem" {
                    if let zoom = YmmpImporter.animValue(item["Zoom"]) { clip.scale = zoom / 100 }
                    applyPosition(item, into: &clip)
                }
                if let opacity = YmmpImporter.animValue(item["Opacity"]) { clip.opacity = opacity / 100 }
            default:
                report.skipped.append(Skipped(typeName: typeName, label: label, reason: "未対応のアイテム種類です"))
                return nil
            }

            // 共通: フェード、音量(未引き継ぎの注記)、エフェクト/キーフレームの落下数
            if let fadeIn = YmmpImporter.number(item["FadeIn"]), fadeIn > 0 { clip.fadeIn = fadeIn }
            if let fadeOut = YmmpImporter.number(item["FadeOut"]), fadeOut > 0 { clip.fadeOut = fadeOut }
            if item["Volume"] != nil, !notedVolume {
                notes.append("音量(Volume)は換算基準が未確定のため引き継いでいません")
                notedVolume = true
            }
            var effectCount = 0
            for key in ["VideoEffects", "AudioEffects", "JimakuVideoEffects", "TachieFaceEffects", "TachieItemVideoEffects"] {
                if let arr = item[key] as? [Any] { effectCount += arr.count }
            }
            if effectCount > 0 { report.droppedEffectCount += effectCount }
            var hasMotion = false
            if let kf = item["KeyFrames"] as? [String: Any] {
                if let frames = kf["Frames"] as? [Any], !frames.isEmpty { hasMotion = true }
                if let count = YmmpImporter.int(kf["Count"]), count > 0 { hasMotion = true }
            }
            if !hasMotion {
                hasMotion = ["X", "Y", "Zoom", "Opacity", "Rotation"].contains { YmmpImporter.animHasMotion(item[$0]) }
            }
            if hasMotion { report.droppedKeyframeItemCount += 1 }

            report.convertedCounts[clip.type.rawValue, default: 0] += 1
            return (clip, layer)
        }

        /// VoiceItem → ボイスクリップ。字幕文(`Serif`)と発音(`Hatsuon`)を MovieCut の
        /// `subtitleText`(字幕に出す文)と `text`(読み上げる文)に対応させる。
        private mutating func convertVoice(_ item: [String: Any], into clip: inout Clip, report: inout Report) -> Bool {
            let label = Self.label(of: item, typeName: "VoiceItem")
            guard let serif = YmmpImporter.string(item["Serif"]), !serif.isEmpty else {
                report.skipped.append(Skipped(typeName: "VoiceItem", label: label, reason: "セリフ(Serif)がありません"))
                return false
            }
            clip.type = .voice
            let hatsuon = YmmpImporter.string(item["Hatsuon"]).flatMap { $0.isEmpty ? nil : $0 }
            clip.text = hatsuon ?? serif
            if let hatsuon, hatsuon != serif { clip.subtitleText = serif }
            let charName = YmmpImporter.string(item["CharacterName"])
            clip.charId = charId(for: charName)
            // 字幕の表示/非表示: アイテム指定が優先、無ければキャラクター設定に従う
            let visibility = YmmpImporter.string(item["JimakuVisibility"])
            if visibility == "Hidden" {
                clip.subtitle = false
            } else if let charName, let raw = rawCharacters[charName] {
                clip.subtitle = YmmpImporter.bool(raw["IsJimakuVisible"]) ?? true
            } else {
                clip.subtitle = true
            }
            if let size = YmmpImporter.animValue(item["FontSize"]) { clip.fontSize = size }
            if let font = YmmpImporter.string(item["Font"]), !font.isEmpty { clip.font = font }
            if let color = YmmpImporter.rgb(YmmpImporter.string(item["FontColor"])) { clip.color = color }
            return true
        }

        /// TextItem の文字スタイル(分かる範囲だけ)。
        private func applyTextStyle(_ item: [String: Any], into clip: inout Clip) {
            if let size = YmmpImporter.animValue(item["FontSize"]) { clip.fontSize = size }
            if let font = YmmpImporter.string(item["Font"]), !font.isEmpty { clip.font = font }
            if let color = YmmpImporter.rgb(YmmpImporter.string(item["FontColor"])) { clip.color = color }
            if let style = YmmpImporter.string(item["Style"]), !style.isEmpty, style != "None",
               let outline = YmmpImporter.rgb(YmmpImporter.string(item["StyleColor"])) {
                clip.outline = outline
            }
        }

        /// 位置の近似換算: YMM4 の `X` / `Y`(ピクセル、中心基準・Y は上向き正)を、MovieCut の 0〜1(中心)に直す。
        private mutating func applyPosition(_ item: [String: Any], into clip: inout Clip) {
            let x = YmmpImporter.animValue(item["X"])
            let y = YmmpImporter.animValue(item["Y"])
            guard x != nil || y != nil else { return }
            if let x, x != 0 { clip.x = min(max(0.5 + x / Double(width), 0), 1) }
            if let y, y != 0 { clip.y = min(max(0.5 - y / Double(height), 0), 1) }
            if !notedPosition {
                notes.append("位置(X / Y)は近似換算です。基準点の違いで表示位置がずれる場合があります")
                notedPosition = true
            }
        }

        /// `$type` から種類名だけを取り出す(例: `YukkuriMovieMaker.Project.Items.VoiceItem, YukkuriMovieMaker` → `VoiceItem`)。
        static func typeName(of item: [String: Any]) -> String? {
            guard let raw = item["$type"] as? String else { return nil }
            let head = raw.split(separator: ",").first.map(String.init) ?? raw
            return head.split(separator: ".").last.map(String.init)
        }

        /// レポート表示用の短いラベル。
        static func label(of item: [String: Any], typeName: String?) -> String {
            if let serif = item["Serif"] as? String, !serif.isEmpty { return String(serif.prefix(24)) }
            if let text = item["Text"] as? String, !text.isEmpty { return String(text.prefix(24)) }
            if let path = item["FilePath"] as? String, !path.isEmpty {
                return (path.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent
            }
            return typeName ?? "(不明なアイテム)"
        }
    }
}

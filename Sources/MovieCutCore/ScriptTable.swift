import Foundation

// MARK: - 台本編集ウィンドウの土台(#41)
//
// 既存のボイスクリップを「セリフ一覧」として表で編集するための、画面を持たない純粋なロジック。
// 1 行 = ボイスクリップ 1 個。編集できるのは話すキャラ・読み上げ文・字幕文・表情タグの 4 つ。
// 音声そのもの(素材・長さ・開始時刻)は変えない: セリフの文字を変えたら、既存の「音声の作り直し」で
// 合成し直すのが従来の流れで、この表はその前の文字の整理に使う。適用は呼び出し側が
// `ProjectModel.edit`(1 回の Undo)に乗せる。

/// 台本一覧の 1 行(ボイスクリップ 1 個分)。
public struct VoiceLine: Equatable, Identifiable, Sendable {
    /// 対象のクリップの id(行の id も兼ねる)。
    public var clipId: String
    /// 話すキャラの id。nil = 変更しない(適用時に今のまま)。
    public var characterId: String?
    /// 話すキャラの名前(表示用に読み取った時点のもの。適用には使わない)。
    public var characterName: String
    /// 読み上げ文(表情タグを除いた本文)。
    public var spoken: String
    /// 表情タグ名(先頭の `[名前]`。空 = タグなし)。
    public var expression: String
    /// 字幕文。nil = 読み上げ文と同じ、空文字 = 字幕なし、それ以外 = その文。
    public var subtitle: String?
    /// 開始時刻と長さ(表示用。適用では変えない)。
    public var start: Double
    public var duration: Double

    public var id: String { clipId }

    public init(clipId: String, characterId: String?, characterName: String, spoken: String,
                expression: String, subtitle: String?, start: Double, duration: Double) {
        self.clipId = clipId; self.characterId = characterId; self.characterName = characterName
        self.spoken = spoken; self.expression = expression; self.subtitle = subtitle
        self.start = start; self.duration = duration
    }

    /// クリップの `text` に戻す形(表情タグ + 読み上げ文)。
    public var clipText: String {
        let tag = expression.trimmingCharacters(in: .whitespaces)
        let body = spoken.trimmingCharacters(in: .whitespaces)
        return tag.isEmpty ? body : "[\(tag)]" + body
    }
}

public enum ScriptTable {
    /// プロジェクトのボイスクリップを、開始時刻の順(同じ時刻は並びの順)に一覧にする。
    public static func lines(in project: Project) -> [VoiceLine] {
        project.allClips.enumerated()
            .filter { $0.element.type == .voice }
            .sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }
            .compactMap { line(for: $0.element, in: project) }
    }

    /// クリップ 1 個を行にする。ボイスでない・読み上げ文が空のものは nil。
    public static func line(for clip: Clip, in project: Project) -> VoiceLine? {
        guard clip.type == .voice else { return nil }
        let (tag, body) = ExpressionTag.split(clip.text ?? "")
        guard !body.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let who = clip.charId.flatMap { id in project.characters.first { $0.id == id } }
        // 字幕文が読み上げ文(タグを除いた本文)と同じなら「指定なし」にそろえる(ファイルに書かない流儀と同じ)
        let subtitle: String? = (clip.subtitleText == body) ? nil : clip.subtitleText
        return VoiceLine(clipId: clip.id, characterId: clip.charId, characterName: who?.name ?? "",
                         spoken: body, expression: tag ?? "", subtitle: subtitle,
                         start: clip.start, duration: clip.duration)
    }

    /// 行の編集をプロジェクトへ当てる。当てた行数を返す。
    /// 当てない行: 対象が無い・ボイスでない・読み上げ文が空・何も変わっていない。
    /// キャラは、プロジェクトに実在する id のときだけ差し替える(消えたキャラへの付け替えで落とさない)。
    @discardableResult
    public static func apply(_ lines: [VoiceLine], to project: inout Project) -> Int {
        var count = 0
        for line in lines where apply(line, to: &project) { count += 1 }
        return count
    }

    @discardableResult
    public static func apply(_ line: VoiceLine, to project: inout Project) -> Bool {
        let text = line.clipText
        guard !ExpressionTag.body(text).trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        for ti in project.tracks.indices {
            guard let ci = project.tracks[ti].clips.firstIndex(where: { $0.id == line.clipId }) else { continue }
            var clip = project.tracks[ti].clips[ci]
            guard clip.type == .voice else { return false }
            let before = clip
            clip.text = text
            // 字幕文が読み上げ文と同じなら書かない(nil)。空文字は「字幕なし」としてそのまま残す
            let body = ExpressionTag.body(text)
            clip.subtitleText = (line.subtitle == body) ? nil : line.subtitle
            if let cid = line.characterId, project.characters.contains(where: { $0.id == cid }) {
                clip.charId = cid
            }
            guard clip != before else { return false }
            project.tracks[ti].clips[ci] = clip
            return true
        }
        return false
    }
}

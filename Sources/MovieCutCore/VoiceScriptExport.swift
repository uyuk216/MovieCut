import Foundation

// MARK: - 台本の書き出し(声のクリップ → 「キャラ名: セリフ」の行)
//
// 書いた行は `ScriptTimeline.parse` で読み直せる。始まりの時刻の順に並べる(同じ時刻は並びの順)。
// キャラが無い・名前が空・セリフが空のクリップは書かず、その数を `skipped` で返す。

public enum VoiceScriptExport {
    public struct Result: Equatable {
        public var text: String
        public var lineCount: Int
        public var skipped: Int
    }

    public static func make(_ project: Project) -> Result {
        let voices = project.allClips.enumerated().filter { $0.element.type == .voice }
            .sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }
        var lines: [String] = []
        var skipped = 0
        for (_, c) in voices {
            let body = (c.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty, let who = project.characters.first(where: { $0.id == c.charId }), !who.name.isEmpty else {
                skipped += 1
                continue
            }
            lines.append("\(who.name): \(body)")
        }
        return Result(text: lines.joined(separator: "\n"), lineCount: lines.count, skipped: skipped)
    }
}

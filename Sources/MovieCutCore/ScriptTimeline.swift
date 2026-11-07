import Foundation

/// 台本 → タイムライン(renderer.js の scriptToTimeline / makeVoiceClip / smoke と同じ)。
public enum ScriptTimeline {
    /// 1080p を基準にした「見た目の大きさの倍率」(renderer.js resK)。
    public static func resK(_ p: Project) -> Double {
        (Double(p.width) * Double(p.height) / (1920.0 * 1080.0)).squareRoot()
    }

    /// 非発話メモ: 行頭が「※」の行は作業メモ。読み上げも字幕も作らない(台本の中の指示や覚え書き用)。
    public static func isNote(line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix("※")
    }

    /// 台本の 1 行を読んだ結果。
    public struct Line: Equatable {
        public var who: Character
        /// 読み上げる文(先頭に表情タグ `[表情]` があってもよい)。口パクの母音もこの文で決まる。
        public var spoken: String
        /// 字幕の文。nil = 読み上げる文と同じ(`|` なし)、空 = 字幕なし(`|` のあとが空)。
        public var subtitle: String?
        public static func == (a: Line, b: Line) -> Bool { a.who.id == b.who.id && a.spoken == b.spoken && a.subtitle == b.subtitle }
    }

    /// 読み上げる文と字幕の区切り(半角 `|` と全角 `｜`)。
    static let subtitleSeparators: Set<Swift.Character> = ["|", "｜"]

    /// 「読み上げ文 | 字幕文」を分ける。最初の区切りだけで分け、前後の空白は除く。区切りが無ければ字幕は nil。
    public static func splitSubtitle(_ rest: String) -> (spoken: String, subtitle: String?) {
        guard let sep = rest.firstIndex(where: { subtitleSeparators.contains($0) }) else { return (rest.trimmingCharacters(in: .whitespaces), nil) }
        let spoken = rest[rest.startIndex..<sep].trimmingCharacters(in: .whitespaces)
        let sub = rest[rest.index(after: sep)...].trimmingCharacters(in: .whitespaces)
        return (spoken, sub)
    }

    /// 1 行を (話すキャラ, 読み上げ文, 字幕文) に分ける。キャラの決め方は `parse(line:)` と同じ。
    /// 読み上げ文が空(「| 字幕」だけの行など)の行は声を作れないので nil。
    public static func parseLine(_ rawLine: String, characters: [Character], selectedCharId: String?) -> Line? {
        guard let (who, rest) = splitSpeaker(rawLine, characters: characters, selectedCharId: selectedCharId) else { return nil }
        let (spoken, subtitle) = splitSubtitle(rest)
        guard !spoken.isEmpty else { return nil }
        return Line(who: who, spoken: spoken, subtitle: subtitle)
    }

    /// 1 行を (話すキャラ, セリフ) に分ける。最初の ":" か "：" で区切り、名前が既知のキャラならその声、
    /// 不明なら selectedCharId のキャラ(無ければ先頭)で行全体がセリフ(renderer.js scriptToTimeline と同じ)。
    /// セリフは読み上げる文だけ(`| 字幕文` があれば除く)。字幕の文も要るときは `parseLine`。
    public static func parse(line rawLine: String, characters: [Character], selectedCharId: String?) -> (Character, String)? {
        guard let (who, rest) = splitSpeaker(rawLine, characters: characters, selectedCharId: selectedCharId) else { return nil }
        let spoken = splitSubtitle(rest).spoken
        return (who, spoken.isEmpty ? rest : spoken)
    }

    /// 話し手とそのあとの全部(字幕の区切りを含む)。
    static func splitSpeaker(_ rawLine: String, characters: [Character], selectedCharId: String?) -> (Character, String)? {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, !isNote(line: line) else { return nil }
        if let sep = line.firstIndex(where: { $0 == ":" || $0 == "：" }), sep != line.startIndex {
            let name = line[line.startIndex..<sep].trimmingCharacters(in: .whitespaces)
            let rest = line[line.index(after: sep)...].trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty, let found = characters.first(where: { $0.name == name }) { return (found, rest) }
        }
        guard let who = characters.first(where: { $0.id == selectedCharId }) ?? characters.first else { return nil }
        return (who, line)
    }

    /// 「名前: セリフ」「名前：セリフ」の行をボイスクリップにして、最初の「全部ボイス」のレイヤー(無ければ新設)の末尾へ並べる。
    /// 名前が分からない行は selectedCharId のキャラ(無ければ先頭)。
    /// - Returns: 追加したクリップ
    @discardableResult
    public static func add(lines rawLines: [String], to project: inout Project, voice: VoiceProvider, directory: URL, selectedCharId: String? = nil) async throws -> [Clip] {
        let lines = rawLines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !isNote(line: $0) }
        guard !lines.isEmpty else { return [] }
        var ti = project.tracks.firstIndex { $0.clips.allSatisfy { $0.type == .voice } }
        if ti == nil {
            project.tracks.append(Track(name: "レイヤー\(project.tracks.count + 1)"))
            ti = project.tracks.count - 1
        }
        let trackIndex = ti!
        var cursor = max(0, project.tracks[trackIndex].clips.map { $0.start + $0.duration }.max() ?? 0)
        var added: [Clip] = []
        for line in lines {
            guard let parsed = parseLine(line, characters: project.characters, selectedCharId: selectedCharId) else { continue }
            let who = parsed.who, text = parsed.spoken
            let r = try await voice.synthesize(character: who, text: ExpressionTag.body(text), in: directory)
            var clip = Clip()
            clip.type = .voice
            clip.start = cursor
            clip.duration = r.duration + 0.15
            clip.offset = 0
            clip.src = r.url.path
            clip.text = text
            // 字幕の文が読み上げる文と同じなら書かない(`|` なしと同じ)
            if let sub = parsed.subtitle, sub != text { clip.subtitleText = sub }
            clip.charId = who.id
            clip.volume = 1
            clip.subtitle = true
            clip.fontSize = max(8, (64 * resK(project)).rounded())
            clip.font = defaultFonts[0]
            project.tracks[trackIndex].clips.append(clip)
            added.append(clip)
            cursor = clip.start + clip.duration + 0.1
        }
        return added
    }

    /// Electron 版 MC_SMOKE の流れ(音声合成は VoiceProvider): 新規 → サイズ → 台本 → テキスト → (ぼかし)。
    public static func smokeProject(size: (width: Int, height: Int)? = nil, codec: String? = nil, blur: Bool = false, voice: VoiceProvider, directory: URL) async throws -> Project {
        var p = Project.new()
        if let s = size { p = p.scaledForResolution(newWidth: s.width, newHeight: s.height) }
        if let c = codec { p.codec = c }
        try await add(lines: ["キャラ1: ゆっくりしていってね", "キャラ2: キャラ2なのだ"], to: &p, voice: voice, directory: directory)
        var text = Clip()
        text.type = .text; text.text = "テスト"; text.start = 0; text.duration = 2
        text.x = 0.5; text.y = 0.2
        text.fontSize = (120 * resK(p)).rounded()
        text.color = "#ffffff"; text.outline = "#000000"; text.font = defaultFonts[0]; text.opacity = 1
        p.tracks[min(4, p.tracks.count - 1)].clips.append(text)
        if blur {
            var b = Clip()
            b.type = .blur; b.start = 0; b.duration = 2
            b.x = 0.5; b.y = 0.15; b.w = 0.5; b.h = 0.25
            b.strength = (30 * resK(p)).rounded(); b.shape = "rect"
            p.tracks[p.tracks.count - 1].clips.append(b)
        }
        return p
    }
}

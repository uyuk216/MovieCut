import Foundation

/// 台本 → タイムライン(renderer.js の scriptToTimeline / makeVoiceClip / smoke と同じ)。
public enum ScriptTimeline {
    /// 1080p を基準にした「見た目の大きさの倍率」(renderer.js resK)。
    public static func resK(_ p: Project) -> Double {
        (Double(p.width) * Double(p.height) / (1920.0 * 1080.0)).squareRoot()
    }

    /// 1 行を (話すキャラ, セリフ) に分ける。最初の ":" か "：" で区切り、名前が既知のキャラならその声、
    /// 不明なら selectedCharId のキャラ(無ければ先頭)で行全体がセリフ(renderer.js scriptToTimeline と同じ)。
    public static func parse(line rawLine: String, characters: [Character], selectedCharId: String?) -> (Character, String)? {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return nil }
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
        let lines = rawLines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
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
            guard let (who, text) = parse(line: line, characters: project.characters, selectedCharId: selectedCharId) else { continue }
            let r = try await voice.synthesize(character: who, text: ExpressionTag.body(text), in: directory)
            var clip = Clip()
            clip.type = .voice
            clip.start = cursor
            clip.duration = r.duration + 0.15
            clip.offset = 0
            clip.src = r.url.path
            clip.text = text
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
        try await add(lines: ["霊夢: ゆっくりしていってね", "ずんだもん: ずんだもんなのだ"], to: &p, voice: voice, directory: directory)
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

import Foundation

/// 字幕 1 件(秒)。
public struct SubtitleCue: Equatable {
    public var start: Double
    public var end: Double
    public var text: String
    public init(start: Double, end: Double, text: String) { self.start = start; self.end = end; self.text = text }
}

public enum SubtitleFormat: String, CaseIterable {
    case srt, vtt

    public var fileExtension: String { rawValue }

    /// 出力先の拡張子から決める(".SRT" も可。知らない拡張子は nil)。
    public init?(pathExtension: String) {
        self.init(rawValue: pathExtension.lowercased())
    }
}

/// SRT / VTT の整形と読み取り(B3。画面にも Undo にも依存しない純粋な処理)。
public enum SubtitleFile {
    /// 字幕を載せるレイヤーの名前(読み込みで作る。書き出しはこの名前のレイヤーの文字クリップも拾う)。
    public static let layerName = "字幕"

    /// 「字幕」「字幕 2」…(読み込みが作るレイヤー)。
    public static func isSubtitleLayer(_ name: String) -> Bool {
        name == layerName || (name.hasPrefix(layerName + " ") && Int(name.dropFirst(layerName.count + 1)) != nil)
    }

    // MARK: 時刻

    /// SRT は `HH:MM:SS,mmm`、VTT は `HH:MM:SS.mmm`。ミリ秒に丸める。負・NaN は 0。時が 99 を超えても桁を増やして書く。
    public static func timestamp(_ t: Double, format: SubtitleFormat) -> String {
        let ms = Int((t.isFinite ? max(0, t) : 0) * 1000 + 0.5)
        let h = ms / 3_600_000, m = ms / 60_000 % 60, s = ms / 1000 % 60, f = ms % 1000
        let sep = format == .srt ? "," : "."
        return String(format: "%02d:%02d:%02d%@%03d", h, m, s, sep, f)
    }

    // MARK: 書き出し

    /// 1 件の本文を整える: 改行は LF にそろえ、空行(SRT/VTT では件の区切りになる)と前後の空白は除く。
    static func cleanBody(_ s: String) -> String {
        s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// 字幕ファイルの文字列。本文が空の件・長さが 0 以下の件は出さない。番号は 1 から振り直す。UTF-8 で書く前提(BOM なし)。
    public static func format(_ cues: [SubtitleCue], as format: SubtitleFormat) -> String {
        var out = format == .vtt ? "WEBVTT\n\n" : ""
        var n = 0
        for c in cues {
            let body = cleanBody(c.text)
            // VTT/SRT どちらでも、本文の中の "-->" は件の区切りと取り違えられる
            let safe = body.replacingOccurrences(of: "-->", with: "->")
            guard !safe.isEmpty, c.end > c.start else { continue }
            n += 1
            if format == .srt { out += "\(n)\n" }
            out += "\(timestamp(c.start, format: format)) --> \(timestamp(c.end, format: format))\n\(safe)\n\n"
        }
        return out
    }

    /// プロジェクトの字幕: 表示される(隠れていないレイヤーの)ボイス(字幕オフでないもの。描画と同じく未設定はオン)と、
    /// 名前が「字幕」のレイヤーの文字クリップ。時刻はタイムライン上の開始と長さ(ボイス・文字は速度の対象外なので、
    /// `duration` がそのまま画面に出る長さ)。開始順(同じなら元の順)。
    public static func cues(from project: Project) -> [SubtitleCue] {
        var list: [(Int, SubtitleCue)] = []
        var order = 0
        for tr in project.tracks where !tr.isHidden {
            for c in tr.clips {
                let isSubtitle: Bool
                switch c.type {
                case .voice: isSubtitle = c.subtitle != false
                case .text: isSubtitle = isSubtitleLayer(tr.name)
                default: isSubtitle = false
                }
                guard isSubtitle, let text = c.text, c.duration > 0 else { continue }
                list.append((order, SubtitleCue(start: c.start, end: c.start + c.duration, text: text)))
                order += 1
            }
        }
        return list.sorted { ($0.1.start, $0.0) < ($1.1.start, $1.0) }.map(\.1)
    }

    // MARK: 読み取り

    /// SRT でも VTT でも読む(形式は自動判定)。BOM・CRLF・CR・番号なし・VTT の WEBVTT/NOTE/STYLE/REGION・件の設定・
    /// HTML/VTT のタグ・ASS の `{\an8}`・ルビ(`<rt>` の読みは捨てる)に耐える。時刻が読めない件・本文が空の件は捨てる。
    /// 重なる件はそのまま返す。開始順に並べる(同じなら元の順)。
    public static func parse(_ raw: String) -> [SubtitleCue] {
        var text = raw
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lines = text.components(separatedBy: "\n")

        // 空行で区切って、"-->" を含む行がある塊を件として読む(その前の行は番号か id なので捨てる)
        var blocks: [[String]] = []
        var cur: [String] = []
        for l in lines {
            if l.trimmingCharacters(in: .whitespaces).isEmpty {
                if !cur.isEmpty { blocks.append(cur); cur = [] }
            } else { cur.append(l) }
        }
        if !cur.isEmpty { blocks.append(cur) }

        var result: [(Int, SubtitleCue)] = []
        for b in blocks {
            guard let ti = b.firstIndex(where: { $0.contains("-->") }) else { continue }
            guard let (s, e) = parseTiming(b[ti]) else { continue }
            let body = stripMarkup(b[(ti + 1)...].joined(separator: "\n"))
            let cleaned = cleanBody(body)
            guard !cleaned.isEmpty else { continue }
            result.append((result.count, SubtitleCue(start: s, end: e, text: cleaned)))
        }
        return result.sorted { ($0.1.start, $0.0) < ($1.1.start, $1.0) }.map(\.1)
    }

    private static let timeRegex = try! NSRegularExpression(pattern: #"(?:(\d+):)?(\d{1,2}):(\d{1,2})(?:[.,](\d+))?"#)

    /// "00:00:01,000 --> 00:00:02.500 align:start" → (1, 2.5)。時は省略可(VTT)、ミリ秒は桁数なりの小数、省略も可。
    static func parseTiming(_ line: String) -> (Double, Double)? {
        let parts = line.components(separatedBy: "-->")
        guard parts.count >= 2 else { return nil }
        guard let s = parseTime(parts[0]) else { return nil }
        // 終わりの後ろは設定(position:… など)なので、最初の時刻だけ読む
        guard let e = parseTime(parts[1]) else { return nil }
        return (s, e)
    }

    static func parseTime(_ s: String) -> Double? {
        let ns = s as NSString
        guard let m = timeRegex.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        func g(_ i: Int) -> String? { m.range(at: i).location == NSNotFound ? nil : ns.substring(with: m.range(at: i)) }
        let h = g(1).flatMap { Double($0) } ?? 0
        guard let mi = g(2).flatMap({ Double($0) }), let se = g(3).flatMap({ Double($0) }) else { return nil }
        var frac = 0.0
        if let f = g(4) { frac = Double("0." + f.prefix(9)) ?? 0 }
        return h * 3600 + mi * 60 + se + frac
    }

    private static let tagPatterns: [NSRegularExpression] = [
        #"(?is)<rt\b[^>]*>.*?</rt>"#,        // ルビの読みは捨てる(親文字だけ残す)
        #"(?is)<rp\b[^>]*>.*?</rp>"#,
        #"</?[A-Za-z][^>]*>"#,               // <i> <b> <c.red> <v 名前> <ruby> など
        #"<\d[\d:.,]*>"#,                    // VTT の語ごとの時刻 <00:01.000>
        #"\{\\[^}]*\}"#,                     // {\an8}
    ].map { try! NSRegularExpression(pattern: $0) }

    /// タグと文字参照を外した本文。
    static func stripMarkup(_ s: String) -> String {
        var t = s
        for re in tagPatterns {
            t = re.stringByReplacingMatches(in: t, range: NSRange(location: 0, length: (t as NSString).length), withTemplate: "")
        }
        for (a, b) in [("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " "), ("&lrm;", ""), ("&rlm;", ""), ("&quot;", "\""), ("&amp;", "&")] {
            t = t.replacingOccurrences(of: a, with: b)
        }
        return t
    }
}

// MARK: - 読み込み(プロジェクトへ)

public enum SubtitleImport {
    /// 字幕クリップの見た目(既存の字幕と同じ: 画面下、白、縁は黒、文字は 64 × 解像度の係数)。
    public static func makeClip(_ cue: SubtitleCue, project: Project) -> Clip {
        var c = Clip()
        c.type = .text
        c.text = cue.text
        c.start = cue.start
        c.duration = cue.end - cue.start
        c.x = 0.5; c.y = 0.88
        c.fontSize = max(8, (64 * ClipEditing.resK(project)).rounded())
        c.color = "#ffffff"
        c.outline = "#000000"
        c.font = defaultFonts[0]
        c.opacity = 1
        return c
    }

    /// 字幕を `offset` 秒ずらして、新しいレイヤー「字幕」(重なる件があれば「字幕 2」…)に文字クリップとして足す。
    /// 新しいレイヤーは一番上(配列の最後)。0 秒より前に終わる件は捨て、頭が 0 未満の件は 0 に切る。
    /// 足すものが無ければ nil。返すのは新しいプロジェクトと、足したクリップの id(開始順)。
    public static func apply(_ cues: [SubtitleCue], to project: Project, offset: Double = 0) -> (project: Project, clipIds: [String])? {
        let off = offset.isFinite ? offset : 0
        let shifted: [SubtitleCue] = cues.compactMap { c in
            let e = c.end + off
            guard e > 1e-9 else { return nil }
            let s = max(0, c.start + off)
            guard e > s else { return nil }
            return SubtitleCue(start: s, end: e, text: c.text)
        }.sorted { $0.start < $1.start }
        guard !shifted.isEmpty else { return nil }

        let clips = shifted.map { makeClip($0, project: project) }
        var p = project
        appendLanes(clips, to: &p)
        return (p, clips.map(\.id))
    }

    /// 文字クリップを、重ならないレイヤーに分けて末尾(一番上)へ足す。レイヤー名は「字幕」「字幕 2」…
    /// (開始順に並んでいること。足す順で最初に入るレイヤーを使う)。
    static func appendLanes(_ clips: [Clip], to p: inout Project) {
        var lanes: [[Clip]] = []
        for clip in clips {
            if let i = lanes.firstIndex(where: { ($0.last.map { $0.start + $0.duration } ?? 0) <= clip.start + 1e-9 }) {
                lanes[i].append(clip)
            } else {
                lanes.append([clip])
            }
        }
        for (i, laneClips) in lanes.enumerated() {
            var t = Track(name: i == 0 ? SubtitleFile.layerName : "\(SubtitleFile.layerName) \(i + 1)")
            t.clips = laneClips
            p.tracks.append(t)
        }
    }
}

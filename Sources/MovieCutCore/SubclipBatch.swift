import Foundation

/// 複数の素材から、範囲(イン点とアウト点)を指定してサブクリップをまとめて作る(候補 38)。
/// 1 行に「素材 範囲[, 範囲…]」を書く(`intro.mov 0:05-0:12, 0:30-0:41`)。範囲だけの行は、直前の行の素材の続き。`#` で始まる行は注釈。
/// 素材は、取り込み済みの素材(`Project.mediaPool`)のパス・ファイル名・拡張子なしの名前・名前の一部のどれでも指せる(一意に決まるとき)。
/// 時刻は `秒` `分:秒` `時:分:秒`(小数可)。区切りは `-` `〜` `~` `–` `→`。作ったクリップは、再生位置から順に隙間なく並べる。
/// 画面を持たない純粋な計算(素材の長さの測定は呼び出し側)。
public enum SubclipBatch {
    public struct Spec: Equatable {
        public var src: String
        public var inTime: Double
        public var outTime: Double
        public var length: Double { outTime - inTime }
        public init(src: String, inTime: Double, outTime: Double) { self.src = src; self.inTime = inTime; self.outTime = outTime }
    }

    public struct LineError: Equatable {
        public var line: Int
        public var message: String
    }

    public struct Parsed: Equatable {
        public var specs: [Spec]
        public var errors: [LineError]
    }

    // MARK: 時刻

    /// "90" "1:30" "1:02:03" "1:30.5" を秒に。読めない・負・極端に大きい値は nil。
    public static func parseTime(_ raw: String) -> Double? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        let parts = s.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count <= 3 else { return nil }
        var total = 0.0
        for (i, p) in parts.enumerated() {
            guard !p.isEmpty, p.allSatisfy({ $0.isNumber || $0 == "." }), p.filter({ $0 == "." }).count <= 1,
                  let v = Double(p), v.isFinite else { return nil }
            // 小数は最後の欄だけ
            if i != parts.count - 1, p.contains(".") { return nil }
            total = total * 60 + v
        }
        return total < 1e7 ? total : nil
    }

    static let separators = "-〜~–—→"

    /// 範囲 1 つ分("0:05-0:12")。
    static func rangePattern() -> NSRegularExpression {
        // 数字と : . だけの時刻 2 つを区切り文字でつなぐ
        try! NSRegularExpression(pattern: "(\\d[\\d:.]*)\\s*[\(separators)]\\s*(\\d[\\d:.]*)")
    }

    // MARK: 素材の解決

    public enum Resolution: Equatable {
        case found(String)
        case failed(String)
    }

    /// 素材の名前から、取り込み済みの素材のパスを決める。一意に決まらなければ理由つきで失敗。
    public static func resolve(_ name: String, pool: [String], fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Resolution {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return .failed("素材の名前がありません") }
        if let hit = pool.first(where: { $0 == n }) { return .found(hit) }
        func pick(_ hits: [String], _ how: String) -> Resolution? {
            if hits.count == 1 { return .found(hits[0]) }
            if hits.count > 1 { return .failed("「\(n)」は\(how)複数の素材に一致します: " + hits.prefix(3).map { ($0 as NSString).lastPathComponent }.joined(separator: "、")) }
            return nil
        }
        let low = n.lowercased()
        let byFile = pool.filter { ($0 as NSString).lastPathComponent.lowercased() == low }
        if let r = pick(byFile, "") { return r }
        let byStem = pool.filter { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased() == low }
        if let r = pick(byStem, "") { return r }
        let byPart = pool.filter { ($0 as NSString).lastPathComponent.lowercased().contains(low) }
        if let r = pick(byPart, "名前の一部で") { return r }
        if n.hasPrefix("/"), ClipEditing.isSupportedMedia(path: n), fileExists(n) { return .found(n) }
        return .failed("素材「\(n)」が見つかりません")
    }

    // MARK: 解析

    public static func parse(_ text: String, pool: [String], fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Parsed {
        var specs: [Spec] = []
        var errors: [LineError] = []
        var current: String?
        let re = rangePattern()
        for (i, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let no = i + 1
            if line.isEmpty || line.hasPrefix("#") { continue }
            let ns = line as NSString
            let matches = re.matches(in: line, range: NSRange(location: 0, length: ns.length))
            guard let firstMatch = matches.first else {
                errors.append(LineError(line: no, message: "範囲(例 0:05-0:12)がありません"))
                continue
            }
            let name = ns.substring(to: firstMatch.range.location).trimmingCharacters(in: CharacterSet(charactersIn: " \t,、:："))
            if !name.isEmpty {
                switch resolve(name, pool: pool, fileExists: fileExists) {
                case .found(let path):
                    let kind = ClipEditing.kindOf(path: path)
                    guard kind == .video || kind == .audio else {
                        errors.append(LineError(line: no, message: "「\((path as NSString).lastPathComponent)」は動画・音声ではありません"))
                        current = nil
                        continue
                    }
                    current = path
                case .failed(let msg):
                    errors.append(LineError(line: no, message: msg))
                    current = nil
                    continue
                }
            }
            guard let src = current else {
                errors.append(LineError(line: no, message: "素材が決まっていません"))
                continue
            }
            for m in matches {
                let a = ns.substring(with: m.range(at: 1)), b = ns.substring(with: m.range(at: 2))
                guard let t0 = parseTime(a), let t1 = parseTime(b) else {
                    errors.append(LineError(line: no, message: "時刻「\(a)-\(b)」を読めません"))
                    continue
                }
                guard t1 - t0 >= ClipEditing.minDuration else {
                    errors.append(LineError(line: no, message: "「\(a)-\(b)」は終わりが始まりより後ではありません"))
                    continue
                }
                specs.append(Spec(src: src, inTime: t0, outTime: t1))
            }
        }
        return Parsed(specs: specs, errors: errors)
    }

    // MARK: クリップを作る・並べる

    public struct Built: Equatable {
        public var clips: [Clip]
        /// 素材の長さを超えるなどで作れなかった指定。
        public var errors: [String]
    }

    /// 指定どおりのサブクリップ(素材の `offset` = イン点、長さ = アウト − イン)を並べて作る。`start` から隙間なく。
    /// `durations`: 素材の長さ(測れなかった素材は無いものとして、範囲をそのまま信じる)。アウトが素材の終わりを超えるなら終わりまでに詰め、
    /// インが素材の終わり以降なら作らない。
    public static func build(_ specs: [Spec], durations: [String: Double], start: Double) -> Built {
        var clips: [Clip] = []
        var errors: [String] = []
        var cursor = max(0, start)
        for s in specs {
            var out = s.outTime
            let name = (s.src as NSString).lastPathComponent
            if let d = durations[s.src] {
                if s.inTime >= d - ClipEditing.minDuration { errors.append("「\(name)」の \(s.inTime) 秒は素材の長さ(\(String(format: "%.1f", d)) 秒)を超えています"); continue }
                out = min(out, d)
            }
            let len = out - s.inTime
            guard len >= ClipEditing.minDuration else { continue }
            var c = ClipEditing.makeMediaClip(path: s.src, kind: ClipEditing.kindOf(path: s.src), duration: len, start: cursor)
            c.offset = s.inTime
            c.srcDuration = durations[s.src] ?? max(out, c.srcDuration ?? 0)
            clips.append(c)
            cursor += len
        }
        return Built(clips: clips, errors: errors)
    }

    public struct PlaceResult: Equatable {
        public var project: Project
        public var newIds: [String]
        public var trackIndex: Int
    }

    /// 並べたクリップを、全体が入る空いたレイヤー(`ClipEditing.placementTrack`)へ入れる。空きが無ければ新しいレイヤーを足す。
    /// 取り込んだ素材として覚える。空なら nil。
    public static func place(_ clips: [Clip], in project: Project) -> PlaceResult? {
        guard let first = clips.first, let last = clips.last else { return nil }
        var p = project
        let total = last.start + last.duration - first.start
        var ti = ClipEditing.placementTrack(in: p, start: first.start, duration: total)
        let blocked = p.tracks.indices.contains(ti) == false || p.tracks[ti].isLocked
            || p.tracks[ti].clips.contains { !($0.start >= first.start + total || $0.start + $0.duration <= first.start) }
        if blocked {
            p.tracks.append(Track(name: "レイヤー\(p.tracks.count + 1)"))
            ti = p.tracks.count - 1
        }
        p.tracks[ti].clips.append(contentsOf: clips)
        UnusedMedia.register(clips.compactMap(\.src), in: &p)
        return PlaceResult(project: p, newIds: clips.map(\.id), trackIndex: ti)
    }
}

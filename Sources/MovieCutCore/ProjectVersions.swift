import Foundation

/// 世代バックアップ: プロジェクトを保存するたびに、その中身の写しを「版の置き場」に残し、古いものから消して N 世代に保つ。
/// 置き場は `DataLocations.versions` の下の、プロジェクトのファイルごとのフォルダ(`<名前>-<場所の短い印>`)。
/// 利用者のプロジェクトのファイルは読むことも書くこともしない(渡された中身 `Data` を、置き場へ新しい名前で書くだけ)。
/// 復元は「写しを開く」だけで、元のファイルや他の世代は変えない。名前・並び・間引きは、ファイルに触らない純粋な関数。
public enum ProjectVersions {
    /// 残す世代数の既定と範囲。
    public static let defaultKeep = 10
    public static let keepRange: ClosedRange<Int> = 1...100
    /// 設定(UserDefaults)のキー。
    public static let keepDefaultsKey = "projectVersionsKeep"
    /// この秒数より短い間に続けて保存されたときは、新しい世代を足さず、いちばん新しい世代を新しい中身に置き換える
    /// (自動保存が世代を使い切らないように)。0 なら保存のたびに 1 世代。
    public static let defaultMinInterval: TimeInterval = 60

    /// 1 つの世代。
    public struct Entry: Equatable, Sendable {
        public var url: URL
        public var date: Date
        public var size: Int
        public init(url: URL, date: Date, size: Int) { self.url = url; self.date = date; self.size = size }
    }

    // MARK: 純粋な名前の決まり

    /// 世代の名前 `yyyyMMdd-HHmmss-SSS[-n].<拡張子>`(時刻は UTC。同じ瞬間が重なるときは `-2`, `-3`…)。
    public static func generationName(date: Date, ext: String, sequence: Int = 1) -> String {
        let c = utc.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: date)
        let ms = min(999, max(0, (c.nanosecond ?? 0) / 1_000_000))
        var s = String(format: "%04d%02d%02d-%02d%02d%02d-%03d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0, ms)
        if sequence > 1 { s += "-\(sequence)" }
        let e = sanitizedExtension(ext)
        return e.isEmpty ? s : s + "." + e
    }

    /// 名前から日付と連番を読む。世代の名前でなければ nil。
    public static func parseGenerationName(_ name: String) -> (date: Date, sequence: Int)? {
        let stem = (name as NSString).deletingPathExtension
        let parts = stem.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3 || parts.count == 4,
              parts[0].count == 8, parts[1].count == 6, parts[2].count == 3,
              parts.prefix(3).allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let ymd = Int(parts[0]), let hms = Int(parts[1]), let ms = Int(parts[2]) else { return nil }
        var seq = 1
        if parts.count == 4 { guard let n = Int(parts[3]), n >= 2 else { return nil }; seq = n }
        var dc = DateComponents()
        dc.year = ymd / 10000; dc.month = ymd / 100 % 100; dc.day = ymd % 100
        dc.hour = hms / 10000; dc.minute = hms / 100 % 100; dc.second = hms % 100
        guard (1...12).contains(dc.month!), (1...31).contains(dc.day!), dc.hour! < 24, dc.minute! < 60, dc.second! < 60,
              let d = utc.date(from: dc) else { return nil }
        return (d.addingTimeInterval(Double(ms) / 1000), seq)
    }

    public static func isGenerationName(_ name: String) -> Bool { parseGenerationName(name) != nil }

    /// 新しい順(日付、同じ瞬間は連番の大きい方が新しい)。世代の名前でないものは入らない。
    public static func sortedNewestFirst(_ names: [String]) -> [String] {
        var items: [(name: String, date: Date, seq: Int)] = []
        for n in names {
            if let p = parseGenerationName(n) { items.append((n, p.date, p.sequence)) }
        }
        items.sort { (a: (name: String, date: Date, seq: Int), b: (name: String, date: Date, seq: Int)) -> Bool in
            if a.date != b.date { return a.date > b.date }
            if a.seq != b.seq { return a.seq > b.seq }
            return a.name > b.name
        }
        return items.map { $0.name }
    }

    /// 消す名前(古い順)。新しい方から `keep` 個を残す。世代の名前でないファイルは決して入れない。
    public static func namesToPrune(_ names: [String], keep: Int) -> [String] {
        let k = clampKeep(keep)
        let sorted = sortedNewestFirst(names)
        guard sorted.count > k else { return [] }
        return Array(sorted[k...].reversed())
    }

    public static func clampKeep(_ n: Int) -> Int { min(max(n, keepRange.lowerBound), keepRange.upperBound) }

    /// 設定から残す世代数(無い・範囲外は既定 / 範囲内に収める)。
    public static func keep(from defaults: UserDefaults) -> Int {
        guard defaults.object(forKey: keepDefaultsKey) != nil else { return defaultKeep }
        return clampKeep(defaults.integer(forKey: keepDefaultsKey))
    }

    /// 置き場のフォルダ名 `<プロジェクト名>-<場所の印>`。同じ名前でも場所が違えば別の置き場になる。
    public static func folderName(for projectURL: URL) -> String {
        let url = projectURL.resolvingSymlinksInPath().standardizedFileURL
        var stem = url.deletingPathExtension().lastPathComponent
        stem = String(stem.map { "/:\\\0".contains($0) || $0.isNewline ? "_" : $0 })
        while stem.hasPrefix(".") { stem.removeFirst() }
        stem = String(stem.prefix(40))
        if stem.isEmpty { stem = "project" }
        return "\(stem)-\(fnvHex(url.path))"
    }

    public static func folder(for projectURL: URL, in locations: DataLocations) -> URL {
        locations.versions.appendingPathComponent(folderName(for: projectURL), isDirectory: true)
    }

    /// 日付と大きさの 1 行("2026/11/05 14:03:55 · 123 KB")。日付は端末のタイムゾーン。
    public static func title(_ e: Entry, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP"); f.timeZone = timeZone; f.dateFormat = "yyyy/MM/dd HH:mm:ss"
        let b = ByteCountFormatter(); b.countStyle = .file
        return "\(f.string(from: e.date)) · \(b.string(fromByteCount: Int64(e.size)))"
    }

    // MARK: ファイルを扱う

    /// 置き場の世代(新しい順)。名前が世代の形でないファイルは数えない。
    public static func list(in folder: URL, fileManager fm: FileManager = .default) -> [Entry] {
        let names = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        return sortedNewestFirst(names).compactMap { n in
            guard let p = parseGenerationName(n) else { return nil }
            let u = folder.appendingPathComponent(n)
            let size = (try? fm.attributesOfItem(atPath: u.path)[.size] as? Int) ?? 0
            return Entry(url: u, date: p.date, size: size)
        }
    }

    public static func list(for projectURL: URL, in locations: DataLocations, fileManager fm: FileManager = .default) -> [Entry] {
        list(in: folder(for: projectURL, in: locations), fileManager: fm)
    }

    public enum Outcome: Equatable, Sendable {
        /// 新しい世代を足した。
        case added(URL)
        /// 直前の世代と中身が同じなので、何もしなかった。
        case unchanged
        /// 直前の世代から間隔が短いので、その世代を新しい中身に置き換えた。
        case replaced(URL)
    }

    /// 保存した中身 `data` を世代として残し、`keep` を超えた古い世代を消す。`projectURL` は保存先(置き場の決定にだけ使い、読み書きしない)。
    /// - 直前の世代と同じ中身なら何もしない。
    /// - 直前の世代より `minInterval` 秒以内なら、その世代を新しい中身へ置き換える(世代を使わない)。
    /// - 書けなかったときは throw(元のプロジェクトのファイルには影響しない)。
    @discardableResult
    public static func record(data: Data, projectURL: URL, now: Date = Date(), locations: DataLocations = .current,
                              keep: Int = defaultKeep, minInterval: TimeInterval = defaultMinInterval,
                              fileManager fm: FileManager = .default) throws -> Outcome {
        let dir = folder(for: projectURL, in: locations)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let existing = list(in: dir, fileManager: fm)
        let ext = projectURL.pathExtension
        var replacing: Entry?
        if let latest = existing.first {
            if latest.size == data.count, let old = try? Data(contentsOf: latest.url), old == data { return .unchanged }
            if minInterval > 0, now.timeIntervalSince(latest.date) >= 0, now.timeIntervalSince(latest.date) < minInterval { replacing = latest }
        }
        // 重ならない名前(同じ瞬間なら連番を足す)
        var seq = 1
        var name = generationName(date: now, ext: ext, sequence: seq)
        while fm.fileExists(atPath: dir.appendingPathComponent(name).path) { seq += 1; name = generationName(date: now, ext: ext, sequence: seq) }
        let url = dir.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        if let r = replacing { try? fm.removeItem(at: r.url) }
        for n in namesToPrune((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [], keep: keep) {
            try? fm.removeItem(at: dir.appendingPathComponent(n))
        }
        return replacing == nil ? .added(url) : .replaced(url)
    }

    /// 世代を読んでプロジェクトにする(開くだけ。世代のファイルは変えない)。
    public static func load(_ entry: Entry) throws -> Project {
        try Project.decode(from: Data(contentsOf: entry.url))
    }

    // MARK: 内部

    private static var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private static func sanitizedExtension(_ e: String) -> String {
        e.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.lowercased()
    }

    /// FNV-1a 64 ビット(場所の短い印。暗号用ではない)。
    private static func fnvHex(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return String(format: "%016llx", h).prefix(10).description
    }
}

import Foundation

/// マーカーの色(旗と案内線)。既定は teal。任意項目で、既定のときは書かない。
public enum MarkerColor: String, CaseIterable, Equatable {
    case teal, red, orange, yellow, green, blue, purple, gray

    public static let `default` = MarkerColor.teal

    public var title: String {
        switch self {
        case .teal: return "ティール"
        case .red: return "赤"
        case .orange: return "オレンジ"
        case .yellow: return "黄"
        case .green: return "緑"
        case .blue: return "青"
        case .purple: return "紫"
        case .gray: return "グレー"
        }
    }

    /// 0xRRGGBB(表示側が NSColor にする)。
    public var hex: UInt32 {
        switch self {
        case .teal: return 0x3dd6c0
        case .red: return 0xff5c5c
        case .orange: return 0xffa13d
        case .yellow: return 0xffd84f
        case .green: return 0x5ccf6a
        case .blue: return 0x4f8cff
        case .purple: return 0xb07cff
        case .gray: return 0x9a9eab
        }
    }

    /// 保存された文字列を色にする。空・未知の値は既定の色(未知の値は保存されたままにする)。
    public static func resolved(_ raw: String?) -> MarkerColor {
        raw.flatMap { MarkerColor(rawValue: $0) } ?? .default
    }
}

/// タイムライン上の目印(M7)。書き出しには影響しない。
public struct Marker: Codable, Equatable, Identifiable {
    public var id: String = newId()
    public var time: Double = 0
    public var name: String = ""
    /// 色(MarkerColor の raw 値)。nil = 既定の色。未知の値はそのまま残す(読み書きで消さない)。
    public var color: String? = nil
    public var extra: [String: JSONValue] = [:]

    static let knownKeys: Set<String> = ["id", "time", "name", "color"]

    public init() {}
    public init(time: Double, name: String) { self.time = time; self.name = name }

    public init(from decoder: Decoder) throws {
        let l = Lenient(c: try decoder.container(keyedBy: AnyKey.self), known: Self.knownKeys)
        id = l.string("id") ?? id
        let t = l.double("time") ?? 0
        time = t.isFinite ? max(0, t) : 0
        name = l.string("name") ?? name
        color = l.string("color").flatMap { $0.isEmpty ? nil : $0 }
        extra = l.extra()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        for (k, v) in extra { try c.encode(v, forKey: AnyKey(k)) }
        try c.encode(id, forKey: AnyKey("id"))
        try c.encode(time, forKey: AnyKey("time"))
        try c.encode(name, forKey: AnyKey("name"))
        if let color, !color.isEmpty, color != MarkerColor.default.rawValue { try c.encode(color, forKey: AnyKey("color")) }
    }
}

/// マーカーの純粋な編集(UI にも Undo にも依存しない)。
public enum MarkerEditing {
    /// 同じ時刻とみなす幅(秒)の下限。
    public static let epsilon = 1e-6

    /// 「マーカーN」の次の番号(既存の「マーカー数字」の最大 + 1)。
    public static func nextName(in project: Project) -> String {
        var maxN = 0
        for m in project.markers where m.name.hasPrefix("マーカー") {
            if let n = Int(m.name.dropFirst("マーカー".count)) { maxN = max(maxN, n) }
        }
        return "マーカー\(maxN + 1)"
    }

    /// 時刻順に並べる(同じ時刻は元の順)。
    public static func sorted(_ markers: [Marker]) -> [Marker] {
        markers.enumerated().sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }.map(\.element)
    }

    /// `t`(0 以上に丸める)にマーカーを足す。名前が nil なら「マーカーN」。足したマーカーの id も返す。
    public static func add(in project: Project, at t: Double, name: String? = nil) -> (project: Project, id: String) {
        var p = project
        var m = Marker(time: max(0, t), name: name ?? nextName(in: project))
        if m.name.isEmpty { m.name = nextName(in: project) }
        p.markers.append(m)
        p.markers = sorted(p.markers)
        return (p, m.id)
    }

    /// ビートの時刻にまとめてマーカーを足す(名前は「ビート」)。`tolerance` 秒以内に既にあるマーカーには重ねない。
    /// 足した数を返す。1 つも足さないときは、同じプロジェクトを返す(呼び出し側は Undo に載せない)。
    public static func addBeats(in project: Project, times: [Double], tolerance: Double) -> (project: Project, added: Int) {
        var p = project
        var added = 0
        for t in times where t.isFinite && t >= 0 {
            if p.markers.contains(where: { abs($0.time - t) <= tolerance }) { continue }
            p.markers.append(Marker(time: t, name: "ビート"))
            added += 1
        }
        guard added > 0 else { return (project, 0) }
        p.markers = sorted(p.markers)
        return (p, added)
    }

    /// 時刻 `t` から `tolerance` 秒以内で一番近いマーカー(無ければ nil)。
    public static func nearest(in project: Project, to t: Double, tolerance: Double) -> Marker? {
        var best: Marker?
        var bestD = Double.infinity
        for m in project.markers {
            let d = abs(m.time - t)
            if d <= tolerance + epsilon && d < bestD { best = m; bestD = d }
        }
        return best
    }

    public static func remove(in project: Project, id: String) -> Project? {
        guard project.markers.contains(where: { $0.id == id }) else { return nil }
        var p = project
        p.markers.removeAll { $0.id == id }
        return p
    }

    /// マーカーの色を変える(既定の色は nil として書く)。同じ色なら変えず nil を返す。
    public static func setColor(in project: Project, id: String, to color: MarkerColor) -> Project? {
        guard let i = project.markers.firstIndex(where: { $0.id == id }) else { return nil }
        // 表示どおり(既知の色か、無い)なら変えない。未知の値は、選んだ色に直す(表示が既定でも保存の値は残っていたため)
        let stored = project.markers[i].color
        let storedIsKnown = stored.map { MarkerColor(rawValue: $0) != nil } ?? true
        guard !(storedIsKnown && MarkerColor.resolved(stored) == color) else { return nil }
        var p = project
        p.markers[i].color = color == .default ? nil : color.rawValue
        return p
    }

    public static func rename(in project: Project, id: String, to name: String) -> Project? {
        guard let i = project.markers.firstIndex(where: { $0.id == id }) else { return nil }
        var p = project
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        p.markers[i].name = n.isEmpty ? p.markers[i].name : n
        return p
    }

    /// マーカーを動かす(0 未満は 0)。並びは時刻順に直す。
    public static func move(in project: Project, id: String, to t: Double) -> Project? {
        guard let i = project.markers.firstIndex(where: { $0.id == id }) else { return nil }
        var p = project
        p.markers[i].time = max(0, t.isFinite ? t : 0)
        p.markers = sorted(p.markers)
        return p
    }

    /// `t` より前(同じ時刻は除く)で一番近いマーカー。
    public static func previous(in project: Project, before t: Double) -> Marker? {
        project.markers.filter { $0.time < t - epsilon }.max { $0.time < $1.time }
    }

    /// `t` より後ろで一番近いマーカー。
    public static func next(in project: Project, after t: Double) -> Marker? {
        project.markers.filter { $0.time > t + epsilon }.min { $0.time < $1.time }
    }
}

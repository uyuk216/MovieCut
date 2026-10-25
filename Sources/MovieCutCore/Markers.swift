import Foundation

/// タイムライン上の目印(M7)。書き出しには影響しない。
public struct Marker: Codable, Equatable, Identifiable {
    public var id: String = newId()
    public var time: Double = 0
    public var name: String = ""
    public var extra: [String: JSONValue] = [:]

    static let knownKeys: Set<String> = ["id", "time", "name"]

    public init() {}
    public init(time: Double, name: String) { self.time = time; self.name = name }

    public init(from decoder: Decoder) throws {
        let l = Lenient(c: try decoder.container(keyedBy: AnyKey.self), known: Self.knownKeys)
        id = l.string("id") ?? id
        let t = l.double("time") ?? 0
        time = t.isFinite ? max(0, t) : 0
        name = l.string("name") ?? name
        extra = l.extra()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        for (k, v) in extra { try c.encode(v, forKey: AnyKey(k)) }
        try c.encode(id, forKey: AnyKey("id"))
        try c.encode(time, forKey: AnyKey("time"))
        try c.encode(name, forKey: AnyKey("name"))
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

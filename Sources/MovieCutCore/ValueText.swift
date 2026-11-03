import Foundation

/// 文字クリップに「他のクリップの値」を表示する(候補 30)。参照先のクリップの項目(位置・拡大率・不透明度・音量・開始・長さなど)を、
/// 再生位置での値(キーフレーム反映)にして、`text` の後ろに続ける。任意項目で、無い(nil)ときは従来どおり。
/// カウントダウン(`counter`)があるときはそちらを優先する。参照先が見つからないときは「—」を出す(描画は止めない)。
public struct ValueRef: Codable, Equatable, Sendable {
    /// 参照できる項目。
    public static let params = ["x", "y", "scale", "opacity", "rotation", "blur", "volume", "start", "duration", "end"]
    /// 表示の形: "auto"(項目ごとの既定)・"number"(数)・"percent"(割合を % に)・"time"(分:秒.小数)。
    public static let formats = ["auto", "number", "percent", "time"]
    public static let defaultParam = "opacity"

    public var clipId: String
    public var param: String
    /// "auto" のとき書かない。
    public var format: String
    /// 小数の桁数 0〜4(既定 1)。
    public var decimals: Int

    public var extra: [String: JSONValue] = [:]
    static let knownKeys: Set<String> = ["clipId", "param", "format", "decimals"]
    public static let defaultDecimals = 1

    public init(clipId: String, param: String = ValueRef.defaultParam, format: String = "auto", decimals: Int = ValueRef.defaultDecimals) {
        self.clipId = clipId
        self.param = Self.params.contains(param) ? param : Self.defaultParam
        self.format = Self.formats.contains(format) ? format : "auto"
        self.decimals = min(max(decimals, 0), 4)
    }

    public init(from decoder: Decoder) throws {
        let l = Lenient(c: try decoder.container(keyedBy: AnyKey.self), known: Self.knownKeys)
        self.init(clipId: l.string("clipId") ?? "", param: l.string("param") ?? Self.defaultParam,
                  format: l.string("format") ?? "auto", decimals: l.int("decimals") ?? Self.defaultDecimals)
        extra = l.extra()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        for (k, v) in extra { try c.encode(v, forKey: AnyKey(k)) }
        try c.encode(clipId, forKey: AnyKey("clipId"))
        try c.encode(param, forKey: AnyKey("param"))
        if format != "auto" { try c.encode(format, forKey: AnyKey("format")) }
        if decimals != Self.defaultDecimals { try c.encode(decimals, forKey: AnyKey("decimals")) }
    }

    public static func label(of param: String) -> String {
        switch param {
        case "x": return "位置 X"
        case "y": return "位置 Y"
        case "scale": return "拡大率"
        case "opacity": return "不透明度"
        case "rotation": return "回転"
        case "blur": return "ぼかし"
        case "volume": return "音量"
        case "start": return "開始"
        case "duration": return "長さ"
        case "end": return "終わり"
        default: return param
        }
    }

    public static func formatLabel(_ f: String) -> String {
        switch f {
        case "number": return "数"
        case "percent": return "％"
        case "time": return "時間"
        default: return "自動"
        }
    }

    /// 参照先の項目の、プロジェクトの時刻 `t` での値(未知の項目・見つからないときは nil)。
    public func value(in project: Project, at t: Double) -> Double? {
        guard let target = Self.find(clipId, in: project.tracks) else { return nil }
        switch param {
        case "start": return target.start
        case "duration": return target.duration
        case "end": return target.start + target.duration
        default:
            guard Self.params.contains(param) else { return nil }
            return Animation.value(of: param, in: target, at: max(0, t - target.start))
        }
    }

    /// 値を文字にする。
    public func format(_ v: Double) -> String {
        let kind: String
        if format != "auto" { kind = format }
        else {
            switch param {
            case "opacity", "volume": kind = "percent"
            case "start", "duration", "end": kind = "time"
            default: kind = "number"
            }
        }
        switch kind {
        case "percent": return String(format: "%.\(decimals)f%%", v * 100)
        case "time":
            let s = max(0, v)
            let m = Int(s / 60)
            let rest = s - Double(m * 60)
            let width = decimals == 0 ? 2 : 3 + decimals
            return String(format: "%02d:%0\(width).\(decimals)f", m, rest)
        default: return String(format: "%.\(decimals)f", v)
        }
    }

    /// 入れ子の複合クリップの中まで探す。
    static func find(_ id: String, in tracks: [Track]) -> Clip? {
        for tr in tracks {
            for c in tr.clips {
                if c.id == id { return c }
                if let inner = c.tracks, let hit = find(id, in: inner) { return hit }
            }
        }
        return nil
    }

    /// 表示する文字(参照先が無ければ「—」)。
    public func text(in project: Project, at t: Double) -> String {
        guard let v = value(in: project, at: t) else { return "—" }
        return format(v)
    }
}

public extension Clip {
    /// 描画に出す文字。カウントダウン → 他のクリップの値 → `text` の順。
    func displayText(at t: Double, in project: Project) -> String {
        if counter == nil, let ref = valueRef { return (text ?? "") + ref.text(in: project, at: t) }
        return displayText(at: t)
    }
}

/// 値の表示の編集。文字クリップだけが対象。何も変わらないときは false。
public enum ValueRefEditing {
    @discardableResult
    public static func set(_ c: inout Clip, to ref: ValueRef?) -> Bool {
        guard c.type == .text else { return false }
        let new = ref.flatMap { $0.clipId.isEmpty || $0.clipId == c.id ? nil : $0 }
        guard new != c.valueRef else { return false }
        c.valueRef = new
        return true
    }

    @discardableResult
    public static func update(_ c: inout Clip, _ change: (inout ValueRef) -> Void) -> Bool {
        guard c.type == .text, var r = c.valueRef else { return false }
        change(&r)
        let n = ValueRef(clipId: r.clipId, param: r.param, format: r.format, decimals: r.decimals)
        var keep = n; keep.extra = r.extra
        guard keep != c.valueRef else { return false }
        c.valueRef = keep
        return true
    }

    /// 参照先にできるクリップ(自分以外・文字クリップ以外もすべて。複合の中も含む)。
    public static func candidates(in project: Project, excluding id: String) -> [Clip] {
        var out: [Clip] = []
        func walk(_ tracks: [Track]) {
            for tr in tracks { for c in tr.clips {
                if c.id != id { out.append(c) }
                if let inner = c.tracks { walk(inner) }
            } }
        }
        walk(project.tracks)
        return out
    }
}

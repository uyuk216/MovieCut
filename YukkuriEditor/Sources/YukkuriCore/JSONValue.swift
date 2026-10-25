import Foundation

/// 知らないキーを捨てずに保持するための、最小の JSON 値。
public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}

/// 任意の文字列キー。既知キーと未知キーを同じコンテナで扱うために使う。
struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ s: String) { stringValue = s }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

/// 寛容なデコード用の補助。型が違う・欠けているときは nil を返す(エラーにしない)。
struct Lenient {
    let c: KeyedDecodingContainer<AnyKey>
    let known: Set<String>

    func value<T: Decodable>(_ key: String) -> T? {
        guard let v = try? c.decodeIfPresent(T.self, forKey: AnyKey(key)) else { return nil }
        return v
    }
    /// 60 でも 60.0 でも "60" 相当でも Int として読む。
    func int(_ key: String) -> Int? {
        if let v: Int = value(key) { return v }
        if let d: Double = value(key), d.isFinite { return Int(d.rounded()) }
        return nil
    }
    func double(_ key: String) -> Double? { value(key) }
    func string(_ key: String) -> String? { value(key) }
    func bool(_ key: String) -> Bool? { value(key) }

    /// 既知キー以外をそのまま集める。
    func extra() -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for k in c.allKeys where !known.contains(k.stringValue) {
            if let v = try? c.decode(JSONValue.self, forKey: k) { out[k.stringValue] = v }
        }
        return out
    }
}

func newId() -> String {
    let chars = "0123456789abcdefghijklmnopqrstuvwxyz".map { String($0) }
    return (0..<8).map { _ in chars.randomElement()! }.joined()
}

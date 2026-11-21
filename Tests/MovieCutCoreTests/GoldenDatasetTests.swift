import XCTest
@testable import MovieCutCore

/// 外部ゴールデンデータセット(`GoldenDataset/`)の検証と生成器。規則は GoldenDataset/README.md を参照。
/// 場所は既存テストと同じく `#filePath` 相対で解決する(Package.swift のリソース宣言は変えない)。
final class GoldenDatasetTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().appendingPathComponent("GoldenDataset")

    private struct Manifest: Decodable {
        struct Case: Decodable { let id: String; let kind: String; let input: String; let expected: String; let notes: String? }
        let datasetVersion: String
        let projectFormatVersion: Int
        let spec: String
        let cases: [Case]
    }

    private func loadManifest() throws -> Manifest {
        try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: Self.root.appendingPathComponent("manifest.json")))
    }

    /// decode → encode した結果を canonical 文字列にする。
    private func canonicalOutput(forInput relPath: String) throws -> String {
        let data = try Data(contentsOf: Self.root.appendingPathComponent(relPath))
        let encoded = try Project.decode(from: data).encoded()
        return try Self.canonical(encoded)
    }

    // MARK: - 検証

    func testManifestHeader() throws {
        let m = try loadManifest()
        XCTAssertEqual(m.projectFormatVersion, 2)
        XCTAssertFalse(m.cases.isEmpty)
    }

    func testAllCasesMatchExpected() throws {
        let m = try loadManifest()
        for c in m.cases {
            let expURL = Self.root.appendingPathComponent(c.expected)
            switch c.kind {
            case "roundtrip-canonical", "fixed-json":
                let expected = try String(contentsOf: expURL, encoding: .utf8)
                XCTAssertEqual(try canonicalOutput(forInput: c.input), expected, "\(c.kind) \(c.id)")
            case "roundtrip-byte-mac":
                let input = try Data(contentsOf: Self.root.appendingPathComponent(c.input))
                let actual = try Project.decode(from: input).encoded()
                XCTAssertEqual(actual, try Data(contentsOf: expURL), "\(c.kind) \(c.id)")
            default:
                XCTFail("未知の kind: \(c.kind)")
            }
        }
    }

    // MARK: - 生成器

    /// `MOVIECUT_GENERATE_GOLDEN=1` のときだけ、canonical 系ケースの expected を書き出す。
    func testGenerateExpected() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MOVIECUT_GENERATE_GOLDEN"] == "1",
                          "MOVIECUT_GENERATE_GOLDEN=1 のときだけ実行")
        for c in try loadManifest().cases where c.kind == "roundtrip-canonical" || c.kind == "fixed-json" {
            let out = try canonicalOutput(forInput: c.input)
            try Data(out.utf8).write(to: Self.root.appendingPathComponent(c.expected), options: .atomic)
        }
    }

    // MARK: - canonical 化の規則自体のテスト

    func testCanonicalRules() throws {
        let json = #"{"b":[],"a":{},"z":[1,2.5,-0.0,1e3,true,null],"s":"a/\"\\\n\u0001é"}"#
        let expected = """
        {
          "a": {},
          "b": [],
          "s": "a/\\\"\\\\\\n\\u0001é",
          "z": [
            1,
            2.5,
            0,
            1000,
            true,
            null
          ]
        }
        """
        XCTAssertEqual(try Self.canonical(Data(json.utf8)), expected)
    }

    // MARK: - canonical 実装

    static func canonical(_ data: Data) throws -> String {
        let v = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return dump(v, indent: 0)
    }

    private static func dump(_ v: Any, indent: Int) -> String {
        let pad = String(repeating: "  ", count: indent + 1)
        let close = String(repeating: "  ", count: indent)
        switch v {
        case is NSNull: return "null"
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            return number(n)
        case let s as String: return string(s)
        case let a as [Any]:
            if a.isEmpty { return "[]" }
            return "[\n" + a.map { pad + dump($0, indent: indent + 1) }.joined(separator: ",\n") + "\n" + close + "]"
        case let o as [String: Any]:
            if o.isEmpty { return "{}" }
            let keys = o.keys.sorted { Array($0.unicodeScalars.map(\.value)).lexicographicallyPrecedes($1.unicodeScalars.map(\.value)) }
            return "{\n" + keys.map { pad + string($0) + ": " + dump(o[$0]!, indent: indent + 1) }.joined(separator: ",\n") + "\n" + close + "}"
        default: return "null"
        }
    }

    private static func number(_ n: NSNumber) -> String {
        let d = n.doubleValue
        if d == d.rounded(), abs(d) < 9007199254740992 { return String(Int64(d)) } // -0 も 0 になる
        return "\(d)"
    }

    private static func string(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if u.value < 0x20 { out += String(format: "\\u%04x", u.value) } else { out.unicodeScalars.append(u) }
            }
        }
        return out + "\""
    }
}

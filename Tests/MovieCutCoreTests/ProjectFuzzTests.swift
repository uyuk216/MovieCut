import XCTest
@testable import MovieCutCore

/// 書類の読み込みのファジング。フィクスチャの JSON を、乱数(固定シード)で
/// キーの削除・追加・値の差し替え・配列の切り詰め・バイト切り詰めで壊し、
/// `Project.decode` が「エラーを返す」か「プロジェクトを返す」のどちらかで止まり、クラッシュしないことを見る。
/// 読めたものは、書き直して読み直しても同じバイト列になる(未知のキーを含めて安定)ことも確かめる。
final class ProjectFuzzTests: XCTestCase {
    /// 再現できるように固定シードの SplitMix64。
    struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    enum Step { case key(String), index(Int) }

    /// 読めた書類にだけ入れる、未知のキー名(既存のキーと衝突しない)。
    static let unknownKeyPrefix = "zzFuzzUnknown"

    static let pool: [JSONValue] = [
        .null, .bool(true), .bool(false), .number(0), .number(-1), .number(1e308), .number(-0.0),
        .number(1e-308), .number(9_007_199_254_740_993), .string(""), .string("x"), .string("0"),
        .string("ぱ\u{0}"), .array([]), .object([:]), .array([.number(1), .string("a")]),
        .object(["a": .null, "b": .array([.bool(true)])]),
    ]

    func allPaths(_ v: JSONValue, _ prefix: [Step] = []) -> [[Step]] {
        var out = [prefix]
        switch v {
        case .object(let d):
            // 辞書の順は実行ごとに変わるので、キーの順にそろえて、同じシードなら同じ壊し方になるようにする
            for (k, child) in d.sorted(by: { $0.key < $1.key }) { out += allPaths(child, prefix + [.key(k)]) }
        case .array(let a):
            for (i, child) in a.enumerated() { out += allPaths(child, prefix + [.index(i)]) }
        default: break
        }
        return out
    }

    /// path の位置の値を変換する。nil を返すと、その値を親から取り除く。
    func transform(_ v: JSONValue, _ path: ArraySlice<Step>, _ f: (JSONValue) -> JSONValue?) -> JSONValue? {
        guard let step = path.first else { return f(v) }
        let rest = path.dropFirst()
        switch (v, step) {
        case (.object(var d), .key(let k)):
            guard let child = d[k] else { return v }
            if let new = transform(child, rest, f) { d[k] = new } else { d[k] = nil }
            return .object(d)
        case (.array(var a), .index(let i)):
            guard i < a.count else { return v }
            if let new = transform(a[i], rest, f) { a[i] = new } else { a.remove(at: i) }
            return .array(a)
        default:
            return v
        }
    }

    /// 1 回分の壊し方。戻り値は壊したバイト列と、未知キーを入れたかどうか(入れたときだけ、その後の round-trip を確かめる)。
    func mutate(_ base: JSONValue, _ rng: inout SplitMix64, index n: Int) -> (JSONValue, String?) {
        var doc = base
        let ops = Int.random(in: 1...4, using: &rng)
        var unknown: String?
        for _ in 0..<ops {
            let paths = allPaths(doc)
            guard let path = paths.randomElement(using: &rng) else { break }
            switch Int.random(in: 0..<5, using: &rng) {
            case 0: // 削除(ルートは消さない)
                if !path.isEmpty, let d = transform(doc, path[...], { _ in nil }) { doc = d }
            case 1: // 値の差し替え(型を変える)
                let repl = Self.pool.randomElement(using: &rng)!
                doc = transform(doc, path[...], { _ in repl }) ?? doc
            case 2: // 既存のオブジェクトに未知のキーを足す(ルートなら検証対象にする)
                let key = "\(Self.unknownKeyPrefix)\(n)_\(Int.random(in: 0..<1000, using: &rng))"
                let val = Self.pool.randomElement(using: &rng)!
                doc = transform(doc, path[...], { node in
                    if case .object(var d) = node { d[key] = val; return .object(d) }
                    return nil
                }) ?? doc
                if path.isEmpty { unknown = key }
            case 3: // 配列の末尾を切る、または先頭に要素を入れる
                doc = transform(doc, path[...], { node in
                    if case .array(var a) = node {
                        if !a.isEmpty { a.removeLast() } else { a.append(Self.pool.randomElement(using: &rng)!) }
                        return .array(a)
                    }
                    return nil
                }) ?? doc
            default: // 数値を極端な値へ
                doc = transform(doc, path[...], { node in
                    if case .number = node { return .number([1e308, -1e308, 0, 1e-300, 1e15].randomElement(using: &rng)!) }
                    return nil
                }) ?? doc
            }
        }
        return (doc, unknown)
    }

    func fixtureURLs() throws -> [URL] {
        let ym = Bundle.module.urls(forResourcesWithExtension: "ymproj", subdirectory: "Fixtures") ?? []
        let js = Bundle.module.urls(forResourcesWithExtension: "json", subdirectory: "Fixtures") ?? []
        let all = (ym + js).sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertFalse(all.isEmpty, "フィクスチャが見つからない")
        return all
    }

    func testFuzzedFixturesNeverCrashAndUnknownKeysRoundTrip() throws {
        let iterations = 150
        var decodedOK = 0, rejected = 0, unknownChecked = 0
        var rng = SplitMix64(state: 0x4D6F_7669_6543_7574)  // "MovieCut"

        for url in try fixtureURLs() {
            let data = try Data(contentsOf: url)
            let base = try JSONDecoder().decode(JSONValue.self, from: data)
            let name = url.lastPathComponent

            for n in 0..<iterations {
                // 2 割はバイト列の切り詰め(途中で切れた JSON)
                let bytes: Data
                var unknown: String?
                if Int.random(in: 0..<5, using: &rng) == 0 {
                    bytes = data.prefix(Int.random(in: 0...data.count, using: &rng))
                } else {
                    var (doc, u) = mutate(base, &rng, index: n)
                    unknown = u
                    // 3 割はルート直下に未知のキーを必ず足す(読めたら残ることを確かめる)
                    if Int.random(in: 0..<3, using: &rng) == 0, case .object(var d) = doc {
                        let key = "\(Self.unknownKeyPrefix)\(n)_root"
                        d[key] = Self.pool.randomElement(using: &rng)!
                        doc = .object(d)
                        unknown = key
                    }
                    bytes = try JSONEncoder().encode(doc)
                }

                guard let project = try? Project.decode(from: bytes) else {
                    rejected += 1
                    continue
                }
                decodedOK += 1

                // 読めたものは書き直し・読み直しても同じバイト列(安定)
                let out1 = try project.encoded()
                let again = try Project.decode(from: out1)
                let out2 = try again.encoded()
                XCTAssertEqual(out1, out2, "\(name) #\(n): 書き直しが安定しない")

                // 未知のキー(ルート直下に足したもの)は、読めた後も残る
                if let key = unknown {
                    let tree = try JSONDecoder().decode(JSONValue.self, from: out1)
                    guard case .object(let d) = tree else {
                        XCTFail("\(name) #\(n): 書き直した結果がオブジェクトでない")
                        continue
                    }
                    XCTAssertNotNil(d[key], "\(name) #\(n): 未知のキー \(key) が消えた")
                    unknownChecked += 1
                }
            }
        }
        // 壊れた入力で「全部読めた」「全部拒否」にならないこと(ファジングが効いている証拠)
        XCTAssertGreaterThan(decodedOK, 0)
        XCTAssertGreaterThan(rejected, 0)
        print("fuzz: decoded=\(decodedOK) rejected=\(rejected) unknownKeyKept=\(unknownChecked)")
    }
}

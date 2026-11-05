import XCTest
@testable import MovieCut

/// ガード: 項目表(AppMenuSpec)で作る MenuItemSpec が、実際のメニュー構造(AppCommands)から全部たどり着けること。
/// 「字幕を追加」「パッケージ保存」「字幕を翻訳」が、表に定義されたのにメニューへ置き忘れられたことがあったため。
/// 方法: AppMenu.swift から MenuItemSpec を返す宣言(関数・定数)を拾い、AppCommands.swift が `AppMenuSpec.<名前>` で直接使う宣言を出発点に、
/// 宣言の本体が呼ぶ別の宣言(まとめ関数が部品を並べる形)をたどる。たどり着けなかった宣言があれば失敗する。
/// (`all` は確認用の一覧で、メニューの描画ではないので出発点にしない。)
final class MenuReachabilityTests: XCTestCase {
    /// 確認用の一覧(`all`)のためだけに部品をまとめた宣言。部品は個別にメニューへ置くので、これ自身は置かなくてよい。
    static let aggregateOnly: Set<String> = ["mediaSubtitleItems"]

    struct Decl { var name: String; var returnsItems: Bool; var body: String }

    /// `enum AppMenuSpec { ... }` の中の static 宣言(インデント 4)を、本体の文字列つきで拾う。
    static func declarations(in source: String) -> [Decl] {
        let lines = source.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.hasPrefix("enum AppMenuSpec") }) else { return [] }
        // enum の終わり = インデント 0 の `}`
        let end = lines[(start + 1)...].firstIndex(where: { $0 == "}" }) ?? lines.count
        let head = try! NSRegularExpression(pattern: #"^    (?:private |fileprivate )?static (?:func|let|var) (\w+)"#)
        var decls: [Decl] = []
        var current: (name: String, sig: String, body: [String])?
        func flush() {
            if let c = current { decls.append(Decl(name: c.name, returnsItems: c.sig.contains("MenuItemSpec"), body: c.body.joined(separator: "\n"))) }
        }
        for line in lines[(start + 1)..<end] {
            let ns = line as NSString
            if let m = head.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                flush()
                current = (ns.substring(with: m.range(at: 1)), line, [line])
            } else if current != nil {
                current!.body.append(line)
            }
        }
        flush()
        return decls
    }

    /// `AppMenuSpec.<名前>` で使っている名前の集合(AppCommands.swift)。
    static func usedByCommands(_ source: String) -> Set<String> {
        let re = try! NSRegularExpression(pattern: #"AppMenuSpec\.(\w+)"#)
        let ns = source as NSString
        return Set(re.matches(in: source, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) })
    }

    /// 本体のコメントを除いた文字列に、名前が識別子として出てくるか。
    static func mentions(_ body: String, _ name: String, selfName: String) -> Bool {
        guard name != selfName else { return false }
        let code = body.components(separatedBy: "\n").map { l -> String in
            if let r = l.range(of: "//") { return String(l[l.startIndex..<r.lowerBound]) }
            return l
        }.joined(separator: "\n")
        return code.range(of: #"(?<![\w.])\#(name)\b"#, options: .regularExpression) != nil
            || code.range(of: #"AppMenuSpec\.\#(name)\b"#, options: .regularExpression) != nil
    }

    /// メニューから届かない MenuItemSpec 宣言の名前。
    static func unreachable(menuSource: String, commandsSource: String) -> [String] {
        let decls = declarations(in: menuSource).filter { $0.name != "all" && !aggregateOnly.contains($0.name) }
        let byName = Dictionary(decls.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        var reached = usedByCommands(commandsSource).intersection(byName.keys)
        var queue = Array(reached)
        while let n = queue.popLast() {
            guard let d = byName[n] else { continue }
            for other in decls where !reached.contains(other.name) && mentions(d.body, other.name, selfName: n) {
                reached.insert(other.name); queue.append(other.name)
            }
        }
        return decls.filter { $0.returnsItems && !reached.contains($0.name) }.map(\.name).sorted()
    }

    private static func source(_ file: String) throws -> String {
        let here = URL(fileURLWithPath: #filePath)
        let url = here.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MovieCut/\(file)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testEveryMenuItemSpecIsReachableFromTheRealMenu() throws {
        let menu = try Self.source("AppMenu.swift"), commands = try Self.source("AppCommands.swift")
        let decls = Self.declarations(in: menu)
        XCTAssertGreaterThan(decls.filter(\.returnsItems).count, 100, "宣言を拾えていない(AppMenu.swift の形が変わった?)")
        for known in ["addSubtitle", "packageSave", "subtitleTranslate", "rollEditItem", "slipEditItem", "layerItems"] {
            XCTAssertTrue(decls.contains { $0.name == known && $0.returnsItems }, "\(known) を拾えていない")
        }
        let missing = Self.unreachable(menuSource: menu, commandsSource: commands)
        XCTAssertTrue(missing.isEmpty, "メニューに置かれていない項目: \(missing.joined(separator: ", ")) — AppCommands.swift に並べるか、まとめ関数に入れてください")
    }

    /// ガード自身の確認: 置き忘れた宣言を見つけられる / まとめ関数経由は届く。
    func testGuardDetectsAnOrphanAndFollowsGroups() {
        let menu = """
        enum AppMenuSpec {
            static func group(_ s: MenuState) -> [MenuItemSpec] {
                [part(s)]
            }
            static func part(_ s: MenuState) -> MenuItemSpec {
                MenuItemSpec(command: .about, title: "x", shortcut: nil, enabled: true, checked: nil)
            }
            static func orphan(_ s: MenuState) -> MenuItemSpec {
                // group(s) と書いてあってもコメントは無視
                MenuItemSpec(command: .about, title: "y", shortcut: nil, enabled: true, checked: nil)
            }
            static func all(_ s: MenuState) -> [MenuItemSpec] { [orphan(s)] + group(s) }
            static func title(_ s: MenuState) -> String { "" }
        }
        """
        let commands = "items(AppMenuSpec.group(s), run)"
        XCTAssertEqual(Self.unreachable(menuSource: menu, commandsSource: commands), ["orphan"])
        XCTAssertEqual(Self.unreachable(menuSource: menu, commandsSource: commands + "\nMenuItemView(spec: AppMenuSpec.orphan(s), perform: run)"), [])
    }
}

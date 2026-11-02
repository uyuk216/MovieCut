import XCTest
@testable import MovieCutCore

final class DockLayoutTests: XCTestCase {
    private func assertValid(_ l: DockLayout, _ msg: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(l.isValid, "不変条件が崩れた: \(msg) \(l)", file: file, line: line)
    }

    static func rounded(_ n: DockNode) -> DockNode {
        switch n {
        case .group: return n
        case .split(let a, let f, let x, let y): return .split(axis: a, fraction: (f * 1e6).rounded() / 1e6, first: rounded(x), second: rounded(y))
        }
    }

    // MARK: 初期配置とプリセット

    func testDefaultIsYMM4Arrangement() {
        let d = DockLayout.default
        assertValid(d)
        XCTAssertEqual(Set(d.docked), Set(DockPanel.allCases))
        guard case .split(let axis, let cf, let left, let right)? = d.root else { return XCTFail() }
        XCTAssertEqual(axis, .horizontal)                                                // 左の列 / 右の列
        XCTAssertEqual(cf, 0.66, accuracy: 0.001)
        XCTAssertEqual(right, .group(DockGroup(panels: [.inspector, .characters], active: .inspector)))  // 右 = プロパティ|キャラクター(タブ)
        guard case .split(.vertical, let vf, let top, let bottom) = left else { return XCTFail() }
        XCTAssertEqual(vf, 0.6, accuracy: 0.001)
        XCTAssertEqual(top, .group(DockGroup(panels: [.preview])))                        // 左上 = プレビュー
        XCTAssertEqual(bottom, .group(DockGroup(panels: [.timeline])))                    // 左下 = タイムライン
    }

    func testPresetsAreValid() {
        for p in DockPreset.allCases { assertValid(DockLayout.preset(p), p.title) }
        XCTAssertEqual(DockLayout.preset(.initial), .default)
        let one = DockLayout.preset(.singleTab)
        XCTAssertEqual(one.root, .group(DockGroup(panels: [.characters, .preview, .inspector, .timeline], active: .preview)))
        // すべて分離 = 4 つのグループ(各 1 パネル)
        func groups(_ n: DockNode) -> [DockGroup] {
            switch n { case .group(let g): return [g]; case .split(_, _, let a, let b): return groups(a) + groups(b) }
        }
        let sep = groups(DockLayout.preset(.allSeparate).root!)
        XCTAssertEqual(sep.count, 4)
        XCTAssertTrue(sep.allSatisfy { $0.panels.count == 1 })
        // プレビューを大きく: プレビューが最大の割合(幅 0.8 * 0.78 ≒ 62%)
        let big = DockLayout.preset(.previewLarge)
        XCTAssertEqual(big.docked.sorted { $0.rawValue < $1.rawValue }, DockPanel.allCases.sorted { $0.rawValue < $1.rawValue })
        XCTAssertNotNil(big.group(containing: .characters)?.panels.contains(.inspector))
    }

    // MARK: タブ

    func testMoveToTabMergesIntoGroupAndCollapsesTheEmptyOne() {
        var l = DockLayout.default
        XCTAssertTrue(l.moveToTab(.inspector, ofGroupContaining: .preview))
        assertValid(l)
        XCTAssertEqual(l.group(containing: .preview)?.panels, [.preview, .inspector])
        XCTAssertEqual(l.group(containing: .preview)?.active, .inspector)               // 入れたタブが前に出る
        XCTAssertEqual(l.docked.count, 4)
        // プロパティの元のグループは消え、空のグループは残らない
        XCTAssertEqual(l.docked.filter { $0 == .inspector }.count, 1)
    }

    func testMoveToTabAtIndexAndReorder() {
        var l = DockLayout.preset(.singleTab)                                            // [キャラクター, プレビュー, プロパティ, タイムライン]
        XCTAssertTrue(l.moveToTab(.timeline, ofGroupContaining: .characters, at: 0))
        XCTAssertEqual(l.group(containing: .preview)?.panels, [.timeline, .characters, .preview, .inspector])
        XCTAssertTrue(l.moveToTab(.timeline, ofGroupContaining: .inspector, at: 4))     // 末尾へ
        XCTAssertEqual(l.group(containing: .preview)?.panels, [.characters, .preview, .inspector, .timeline])
        XCTAssertFalse(l.moveToTab(.timeline, ofGroupContaining: .inspector, at: 4), "同じ位置なら何も変わらない")
        XCTAssertFalse(l.moveToTab(.timeline, ofGroupContaining: .timeline))
        assertValid(l)
    }

    func testMoveToTabRefusesUndockedTarget() {
        var l = DockLayout.default
        l.detach(.preview)
        let before = l
        XCTAssertFalse(l.moveToTab(.inspector, ofGroupContaining: .preview))
        XCTAssertEqual(l, before)
    }

    // MARK: 辺への分割

    func testMoveToEdgeCreatesSplit() {
        var l = DockLayout.preset(.singleTab)
        XCTAssertTrue(l.moveToEdge(.timeline, .bottom, ofGroupContaining: .preview, fraction: 0.3))
        assertValid(l)
        guard case .split(let axis, let f, let first, let second)? = l.root else { return XCTFail() }
        XCTAssertEqual(axis, .vertical)
        XCTAssertEqual(f, 0.7, accuracy: 1e-9)                                          // 新しい側が下 30%
        XCTAssertEqual(second, .group(DockGroup(panels: [.timeline])))
        XCTAssertEqual(first.panels, [.characters, .preview, .inspector])

        XCTAssertTrue(l.moveToEdge(.characters, .left, ofGroupContaining: .preview))
        assertValid(l)
        XCTAssertEqual(l.docked.first, .characters)
    }

    func testMoveToEdgeOfOwnSingleGroupIsNoOp() {
        var l = DockLayout.default
        let before = l
        XCTAssertFalse(l.moveToEdge(.timeline, .top, ofGroupContaining: .timeline))
        XCTAssertEqual(l, before)
    }

    func testMoveToEdgeOfOwnGroupSplitsItOff() {
        var l = DockLayout.preset(.singleTab)
        XCTAssertTrue(l.moveToEdge(.inspector, .right, ofGroupContaining: .inspector))
        assertValid(l)
        XCTAssertEqual(l.group(containing: .inspector)?.panels, [.inspector])
        XCTAssertEqual(l.group(containing: .preview)?.panels, [.characters, .preview, .timeline])
    }

    func testActiveTabIsFixedWhenTheActiveOneLeaves() {
        var l = DockLayout.preset(.singleTab)                                            // active = preview
        XCTAssertTrue(l.moveToEdge(.preview, .top, ofGroupContaining: .timeline))
        assertValid(l)
        let rest = l.group(containing: .timeline)!
        XCTAssertTrue(rest.panels.contains(rest.active))
        XCTAssertFalse(rest.panels.contains(.preview))
    }

    // MARK: 別ウインドウ・閉じる・戻す

    func testDetachAndAttachReturnsToTheHomeNeighbour() {
        for p in DockPanel.allCases {
            var l = DockLayout.default
            XCTAssertTrue(l.detach(p))
            assertValid(l, "detach \(p)")
            XCTAssertEqual(l.floating, [p])
            XCTAssertEqual(l.location(of: p), .floating)
            XCTAssertFalse(l.docked.contains(p))
            XCTAssertTrue(l.attach(p))
            assertValid(l, "attach \(p)")
            XCTAssertEqual(l.location(of: p), .docked)
            XCTAssertTrue(l.floating.isEmpty)
            // 戻すと初期配置そのもの(構造も比率も。浮動小数の誤差は丸める)に戻る
            XCTAssertEqual(Self.rounded(l.root!), Self.rounded(DockLayout.default.root!), "\(p) が元の位置に戻る")
        }
    }

    func testDetachTwiceAndAttachDockedAreNoOps() {
        var l = DockLayout.default
        XCTAssertTrue(l.detach(.inspector))
        XCTAssertFalse(l.detach(.inspector))
        XCTAssertFalse(l.attach(.timeline))
        XCTAssertEqual(l.floating, [.inspector])
    }

    func testDetachEverythingLeavesEmptyRootButStaysValid() {
        var l = DockLayout.default
        for p in DockPanel.allCases { XCTAssertTrue(l.detach(p)) }
        XCTAssertNil(l.root)
        assertValid(l)
        XCTAssertEqual(l.floating.count, 4)
        XCTAssertTrue(l.attach(.preview))
        XCTAssertEqual(l.docked, [.preview])
        XCTAssertTrue(l.attach(.timeline))
        XCTAssertEqual(Set(l.docked), [.preview, .timeline])
        assertValid(l)
    }

    func testCloseAndReopenViaToggle() {
        var l = DockLayout.default
        XCTAssertTrue(l.close(.characters))
        XCTAssertFalse(l.close(.characters))
        XCTAssertEqual(l.closed, [.characters])
        XCTAssertFalse(l.isVisible(.characters))
        assertValid(l)
        l.toggle(.characters)
        XCTAssertTrue(l.isVisible(.characters))
        XCTAssertEqual(l.docked, DockLayout.default.docked)
        // 別ウインドウのパネルを toggle すると閉じる
        l.detach(.inspector)
        XCTAssertTrue(l.isVisible(.inspector))
        l.toggle(.inspector)
        XCTAssertEqual(l.location(of: .inspector), .closed)
        assertValid(l)
    }

    func testResetFromAnything() {
        var l = DockLayout.preset(.allSeparate)
        l.detach(.timeline); l.close(.characters)
        l.apply(.initial)
        XCTAssertEqual(l, .default)
    }

    func testReattachAllFloating() {
        var l = DockLayout.default
        l.detach(.preview); l.detach(.inspector); l.close(.characters)
        l.reattachAllFloating()
        XCTAssertTrue(l.floating.isEmpty)
        XCTAssertEqual(l.closed, [.characters])                                          // 閉じたものは閉じたまま
        assertValid(l)
    }

    // MARK: 比率

    func testSetFractionClampsAndTargetsTheRightSplit() {
        var l = DockLayout.default
        XCTAssertTrue(l.setFraction(at: [], to: 0.5))
        XCTAssertTrue(l.setFraction(at: [], to: 5))
        guard case .split(_, let f, _, _)? = l.root else { return XCTFail() }
        XCTAssertEqual(f, DockLayout.maxFraction)
        XCTAssertTrue(l.setFraction(at: [false], to: -3))
        guard case .split(_, _, let top, _)? = l.root, case .split(_, let f2, _, _) = top else { return XCTFail() }
        XCTAssertEqual(f2, DockLayout.minFraction)
        XCTAssertFalse(l.setFraction(at: [false], to: -3), "同じ値は変更なし")
        XCTAssertFalse(l.setFraction(at: [true], to: 0.5), "グループには比率が無い")
        l.setFraction(at: [], to: .nan)
        assertValid(l, "NaN")
        assertValid(l)
    }

    func testMetricsKeepBothSidesAtLeastMinimum() {
        XCTAssertEqual(DockMetrics.firstSize(total: 1000, fraction: 0.5), (1000 - 6) * 0.5, accuracy: 1e-9)
        XCTAssertEqual(DockMetrics.firstSize(total: 1000, fraction: 0.1), 120, accuracy: 1e-9)              // 最小
        XCTAssertEqual(DockMetrics.firstSize(total: 1000, fraction: 0.9), 1000 - 6 - 120, accuracy: 1e-9)
        XCTAssertEqual(DockMetrics.firstSize(total: 200, fraction: 0.9), 97, accuracy: 1e-9)                // 狭すぎれば半々
        XCTAssertEqual(DockMetrics.fraction(forFirstSize: 497, total: 1000), 0.5, accuracy: 1e-9)
        XCTAssertEqual(DockMetrics.fraction(forFirstSize: 5000, total: 1000), 0.9, accuracy: 1e-9)
    }

    // MARK: ドロップ位置

    func testDropZones() {
        func z(_ x: Double, _ y: Double) -> DockDropZone { DockDropZone.zone(x: x, y: y, width: 400, height: 326, tabBarHeight: 26) }
        XCTAssertEqual(z(200, 10), .tab)                  // タブバー
        XCTAssertEqual(z(200, 26 + 150), .tab)            // 中央
        XCTAssertEqual(z(10, 26 + 150), .edge(.left))
        XCTAssertEqual(z(395, 26 + 150), .edge(.right))
        XCTAssertEqual(z(200, 26 + 5), .edge(.top))
        XCTAssertEqual(z(200, 320), .edge(.bottom))
        XCTAssertEqual(z(-50, 26 + 150), .edge(.left))    // はみ出しは丸める
        XCTAssertEqual(DockDropZone.zone(x: 0, y: 0, width: 0, height: 0), .tab)
    }

    // MARK: 保存(JSON)

    func testJSONRoundTripForEveryPresetAndMixedStates() throws {
        var mixed = DockLayout.preset(.previewLarge)
        mixed.detach(.timeline); mixed.close(.characters)
        for l in DockPreset.allCases.map({ DockLayout.preset($0) }) + [mixed, DockLayout.default] {
            let data = try XCTUnwrap(l.encoded())
            XCTAssertEqual(DockLayout.decoded(from: data), l)
            XCTAssertEqual(try JSONDecoder().decode(DockLayout.self, from: data), l)
        }
        XCTAssertEqual(DockLayout.decoded(from: mixed.encoded()).floating, [.timeline])
    }

    func testForLaunchReattachesFloatingPanels() throws {
        var l = DockLayout.default
        l.detach(.preview)
        let launched = DockLayout.forLaunch(from: l.encoded())
        XCTAssertTrue(launched.floating.isEmpty)
        XCTAssertEqual(launched.location(of: .preview), .docked)
        assertValid(launched)
    }

    func testGarbageFallsBackToDefault() {
        let junk: [Data?] = [nil, Data(), Data("not json".utf8), Data("{}".utf8), Data("[1,2,3]".utf8), Data("null".utf8),
                             Data(#"{"root":{"kind":"wat"}}"#.utf8),
                             Data(#"{"root":{"kind":"group","panels":[]}}"#.utf8),                                // 空のグループ
                             Data(#"{"root":{"kind":"group","panels":["preview","preview","timeline","inspector","characters"]}}"#.utf8),   // 重複
                             Data(#"{"root":{"kind":"group","panels":["preview"]}}"#.utf8),                       // 足りない
                             Data(#"{"root":{"kind":"group","panels":["preview","nope"]}}"#.utf8),                // 知らないパネル
                             Data(#"{"root":null,"floating":["preview"],"closed":[]}"#.utf8),                    // 足りない
                             Data(#"{"root":{"kind":"split","axis":"diagonal","fraction":0.5}}"#.utf8)]
        for d in junk { XCTAssertEqual(DockLayout.decoded(from: d), .default, String(data: d ?? Data(), encoding: .utf8) ?? "nil") }
    }

    func testOutOfRangeFractionsAreClampedNotDiscarded() throws {
        var l = DockLayout.default
        l.setFraction(at: [], to: 0.5)
        var json = try XCTUnwrap(String(data: try XCTUnwrap(l.encoded()), encoding: .utf8))
        json = json.replacingOccurrences(of: "0.5", with: "7.5")
        let back = DockLayout.decoded(from: Data(json.utf8))
        XCTAssertNotEqual(back, .default)
        assertValid(back)
        guard case .split(_, let f, _, _)? = back.root else { return XCTFail() }
        XCTAssertEqual(f, DockLayout.maxFraction)
    }

    func testActiveNotInGroupIsRepaired() {
        let json = #"{"root":{"kind":"group","panels":["characters","preview","inspector","timeline"],"active":"nope"}}"#
        // 知らない active は decode で落ちる → 初期配置(壊れた値を黙って通さない)
        XCTAssertEqual(DockLayout.decoded(from: Data(json.utf8)), .default)
        let missing = #"{"root":{"kind":"group","panels":["characters","preview","inspector","timeline"]}}"#
        let l = DockLayout.decoded(from: Data(missing.utf8))
        XCTAssertEqual(l.group(containing: .preview)?.active, .characters)               // active が無ければ先頭
        XCTAssertTrue(l.isValid)
    }

    func testVeryDeepTreeIsRejected() {
        var node = "{\"kind\":\"group\",\"panels\":[\"characters\",\"preview\",\"inspector\",\"timeline\"]}"
        let leaf = "{\"kind\":\"group\",\"panels\":[\"characters\"]}"
        for _ in 0..<40 { node = "{\"kind\":\"split\",\"axis\":\"horizontal\",\"fraction\":0.5,\"first\":\(node),\"second\":\(leaf)}" }
        XCTAssertEqual(DockLayout.decoded(from: Data("{\"root\":\(node)}".utf8)), .default)
    }

    // MARK: 乱数で操作を重ねても崩れない

    func testRandomOperationSequencesKeepInvariants() {
        var rng = SystemRandomNumberGenerator()
        var l = DockLayout.default
        let panels = DockPanel.allCases, edges = DockEdge.allCases
        for step in 0..<4000 {
            let a = panels.randomElement(using: &rng)!, b = panels.randomElement(using: &rng)!
            switch Int.random(in: 0..<9, using: &rng) {
            case 0: l.moveToTab(a, ofGroupContaining: b, at: Bool.random() ? Int.random(in: -1..<6) : nil)
            case 1: l.moveToEdge(a, edges.randomElement(using: &rng)!, ofGroupContaining: b, fraction: Double.random(in: -1..<2))
            case 2: l.detach(a)
            case 3: l.attach(a)
            case 4: l.close(a)
            case 5: l.toggle(a)
            case 6: l.setActive(a)
            case 7: l.setFraction(at: (0..<Int.random(in: 0..<4)).map { _ in Bool.random() }, to: Double.random(in: -1..<2))
            default: if Int.random(in: 0..<30, using: &rng) == 0 { l.apply(DockPreset.allCases.randomElement(using: &rng)!) }
            }
            XCTAssertTrue(l.isValid, "step \(step): \(l)")
            if step % 200 == 0 { XCTAssertEqual(DockLayout.decoded(from: l.encoded()), l) }
        }
    }
}

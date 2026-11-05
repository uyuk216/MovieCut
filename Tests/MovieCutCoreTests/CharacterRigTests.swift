import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import MovieCutCore

/// パーツ式立ち絵(`CharacterRig`): 保存形式・振り分け・状態の重ね方・合成とキャッシュ・描画経路・実ファイル(あれば)。
final class CharacterRigTests: XCTestCase {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("rig-tests-\(UUID().uuidString)")
    override func setUpWithError() throws { try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    /// 単色(中央の四角だけ)の PNG。size × size、`box` が nil なら全面。
    func png(_ name: String, w: Int = 40, h: Int = 40, color: (UInt8, UInt8, UInt8), box: CGRect? = nil) throws -> String {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: CGFloat(color.0) / 255, green: CGFloat(color.1) / 255, blue: CGFloat(color.2) / 255, alpha: 1))
        ctx.fill(box ?? CGRect(x: 0, y: 0, width: w, height: h))
        let url = tmp.appendingPathComponent(name)
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url.path
    }

    func rgb(_ img: CGImage, _ x: Int, _ y: Int) -> [Int] {
        var d = [UInt8](repeating: 0, count: img.width * img.height * 4)
        let c = CGContext(data: &d, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        let i = (y * img.width + x) * 4
        return [Int(d[i]), Int(d[i + 1]), Int(d[i + 2]), Int(d[i + 3])]
    }

    func sampleRig() -> CharacterRig {
        var r = CharacterRig(slots: [
            RigSlot(name: "体", parts: ["b0"], active: 0),
            RigSlot(name: "眉", parts: ["m0", "m1", "m2"], active: 0),
            RigSlot(name: "目", parts: ["e0", "e1", "e2"], active: 0),
            RigSlot(name: "口", parts: ["k0", "k1", "k2", "k3"], active: 0),
            RigSlot(name: "頬", parts: ["c0"], active: -1),
        ])
        r.blink = 2; r.mouthClosed = 1; r.mouthOpen = 3; r.vowels = ["a": 3, "i": 2]
        r.expressions = ["笑顔": ["眉": 1, "目": 1, "口": 2, "頬": 0], "壊れ": ["眉": 99]]
        return r
    }

    // MARK: 保存形式

    func testRigRoundTripKeepsUnknownKeysAndOmitsWhenAbsent() throws {
        var c = Character(); c.name = "霊夢"
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(c), as: UTF8.self).contains("\"rig\""), "リグが無ければ書かない")
        c.rig = sampleRig()
        c.rig?.extra["future"] = .string("x")
        c.rig?.slots[0].extra["note"] = .number(3)
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        let data = try enc.encode(c)
        let back = try JSONDecoder().decode(Character.self, from: data)
        XCTAssertEqual(back, c)
        XCTAssertEqual(back.rig?.extra["future"], .string("x"))
        XCTAssertEqual(back.rig?.slots[0].extra["note"], .number(3))
        XCTAssertEqual(try enc.encode(back), data, "書き直しても同じ")
    }

    func testEmptyOptionalRigFieldsAreNotWritten() throws {
        var r = sampleRig(); r.vowels = [:]; r.expressions = [:]; r.blink = nil
        let s = String(decoding: try JSONEncoder().encode(r), as: UTF8.self)
        XCTAssertFalse(s.contains("vowels")); XCTAssertFalse(s.contains("expressions")); XCTAssertFalse(s.contains("blink"))
        let back = try JSONDecoder().decode(CharacterRig.self, from: Data(s.utf8))
        XCTAssertNil(back.vowels); XCTAssertNil(back.expressions)
    }

    func testOldFixtureCharactersStayByteIdentical() throws {
        // フィクスチャのキャラは rig を持たない: 読み → 書きで rig が足されない
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for f in files where ["ymproj", "mcpjc"].contains(f.pathExtension) {
            let p = try Project.load(from: f)
            XCTAssertTrue(p.characters.allSatisfy { $0.rig == nil }, f.lastPathComponent)
            let out = String(decoding: try JSONEncoder().encode(p.characters), as: UTF8.self)
            XCTAssertFalse(out.contains("\"rig\""))
        }
    }

    // MARK: 名前・振り分け

    func testNaturalSortAndPrefix() {
        let names = ["目 (10).png", "目 (2).png", "目 (1).png"]
        XCTAssertEqual(names.sorted(by: RigNaming.naturalLess), ["目 (1).png", "目 (2).png", "目 (10).png"])
        XCTAssertEqual(RigNaming.prefix(of: "正面A：目 (12).png"), "正面A：目")
        XCTAssertEqual(RigNaming.prefix(of: "髪3.png"), "髪")
        XCTAssertEqual(RigNaming.slotName(for: "正面A：眉 (1)"), "眉")
        XCTAssertEqual(RigNaming.slotName(for: "正面A口"), "口")
        XCTAssertEqual(RigNaming.slotName(for: "正面：頬"), "頬")
        XCTAssertEqual(RigNaming.slotName(for: "霊夢正面ver1 (2)"), "体")
        XCTAssertEqual(RigNaming.slotName(for: "尻尾 (3)"), "尻尾")
        XCTAssertNil(RigNaming.slotName(for: "ふつうの名前"))
    }

    func testGroupingBySlotsSizesAndOrder() throws {
        func f(_ p: String, _ dir: String = "x") -> (path: String, parent: String) { ("/m/\(p)", dir) }
        let files = [f("目 (10).png"), f("目 (2).png"), f("目 (1).png"), f("眉 (1).png"), f("口 (1).png"), f("口 (2).png"),
                     f("頬.png"), f("髪 (1).png"), f("体 (1).png"), f("体 (2).png"),
                     f("顔A体A (1).png"), f("目 (99).png"), f("尻尾 加工用.png"), f("ふつう.png"), f("羽 (1).png"), f("羽 (2).png")]
        let sizes: [String: (w: Int, h: Int)] = [
            "/m/髪 (1).png": (100, 110),           // 高さだけ少し違う: 使う
            "/m/顔A体A (1).png": (100, 100),       // 完成絵: 体にしない(未分類に回る)
            "/m/目 (99).png": (50, 50),            // 違う大きさ: 使わない
        ]
        let rep = try XCTUnwrap(RigFolderImporter.group(files: files) { sizes[$0] ?? (100, 100) })
        XCTAssertEqual(rep.rig.slots.map(\.name), ["体", "髪", "頬", "眉", "目", "口", "羽"], "標準の並び → 自由なスロット")
        XCTAssertEqual(rep.rig.slot("目")?.parts.map { ($0 as NSString).lastPathComponent }, ["目 (1).png", "目 (2).png", "目 (10).png"])
        XCTAssertEqual(rep.skippedSize, ["目 (99).png"])
        XCTAssertEqual(rep.rig.slot("頬")?.active, -1); XCTAssertEqual(rep.rig.slot("髪")?.active, -1)
        XCTAssertEqual(rep.rig.slot("体")?.active, 0); XCTAssertEqual(rep.rig.slot("口")?.active, 0)
        XCTAssertEqual(rep.rig.slot("羽")?.parts.count, 2, "同じ接頭辞が 2 枚以上なら自由なスロット")
        XCTAssertEqual(rep.unclassified, 2, "顔A体A と ふつう")
        XCTAssertNil(RigFolderImporter.group(files: [], sizeOf: { _ in (1, 1) }))
    }

    func testFolderScanReadsSubfoldersAndParentName() throws {
        for (dir, name) in [("眉フォルダ", "a (1).png"), ("眉フォルダ", "a (2).png")] {
            let d = tmp.appendingPathComponent(dir); try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            _ = try png("\(dir)/\(name)", color: (1, 2, 3))
        }
        _ = try png("目 (1).png", color: (1, 2, 3)); _ = try png("目 (2).png", color: (3, 2, 1))
        let rep = try XCTUnwrap(RigFolderImporter.scan(folder: tmp))
        XCTAssertEqual(rep.rig.slot("眉")?.parts.count, 2, "名前に語が無くても親フォルダ名で振り分ける")
        XCTAssertEqual(rep.rig.slot("目")?.parts.count, 2)
        XCTAssertEqual(rep.width, 40)
    }

    func testBlinkAndMouthGuess() throws {
        // 目: 3 枚は大きな目、1 枚は細い線(閉じた目)。口: 小さい・大きい
        let big = CGRect(x: 5, y: 10, width: 30, height: 14), thin = CGRect(x: 5, y: 16, width: 30, height: 2)
        let eyes = [try png("e0.png", color: (0, 0, 0), box: big), try png("e1.png", color: (0, 0, 0), box: big),
                    try png("e2.png", color: (0, 0, 0), box: thin), try png("e3.png", color: (0, 0, 0), box: big)]
        let mouths = [try png("k0.png", color: (9, 9, 9), box: CGRect(x: 15, y: 15, width: 10, height: 3)),
                      try png("k1.png", color: (9, 9, 9), box: CGRect(x: 12, y: 8, width: 16, height: 16))]
        var rig = CharacterRig(slots: [RigSlot(name: "目", parts: eyes), RigSlot(name: "口", parts: mouths)])
        RigHeuristics.guessRoles(&rig, box: { RigHeuristics.opaqueBox($0, maxPixel: 40) })
        XCTAssertEqual(rig.blink, 2)
        XCTAssertEqual(rig.mouthClosed, 0); XCTAssertEqual(rig.mouthOpen, 1)
        // 全部同じなら自信が無いので何も設定しない
        var flat = CharacterRig(slots: [RigSlot(name: "目", parts: [eyes[0], eyes[1]])])
        RigHeuristics.guessRoles(&flat, box: { RigHeuristics.opaqueBox($0, maxPixel: 40) })
        XCTAssertNil(flat.blink)
    }

    // MARK: 状態の重ね方

    func testResolvedActiveOrderExpressionMouthBlink() {
        let r = sampleRig()
        XCTAssertEqual(r.resolvedActive(), [0, 0, 0, 0, -1])
        // 表情 → 口(話していなければ閉じ)→ まばたき
        XCTAssertEqual(r.resolvedActive(expression: "笑顔", mouth: .closed), [0, 1, 1, 1, 0], "閉じ口は表情の口より優先")
        XCTAssertEqual(r.resolvedActive(expression: "笑顔", mouth: .unchanged), [0, 1, 1, 2, 0])
        XCTAssertEqual(r.resolvedActive(mouth: .open), [0, 0, 0, 3, -1])
        XCTAssertEqual(r.resolvedActive(mouth: .vowel("a")), [0, 0, 0, 3, -1])
        XCTAssertEqual(r.resolvedActive(mouth: .vowel("i")), [0, 0, 0, 2, -1])
        XCTAssertEqual(r.resolvedActive(mouth: .vowel("u")), [0, 0, 0, 3, -1], "割り当てのない母音は「開き」")
        XCTAssertEqual(r.resolvedActive(expression: "笑顔", blinking: true), [0, 1, 2, 2, 0], "まばたきは表情の目より優先")
        XCTAssertEqual(r.resolvedActive(expression: "壊れ"), [0, 0, 0, 0, -1], "使えない添字・未知の表情は無視")
        XCTAssertEqual(r.resolvedActive(expression: "ない"), [0, 0, 0, 0, -1])
        var noBlink = r; noBlink.blink = nil
        XCTAssertEqual(noBlink.resolvedActive(blinking: true), [0, 0, 0, 0, -1])
    }

    func testPathsSkipNoneAndInvalid() {
        var r = sampleRig()
        XCTAssertEqual(r.paths(active: r.resolvedActive()), ["b0", "m0", "e0", "k0"])
        r.slots[1].active = 99
        XCTAssertEqual(r.paths(active: r.slots.map(\.active)), ["b0", "e0", "k0"])
    }

    // MARK: 編集

    func testEditingNoOpsReturnSameValue() {
        let r = sampleRig()
        XCTAssertEqual(RigEditing.select(r, slot: "眉", index: 0), r, "同じ値")
        XCTAssertEqual(RigEditing.select(r, slot: "眉", index: 9), r, "範囲外")
        XCTAssertEqual(RigEditing.select(r, slot: "ない", index: 0), r)
        XCTAssertNotEqual(RigEditing.select(r, slot: "眉", index: 2), r)
        XCTAssertEqual(RigEditing.select(r, slot: "眉", index: 2).slot("眉")?.active, 2)
        // まばたき: 目が 0 番を選んでいて blink=2 → 0 に変わる。もう一度同じなら変わらない
        let b = RigEditing.assignBlink(r)
        XCTAssertEqual(b.blink, 0); XCTAssertEqual(RigEditing.assignBlink(b), b)
        XCTAssertEqual(RigEditing.clearBlink(RigEditing.clearBlink(r)), RigEditing.clearBlink(r))
        // 目が「出さない」のとき割り当てできない
        let off = RigEditing.select(r, slot: "目", index: -1)
        XCTAssertEqual(RigEditing.assignBlink(off), off)
    }

    func testMouthAssignmentAndExpressionEditing() {
        var r = sampleRig()
        r = RigEditing.select(r, slot: "口", index: 2)
        let u = RigEditing.assignMouth(r, role: "u")
        XCTAssertEqual(u.vowels?["u"], 2)
        XCTAssertEqual(RigEditing.assignMouth(u, role: "u"), u, "同じ割り当ては変わらない")
        let cleared = RigEditing.assignMouth(u, role: "u", use: false)
        XCTAssertNil(cleared.vowels?["u"])
        XCTAssertEqual(RigEditing.assignMouth(cleared, role: "u", use: false), cleared)
        var only = CharacterRig(slots: [RigSlot(name: "口", parts: ["k"], active: 0)])
        only = RigEditing.assignMouth(only, role: "a"); only = RigEditing.assignMouth(only, role: "a", use: false)
        XCTAssertNil(only.vowels, "空になれば項目ごと消す")
        XCTAssertEqual(RigEditing.assignMouth(r, role: "zzz"), r)
        // 表情
        let e = RigEditing.captureExpression(r, name: " 驚き ")
        XCTAssertEqual(e.expressions?["驚き"]?["口"], 2)
        XCTAssertEqual(RigEditing.captureExpression(e, name: "驚き"), e, "同じ内容の上書きは変わらない")
        XCTAssertEqual(RigEditing.captureExpression(r, name: "[x]"), r)
        XCTAssertEqual(RigEditing.captureExpression(r, name: " "), r)
        let n = RigEditing.renameExpression(e, from: "驚き", to: "びっくり")
        XCTAssertNotNil(n.expressions?["びっくり"]); XCTAssertNil(n.expressions?["驚き"])
        XCTAssertEqual(RigEditing.renameExpression(e, from: "驚き", to: "笑顔"), e, "既にある名前")
        XCTAssertEqual(RigEditing.renameExpression(e, from: "ない", to: "x"), e)
        let d = RigEditing.deleteExpression(RigEditing.deleteExpression(RigEditing.deleteExpression(n, name: "びっくり"), name: "笑顔"), name: "壊れ")
        XCTAssertNil(d.expressions, "最後の 1 つを消したら項目ごと消す")
        XCTAssertEqual(RigEditing.deleteExpression(d, name: "ない"), d)
        let a = RigEditing.applyExpression(r, name: "笑顔")
        XCTAssertEqual(a.slots.map(\.active), [0, 1, 1, 2, 0])
        XCTAssertEqual(RigEditing.applyExpression(a, name: "笑顔"), a)
    }

    // MARK: 合成とキャッシュ

    func testCompositeOrderAndCacheKeyedByCombination() throws {
        let body = try png("body.png", color: (200, 0, 0))                                         // 全面 赤
        let eye0 = try png("eye0.png", color: (0, 200, 0), box: CGRect(x: 10, y: 10, width: 20, height: 20))
        let eye1 = try png("eye1.png", color: (0, 0, 200), box: CGRect(x: 10, y: 10, width: 20, height: 20))
        let cache = RigFrameCache()
        let a = try XCTUnwrap(cache.frame(paths: [body, eye0], height: 40))
        XCTAssertTrue(a.width == 40 && a.height == 40)
        XCTAssertEqual(rgb(a, 20, 20), [0, 200, 0, 255], "後のパーツが上")
        XCTAssertEqual(rgb(a, 2, 2), [200, 0, 0, 255])
        XCTAssertEqual(cache.composeCount, 1)
        _ = cache.frame(paths: [body, eye0], height: 40)
        XCTAssertEqual(cache.composeCount, 1, "同じ組み合わせはキャッシュ")
        let b = try XCTUnwrap(cache.frame(paths: [body, eye1], height: 40))
        XCTAssertEqual(rgb(b, 20, 20), [0, 0, 200, 255])
        XCTAssertEqual(cache.composeCount, 2)
        _ = cache.frame(paths: [body, eye0], height: 20)
        XCTAssertEqual(cache.composeCount, 3, "高さが違えば別")
        XCTAssertEqual(cache.loadCount, 5, "body・eye0・eye1(40)と body・eye0(20)。同じ大きさのパーツは読み直さない")
        XCTAssertNil(cache.frame(paths: ["/nonexistent.png"], height: 40))
        XCTAssertNotNil(cache.frame(paths: [body, "/nonexistent.png"], height: 40), "読めないパーツは飛ばす")
    }

    func testCacheEvictsOldestBeyondLimit() throws {
        let p = try png("c.png", color: (1, 1, 1))
        let cache = RigFrameCache(); cache.frameLimit = 3
        for h in [10, 11, 12, 13, 14] { _ = cache.frame(paths: [p], height: h) }
        XCTAssertEqual(cache.cachedFrameCount, 3)
        let before = cache.composeCount
        _ = cache.frame(paths: [p], height: 14); XCTAssertEqual(cache.composeCount, before)
        _ = cache.frame(paths: [p], height: 10); XCTAssertEqual(cache.composeCount, before + 1, "追い出されたものは作り直す")
    }

    func testDifferentSizedPartIsBottomAlignedNotStretched() throws {
        let base = try png("base.png", w: 40, h: 40, color: (0, 0, 0))
        // 40×60 の画像の下 10px だけ白。下に揃えるので、40×40 の最下段が白になる
        let tall = try png("tall.png", w: 40, h: 60, color: (255, 255, 255), box: CGRect(x: 0, y: 0, width: 40, height: 10))
        let img = try XCTUnwrap(RigFrameCache().frame(paths: [base, tall], height: 40))
        XCTAssertEqual(rgb(img, 20, 39), [255, 255, 255, 255], "下端は白")
        XCTAssertEqual(rgb(img, 20, 20), [0, 0, 0, 255], "それより上は黒のまま(引き伸ばさない)")
    }

    // MARK: 描画(プレビューと書き出しと同じ Renderer)

    func rigProject(rig: CharacterRig, h: Int = 100) -> Project {
        var p = Project(); p.width = 200; p.height = h; p.bg = "#000000"; p.tracks = []
        var c = Character(); c.id = "reimu"; c.name = "霊夢"; c.x = 0.5; c.y = 0.5; c.scale = 1; c.rig = rig
        p.characters = [c]
        return p
    }

    func testRendererDrawsRigAndBlinks() throws {
        let body = try png("rb.png", color: (200, 0, 0))
        let open = try png("ro.png", color: (0, 200, 0), box: CGRect(x: 15, y: 15, width: 10, height: 10))
        let shut = try png("rs.png", color: (0, 0, 200), box: CGRect(x: 15, y: 15, width: 10, height: 10))
        var rig = CharacterRig(slots: [RigSlot(name: "体", parts: [body], active: 0), RigSlot(name: "目", parts: [open, shut], active: 0)])
        rig.blink = 1
        let p = rigProject(rig: rig)
        let assets = RenderAssets()
        func center(_ t: Double) throws -> [Int] {
            let img = try XCTUnwrap(Renderer(project: p, assets: assets).renderImage(t: t))
            return rgb(img, 100, 50)
        }
        // 瞬きの時刻: 種はキャラ id
        let tBlink = try XCTUnwrap(Blink.starts(seed: "reimu", until: 30).first) + 0.05
        XCTAssertTrue(Blink.isClosed(seed: "reimu", t: tBlink))
        XCTAssertEqual(try center(0.1), [0, 200, 0, 255], "開いた目")
        XCTAssertEqual(try center(tBlink), [0, 0, 200, 255], "まばたき中は閉じた目")
        XCTAssertEqual(try center(0.1), [0, 200, 0, 255])
        XCTAssertEqual(assets.rigCache.composeCount, 2, "組み合わせは 2 通りだけ合成した")
    }

    func testRendererNoBlinkWithoutAssignmentAndLegacyCharactersUnchanged() throws {
        let body = try png("lb.png", color: (200, 0, 0))
        let open = try png("lo.png", color: (0, 200, 0), box: CGRect(x: 15, y: 15, width: 10, height: 10))
        let shut = try png("ls.png", color: (0, 0, 200), box: CGRect(x: 15, y: 15, width: 10, height: 10))
        let rig = CharacterRig(slots: [RigSlot(name: "体", parts: [body], active: 0), RigSlot(name: "目", parts: [open, shut], active: 0)])
        let p = rigProject(rig: rig)
        let tBlink = try XCTUnwrap(Blink.starts(seed: "reimu", until: 30).first) + 0.05
        let img = try XCTUnwrap(Renderer(project: p, assets: RenderAssets()).renderImage(t: tBlink))
        XCTAssertEqual(rgb(img, 100, 50), [0, 200, 0, 255], "まばたきの割り当てが無ければ変わらない")
        // リグの無い従来のキャラは、画像を設定していればこれまでどおり
        var legacy = rigProject(rig: rig); legacy.characters[0].rig = nil; legacy.characters[0].imgClosed = body
        let l = try XCTUnwrap(Renderer(project: legacy, assets: RenderAssets()).renderImage(t: 0.1))
        XCTAssertEqual(rgb(l, 100, 50), [200, 0, 0, 255])
    }

    // MARK: PSD → リグ

    func solid(_ w: Int, _ h: Int, _ c: [UInt8]) -> [[UInt8]] { [[UInt8]](repeating: c, count: w * h) }

    func testPSDGroupsMapToSlotsWithVisibleActive() throws {
        var b = PSDBuilder(width: 8, height: 8)
        func leaf(_ n: String, _ rect: (Int, Int, Int, Int), _ c: [UInt8], visible: Bool = true) -> PSDBuilder.L {
            PSDBuilder.L(name: n, rect: rect, rgba: solid(rect.3 - rect.1, rect.2 - rect.0, c), visible: visible)
        }
        func marker(_ n: String, _ section: UInt32) -> PSDBuilder.L { PSDBuilder.L(name: n, rect: (0, 0, 0, 0), section: section) }
        // 下から: 用紙(無視)、体、[目 グループ: 閉じ(隠し)・開き(見える)]、[名前のないグループ: 目より上 → 眉]、[口 グループ]
        b.layers = [
            leaf("用紙", (0, 0, 8, 8), [255, 255, 255, 255]),
            leaf("からだ", (0, 0, 8, 8), [200, 0, 0, 255]),
            marker("</Layer group>", 3), leaf("目2", (3, 1, 4, 7), [0, 0, 255, 255], visible: false), leaf("目1", (3, 1, 4, 7), [0, 255, 0, 255]), marker("目", 1),
            marker("</Layer group>", 3), leaf("a", (1, 1, 2, 7), [9, 9, 9, 255]), leaf("b", (1, 1, 2, 7), [8, 8, 8, 255], visible: false), marker("グループ 1", 2),
            marker("</Layer group>", 3), leaf("口b", (5, 3, 6, 5), [255, 255, 0, 255], visible: false), leaf("口a", (5, 3, 6, 5), [255, 0, 255, 255], visible: false), marker("口", 1),
        ]
        let doc = try PSDParser.parse(b.build())
        XCTAssertEqual(doc.layers.count, 14)
        let res = try RigPSDImporter.build(doc, cacheDir: tmp.appendingPathComponent("psdsmall"))
        XCTAssertEqual(res.rig.slots.map(\.name), ["体", "眉", "目", "口"])
        XCTAssertEqual(res.rig.slot("体")?.parts.count, 1, "用紙は使わない")
        XCTAssertEqual(res.rig.slot("目")?.parts.count, 2)
        XCTAssertEqual(res.rig.slot("目")?.active, 0, "見えている 目1(パネルの上)が最初の選択")
        XCTAssertEqual(res.rig.slot("眉")?.parts.count, 2)
        XCTAssertTrue(res.notes.contains { $0.contains("眉") })
        XCTAssertEqual(res.rig.slot("口")?.active, 0, "どれも見えていなければ先頭")
        XCTAssertTrue(res.rig.allPaths.allSatisfy { FileManager.default.fileExists(atPath: $0) })
        // 全面の PNG(キャンバスの大きさ)で、レイヤーの位置に描かれている
        let eye = try XCTUnwrap(RigImageLoader.thumbnail(try XCTUnwrap(res.rig.slot("目")?.parts.first), maxPixel: 8))
        XCTAssertTrue(eye.width == 8 && eye.height == 8)
        XCTAssertEqual(rgb(eye, 3, 3), [0, 255, 0, 255]); XCTAssertEqual(rgb(eye, 0, 0)[3], 0)
        // 2 回目は書き直さない(キャッシュ)
        let again = try RigPSDImporter.build(doc, cacheDir: tmp.appendingPathComponent("psdsmall"))
        XCTAssertEqual(again.rig.allPaths, res.rig.allPaths)
    }

    func testPSDWithoutLayersFallsBackToCompositeBody() throws {
        var b = PSDBuilder(width: 4, height: 4)
        b.composite = solid(4, 4, [10, 20, 30, 255])
        let doc = try PSDParser.parse(b.build())
        let res = try RigPSDImporter.build(doc, cacheDir: tmp.appendingPathComponent("psdflat"))
        XCTAssertEqual(res.rig.slots.map(\.name), ["体"])
        XCTAssertTrue(res.notes.contains { $0.contains("統合画像") })
    }

    // MARK: 実ファイル(無ければ飛ばす)

    func testUserFolderGroupingIfPresent() throws {
        let dir = URL(fileURLWithPath: "/Users/USER/動画素材/立ち絵/立ち絵素材フォルダ")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: dir.path), "ユーザーの素材フォルダがありません")
        let rep = try XCTUnwrap(RigFolderImporter.scan(folder: dir))
        let n = Dictionary(uniqueKeysWithValues: rep.rig.slots.map { ($0.name, $0.parts.count) })
        print("rig(folder):", rep.rig.slots.map { "\($0.name)=\($0.parts.count)" }.joined(separator: " "), "skipped:", rep.skippedSize.count)
        XCTAssertEqual(n["眉"], 6); XCTAssertEqual(n["目"], 45); XCTAssertEqual(n["口"], 36)
        XCTAssertEqual(n["体"], 4); XCTAssertEqual(n["髪"], 5); XCTAssertEqual(n["尻尾"], 4); XCTAssertEqual(n["頬"], 1)
        XCTAssertEqual(rep.width, 3000)
        XCTAssertEqual(rep.rig.slot("目")?.parts.first.map { ($0 as NSString).lastPathComponent }, "正面A：目 (1).png")
        // 合成(冷たいキャッシュ)
        let cache = RigFrameCache()
        let img = try XCTUnwrap(cache.frame(paths: rep.rig.paths(active: rep.rig.resolvedActive()), height: 540))
        XCTAssertEqual(img.height, 540)
    }

    func testRealPSDParsesAndMapsToRigIfPresent() throws {
        let file = URL(fileURLWithPath: "/Users/USER/Downloads/立ち絵素材.psd")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: file.path), "実物の PSD がありません")
        let doc = try PSDParser.parse(Data(contentsOf: file, options: .mappedIfSafe))
        let groups = doc.layers.filter { $0.group == .openFolder || $0.group == .closedFolder }.map(\.name)
        print("PSD: \(doc.width)x\(doc.height) depth=\(doc.depth) layers=\(doc.layers.count) content=\(doc.contentLayers.count) groups=\(groups.count) layerError=\(doc.layerError ?? "なし") composite=\(doc.composite != nil)")
        XCTAssertNil(doc.layerError, "レイヤーを読めた(統合画像への逃げではない)")
        XCTAssertEqual(doc.width, 3000); XCTAssertEqual(doc.height, 3200); XCTAssertEqual(doc.depth, 8)
        XCTAssertEqual(doc.layers.count, 92)
        XCTAssertEqual(doc.contentLayers.count, 78)
        XCTAssertEqual(groups.count, 7)
        XCTAssertTrue(groups.contains("フォルダー 22"))
        XCTAssertNotNil(doc.composite)
        XCTAssertTrue(doc.contentLayers.contains { !$0.raster.isEmpty })
        // PSD → リグ
        let res = try RigPSDImporter.build(doc, cacheDir: tmp.appendingPathComponent("psdrig"))
        print("rig(psd):", res.rig.slots.map { "\($0.name)=\($0.parts.count)(active \($0.active))" }.joined(separator: " "))
        let n = Dictionary(uniqueKeysWithValues: res.rig.slots.map { ($0.name, $0) })
        XCTAssertNotNil(n["体"]); XCTAssertNotNil(n["眉"]); XCTAssertNotNil(n["目"]); XCTAssertNotNil(n["口"])
        XCTAssertEqual(n["目"]?.parts.count, 28); XCTAssertEqual(n["口"]?.parts.count, 25)
        XCTAssertGreaterThanOrEqual(n["目"]?.active ?? -1, 0, "最初に見えているレイヤーが初期の選択")
        let img = try XCTUnwrap(RigFrameCache().frame(paths: res.rig.paths(active: res.rig.resolvedActive()), height: 400))
        XCTAssertEqual(img.height, 400)
    }
}

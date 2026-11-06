import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import MovieCutCore

/// パーツの先読み: 主な状態の組み合わせ・先読み後はキャッシュに当たる・描画経路と同じキー・実データでの初回コスト(あれば)。
final class RigPrewarmTests: XCTestCase {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("rig-prewarm-\(UUID().uuidString)")
    override func setUpWithError() throws { try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

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

    func rig() throws -> CharacterRig {
        var r = CharacterRig(slots: [
            RigSlot(name: "体", parts: [try png("b.png", color: (90, 90, 90))], active: 0),
            RigSlot(name: "目", parts: (0..<3).map { try! png("e\($0).png", color: (0, UInt8(60 * $0), 0), box: CGRect(x: 5, y: 20, width: 10, height: 5)) }, active: 0),
            RigSlot(name: "口", parts: (0..<4).map { try! png("m\($0).png", color: (UInt8(50 * $0), 0, 0), box: CGRect(x: 15, y: 5, width: 10, height: CGFloat(2 + $0))) }, active: 0),
        ])
        r.blink = 2; r.mouthClosed = 0; r.mouthOpen = 3; r.vowels = ["a": 3, "i": 1]
        r.expressions = ["笑顔": ["目": 1, "口": 2]]
        return r
    }

    func testCombinationsCoverMouthBlinkAndExpressionsWithoutDuplicates() throws {
        let r = try rig()
        let c = RigPrewarm.combinations(of: r)
        XCTAssertEqual(Set(c).count, c.count, "同じ組み合わせは 1 つ")
        XCTAssertEqual(c.first, r.resolvedActive(mouth: .closed), "最初は今の選択(口は閉じ)")
        XCTAssertTrue(c.contains(r.resolvedActive(mouth: .open)))
        XCTAssertTrue(c.contains(r.resolvedActive(mouth: .vowel("i"))))
        XCTAssertTrue(c.contains(r.resolvedActive(mouth: .closed, blinking: true)))
        XCTAssertTrue(c.contains(r.resolvedActive(expression: "笑顔", mouth: .open)))
        XCTAssertLessThanOrEqual(RigPrewarm.combinations(of: r, limit: 3).count, 3)
        // 何も割り当てていないリグは 1 つだけ
        XCTAssertEqual(RigPrewarm.combinations(of: CharacterRig(slots: r.slots)).count, 1)
    }

    func testPrewarmFillsCacheSoLaterFramesHit() throws {
        let r = try rig()
        let cache = RigFrameCache()
        let n = cache.prewarm(rig: r, height: 40)
        XCTAssertGreaterThan(n, 3)
        let composes = cache.composeCount, loads = cache.loadCount
        // 描画経路と同じ呼び方(offsets・alignment 付き)で、主な状態が全部当たる
        for m in [RigMouth.closed, .open, .vowel("a"), .vowel("i")] {
            for blink in [false, true] {
                let paths = r.paths(active: r.resolvedActive(mouth: m, blinking: blink))
                XCTAssertNotNil(cache.frame(paths: paths, height: 40, offsets: r.offsets(for: paths), alignment: r.alignmentOrDefault))
            }
        }
        XCTAssertEqual(cache.composeCount, composes, "先読み済みの組み合わせは作り直さない")
        XCTAssertEqual(cache.loadCount, loads)
        // 2 回目の先読みは何も作らない
        XCTAssertEqual(cache.prewarm(rig: r, height: 40), 0)
        // パーツの無いリグ・高さ 0 は何もしない
        XCTAssertEqual(cache.prewarm(rig: CharacterRig(), height: 40), 0)
        XCTAssertEqual(cache.prewarm(rig: r, height: 0), 0)
    }

    func testPrewarmHonoursAlignmentAndOffsetsKeyAndMissingFilesDoNotCrash() throws {
        var r = try rig()
        r.alignment = .center
        r.partOffsets = [r.slots[1].parts[0]: PartOffset(dx: 2, dy: 1)]
        let cache = RigFrameCache()
        cache.prewarm(rig: r, height: 40)
        let before = cache.composeCount
        let paths = r.paths(active: r.resolvedActive(mouth: .closed))
        _ = cache.frame(paths: paths, height: 40, offsets: r.offsets(for: paths), alignment: .center)
        XCTAssertEqual(cache.composeCount, before)
        // 無いファイルだけのリグ
        let ghost = CharacterRig(slots: [RigSlot(name: "体", parts: ["/nonexistent/a.png"])])
        XCTAssertEqual(RigFrameCache().prewarm(rig: ghost, height: 40), 0)
    }

    func testAssetsPrewarmTachiesUsesTheRendererHeightAndTheFirstRenderIsAllHits() throws {
        let r = try rig()
        var t = Tachie(name: "r"); t.id = "t"; t.rig = r
        var c = Clip(); c.id = "c"; c.type = .tachie; c.tachieId = "t"; c.start = 0; c.duration = 3; c.mouthDrive = MouthDrive.none; c.x = 0.5; c.y = 0.5
        var p = Project(); p.width = 100; p.height = 100; p.bg = "#000000"; p.tachies = [t]
        var tr = Track(name: "L"); tr.clips = [c]; p.tracks = [tr]
        let assets = RenderAssets()
        let n = assets.prewarmTachies(project: p)
        XCTAssertGreaterThan(n, 0)
        let composes = assets.rigCache.composeCount, loads = assets.rigCache.loadCount
        XCTAssertNotNil(Renderer(project: p, assets: assets).renderImage(t: 0.5))
        XCTAssertEqual(assets.rigCache.composeCount, composes, "最初の描画は、先読みした立ち絵に当たる(新しく合成しない)")
        XCTAssertEqual(assets.rigCache.loadCount, loads)
        // 立ち絵クリップが無い・単純画像の立ち絵だけなら何もしない
        var q = p; q.tracks = []
        XCTAssertEqual(RenderAssets().prewarmTachies(project: q), 0)
        // 隠したレイヤーは先読みしない
        var h = p; h.tracks[0].hidden = true
        XCTAssertEqual(RenderAssets().prewarmTachies(project: h), 0)
    }

    func testPrewarmIsSafeToRunInTheBackgroundWhileRendering() throws {
        let r = try rig()
        var t = Tachie(name: "r"); t.id = "t"; t.rig = r
        var c = Clip(); c.id = "c"; c.type = .tachie; c.tachieId = "t"; c.start = 0; c.duration = 3; c.mouthDrive = MouthDrive.none
        var p = Project(); p.width = 100; p.height = 100; p.bg = "#000000"; p.tachies = [t]
        var tr = Track(name: "L"); tr.clips = [c]; p.tracks = [tr]
        let assets = RenderAssets()
        let done = expectation(description: "prewarm")
        DispatchQueue.global(qos: .utility).async { _ = assets.prewarmTachies(project: p); done.fulfill() }
        for i in 0..<30 { XCTAssertNotNil(Renderer(project: p, assets: assets).renderImage(t: Double(i) * 0.05)) }
        wait(for: [done], timeout: 20)
    }

    // MARK: 実データ(無ければ飛ばす): 初回の使用コストを、先読みなしとありで測る

    func testRealRigFirstUseCostWithAndWithoutPrewarmIfPresent() throws {
        let dir = URL(fileURLWithPath: "/Users/USER/動画素材/立ち絵/立ち絵素材フォルダ")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: dir.path), "素材フォルダがありません")
        let rep = try XCTUnwrap(RigFolderImporter.scan(folder: dir))
        var rig = rep.rig
        rig = RigEditing.select(rig, slot: "髪", index: 1)
        let height = 648   // 1080p の立ち絵(画面の高さ × 0.6)
        func ms(_ body: () -> Void) -> Double { let t = DispatchTime.now(); body(); return Double(DispatchTime.now().uptimeNanoseconds - t.uptimeNanoseconds) / 1e6 }
        func use(_ cache: RigFrameCache, _ m: RigMouth, blink: Bool) {
            let paths = rig.paths(active: rig.resolvedActive(mouth: m, blinking: blink))
            _ = cache.frame(paths: paths, height: height, offsets: rig.offsets(for: paths), alignment: rig.alignmentOrDefault)
        }
        // 先読みなし: 最初の使用(口を開く・まばたき)で読み込みと合成が走る
        let cold = RigFrameCache()
        use(cold, .closed, blink: false)   // 最初の 1 枚(これは先読みの有無にかかわらず、最初に見える前に必要)
        let coldOpen = ms { use(cold, .open, blink: false) }
        let coldBlink = ms { use(cold, .closed, blink: true) }
        // 先読みあり
        let warm = RigFrameCache()
        let prewarmMs = ms { warm.prewarm(rig: rig, height: height) }
        let warmOpen = ms { use(warm, .open, blink: false) }
        let warmBlink = ms { use(warm, .closed, blink: true) }
        print(String(format: "初回使用コスト(1080p 相当, 高さ %d): 口を開く 先読みなし %.1f ms / あり %.2f ms、まばたき 先読みなし %.1f ms / あり %.2f ms、先読み全体(背景) %.0f ms", height, coldOpen, warmOpen, coldBlink, warmBlink, prewarmMs))
        XCTAssertLessThan(warmOpen, 5, "先読み済みなら、初回の使用でもキャッシュに当たる")
        XCTAssertLessThan(warmBlink, 5)
        XCTAssertGreaterThan(coldOpen + coldBlink, warmOpen + warmBlink)
    }
}

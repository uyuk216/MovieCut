import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import MovieCutCore

/// 配線(Part A): ハイライト補正のエフェクト(描画経路・色表)、台本の表情画像の欠落、ソースの使用範囲の表示。
final class PartAWiringTests: XCTestCase {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("partA-tests-\(UUID().uuidString)")
    override func setUpWithError() throws { try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    // MARK: ハイライト補正(エフェクトの種類)

    func testHighlightRolloffKindLabelParamsAndDefault() {
        XCTAssertEqual(EffectKind.highlightRolloff.label, "ハイライト補正")
        XCTAssertEqual(EffectKind.highlightRolloff.params.map(\.key), ["knee"])
        XCTAssertEqual(Effect(.highlightRolloff).value("knee"), HighlightRolloff.defaultKnee, accuracy: 1e-9)
        XCTAssertTrue(EffectKind.allCases.contains(.highlightRolloff))
    }

    func testHighlightRolloffEffectRoundTripsAndOldFilesStayClean() throws {
        var c = Clip(); c.id = "h"; c.type = .image; c.src = "/a.png"
        c.effects = [Effect(.highlightRolloff)]
        let text = String(decoding: try JSONEncoder().encode(c.effects[0]), as: UTF8.self)
        XCTAssertTrue(text.contains("highlightRolloff"))
        let back = try JSONDecoder().decode(Effect.self, from: Data(text.utf8))
        XCTAssertEqual(back.known, .highlightRolloff)
        XCTAssertEqual(back.value("knee"), HighlightRolloff.defaultKnee, accuracy: 1e-9)
        // 使わなければ、どのファイルにも現れない
        var q = Project.new(); q.tracks[4].clips = [Clip()]
        XCTAssertFalse(String(decoding: try q.encoded(), as: UTF8.self).contains("highlightRolloff"))
    }

    func testCubeDataMatchesCurveAtEachCell() {
        let n = HighlightRolloff.cubeDimension
        let data = HighlightRolloff.cubeData(knee: 0.8)
        XCTAssertEqual(data.count, n * n * n * 4 * MemoryLayout<Float>.size)
        let f = Array(data.withUnsafeBytes { $0.bindMemory(to: Float.self) })
        XCTAssertEqual(f[0], 0, accuracy: 1e-6, "黒は黒のまま")
        let white = (n * n * n - 1) * 4
        XCTAssertEqual(Double(f[white]), HighlightRolloff.apply(1, knee: 0.8), accuracy: 1e-6)
        XCTAssertLessThan(f[white], 1, "白は白に届かない")
        // 膝より下の格子は変わらない(0.5 の格子は 0.5)
        let mid = Int((0.5 * Double(n - 1)).rounded())
        XCTAssertEqual(Double(f[mid * 4]), Double(mid) / Double(n - 1), accuracy: 1e-6)
    }

    private func solidPNG(gray: CGFloat, name: String) throws -> String {
        let n = 200
        let c = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(gray: gray, alpha: 1); c.fill(CGRect(x: 0, y: 0, width: n, height: n))
        let url = tmp.appendingPathComponent("\(name).png")
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, c.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url.path
    }

    /// 200×200 のキャンバスいっぱいの画像に、エフェクトをかけて描く(プレビューと同じ Renderer の経路)。
    private func centerGray(_ effects: [Effect], gray: CGFloat, name: String) throws -> Int {
        var c = Clip(); c.id = "i"; c.type = .image; c.src = try solidPNG(gray: gray, name: name)
        c.start = 0; c.duration = 4; c.x = 0.5; c.y = 0.5; c.scale = 1; c.effects = effects
        var p = Project(); p.width = 200; p.height = 200; p.bg = "#000000"; p.characters = []
        var tr = Track(name: "L1"); tr.clips = [c]; p.tracks = [tr]
        let img = try XCTUnwrap(Renderer(project: p, assets: RenderAssets()).renderImage(t: 0.5))
        var d = [UInt8](repeating: 0, count: img.width * img.height * 4)
        let ctx = CGContext(data: &d, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        let i = ((img.height / 2) * img.width + img.width / 2) * 4
        return Int(d[i])
    }

    func testHighlightRolloffCompressesWhiteButKeepsShadows() throws {
        let white = try centerGray([], gray: 1, name: "w0")
        XCTAssertGreaterThan(white, 250, "効果なしの白はほぼ 255")
        let rolled = try centerGray([Effect(.highlightRolloff)], gray: 1, name: "w1")
        let expected = HighlightRolloff.apply(1) * 255
        XCTAssertEqual(Double(rolled), expected, accuracy: 8, "白が圧縮されている")
        XCTAssertLessThan(rolled, white)
        let shadow = try centerGray([Effect(.highlightRolloff)], gray: 0.5, name: "g5")
        XCTAssertEqual(Double(shadow), 128, accuracy: 3, "膝より下は変わらない")
    }

    // MARK: 表情画像の欠落(台本)

    func testMissingInScriptWarnsOnlyForUsedAbsentTags() {
        var reimu = MovieCutCore.Character(); reimu.id = "r"; reimu.name = "キャラ1"
        reimu.expressions = ["笑顔": "/c/smile.png", "怒り": "/c/angry.png"]
        var marisa = MovieCutCore.Character(); marisa.id = "m"; marisa.name = "キャラ3"
        marisa.expressions = ["喜び": "/c/joy.png"]
        let text = "キャラ1: [笑顔]こんにちは\nキャラ1: [怒り]待って\nキャラ3: [喜び]やった\nキャラ1: [怒り]もう一回\nキャラ1: [未登録]ふつう\n※ キャラ1: [怒り]メモ"
        let present: Set<String> = ["/c/smile.png", "/c/joy.png"]
        XCTAssertEqual(CharacterPartCheck.missingInScript(text, characters: [reimu, marisa]) { present.contains($0) }, ["キャラ1: 怒り"],
                       "同じ表情は 1 回、登録の無い表情・メモ行は警告しない")
    }

    func testMissingInScriptUsesFirstCharacterWhenNoName() {
        var reimu = MovieCutCore.Character(); reimu.id = "r"; reimu.name = "キャラ1"
        reimu.expressions = ["怒り": "/c/angry.png"]
        XCTAssertEqual(CharacterPartCheck.missingInScript("[怒り]名前なし", characters: [reimu]) { _ in false }, ["キャラ1: 怒り"])
        XCTAssertEqual(CharacterPartCheck.missingInScript("", characters: [reimu]) { _ in false }, [])
        XCTAssertEqual(CharacterPartCheck.missingInScript("[怒り]x", characters: []) { _ in false }, [])
    }

    // MARK: ソースの使用範囲の表示

    func testSourceUsageLabelFormatsClockAndSkipsFreeze() {
        var c = Clip(); c.type = .video; c.offset = 0; c.duration = 3; c.srcDuration = 20
        XCTAssertEqual(SourceUsage.label(of: c), "ソースの使用範囲 00:00–00:03")
        c.offset = 3700; c.duration = 60; c.srcDuration = 5000
        XCTAssertEqual(SourceUsage.label(of: c), "ソースの使用範囲 1:01:40–1:02:40")
        c.freeze = true
        XCTAssertNil(SourceUsage.label(of: c))
    }
}

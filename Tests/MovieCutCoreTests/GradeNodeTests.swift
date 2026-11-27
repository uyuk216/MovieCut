import XCTest
import CoreImage
@testable import MovieCutCore

final class GradeNodeTests: XCTestCase {
    // MARK: ヘルパー

    private func solid(_ r: Double, _ g: Double, _ b: Double) -> CIImage {
        CIImage(color: CIColor(red: r, green: g, blue: b)).cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4))
    }

    private func pixel(_ img: CIImage) -> [Double] {
        var buf = [UInt8](repeating: 0, count: 4 * 4 * 4)
        let ctx = CIContext()
        ctx.render(img, toBitmap: &buf, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 4, height: 4), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return buf[0..<4].map { Double($0) / 255 }
    }

    private func node(_ kind: EffectKind, _ params: [String: Double] = [:], opacity: Double = 1, enabled: Bool = true) -> GradeNode {
        var e = Effect(kind)
        for (k, v) in params { e.params[k] = v }
        return GradeNode(name: kind.label, enabled: enabled, opacity: opacity, effects: [e])
    }

    private func grade(_ img: CIImage, _ nodes: [GradeNode]) -> [Double] {
        var c = Clip(); c.type = .image; c.gradeNodes = nodes
        let fx = c.resolvedGradeNodes()
        return pixel(EffectPipeline.apply(img, effects: fx, bounds: img.extent, scale: 1, pluginProviders: []))
    }

    // MARK: 評価

    func testNoNodesIsIdentityAndInactive() {
        var c = Clip(); c.type = .image
        XCTAssertFalse(c.hasActiveGradeNodes)
        XCTAssertTrue(c.resolvedGradeNodes().isEmpty)
        c.gradeNodes = []
        XCTAssertFalse(c.hasActiveGradeNodes)
    }

    func testOrderMatters() {
        let src = solid(0.2, 0.3, 0.4)
        let a = node(.exposure, ["ev": 1]), b = node(.contrast, ["amount": 2])
        let ab = grade(src, [a, b]), ba = grade(src, [b, a])
        XCTAssertNotEqual(ab, ba, "非可換な 2 ノードは順序で結果が変わる")
        XCTAssertGreaterThan(zip(ab, ba).map { abs($0 - $1) }.max() ?? 0, 0.02)
    }

    func testSerialEqualsManualChain() {
        let src = solid(0.2, 0.3, 0.4)
        let a = node(.exposure, ["ev": 1]), b = node(.contrast, ["amount": 2])
        let viaNodes = grade(src, [a, b])
        let manual = EffectPipeline.apply(src, effects: EffectPipeline.resolve({ var c = Clip(); c.effects = [a.effects[0], b.effects[0]]; return c }(), atClipTime: 0), bounds: src.extent, scale: 1)
        XCTAssertEqual(viaNodes, pixel(manual))
    }

    func testDisabledNodePassesThrough() {
        let src = solid(0.2, 0.3, 0.4)
        let base = pixel(src)
        XCTAssertEqual(grade(src, [node(.exposure, ["ev": 1], enabled: false)]), base)
        XCTAssertEqual(grade(src, [node(.exposure, ["ev": 1], opacity: 0)]), base)
        var c = Clip(); c.gradeNodes = [node(.exposure, ["ev": 1], enabled: false)]
        XCTAssertFalse(c.hasActiveGradeNodes)
        // 無効ノードを挟んでも、有効ノードの結果は変わらない
        let on = node(.exposure, ["ev": 1])
        XCTAssertEqual(grade(src, [node(.contrast, ["amount": 2], enabled: false), on]), grade(src, [on]))
    }

    func testOpacityMixesInputAndResult() {
        let src = solid(0.2, 0.3, 0.4)
        let full = grade(src, [node(.exposure, ["ev": 1])])
        let half = grade(src, [node(.exposure, ["ev": 1], opacity: 0.5)])
        let base = pixel(src)
        for i in 0..<3 { XCTAssertEqual(half[i], (full[i] + base[i]) / 2, accuracy: 0.02, "channel \(i)") }
        XCTAssertEqual(half[3], 1, accuracy: 0.01)
        XCTAssertEqual(grade(src, [node(.exposure, ["ev": 1], opacity: 1)]), full)
    }

    func testIdentityContentIsSkippedAndNonColorKindsIgnored() {
        var c = Clip()
        c.gradeNodes = [node(.exposure, ["ev": 0]), node(.gaussianBlur, ["radius": 20])]
        XCTAssertFalse(c.hasActiveGradeNodes)
    }

    // MARK: 編集

    func testEditing() {
        var c = Clip(); c.type = .video
        let a = node(.exposure, ["ev": 1]), b = node(.contrast, ["amount": 2])
        XCTAssertTrue(GradeNodeEditing.add(&c, a)); XCTAssertTrue(GradeNodeEditing.add(&c, b))
        XCTAssertTrue(GradeNodeEditing.move(&c, id: b.id, by: -1))
        XCTAssertEqual(c.gradeNodes?.map(\.id), [b.id, a.id])
        XCTAssertFalse(GradeNodeEditing.move(&c, id: b.id, by: -1))
        XCTAssertTrue(GradeNodeEditing.setEnabled(&c, id: a.id, false))
        XCTAssertTrue(GradeNodeEditing.setOpacity(&c, id: a.id, -5)); XCTAssertEqual(c.gradeNodes?[1].opacity, 0)
        XCTAssertTrue(GradeNodeEditing.setParam(&c, id: b.id, key: "amount", 99)); XCTAssertEqual(c.gradeNodes?[0].effects[0].params["amount"], 3)
        XCTAssertTrue(GradeNodeEditing.remove(&c, id: a.id)); XCTAssertTrue(GradeNodeEditing.remove(&c, id: b.id))
        XCTAssertNil(c.gradeNodes)
        var audio = Clip(); audio.type = .audio
        XCTAssertFalse(GradeNodeEditing.add(&audio, a))
    }

    // MARK: 保存・復元と後方互換

    private func project(_ c: Clip) -> Project {
        var p = Project(); p.tracks = [{ var t = Track(name: "v"); t.clips = [c]; return t }()]
        return p
    }

    func testRoundTrip() throws {
        var c = Clip(); c.type = .video
        var lut = node(.lut, ["intensity": 0.8], opacity: 0.6); lut.effects[0].path = "/tmp/x.cube"
        c.gradeNodes = [node(.colorWheels, ["liftAmount": 0.3, "liftAngle": 40]), lut, node(.exposure, ["ev": 0.5], enabled: false)]
        let p = project(c)
        let back = try Project.decode(from: p.encoded())
        XCTAssertEqual(back.tracks[0].clips[0].gradeNodes, c.gradeNodes)
        XCTAssertEqual(back, p)
    }

    func testNoNodesNotWrittenAndOldFormatLoads() throws {
        var c = Clip(); c.type = .video; c.gradeNodes = []
        XCTAssertFalse(String(decoding: try project(c).encoded(), as: UTF8.self).contains("gradeNodes"))
        let json = #"{"tracks":[{"clips":[{"type":"video","start":1,"duration":2}]}]}"#
        let p = try Project.decode(from: Data(json.utf8))
        XCTAssertNil(p.tracks[0].clips[0].gradeNodes)
        XCTAssertEqual(try Project.decode(from: p.encoded()), p)
    }

    func testUnknownFieldsPreserved() throws {
        let json = #"{"tracks":[{"clips":[{"type":"video","gradeNodes":[{"id":"n1","future":7,"effects":[{"kind":"exposure","params":{"ev":1}}]}]}]},{"clips":[{"type":"video","gradeNodes":"weird"}]}]}"#
        let p = try Project.decode(from: Data(json.utf8))
        XCTAssertEqual(p.tracks[0].clips[0].gradeNodes?.count, 1)
        let out = String(decoding: try p.encoded(), as: UTF8.self)
        XCTAssertTrue(out.contains("future"))
        XCTAssertTrue(out.contains("weird"))
        XCTAssertNil(p.tracks[1].clips[0].gradeNodes)
    }

    // MARK: Renderer 接続

    private func renderFrame(_ nodes: [GradeNode]?) throws -> [UInt8] {
        var c = Clip(); c.type = .text; c.start = 0; c.duration = 1; c.text = "■■■"; c.fontSize = 40; c.color = "#336699"; c.gradeNodes = nodes
        var p = Project(); p.width = 64; p.height = 36
        p.tracks = [{ var t = Track(name: "t"); t.clips = [c]; return t }()]
        let img = try XCTUnwrap(Renderer(project: p, assets: RenderAssets()).renderImage(t: 0.5))
        return Array(try XCTUnwrap(img.dataProvider?.data as Data?))
    }

    func testRendererNoNodesMatchesLegacyAndNodesChangeOutput() throws {
        let legacy = try renderFrame(nil)
        XCTAssertEqual(try renderFrame([]), legacy)
        XCTAssertEqual(try renderFrame([node(.exposure, ["ev": 1], enabled: false)]), legacy, "無効ノードだけなら従来と同じ")
        XCTAssertEqual(try renderFrame([node(.exposure, ["ev": 0])]), legacy, "何もしない中身は従来と同じ")
        XCTAssertNotEqual(try renderFrame([node(.exposure, ["ev": 1])]), legacy, "有効ノードは描画に効く")
    }
}

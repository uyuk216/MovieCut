import XCTest
@testable import MovieCutCore

final class MissingMediaPlaceholderTests: XCTestCase {
    private func project(src: String = "/nonexistent/dir/消えた素材.png") -> Project {
        var p = Project()
        p.width = 640; p.height = 360; p.bg = "#000000"
        var c = Clip(); c.type = .image; c.src = src; c.start = 0; c.duration = 5
        p.tracks = [Track(name: "L1")]
        p.tracks[0].clips = [c]
        return p
    }

    private func pixel(_ img: CGImage, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
        let data = img.dataProvider!.data! as Data
        let bpr = img.bytesPerRow, o = y * bpr + x * 4
        return (Int(data[o + 2]), Int(data[o + 1]), Int(data[o]))  // BGRA
    }

    func testPlaceholderDrawnDarkRedWhenEnabled() {
        let p = project()
        let img = Renderer(project: p, assets: RenderAssets(), missingMediaPlaceholder: true).renderImage(t: 1)!
        let l = MissingMediaPlaceholder.layout(canvasWidth: 640, canvasHeight: 360, fileName: "x")
        // 札の左上寄り(文字に当たらない所)が暗い赤
        let px = pixel(img, Int(l.card.minX) + 12, Int(l.card.minY) + 12)
        XCTAssertGreaterThan(px.r, 60); XCTAssertLessThan(px.r, 140)
        XCTAssertLessThan(px.g, 40); XCTAssertLessThan(px.b, 40)
        // 札の外は背景のまま
        let out = pixel(img, 5, 5)
        XCTAssertEqual(out.r + out.g + out.b, 0)
        // 文字がある: 札の中に白っぽい画素が存在する
        var bright = 0
        for y in Int(l.card.minY)..<Int(l.card.maxY) {
            for x in stride(from: Int(l.card.minX), to: Int(l.card.maxX), by: 1) where pixel(img, x, y).g > 200 { bright += 1 }
        }
        XCTAssertGreaterThan(bright, 50)
    }

    func testDefaultKeepsSkippingMissingMedia() {
        let img = Renderer(project: project(), assets: RenderAssets()).renderImage(t: 1)!
        let l = MissingMediaPlaceholder.layout(canvasWidth: 640, canvasHeight: 360, fileName: "x")
        let px = pixel(img, Int(l.card.minX) + 12, Int(l.card.minY) + 12)
        XCTAssertEqual(px.r + px.g + px.b, 0)
    }

    func testLayoutAndShortName() {
        let l = MissingMediaPlaceholder.layout(canvasWidth: 1920, canvasHeight: 1080, fileName: "a.png")
        XCTAssertEqual(l.card.midX, 960, accuracy: 0.01); XCTAssertEqual(l.card.midY, 540, accuracy: 0.01)
        XCTAssertGreaterThan(l.titleSize, l.nameSize)
        XCTAssertLessThan(l.titleY, l.nameY)
        let long = String(repeating: "あ", count: 80) + ".mov"
        XCTAssertEqual(MissingMediaPlaceholder.shortName(long, limit: 32).count, 32)
        XCTAssertEqual(MissingMediaPlaceholder.shortName("a.png", limit: 32), "a.png")
        XCTAssertEqual(MissingMediaPlaceholder.title, "メディアが見つかりません")
    }

    func testTimelineMarkDecision() {
        var c = Clip(); c.type = .video; c.src = "/gone.mov"
        XCTAssertNil(MissingMediaPlaceholder.timelineMark(for: c, width: 100, exists: { _ in true }))
        let m = MissingMediaPlaceholder.timelineMark(for: c, width: 100, exists: { _ in false })
        XCTAssertEqual(m?.hatch, true); XCTAssertEqual(m?.showsBadge, true)
        XCTAssertTrue(m!.help.contains("メディアが見つかりません"))
        XCTAssertEqual(MissingMediaPlaceholder.timelineMark(for: c, width: 10, exists: { _ in false })?.showsBadge, false)
        XCTAssertEqual(MissingMediaPlaceholder.timelineMark(for: c, width: 1, exists: { _ in false })?.hatch, false)
        c.src = ""; XCTAssertNil(MissingMediaPlaceholder.timelineMark(for: c, width: 100, exists: { _ in false }))
        c.src = nil; XCTAssertNil(MissingMediaPlaceholder.timelineMark(for: c, width: 100, exists: { _ in false }))
        var t = Clip(); t.type = .text
        XCTAssertNil(MissingMediaPlaceholder.timelineMark(for: t, width: 100, exists: { _ in false }))
    }
}

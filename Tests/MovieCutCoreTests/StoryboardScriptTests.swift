import XCTest
import CoreGraphics
import ImageIO
@testable import MovieCutCore

/// 絵コンテ(代表フレームの格子)と、台本の書き出し(声のクリップ → 「キャラ名: セリフ」)。
final class StoryboardScriptTests: XCTestCase {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("storyboard-tests-\(UUID().uuidString)")
    override func setUpWithError() throws { try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    // MARK: 絵コンテ

    func testTimesAreCentersOfEqualSlices() {
        XCTAssertEqual(Storyboard.times(duration: 8, count: 4), [1, 3, 5, 7])
        XCTAssertEqual(Storyboard.times(duration: 8, count: 0), [4], "0 枚は 1 枚に直す")
        XCTAssertEqual(Storyboard.times(duration: 8, count: 1000).count, Storyboard.maxCount, "上限は 64 枚")
        XCTAssertEqual(Storyboard.times(duration: 8).count, Storyboard.defaultCount)
        XCTAssertEqual(Storyboard.times(duration: 0, count: 4), [])
        XCTAssertEqual(Storyboard.times(duration: .nan, count: 4), [])
        XCTAssertEqual(Storyboard.times(duration: -3, count: 4), [])
    }

    func testGridFitsColumnsAndRows() {
        XCTAssertEqual(Storyboard.grid(count: 12, columns: 4).columns, 4)
        XCTAssertEqual(Storyboard.grid(count: 12, columns: 4).rows, 3)
        XCTAssertEqual(Storyboard.grid(count: 5, columns: 4).rows, 2)
        XCTAssertEqual(Storyboard.grid(count: 3, columns: 10).columns, 3, "列は枚数を超えない")
        XCTAssertEqual(Storyboard.grid(count: 3, columns: 10).rows, 1)
        XCTAssertEqual(Storyboard.grid(count: 0, columns: 0).columns, 1)
    }

    func testCellKeepsAspectRatioAndEvenHeight() {
        XCTAssertEqual(Storyboard.cellSize(width: 1920, height: 1080), CGSize(width: 480, height: 270))
        XCTAssertEqual(Storyboard.cellSize(width: 1080, height: 1920).height, 854, "縦は偶数に揃える")
        XCTAssertEqual(Storyboard.cellSize(width: 0, height: 0), CGSize(width: 480, height: 270))
    }

    func testComposeIsEmptyForNoFramesAndWritesGridSize() throws {
        XCTAssertNil(Storyboard.compose([], cell: CGSize(width: 4, height: 2), columns: 2, background: nil))
        let red = try XCTUnwrap(solid(w: 8, h: 8))
        let board = try XCTUnwrap(Storyboard.compose([red, red, red], cell: CGSize(width: 16, height: 8), columns: 2, background: nil))
        XCTAssertEqual(board.width, 32, "2 列")
        XCTAssertEqual(board.height, 16, "2 行")
    }

    private func solid(w: Int, h: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    private func textProject(duration: Double) -> Project {
        var p = Project.new()
        p.width = 320; p.height = 180; p.fps = 10
        var c = Clip(); c.id = "t"; c.type = .text; c.text = "絵コンテ"; c.start = 0; c.duration = duration; c.fontSize = 40
        p.tracks[4].clips = [c]
        return p
    }

    private func pngSize(_ url: URL) throws -> (Int, Int) {
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let img = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
        return (img.width, img.height)
    }

    func testWriteProducesPNGOfGridSize() throws {
        let url = tmp.appendingPathComponent("board.png")
        try Storyboard.write(project: textProject(duration: 4), count: 12, columns: 4, to: url)
        let (w, h) = try pngSize(url)
        XCTAssertEqual(w, 1920)
        XCTAssertEqual(h, 810)
        let url3 = tmp.appendingPathComponent("board3.png")
        try Storyboard.write(project: textProject(duration: 4), count: 3, columns: 4, to: url3)
        let (w3, h3) = try pngSize(url3)
        XCTAssertEqual(w3, 1440)
        XCTAssertEqual(h3, 270)
    }

    func testWriteRefusesEmptyTimeline() {
        let url = tmp.appendingPathComponent("none.png")
        XCTAssertThrowsError(try Storyboard.write(project: textProject(duration: 0), to: url)) { error in
            XCTAssertEqual(error as? Storyboard.Failure, .noLength)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: 台本の書き出し

    private func character(_ id: String, _ name: String) -> MovieCutCore.Character {
        var c = MovieCutCore.Character(); c.id = id; c.name = name
        return c
    }

    private func voice(_ id: String, _ start: Double, char: String, text: String?) -> Clip {
        var c = Clip(); c.id = id; c.type = .voice; c.start = start; c.duration = 1; c.charId = char; c.text = text
        return c
    }

    func testVoiceScriptSortsByStartAndSkipsIncomplete() {
        var p = Project.new()
        p.characters = [character("a", "霊夢"), character("b", "魔理沙")]
        var text = Clip(); text.id = "x"; text.type = .text; text.text = "字幕ではない"; text.start = 0; text.duration = 1; text.fontSize = 40
        p.tracks[0].clips = [voice("v2", 2, char: "a", text: "[笑顔]こんにちは"), voice("v1", 0, char: "b", text: "やあ"),
                             voice("v3", 3, char: "zz", text: "知らない人"), voice("v4", 4, char: "a", text: "   "), text]
        let r = VoiceScriptExport.make(p)
        XCTAssertEqual(r.text, "魔理沙: やあ\n霊夢: [笑顔]こんにちは")
        XCTAssertEqual(r.lineCount, 2)
        XCTAssertEqual(r.skipped, 2, "キャラが無いものと、セリフが空のもの")
    }

    func testVoiceScriptLinesReadBackToSameCharactersAndText() {
        var p = Project.new()
        p.characters = [character("a", "霊夢"), character("b", "魔理沙")]
        p.tracks[0].clips = [voice("v1", 0, char: "b", text: "やあ"), voice("v2", 2, char: "a", text: "[笑顔]こんにちは")]
        let r = VoiceScriptExport.make(p)
        let lines = r.text.components(separatedBy: "\n")
        let parsed = lines.compactMap { ScriptTimeline.parse(line: $0, characters: p.characters, selectedCharId: nil) }
        XCTAssertEqual(parsed.map { $0.0.id }, ["b", "a"])
        XCTAssertEqual(parsed.map { $0.1 }, ["やあ", "[笑顔]こんにちは"])
    }

    func testVoiceScriptEmptyWhenNoVoices() {
        XCTAssertEqual(VoiceScriptExport.make(Project.new()), VoiceScriptExport.Result(text: "", lineCount: 0, skipped: 0))
    }
}

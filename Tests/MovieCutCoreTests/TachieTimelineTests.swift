import XCTest
import CoreGraphics
import ImageIO
@testable import MovieCutCore

/// 立ち絵クリップのタイムライン上の扱い: 連動する声・声の長さに合わせる・表情の切り替わり・絵のある所だけを選ぶ。
final class TachieTimelineTests: XCTestCase {
    private func voice(_ id: String, _ ch: String, _ start: Double, _ dur: Double, _ text: String = "こんにちは") -> Clip {
        var v = Clip(); v.id = id; v.type = .voice; v.charId = ch; v.start = start; v.duration = dur; v.text = text; return v
    }

    private func project(drive: MouthDrive = .all, tachieStart: Double = 0, tachieDur: Double = 1) -> Project {
        var p = Project.new()
        p.characters = []
        var a = Character(); a.id = "A"; a.name = "A"; var b = Character(); b.id = "B"; b.name = "B"
        p.characters = [a, b]
        var t = Tachie(name: "立ち"); t.id = "t"; t.imgClosed = "/x.png"
        p.tachies = [t]
        p.tracks = [Track(name: "声"), Track(name: "立ち絵")]
        p.tracks[0].clips = [voice("v1", "A", 1, 2, "[笑顔]やあ"), voice("v2", "B", 3, 1, "はい"), voice("v3", "A", 5, 1, "[笑顔]またね")]
        var c = TachieEditing.makeClip(p, tachieId: "t", start: tachieStart, duration: tachieDur, drive: drive)!
        c.id = "tc"
        p.tracks[1].clips = [c]
        return p
    }

    func testDriverVoicesFollowTheMouthDrive() {
        let ids: (MouthDrive) -> [String] = { d in
            let p = self.project(drive: d)
            return TachieEditing.driverVoices(p, clip: p.tracks[1].clips[0]).map(\.id)
        }
        XCTAssertEqual(ids(.all), ["v1", "v2", "v3"])
        XCTAssertEqual(ids(.character("A")), ["v1", "v3"])
        XCTAssertEqual(ids(.voiceClip("v2")), ["v2"])
        XCTAssertEqual(ids(.none), [])
    }

    func testFitToVoiceUsesTheDrivenVoiceSpanAndIsIdempotent() {
        var p = project(drive: .character("A"))
        let fitted = TachieEditing.fitToVoice(p, clipId: "tc")
        XCTAssertEqual(fitted.tracks[1].clips[0].start, 1, accuracy: 1e-9)
        XCTAssertEqual(fitted.tracks[1].clips[0].duration, 5, accuracy: 1e-9)           // 1 〜 6
        XCTAssertEqual(TachieEditing.fitToVoice(fitted, clipId: "tc"), fitted, "もう合っていれば変えない")
        p = project(drive: .none)
        XCTAssertEqual(TachieEditing.fitToVoice(p, clipId: "tc"), p, "動かさない = 声が無い")
        XCTAssertEqual(TachieEditing.fitToVoice(p, clipId: "nope"), p)
        XCTAssertEqual(TachieEditing.fitToVoice(p, clipId: "v1"), p, "立ち絵クリップ以外は変えない")
    }

    func testFitToVoiceRefusesToOverlapAnotherClipOnTheLayer() {
        var p = project(drive: .voiceClip("v3"))        // 5〜6
        var other = Clip(); other.id = "o"; other.type = .text; other.start = 5.5; other.duration = 1; other.text = "x"
        p.tracks[1].clips.append(other)
        XCTAssertEqual(TachieEditing.fitToVoice(p, clipId: "tc"), p)
    }

    func testExpressionChangesSkipRepeatedTags() {
        let p = project(drive: .all, tachieStart: 0, tachieDur: 10)
        let ch = TachieEditing.expressionChanges(p, clip: p.tracks[1].clips[0])
        XCTAssertEqual(ch.map(\.tag), ["笑顔", nil, "笑顔"])
        XCTAssertEqual(ch.map(\.time), [1, 3, 5])
        let narrow = project(drive: .all, tachieStart: 3.2, tachieDur: 0.5)
        XCTAssertEqual(TachieEditing.expressionChanges(narrow, clip: narrow.tracks[1].clips[0]).map(\.voiceId), ["v2"], "区間に掛かる声だけ")
    }

    // MARK: 絵のある所だけを選ぶ

    private func writePNG(opaque box: CGRect) throws -> String {
        let n = 40
        let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)); ctx.fill(box)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tpick-\(UUID().uuidString).png")
        let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url.path
    }

    func testPickingIgnoresTransparentPixelsOfATachie() throws {
        var p = Project.new()
        p.width = 1280; p.height = 720; p.characters = []
        var t = Tachie(name: "t"); t.id = "t"; t.imgClosed = try writePNG(opaque: CGRect(x: 10, y: 10, width: 20, height: 20))
        p.tachies = [t]
        var c = TachieEditing.makeClip(p, tachieId: "t", start: 0, duration: 4)!
        c.id = "tc"; c.x = 0.5; c.y = 0.5
        p.tracks[0].clips = [c]
        let assets = RenderAssets()
        // 高さ 432 の正方形(中心 640,360)。中央は不透明、左端(枠の内側)は透明
        XCTAssertEqual(PreviewPicking.hits(in: p, at: CGPoint(x: 640, y: 360), time: 1, assets: assets), ["tc"])
        XCTAssertEqual(PreviewPicking.hits(in: p, at: CGPoint(x: 640 - 200, y: 360), time: 1, assets: assets), [], "枠の中でも透明な所は選ばない")
        XCTAssertEqual(PreviewPicking.hits(in: p, at: CGPoint(x: 10, y: 10), time: 1, assets: assets), [])
        // 反転しても中央は当たる
        p.tracks[0].clips[0].flipH = true
        XCTAssertEqual(PreviewPicking.hits(in: p, at: CGPoint(x: 640, y: 360), time: 1, assets: assets), ["tc"])
    }
}

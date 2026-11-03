import XCTest
import CoreGraphics
import Foundation
@testable import MovieCutCore

/// 登場アニメーションのプリセット(フェードイン・タイプライター・ポップ)。
final class AnimatedPresetTests: XCTestCase {
    private func preset(_ id: String) throws -> SavedTextStyle {
        try XCTUnwrap(TextStyleLibrary.builtins.first { $0.id == id })
    }

    private func textClip() -> Clip {
        var c = Clip(); c.id = "t"; c.type = .text; c.start = 0; c.duration = 4; c.text = "ABCDEFGH"; c.fontSize = 60; c.color = "#ffffff"
        return c
    }

    func testPresetsExistWithIdsAndNames() throws {
        XCTAssertEqual(try preset("builtin.fadein").name, "フェードイン")
        XCTAssertEqual(try preset("builtin.typewriter").name, "タイプライター")
        XCTAssertEqual(try preset("builtin.pop").name, "ポップ")
        XCTAssertEqual(TextStyleLibrary.builtins.count, 16)
        XCTAssertTrue(TextStyleLibrary.builtins.allSatisfy(\.isBuiltin))
    }

    func testApplySetsAnimationAndIsOneChange() throws {
        for (id, kind) in [("builtin.fadein", TextAnimKind.fadeIn), ("builtin.typewriter", .typewriter), ("builtin.pop", .pop)] {
            var c = textClip()
            let look = try preset(id).look
            XCTAssertTrue(look.apply(to: &c))
            XCTAssertEqual(c.textAnim?.known, kind)
            XCTAssertNotNil(c.textAnim?.duration)
            XCTAssertFalse(look.apply(to: &c), "同じプリセットをもう一度は変更なし")
        }
        // 既存のスタイル(アニメーション指定なし)は、いまのアニメーションを変えない
        var c = textClip()
        _ = TextStyleEditing.setAnim(&c, kind: .shake)
        _ = TextStyleLibrary.builtins[1].look.apply(to: &c)
        XCTAssertEqual(c.textAnim?.known, .shake)
    }

    func testAnimatedTitleTemplates() throws {
        let titles = TextStyleLibrary.animatedTitles
        XCTAssertGreaterThanOrEqual(titles.count, 6)
        XCTAssertEqual(Set(titles.map(\.id)).count, titles.count)
        XCTAssertTrue(titles.allSatisfy { $0.id.hasPrefix(TextStyleLibrary.titlePrefix) && $0.isBuiltin })
        XCTAssertEqual(Set(titles.compactMap { $0.look.anim?.known }).count, 6, "6 種類のアニメーションを使う")
        for t in titles {
            let anim = try XCTUnwrap(t.look.anim, t.name)
            XCTAssertNotNil(anim.known, t.name)
            XCTAssertEqual(t.look.style?.normalized, t.look.style)
            var c = textClip()
            XCTAssertTrue(t.look.apply(to: &c), t.name)
            XCTAssertEqual(c.textAnim, anim)
            XCTAssertFalse(t.look.apply(to: &c), "もう一度は変更なし")
            // 保存して読み直しても同じ(スクロールの速さ・時間は任意項目)
            let back = try JSONDecoder().decode(Clip.self, from: JSONEncoder().encode(c))
            XCTAssertEqual(back.textAnim, c.textAnim)
        }
        XCTAssertNil(try XCTUnwrap(titles.first { $0.id.hasSuffix("credits") }).look.anim?.duration)
    }

    func testRoundTripAndOldFixtureUnchanged() throws {
        var c = textClip()
        _ = try preset("builtin.fadein").look.apply(to: &c)
        let back = try JSONDecoder().decode(Clip.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(back.textAnim, c.textAnim)
        // 保存したスタイルの往復と、未知のアニメーション種類の保持
        let saved = SavedTextStyle(id: "user.1", name: "x", look: try preset("builtin.pop").look)
        let l2 = try JSONDecoder().decode(SavedTextStyle.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(l2, saved)
        let unk = try JSONDecoder().decode(TextAnim.self, from: Data(#"{"kind":"zzz","duration":2,"foo":1}"#.utf8))
        XCTAssertNil(unk.known)
        XCTAssertTrue(String(decoding: try JSONEncoder().encode(unk), as: UTF8.self).contains("foo"))
        // アニメーションを持たない見た目は anim を書かない
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(TextLook(color: "#fff")), as: UTF8.self).contains("anim"))
        // 古いフィクスチャ: 読んで書き直してもバイト一致
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
        for f in ["rich.ymproj", "keyframes.ymproj"] {
            let data = try Data(contentsOf: dir.appendingPathComponent(f))
            let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
            let once = try enc.encode(JSONDecoder().decode(Project.self, from: data))
            let twice = try enc.encode(JSONDecoder().decode(Project.self, from: once))
            XCTAssertEqual(once, twice, f)
            XCTAssertFalse(String(decoding: once, as: UTF8.self).contains("fadeIn"))
        }
    }

    func testFadeMathAndState() {
        let a = TextAnim(kind: "fadeIn", duration: 1)
        XCTAssertEqual(TextAnimMath.state(a, text: "x", rel: 0, size: 60).alpha, 0, accuracy: 1e-9)
        XCTAssertEqual(TextAnimMath.state(a, text: "x", rel: 0.5, size: 60).alpha, 0.5, accuracy: 1e-9)
        XCTAssertFalse(TextAnimMath.state(a, text: "x", rel: 1.5, size: 60).active)
    }

    // MARK: 描画

    private func pixels(_ c: Clip, t: Double) throws -> [UInt8] {
        var p = Project(); p.width = 320; p.height = 160; p.bg = "#000000"
        var tr = Track(name: "L1"); tr.clips = [c]; p.tracks = [tr]
        let img = try XCTUnwrap(Renderer(project: p, assets: RenderAssets()).renderImage(t: t))
        var d = [UInt8](repeating: 0, count: img.width * img.height * 4)
        let ctx = try XCTUnwrap(CGContext(data: &d, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return d
    }

    private func brightness(_ d: [UInt8]) -> Int { stride(from: 0, to: d.count, by: 4).reduce(0) { $0 + Int(d[$1]) } }

    func testRenderedFramesDifferFromStaticAtEarlyTime() throws {
        let plain = textClip()
        let still = try pixels(plain, t: 0.1)
        XCTAssertGreaterThan(brightness(still), 0)
        for id in ["builtin.fadein", "builtin.typewriter", "builtin.pop"] {
            var c = textClip()
            _ = try preset(id).look.apply(to: &c)
            let early = try pixels(c, t: 0.1)
            XCTAssertNotEqual(early, still, id)
            if id != "builtin.pop" { XCTAssertLessThan(brightness(early), brightness(still), id) }
            // アニメーションの後は静止した文字と同じ
            XCTAssertEqual(try pixels(c, t: 3), try pixels(plain, t: 3), id)
        }
        // フェードインの途中は、始めより明るく終わりより暗い
        var f = textClip(); _ = try preset("builtin.fadein").look.apply(to: &f)
        let b0 = brightness(try pixels(f, t: 0.05)), b1 = brightness(try pixels(f, t: 0.4)), b2 = brightness(try pixels(f, t: 2))
        XCTAssertLessThan(b0, b1); XCTAssertLessThan(b1, b2)
    }
}

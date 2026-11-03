import XCTest
@testable import MovieCutCore

/// 他のクリップの値を文字クリップに表示する(候補 30)。
final class ValueTextTests: XCTestCase {
    private func project() -> Project {
        var p = Project()
        var img = Clip(); img.id = "img"; img.type = .image; img.src = "/nonexistent/a.png"; img.start = 2; img.duration = 4
        img.opacity = 0.5; img.x = 0.25; img.scale = 1.5
        img.keyframes["opacity"] = [Keyframe(t: 0, v: 0), Keyframe(t: 4, v: 1)]
        var txt = Clip(); txt.id = "txt"; txt.type = .text; txt.text = "不透明度 "; txt.start = 0; txt.duration = 8
        txt.valueRef = ValueRef(clipId: "img", param: "opacity")
        p.tracks[0].clips = [img]
        p.tracks[1].clips = [txt]
        return p
    }

    func testValueFollowsKeyframesAtProjectTime() {
        let p = project()
        let r = ValueRef(clipId: "img", param: "opacity")
        XCTAssertEqual(r.value(in: p, at: 2)!, 0, accuracy: 1e-9)
        XCTAssertEqual(r.value(in: p, at: 4)!, 0.5, accuracy: 1e-9)
        XCTAssertEqual(r.value(in: p, at: 99)!, 1, accuracy: 1e-9, "クリップの後ろは最後のキー")
        XCTAssertEqual(ValueRef(clipId: "img", param: "x").value(in: p, at: 3)!, 0.25, accuracy: 1e-9, "キー無しは設定値")
    }

    func testTimingParams() {
        let p = project()
        XCTAssertEqual(ValueRef(clipId: "img", param: "start").value(in: p, at: 0), 2)
        XCTAssertEqual(ValueRef(clipId: "img", param: "duration").value(in: p, at: 0), 4)
        XCTAssertEqual(ValueRef(clipId: "img", param: "end").value(in: p, at: 0), 6)
    }

    func testFormats() {
        XCTAssertEqual(ValueRef(clipId: "a", param: "opacity").format(0.5), "50.0%", "不透明度の自動は %")
        XCTAssertEqual(ValueRef(clipId: "a", param: "scale", decimals: 2).format(1.5), "1.50")
        XCTAssertEqual(ValueRef(clipId: "a", param: "scale", format: "percent", decimals: 0).format(1.5), "150%")
        XCTAssertEqual(ValueRef(clipId: "a", param: "start", decimals: 1).format(75.25), "01:15.2")
        XCTAssertEqual(ValueRef(clipId: "a", param: "end", decimals: 0).format(5), "00:05")
        XCTAssertEqual(ValueRef(clipId: "a", param: "x", decimals: 99).decimals, 4, "桁数は 0〜4")
        XCTAssertEqual(ValueRef(clipId: "a", param: "bogus").param, ValueRef.defaultParam)
    }

    func testDisplayTextAndMissingTarget() {
        let p = project()
        let t = p.tracks[1].clips[0]
        XCTAssertEqual(t.displayText(at: 4, in: p), "不透明度 50.0%")
        var gone = t; gone.valueRef = ValueRef(clipId: "none")
        XCTAssertEqual(gone.displayText(at: 4, in: p), "不透明度 —", "参照先が無くても落ちない")
        var plain = t; plain.valueRef = nil
        XCTAssertEqual(plain.displayText(at: 4, in: p), "不透明度 ")
        var both = t; both.counter = TextCounter(from: 5, to: 0, format: "ss")
        XCTAssertEqual(both.displayText(at: 0, in: p), "不透明度 5", "カウントダウンを優先")
    }

    func testFindsClipInsideCompound() {
        var p = project()
        var inner = Clip(); inner.id = "inner"; inner.type = .image; inner.start = 1; inner.duration = 2; inner.opacity = 0.2
        var comp = Clip(); comp.id = "comp"; comp.type = .compound; comp.start = 0; comp.duration = 3
        var tr = Track(name: "中"); tr.clips = [inner]; comp.tracks = [tr]
        p.tracks[2].clips = [comp]
        XCTAssertEqual(ValueRef(clipId: "inner", param: "opacity").value(in: p, at: 1)!, 0.2, accuracy: 1e-9)
    }

    func testRoundTripOptionalAndKeepsUnknownKeys() throws {
        var c = Clip(); c.type = .text; c.text = "x"
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(c), as: UTF8.self).contains("valueRef"), "未設定は書かない")
        c.valueRef = ValueRef(clipId: "img", param: "scale")
        let s = String(decoding: try JSONEncoder().encode(c), as: UTF8.self)
        XCTAssertFalse(s.contains("\"format\""), "自動は書かない")
        XCTAssertFalse(s.contains("decimals"), "既定の桁は書かない")
        let back = try JSONDecoder().decode(Clip.self, from: Data(s.utf8))
        XCTAssertEqual(back.valueRef, c.valueRef)
        let withExtra = #"{"id":"t","type":"text","start":0,"duration":1,"valueRef":{"clipId":"a","param":"x","future":1,"decimals":3}}"#
        let c2 = try JSONDecoder().decode(Clip.self, from: Data(withExtra.utf8))
        XCTAssertEqual(c2.valueRef?.decimals, 3)
        XCTAssertTrue(String(decoding: try JSONEncoder().encode(c2), as: UTF8.self).contains("future"))
        let bad = #"{"id":"t","type":"text","start":0,"duration":1,"valueRef":7}"#
        let c3 = try JSONDecoder().decode(Clip.self, from: Data(bad.utf8))
        XCTAssertNil(c3.valueRef)
        XCTAssertTrue(String(decoding: try JSONEncoder().encode(c3), as: UTF8.self).contains("\"valueRef\":7"))
    }

    func testEditingRules() {
        var t = Clip(); t.id = "t"; t.type = .text
        XCTAssertFalse(ValueRefEditing.set(&t, to: ValueRef(clipId: "t")), "自分自身は参照しない")
        XCTAssertFalse(ValueRefEditing.set(&t, to: ValueRef(clipId: "")))
        XCTAssertTrue(ValueRefEditing.set(&t, to: ValueRef(clipId: "a")))
        XCTAssertFalse(ValueRefEditing.set(&t, to: ValueRef(clipId: "a")), "同じ値は変更なし")
        XCTAssertTrue(ValueRefEditing.update(&t) { $0.param = "x" })
        XCTAssertFalse(ValueRefEditing.update(&t) { $0.param = "x" })
        XCTAssertTrue(ValueRefEditing.set(&t, to: nil))
        var img = Clip(); img.type = .image
        XCTAssertFalse(ValueRefEditing.set(&img, to: ValueRef(clipId: "a")), "文字クリップだけ")
        XCTAssertEqual(ValueRefEditing.candidates(in: project(), excluding: "txt").map(\.id), ["img"])
    }

    func testRendererDrawsDifferentPixelsWhenValueChanges() throws {
        var p = project()
        p.tracks[0].clips[0].keyframes = [:]
        p.tracks[1].clips[0].fontSize = 120
        let a = try XCTUnwrap(Renderer(project: p, assets: RenderAssets()).renderImage(t: 3))
        p.tracks[0].clips[0].opacity = 0.9
        let b = try XCTUnwrap(Renderer(project: p, assets: RenderAssets()).renderImage(t: 3))
        XCTAssertNotEqual(a.dataProvider?.data as Data?, b.dataProvider?.data as Data?, "参照先の値が変われば文字の絵が変わる")
    }
}

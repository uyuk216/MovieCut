import XCTest
@testable import MovieCutCore

/// テンプレートの差し替え項目(スロット): 後方互換・保存往復・定義・適用・検証。
final class TemplateSlotsTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MovieCutTemplateSlotsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func textClip() -> Clip {
        var c = Clip()
        c.type = .text; c.text = "見出し"; c.start = 3; c.duration = 4
        c.fontSize = 96; c.color = "#ff0000"; c.outline = "#000000"
        return c
    }

    private func imageClip() -> Clip {
        var c = Clip()
        c.type = .image; c.src = "/tmp/a.png"; c.duration = 3
        return c
    }

    private func slotTemplate() -> ItemTemplate {
        ItemTemplate.capture(name: "T", from: textClip(), slots: [
            TemplateSlot(id: "text", label: "文字", kind: .text, target: .text),
            TemplateSlot(id: "color", label: "文字色", kind: .color, target: .color),
        ])!
    }

    // MARK: 後方互換

    func testLegacyJSONWithoutSlotsLoads() throws {
        let clipData = try JSONEncoder().encode(textClip())
        let clipJSON = String(data: clipData, encoding: .utf8)!
        let json = #"{"version":1,"templates":[{"id":"user.old","name":"旧","clip":\#(clipJSON)}]}"#
        let store = ItemTemplateStore(directory: dir)
        try json.write(to: store.fileURL, atomically: true, encoding: .utf8)
        let list = store.load()
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].slots, [])
        let made = list[0].makeClip()
        XCTAssertEqual(made.text, "見出し")
        XCTAssertEqual(made.start, 0)
        var target = Clip(); target.type = .text; target.text = "別"; target.start = 9; target.duration = 2
        XCTAssertTrue(list[0].apply(to: &target))
        XCTAssertEqual(target.text, "別")
        XCTAssertEqual(target.fontSize, 96)
    }

    func testEncodeWithoutSlotsOmitsKey() throws {
        let t = ItemTemplate.capture(name: "T", from: textClip())!
        let s = String(data: try JSONEncoder().encode(t), encoding: .utf8)!
        XCTAssertFalse(s.contains("\"slots\""))
        let s2 = String(data: try JSONEncoder().encode(slotTemplate()), encoding: .utf8)!
        XCTAssertTrue(s2.contains("\"slots\""))
    }

    func testSlotDecodeIsLenient() throws {
        let json = #"{"id":"a","label":"A","kind":"text","target":"text"}"#
        let s = try JSONDecoder().decode(TemplateSlot.self, from: Data(json.utf8))
        XCTAssertFalse(s.required)
        XCTAssertNil(s.defaultValue)
    }

    // MARK: 保存往復

    func testStoreRoundTripKeepsSlots() throws {
        let store = ItemTemplateStore(directory: dir)
        try store.save([slotTemplate()])
        let loaded = store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].slots.map(\.id), ["text", "color"])
        XCTAssertEqual(loaded[0].slots[0].defaultValue, "見出し")
        XCTAssertEqual(loaded[0].slots, slotTemplate().slots.map { s in
            var x = s; x.defaultValue = s.value(in: textClip()); return x
        })
    }

    func testStoreLoadDropsBrokenSlotOnly() throws {
        let clipJSON = String(data: try JSONEncoder().encode(textClip()), encoding: .utf8)!
        let json = #"{"version":1,"templates":[{"id":"user.x","name":"X","clip":\#(clipJSON),"slots":[{"id":"ok","label":"L","kind":"text","target":"text"},{"id":"bad","label":"L","kind":"nope","target":"text"},{"id":"img","label":"I","kind":"image","target":"src"}]}]}"#
        let store = ItemTemplateStore(directory: dir)
        try json.write(to: store.fileURL, atomically: true, encoding: .utf8)
        let list = store.load()
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].slots.map(\.id), ["ok"], "壊れた・不両立なスロットだけ捨てる")
    }

    // MARK: 定義

    func testCaptureNormalizesSlots() {
        let t = ItemTemplate.capture(name: "T", from: textClip(), slots: [
            TemplateSlot(id: " te xt!", label: "  文字\n入力 ", kind: .text, target: .text),
            TemplateSlot(id: "text", label: "重複", kind: .text, target: .subtitleText),
            TemplateSlot(id: "img", label: "画像", kind: .image, target: .source),
            TemplateSlot(id: "bad", label: "不対応", kind: .color, target: .text),
            TemplateSlot(id: "c", label: "色", kind: .color, target: .color, defaultValue: "#00ff00"),
        ])!
        XCTAssertEqual(t.slots.map(\.id), ["text", "c"])
        XCTAssertEqual(t.slots[0].label, "文字 入力")
        XCTAssertEqual(t.slots[0].defaultValue, "見出し")
        XCTAssertEqual(t.slots[1].defaultValue, "#00ff00")
    }

    func testCaptureLimitsSlotCount() {
        var slots: [TemplateSlot] = []
        for i in 0..<30 { slots.append(TemplateSlot(id: "s\(i)", label: "L", kind: .text, target: .text)) }
        // 同じ id でなければ 20 件まで(同一 target でも id が違えば許す)
        let t = ItemTemplate.capture(name: "T", from: textClip(), slots: slots)!
        XCTAssertEqual(t.slots.count, ItemTemplate.maxSlots)
    }

    func testSuggestedSlotsOnlyForRealValues() {
        let ids = ItemTemplate.suggestedSlots(for: textClip()).map(\.id)
        XCTAssertEqual(ids, ["text", "color", "outline"])
        var empty = Clip(); empty.type = .text
        XCTAssertEqual(ItemTemplate.suggestedSlots(for: empty).map(\.id), [])
        XCTAssertEqual(ItemTemplate.suggestedSlots(for: imageClip()).map(\.id), ["image"])
        var v = textClip(); v.type = .voice; v.subtitleText = "字幕"
        XCTAssertTrue(ItemTemplate.suggestedSlots(for: v).map(\.id).contains("subtitleText"))
        var shape = Clip(); shape.type = .shape; shape.figure = Figure(fill: "#112233")
        XCTAssertEqual(ItemTemplate.suggestedSlots(for: shape).map(\.id), ["figureFill"])
    }

    // MARK: 新規作成

    func testMakeClipReplacesOnlySlotFields() {
        let t = slotTemplate()
        let c = t.makeClip(values: ["text": "新しい文", "color": "#00ff00"])
        XCTAssertEqual(c.text, "新しい文")
        XCTAssertEqual(c.color, "#00ff00")
        XCTAssertEqual(c.outline, "#000000", "スロット外はテンプレートのまま")
        XCTAssertEqual(c.fontSize, 96)
        XCTAssertNotEqual(c.id, t.clip.id)
        XCTAssertEqual(c.start, 0)
        XCTAssertEqual(t.makeClip(values: [:]).text, "見出し")
    }

    func testMakeClipReplacesImageSource() {
        let t = ItemTemplate.capture(name: "I", from: imageClip(), slots: ItemTemplate.suggestedSlots(for: imageClip()))!
        XCTAssertEqual(t.makeClip(values: ["image": "/tmp/b.png"]).src, "/tmp/b.png")
        XCTAssertEqual(t.makeClip().src, "/tmp/a.png")
    }

    func testFigureFillCreatesFigure() {
        var c = Clip(); c.type = .shape; c.duration = 2
        let slot = TemplateSlot(id: "f", label: "塗り", kind: .color, target: .figureFill)
        var target = c
        XCTAssertTrue(slot.apply("none", to: &target))
        XCTAssertEqual(target.figure?.fill, "none")
        XCTAssertFalse(TemplateSlot(id: "c", label: "c", kind: .color, target: .color).apply("none", to: &c))
    }

    // MARK: 既存クリップへの適用

    func testApplyValuesOverwritesContentButKeepsPlacement() {
        let t = slotTemplate()
        var target = Clip()
        target.type = .text; target.text = "元の文"; target.start = 10; target.duration = 7; target.fontSize = 40
        let id = target.id
        let r = t.apply(values: ["text": "差し替え"], to: &target)
        XCTAssertTrue(r.changed)
        XCTAssertEqual(r.appliedSlotIds, ["text"])
        XCTAssertEqual(target.text, "差し替え")
        XCTAssertEqual(target.start, 10)
        XCTAssertEqual(target.duration, 7)
        XCTAssertEqual(target.id, id)
        XCTAssertEqual(target.fontSize, 96, "見た目はテンプレートから")

        var other = target; other.text = "保持される"
        _ = t.apply(values: [:], to: &other)
        XCTAssertEqual(other.text, "保持される")
    }

    func testApplyValuesSkipsDifferentType() {
        var target = imageClip()
        let before = target
        let r = slotTemplate().apply(values: ["text": "x"], to: &target)
        XCTAssertFalse(r.changed)
        XCTAssertEqual(target, before)
    }

    // MARK: 検証

    func testInvalidColorRejectedAndDefaultKept() {
        let t = slotTemplate()
        for bad in ["#zzz", "red", "#12345", "none"] {
            let r = t.instantiate(values: ["color": bad])
            XCTAssertEqual(r.clip.color, "#ff0000", bad)
            XCTAssertEqual(r.rejections, [TemplateSlotRejection(slotId: "color", reason: .invalidValue)], bad)
            XCTAssertEqual(r.appliedSlotIds, [])
        }
        XCTAssertEqual(t.makeClip(values: ["color": "#11223344"]).color, "#11223344")
    }

    func testRequiredTextEmptyRejected() {
        var t = slotTemplate()
        t.slots[0].required = true
        let r = t.instantiate(values: ["text": "   "])
        XCTAssertEqual(r.clip.text, "見出し")
        XCTAssertEqual(r.rejections, [TemplateSlotRejection(slotId: "text", reason: .emptyRequired)])
        // 任意の空は「既定を使う」(拒否ではない)
        let o = slotTemplate().instantiate(values: ["text": ""])
        XCTAssertEqual(o.clip.text, "見出し")
        XCTAssertTrue(o.rejections.isEmpty)
    }

    func testUnknownSlotRecordedDeterministically() {
        let r = slotTemplate().instantiate(values: ["zzz": "1", "aaa": "2", "text": "ok"])
        XCTAssertEqual(r.rejections.map(\.slotId), ["aaa", "zzz"])
        XCTAssertTrue(r.rejections.allSatisfy { $0.reason == .unknownSlot })
        XCTAssertEqual(r.clip.text, "ok")
    }

    func testCompatibilityRules() {
        let img = imageClip()
        XCTAssertFalse(TemplateSlot(id: "t", label: "t", kind: .text, target: .text).isCompatible(with: img))
        XCTAssertTrue(TemplateSlot(id: "s", label: "s", kind: .image, target: .source).isCompatible(with: img))
        XCTAssertFalse(TemplateSlot(id: "s", label: "s", kind: .text, target: .source).isCompatible(with: img))
        XCTAssertFalse(TemplateSlot(id: "f", label: "f", kind: .color, target: .figureFill).isCompatible(with: img))
        XCTAssertTrue(TemplateSlot(id: "c", label: "c", kind: .color, target: .outline).isCompatible(with: img))
    }
}


// MARK: - バグ確認 第2部 C12: 素材差し替えで旧素材の長さを捨てる

final class TemplateSlotSourceReplacementTests: XCTestCase {
    func testReplacingTheSourceClearsTheOldSourceLength() {
        var c = Clip(); c.type = .image; c.src = "/old.png"; c.srcDuration = 5
        let slot = TemplateSlot(id: "img", label: "画像", kind: .image, target: .source)
        XCTAssertTrue(slot.apply("/new.png", to: &c))
        XCTAssertEqual(c.src, "/new.png")
        XCTAssertNil(c.srcDuration)
    }
}

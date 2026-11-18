import XCTest
@testable import MovieCutCore

/// アイテムテンプレート(#8): クリップ設定の保存・適用・新規作成と、保存先の読み書き。
final class ItemTemplateTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MovieCutItemTemplateTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func styledTextClip() -> Clip {
        var c = Clip()
        c.type = .text; c.text = "見出し"; c.start = 3; c.duration = 4
        c.x = 0.3; c.y = 0.25; c.fontSize = 96; c.color = "#ff0000"; c.outline = "#000000"
        c.font = "Hiragino Sans"; c.opacity = 0.9; c.rotation = 15
        c.effects = [Effect(kind: "brightness", params: ["amount": 0.4])]
        c.fadeIn = 0.5
        var s = TextStyle(); s.bold = true
        c.textStyle = s
        return c
    }

    // MARK: 保存(capture)

    func testCaptureNormalizesStartAndDropsBookkeeping() {
        var src = styledTextClip()
        src.note = "メモ"; src.locked = true; src.group = "g1"
        let t = ItemTemplate.capture(name: "  私の見出し  ", from: src)
        XCTAssertEqual(t?.name, "私の見出し")
        XCTAssertEqual(t?.clip.start, 0, "開始時刻は 0 にそろえる")
        XCTAssertEqual(t?.clip.duration, 4, "長さは残す(新規作成の土台になる)")
        XCTAssertNil(t?.clip.note)
        XCTAssertNil(t?.clip.locked)
        XCTAssertNil(t?.clip.group)
        XCTAssertEqual(t?.clip.fontSize, 96)
        XCTAssertEqual(src.start, 3, "元のクリップは変えない")
    }

    func testCaptureRejectsEmptyName() {
        XCTAssertNil(ItemTemplate.capture(name: "   ", from: styledTextClip()))
        XCTAssertNil(ItemTemplate.capture(name: "\n", from: styledTextClip()))
    }

    // MARK: 既存クリップへの適用

    func testApplyCopiesPresentationButKeepsContentAndPlacement() {
        let t = ItemTemplate.capture(name: "T", from: styledTextClip())!
        var target = Clip()
        target.type = .text; target.text = "別の文"; target.start = 10; target.duration = 7
        target.offset = 1.5; target.src = "/tmp/a.png"; target.fontSize = 40; target.color = "#00ff00"
        let targetId = target.id
        XCTAssertTrue(t.apply(to: &target))
        // 見た目・振る舞いは写る
        XCTAssertEqual(target.fontSize, 96)
        XCTAssertEqual(target.color, "#ff0000")
        XCTAssertEqual(target.x, 0.3)
        XCTAssertEqual(target.rotation, 15)
        XCTAssertEqual(target.effects, [Effect(kind: "brightness", params: ["amount": 0.4])])
        XCTAssertEqual(target.fadeIn, 0.5)
        XCTAssertEqual(target.textStyle?.bold, true)
        // 中身と配置は残る
        XCTAssertEqual(target.id, targetId)
        XCTAssertEqual(target.text, "別の文")
        XCTAssertEqual(target.start, 10)
        XCTAssertEqual(target.duration, 7)
        XCTAssertEqual(target.offset, 1.5)
        XCTAssertEqual(target.src, "/tmp/a.png")
    }

    func testApplyToVoiceKeepsCharacterSubtitleAndAudio() {
        var src = Clip()
        src.type = .voice; src.text = "あいぼう"; src.subtitleText = "相棒"
        src.fontSize = 80; src.subtitle = true
        let charId = "char-src"
        src.charId = charId
        let t = ItemTemplate.capture(name: "V", from: src)!

        var target = Clip()
        target.type = .voice; target.text = "ほんね"; target.subtitleText = "本音"
        target.src = "/voices/b.wav"; target.charId = "char-target"; target.duration = 2.5
        XCTAssertTrue(t.apply(to: &target))
        XCTAssertEqual(target.fontSize, 80, "字幕の大きさは写る")
        XCTAssertEqual(target.text, "ほんね", "セリフは変えない")
        XCTAssertEqual(target.subtitleText, "本音", "字幕文は変えない")
        XCTAssertEqual(target.charId, "char-target", "話すキャラは変えない")
        XCTAssertEqual(target.src, "/voices/b.wav")
        XCTAssertEqual(target.duration, 2.5)
    }

    func testApplyRejectsDifferentTypeAndReportsNoChange() {
        let t = ItemTemplate.capture(name: "T", from: styledTextClip())!
        var image = Clip(); image.type = .image
        XCTAssertFalse(t.apply(to: &image), "種類が違えば当てない")
        var same = styledTextClip(); same.start = 0
        XCTAssertFalse(t.apply(to: &same), "同じ設定なら「変えた」と言わない")
    }

    // MARK: 新規作成

    func testMakeClipRenewsIdAndKeepsSnapshot() {
        let t = ItemTemplate.capture(name: "T", from: styledTextClip())!
        let made = t.makeClip()
        XCTAssertNotEqual(made.id, t.clip.id)
        XCTAssertEqual(made.start, 0)
        XCTAssertEqual(made.duration, 4)
        XCTAssertEqual(made.text, "見出し", "新規作成は保存した写しそのまま(セリフも含む)")
        XCTAssertEqual(made.fontSize, 96)
    }

    func testMakeClipFallsBackDurationWhenZero() {
        var c = Clip(); c.type = .blur; c.duration = 0; c.strength = 20
        let t = ItemTemplate.capture(name: "B", from: c)!
        XCTAssertEqual(t.makeClip().duration, 2)
    }

    // MARK: 組み込みと一覧

    func testBuiltinsExistAndAreFindable() {
        XCTAssertEqual(ItemTemplateLibrary.builtins.count, 3)
        XCTAssertNotNil(ItemTemplateLibrary.find(name: "字幕・標準(ボイス)", user: []))
        XCTAssertEqual(ItemTemplateLibrary.find(name: "字幕・標準(ボイス)", user: [])?.clipType, .voice)
        XCTAssertTrue(ItemTemplateLibrary.builtins.allSatisfy { $0.id.hasPrefix("builtin.") })
    }

    func testAddAvoidsDuplicateNamesAndCapsList() {
        var list: [ItemTemplate] = []
        let c = styledTextClip()
        XCTAssertNotNil(ItemTemplateLibrary.add(&list, ItemTemplate.capture(name: "重なり", from: c)!))
        XCTAssertNotNil(ItemTemplateLibrary.add(&list, ItemTemplate.capture(name: "重なり", from: c)!))
        XCTAssertEqual(list.map(\.name), ["重なり", "重なり 2"])
        XCTAssertTrue(ItemTemplateLibrary.delete(&list, id: list[0].id))
        XCTAssertEqual(list.map(\.name), ["重なり 2"])
    }

    // MARK: 保存先の読み書き

    func testStoreRoundTrip() throws {
        let store = ItemTemplateStore(directory: dir)
        XCTAssertEqual(store.load(), [])
        let saved = try store.save(clip: styledTextClip(), as: "見出し用")
        XCTAssertEqual(saved?.name, "見出し用")
        let loaded = store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.name, "見出し用")
        XCTAssertEqual(loaded.first?.clip.fontSize, 96)
        XCTAssertEqual(loaded.first?.clip.effects.count, 1)
        // 同じ名前は避けて足す
        let second = try store.save(clip: styledTextClip(), as: "見出し用")
        XCTAssertEqual(second?.name, "見出し用 2")
        XCTAssertEqual(store.load().count, 2)
    }

    func testStoreIgnoresBrokenFile() throws {
        let store = ItemTemplateStore(directory: dir)
        try Data("not json".utf8).write(to: store.fileURL)
        XCTAssertEqual(store.load(), [])
        try Data(#"{"version":1,"templates":[{"id":"x"},42,{"id":"user.ok","name":"OK","clip":{"id":"c","type":"text","start":0,"duration":1,"offset":0}}]}"#.utf8)
            .write(to: store.fileURL)
        let loaded = store.load()
        XCTAssertEqual(loaded.map(\.name), ["OK"], "壊れた項目だけ捨てる")
    }
}

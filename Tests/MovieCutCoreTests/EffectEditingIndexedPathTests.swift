import XCTest
@testable import MovieCutCore

/// 第2部 A06/A02 の Core 側修正の回帰テスト。
final class EffectEditingIndexedPathTests: XCTestCase {

    // A06: LUT が複数あるとき、カード指定の差し替えはそのカードの LUT だけを変える
    func testSetLUTPathTargetsIndexedEffect() {
        var c = Clip(); c.type = .video
        var e1 = Effect(.lut); e1.path = "a.cube"
        var e2 = Effect(.lut); e2.path = "b.cube"
        c.effects = [e1, e2]
        XCTAssertTrue(EffectEditing.setLUTPath(&c, "z.cube", effectIndex: 1))
        XCTAssertEqual(c.effects[0].path, "a.cube", "最初の LUT は変わらない")
        XCTAssertEqual(c.effects[1].path, "z.cube")
        XCTAssertTrue(EffectEditing.setLUTPath(&c, "y.cube"))
        XCTAssertEqual(c.effects[0].path, "y.cube", "番号なしは従来どおり最初の LUT")
    }

    func testSetColorTransferPathTargetsIndexedEffect() {
        var c = Clip(); c.type = .video
        var e1 = Effect(.colorTransfer); e1.path = "a.png"
        var e2 = Effect(.colorTransfer); e2.path = "b.png"
        c.effects = [e1, e2]
        XCTAssertTrue(EffectEditing.setColorTransferPath(&c, "z.png", effectIndex: 1))
        XCTAssertEqual(c.effects[0].path, "a.png")
        XCTAssertEqual(c.effects[1].path, "z.png")
    }

    // A02: ProRes の書き出しプリセットは、保存して読み直しても落ちない
    func testProResPresetSurvivesRoundTrip() {
        let preset = CustomExportPreset(name: "ProRes確認", width: 1920, height: 1080, codec: "prores422", fps: 30)
        let back = CustomExportPresetStore.decode(CustomExportPresetStore.encode([preset]))
        XCTAssertEqual(back.count, 1)
        XCTAssertEqual(back.first?.codec, "prores422")
    }
}

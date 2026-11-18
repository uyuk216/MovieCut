import XCTest
@testable import MovieCutCore

/// 顔ぼかしの一括付与: 対象種別・上書き規則・複合クリップの再帰・一括解除。
final class FaceBlurBulkTests: XCTestCase {
    func clip(_ type: ClipType, effects: [Effect] = []) -> Clip {
        var c = Clip(); c.type = type; c.effects = effects; return c
    }

    func project(with clips: [Clip]) -> Project {
        var p = Project(); p.characters = []
        var tr = Track(name: "L1"); tr.clips = clips; p.tracks = [tr]
        return p
    }

    func testAppliesToImageAndVideoOnlyByDefault() {
        var p = project(with: [clip(.image), clip(.video), clip(.audio), clip(.text), clip(.tachie)])
        let changed = FaceBlurBulk.apply(to: &p)
        XCTAssertEqual(changed, 2)
        XCTAssertTrue(FaceBlurBulk.hasFaceBlur(p.tracks[0].clips[0]))
        XCTAssertTrue(FaceBlurBulk.hasFaceBlur(p.tracks[0].clips[1]))
        XCTAssertFalse(FaceBlurBulk.hasFaceBlur(p.tracks[0].clips[3]), "テキストは既定では対象外")
        XCTAssertEqual(FaceBlurBulk.count(in: p), 2)
        let e = p.tracks[0].clips[0].effects.first { $0.kind == EffectKind.faceBlur.rawValue }!
        XCTAssertEqual(e.value("strength"), 0.6); XCTAssertEqual(e.value("mode"), 0); XCTAssertEqual(e.value("size"), 38)
    }

    func testIncludeAllSupportedTypesAlsoCoversTextAndTachie() {
        var p = project(with: [clip(.text), clip(.tachie), clip(.audio)])
        var opt = FaceBlurBulk.Options(); opt.includeAllSupportedTypes = true
        XCTAssertEqual(FaceBlurBulk.apply(to: &p, options: opt), 2, "音声はエフェクト非対応なので対象外")
    }

    func testOptionsAreReflectedAndClamped() {
        var opt = FaceBlurBulk.Options(); opt.strength = 5; opt.mode = 1; opt.size = 12
        let e = FaceBlurBulk.makeEffect(opt)
        XCTAssertEqual(e.value("strength"), 1, "範囲に丸める")
        XCTAssertEqual(e.value("mode"), 1); XCTAssertEqual(e.value("size"), 12)
    }

    func testSecondApplyReplacesInsteadOfDuplicating() {
        var p = project(with: [clip(.image)])
        XCTAssertEqual(FaceBlurBulk.apply(to: &p), 1)
        var opt = FaceBlurBulk.Options(); opt.strength = 0.9
        XCTAssertEqual(FaceBlurBulk.apply(to: &p, options: opt), 1, "設定が変われば更新として数える")
        XCTAssertEqual(p.tracks[0].clips[0].effects.filter { $0.kind == EffectKind.faceBlur.rawValue }.count, 1, "重複しない")
        XCTAssertEqual(p.tracks[0].clips[0].effects[0].value("strength"), 0.9)
        XCTAssertEqual(FaceBlurBulk.apply(to: &p, options: opt), 0, "同じ設定なら何もしない")
    }

    func testReplaceExistingFalseLeavesExistingUntouched() {
        var existing = Effect(.faceBlur); existing.params["strength"] = 0.3
        var p = project(with: [clip(.image, effects: [existing])])
        var opt = FaceBlurBulk.Options(); opt.replaceExisting = false; opt.strength = 0.9
        XCTAssertEqual(FaceBlurBulk.apply(to: &p, options: opt), 0)
        XCTAssertEqual(p.tracks[0].clips[0].effects[0].value("strength"), 0.3)
    }

    func testAppliesInsideCompoundClipsRecursively() {
        var inner = Track(name: "in"); inner.clips = [clip(.image), clip(.video)]
        var comp = clip(.compound); comp.tracks = [inner]
        var p = project(with: [comp])
        XCTAssertEqual(FaceBlurBulk.apply(to: &p), 3, "複合クリップ自体 + 中の映像 2 つ")
        XCTAssertEqual(FaceBlurBulk.count(in: p), 3)
        XCTAssertEqual(FaceBlurBulk.removeAll(from: &p), 3)
        XCTAssertEqual(FaceBlurBulk.count(in: p), 0)
    }

    func testRemoveAllRemovesOnlyFaceBlur() {
        var c = clip(.image, effects: [Effect(.sepia), Effect(.faceBlur), Effect(.vignette)])
        var p = project(with: [c])
        XCTAssertEqual(FaceBlurBulk.removeAll(from: &p), 1)
        XCTAssertEqual(p.tracks[0].clips[0].effects.map(\.kind), [EffectKind.sepia.rawValue, EffectKind.vignette.rawValue])
        XCTAssertEqual(FaceBlurBulk.removeAll(from: &p), 0, "もう無ければ 0")
        XCTAssertEqual(FaceBlurBulk.count(in: p), 0)
    }
}

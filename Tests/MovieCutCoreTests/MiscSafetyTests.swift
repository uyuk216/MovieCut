import XCTest
@testable import MovieCutCore

/// C23(その他・CLI基盤): キャラクター削除の入れ子対応、時刻・長さの整形、
/// キャッシュ合計の溢れ、収録範囲の交差、WAVレートの範囲。
final class MiscSafetyTests: XCTestCase {

    func testCharacterDeleteRemovesNestedVoices() {
        var ch = MovieCutCore.Character(); ch.id = "c1"
        var ch2 = MovieCutCore.Character(); ch2.id = "c2"
        func voice(_ id: String) -> Clip { var c = Clip(); c.id = id; c.type = .voice; c.charId = "c1"; c.start = 0; c.duration = 1; return c }
        var inner = Track(); inner.clips = [voice("v-in-compound")]
        var comp = Clip(); comp.type = .compound; comp.start = 0; comp.duration = 1; comp.tracks = [inner]
        var top = Track(); top.clips = [voice("v-top"), comp]
        var sceneTrack = Track(); sceneTrack.clips = [voice("v-in-scene")]
        var p = Project(); p.characters = [ch, ch2]; p.tracks = [top]
        p.scenes = [SceneDefinition(id: "s1", name: "S", tracks: [sceneTrack])]
        let r = CharacterEditing.delete(charId: "c1", in: p)
        XCTAssertEqual(Set(r?.removedClipIds ?? []), ["v-top", "v-in-compound", "v-in-scene"])
        XCTAssertTrue(CharacterEditing.voiceClips(of: "c1", in: r!.project).isEmpty)
    }

    func testMemoryBudgetHandlesNonFiniteAndHuge() {
        XCTAssertNil(MemoryBudget.limitBytes(totalRAMGB: .nan))
        XCTAssertNil(MemoryBudget.limitBytes(totalRAMGB: .infinity))
        _ = MemoryBudget.limitBytes(totalRAMGB: 1e300)
        XCTAssertNotNil(MemoryBudget.limitBytes(totalRAMGB: 16))
    }

    func testCacheBudgetTotalOverflowDoesNotTrap() {
        let m = CacheBudgetManager(limitBytes: nil)
        _ = m.register(key: "a", cost: Int64.max, onEvict: {})
        _ = m.register(key: "b", cost: 1, onEvict: {})
    }

    func testReviewCommentCSVTimesAreSanitized() {
        let csv = "id,timecode,time,endTime,author,resolved,clipId,body\n" +
                  ",,nan,,,,,本文1\n" +
                  ",,1e100,,,,,本文2\n"
        let got = ReviewCommentExchange.decodeCSV(csv)
        XCTAssertEqual(got.count, 2)
        XCTAssertEqual(got[0].time, 0)
        XCTAssertEqual(got[1].time, 1.0e12)
    }

    func testReviewCommentAddAndUpdateClampBody() {
        let long = String(repeating: "あ", count: 4001)
        let added = ReviewCommentEditing.add(in: Project(), at: .nan, body: long)
        XCTAssertEqual(added?.project.reviewComments.first?.body.count, 4000)
        XCTAssertEqual(added?.project.reviewComments.first?.time, 0)
        let id = added!.id
        let updated = ReviewCommentEditing.updateBody(in: added!.project, id: id, to: long + "x")
        XCTAssertEqual(updated?.reviewComments.first?.body.count, 4000)
    }

    func testScreenRecordingRegionIntersectsDisplay() {
        let r = ScreenRecordingRegion(x: -100, y: 0, width: 200, height: 100)
        let c = r.clamped(toDisplayWidth: 1920, height: 1080)
        XCTAssertEqual(c, ScreenRecordingRegion(x: 0, y: 0, width: 100, height: 100))
        let outside = ScreenRecordingRegion(x: -200, y: 0, width: 100, height: 100)
        XCTAssertNil(outside.clamped(toDisplayWidth: 1920, height: 1080))
    }

    func testWavDataClampsSampleRate() {
        XCTAssertFalse(BuiltInSounds.wavData([], sampleRate: -1).isEmpty)
        XCTAssertFalse(BuiltInSounds.wavData([], sampleRate: 0).isEmpty)
        XCTAssertFalse(BuiltInSounds.wavData([], sampleRate: Int.max).isEmpty)
    }
}

import XCTest
@testable import MovieCutCore

/// 立ち絵クリップの「プロジェクトの長さに合わせる」(`followsProjectEnd`): 保存形式・合わせ直し・手で変えたらやめる・移行クリップ。
final class TachieFollowEndTests: XCTestCase {
    func clip(_ id: String, _ type: ClipType, start: Double, duration: Double) -> Clip {
        var c = Clip(); c.id = id; c.type = type; c.start = start; c.duration = duration; return c
    }

    func project(follow: Bool = true, tachieDuration: Double = 5, voices: [(Double, Double)] = [(0, 5)]) -> Project {
        var p = Project(); p.width = 100; p.height = 100
        var t = clip("t1", .tachie, start: 0, duration: tachieDuration); t.tachieId = "ta"
        if follow { t.followsProjectEnd = true }
        var tt = Track(name: "立ち絵"); tt.clips = [t]
        var vt = Track(name: "声"); vt.clips = voices.enumerated().map { clip("v\($0.offset)", .voice, start: $0.element.0, duration: $0.element.1) }
        p.tracks = [tt, vt]
        p.tachies = [Tachie(name: "a")]; p.tachies[0].id = "ta"
        return p
    }

    func dur(_ p: Project, _ id: String = "t1") -> Double { p.allClips.first { $0.id == id }!.duration }

    func testFieldIsWrittenOnlyWhenSetAndRoundTripsAndKeepsUnreadableValue() throws {
        var c = clip("c", .tachie, start: 0, duration: 2)
        let enc = JSONEncoder(); enc.outputFormatting = .sortedKeys
        XCTAssertFalse(String(decoding: try enc.encode(c), as: UTF8.self).contains("followsProjectEnd"))
        c.followsProjectEnd = true
        let data = try enc.encode(c)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"followsProjectEnd\":true"))
        let back = try JSONDecoder().decode(Clip.self, from: data)
        XCTAssertEqual(back.followsProjectEnd, true)
        XCTAssertEqual(try enc.encode(back), data)
        let odd = try JSONDecoder().decode(Clip.self, from: Data(#"{"id":"c","type":"tachie","start":0,"duration":1,"followsProjectEnd":"yes"}"#.utf8))
        XCTAssertNil(odd.followsProjectEnd)
        XCTAssertTrue(String(decoding: try enc.encode(odd), as: UTF8.self).contains("\"followsProjectEnd\":\"yes\""))
        // false は既定と同じ(書かない・保たない)
        let f = try JSONDecoder().decode(Clip.self, from: Data(#"{"id":"c","type":"tachie","start":0,"duration":1,"followsProjectEnd":false}"#.utf8))
        XCTAssertNil(f.followsProjectEnd)
        XCTAssertEqual(try enc.encode(try JSONDecoder().decode(Clip.self, from: try enc.encode(f))), try enc.encode(f))
    }

    func testNoFlaggedClipsMeansSameValueAndNothingChanges() {
        let p = project(follow: false)
        XCTAssertEqual(TachieEditing.syncProjectEnd(p), p)
    }

    func testExtendsToLaterVoicesAndShrinksWhenTheyGo() {
        var p = project(tachieDuration: 5, voices: [(0, 5)])
        XCTAssertEqual(TachieEditing.syncProjectEnd(p), p, "もう合っている")
        p.tracks[1].clips.append(clip("v9", .voice, start: 6, duration: 4))   // 後から足した声(終わり 10 秒)
        let q = TachieEditing.syncProjectEnd(p)
        XCTAssertEqual(dur(q), 10, accuracy: 1e-9)
        XCTAssertEqual(TachieEditing.syncProjectEnd(q), q, "何度かけても同じ")
        var r = q; r.tracks[1].clips.removeAll { $0.id == "v9" }
        XCTAssertEqual(dur(TachieEditing.syncProjectEnd(r)), 5, accuracy: 1e-9, "声が無くなったら縮む")
        XCTAssertEqual(q.endTime, 10, accuracy: 1e-9)
    }

    func testStopsAtNextClipInSameLayerAndKeepsLengthWhenNoTarget() {
        var p = project(voices: [(0, 10)])
        var next = clip("n", .tachie, start: 7, duration: 1); next.tachieId = "ta"
        p.tracks[0].clips.append(next)
        let q = TachieEditing.syncProjectEnd(p)
        XCTAssertEqual(dur(q), 7, accuracy: 1e-9, "同じレイヤーの次のクリップの頭まで")
        // 終わりがクリップの頭より前なら、触らない(長さ 0 にしない)
        let e = project(tachieDuration: 3, voices: [])
        var f = e; f.tracks[0].clips[0].start = 4
        XCTAssertEqual(dur(TachieEditing.syncProjectEnd(f)), 3)
    }

    func testManualGeometryChangeStopsFollowing() {
        let before = project(tachieDuration: 5, voices: [(0, 5)])
        var trimmed = before; trimmed.tracks[0].clips[0].duration = 2     // 右端を手で縮めた
        let after = TachieEditing.syncProjectEnd(trimmed, old: before)
        XCTAssertEqual(dur(after), 2)
        XCTAssertNil(after.allClips.first { $0.id == "t1" }!.followsProjectEnd, "手で変えたら印を外す")
        // 別のクリップだけが変わった編集では、合わせ続ける
        var other = before; other.tracks[1].clips.append(clip("v9", .voice, start: 6, duration: 4))
        XCTAssertEqual(dur(TachieEditing.syncProjectEnd(other, old: before)), 10, accuracy: 1e-9)
        // 印を付けただけの編集(長さは同じ)は、その場で合わせる
        let plain = project(follow: false, tachieDuration: 2, voices: [(0, 8)])
        var on = plain; on.tracks[0].clips[0].followsProjectEnd = true
        XCTAssertEqual(dur(TachieEditing.syncProjectEnd(on, old: plain)), 8, accuracy: 1e-9)
        XCTAssertEqual(on.allClips.first { $0.id == "t1" }!.followsProjectEnd, true)
    }

    func testFlaggedClipsDoNotCountAsTheProjectEndThemselves() {
        // 印のあるクリップ同士で終わりを押し合わない(2 つとも、印の無いクリップの終わりに揃う)
        var p = project(voices: [(0, 6)])
        var b = clip("t2", .tachie, start: 1, duration: 20); b.tachieId = "ta"; b.followsProjectEnd = true
        var t2 = Track(name: "b"); t2.clips = [b]; p.tracks.append(t2)
        let q = TachieEditing.syncProjectEnd(p)
        XCTAssertEqual(dur(q, "t1"), 6, accuracy: 1e-9)
        XCTAssertEqual(dur(q, "t2"), 5, accuracy: 1e-9, "6 秒まで(頭 1 秒から 5 秒間)")
    }

    func testMigratedClipsFollowTheProjectEnd() throws {
        var p = Project(); p.width = 100; p.height = 100
        var ch = Character(); ch.id = "c1"; ch.name = "れいむ"; ch.imgClosed = "/a.png"
        p.characters = [ch]
        var tr = Track(name: "声"); tr.clips = [clip("v0", .voice, start: 0, duration: 4)]; p.tracks = [tr]
        let m = TachieMigration.migrated(p)
        let tc = try XCTUnwrap(m.allClips.first { $0.type == .tachie })
        XCTAssertEqual(tc.followsProjectEnd, true)
        XCTAssertEqual(tc.duration, 4, accuracy: 1e-9)
        // 後から足した声(8 秒まで)に、合わせ直しで届く
        var later = m; later.tracks[0].clips.append(clip("v1", .voice, start: 5, duration: 3))
        XCTAssertEqual(TachieEditing.syncProjectEnd(later).allClips.first { $0.type == .tachie }!.duration, 8, accuracy: 1e-9)
        // 2 回移行しても変わらない
        XCTAssertEqual(TachieMigration.migrated(m), m)
    }

    func testMakeClipOnlyMarksWhenAsked() throws {
        var p = Project(); p.tachies = [Tachie(name: "a")]
        let id = p.tachies[0].id
        XCTAssertNil(try XCTUnwrap(TachieEditing.makeClip(p, tachieId: id, start: 1, duration: 2)).followsProjectEnd)
        XCTAssertEqual(try XCTUnwrap(TachieEditing.makeClip(p, tachieId: id, start: 1, duration: 2, followsProjectEnd: true)).followsProjectEnd, true)
    }
}

import XCTest
@testable import MovieCutCore

/// 複数素材から範囲を指定してサブクリップを一括作成(候補 38)。
final class SubclipBatchTests: XCTestCase {
    private let pool = ["/m/intro.mov", "/m/interview-01.mov", "/m/interview-02.mov", "/m/bgm.wav", "/m/photo.png", "/m/ある日.mp4"]

    func testParseTime() {
        XCTAssertEqual(SubclipBatch.parseTime("90"), 90)
        XCTAssertEqual(SubclipBatch.parseTime("1:30"), 90)
        XCTAssertEqual(SubclipBatch.parseTime("1:02:03"), 3723)
        XCTAssertEqual(SubclipBatch.parseTime("0:05.5"), 5.5)
        XCTAssertEqual(SubclipBatch.parseTime(" 12.25 "), 12.25)
        for bad in ["", "abc", "1:2:3:4", "1.5:30", "-3", "1::2", "1..2", ":30", "99999999"] {
            XCTAssertNil(SubclipBatch.parseTime(bad), bad)
        }
    }

    func testResolveOrder() {
        func found(_ s: String) -> String? { if case .found(let p) = SubclipBatch.resolve(s, pool: pool) { return p }; return nil }
        XCTAssertEqual(found("/m/intro.mov"), "/m/intro.mov")
        XCTAssertEqual(found("INTRO.mov"), "/m/intro.mov", "ファイル名(大文字小文字無視)")
        XCTAssertEqual(found("intro"), "/m/intro.mov", "拡張子なし")
        XCTAssertEqual(found("bgm"), "/m/bgm.wav")
        XCTAssertEqual(found("ある日"), "/m/ある日.mp4")
        XCTAssertEqual(found("01"), "/m/interview-01.mov", "名前の一部(一意)")
        if case .failed(let m) = SubclipBatch.resolve("interview", pool: pool) { XCTAssertTrue(m.contains("複数")) } else { XCTFail() }
        if case .failed(let m) = SubclipBatch.resolve("zzz", pool: pool) { XCTAssertTrue(m.contains("見つかりません")) } else { XCTFail() }
        XCTAssertEqual(found("intro.mov"), "/m/intro.mov")
        if case .found(let p) = SubclipBatch.resolve("/x/outside.mov", pool: pool, fileExists: { _ in true }) { XCTAssertEqual(p, "/x/outside.mov") } else { XCTFail("プール外の絶対パス") }
        if case .failed = SubclipBatch.resolve("/x/outside.mov", pool: pool, fileExists: { _ in false }) {} else { XCTFail() }
    }

    func testParseMultipleLinesRangesAndContinuation() {
        let text = """
        # 注釈
        intro.mov 0:05-0:12, 0:30〜0:41.5
          1:00 - 1:10
        bgm 5-9

        interview-02.mov 0:01→0:03
        """
        let r = SubclipBatch.parse(text, pool: pool)
        XCTAssertTrue(r.errors.isEmpty, "\(r.errors)")
        XCTAssertEqual(r.specs, [
            .init(src: "/m/intro.mov", inTime: 5, outTime: 12),
            .init(src: "/m/intro.mov", inTime: 30, outTime: 41.5),
            .init(src: "/m/intro.mov", inTime: 60, outTime: 70),
            .init(src: "/m/bgm.wav", inTime: 5, outTime: 9),
            .init(src: "/m/interview-02.mov", inTime: 1, outTime: 3)])
    }

    func testParseErrorsAreReportedPerLineAndOthersStillWork() {
        let text = """
        intro.mov 0:05-0:12
        nothing here
        zzz.mov 1-2
        photo.png 1-2
        interview 1-2
        intro.mov 9-3
        0:01-0:02
        """
        let r = SubclipBatch.parse(text, pool: pool)
        XCTAssertEqual(r.specs, [.init(src: "/m/intro.mov", inTime: 5, outTime: 12), .init(src: "/m/intro.mov", inTime: 1, outTime: 2)],
                       "正しい行だけ残る。範囲が不正でも素材は決まるので、最後の範囲だけの行は intro の続き")
        XCTAssertEqual(r.errors.map(\.line), [2, 3, 4, 5, 6])
        XCTAssertTrue(r.errors[2].message.contains("動画・音声ではありません"))
        XCTAssertTrue(r.errors[3].message.contains("複数"))
        XCTAssertTrue(r.errors[4].message.contains("後ではありません"))
        // 素材が決まっていない行
        let r2 = SubclipBatch.parse("0:01-0:02\nzzz 1-2\n3-4", pool: pool)
        XCTAssertEqual(r2.errors.map(\.message), ["素材が決まっていません", "素材「zzz」が見つかりません", "素材が決まっていません"])
    }

    func testBuildPlacesBackToBackWithOffsets() throws {
        let specs: [SubclipBatch.Spec] = [.init(src: "/m/intro.mov", inTime: 5, outTime: 12), .init(src: "/m/bgm.wav", inTime: 0, outTime: 3)]
        let b = SubclipBatch.build(specs, durations: ["/m/intro.mov": 60, "/m/bgm.wav": 30], start: 10)
        XCTAssertEqual(b.clips.map(\.start), [10, 17])
        XCTAssertEqual(b.clips.map(\.duration), [7, 3])
        XCTAssertEqual(b.clips.map(\.offset), [5, 0])
        XCTAssertEqual(b.clips.map(\.type), [.video, .audio])
        XCTAssertEqual(b.clips.map(\.srcDuration), [60, 30])
        XCTAssertEqual(Set(b.clips.map(\.id)).count, 2)
        XCTAssertTrue(b.errors.isEmpty)
    }

    func testBuildClampsToSourceLengthAndSkipsBeyond() {
        let specs: [SubclipBatch.Spec] = [.init(src: "/m/intro.mov", inTime: 8, outTime: 20), .init(src: "/m/intro.mov", inTime: 12, outTime: 15),
                                          .init(src: "/m/bgm.wav", inTime: 1, outTime: 2)]
        let b = SubclipBatch.build(specs, durations: ["/m/intro.mov": 10], start: 0)
        XCTAssertEqual(b.clips.map(\.duration), [2, 1], "終わりを超える分は詰める。長さが測れない素材はそのまま")
        XCTAssertEqual(b.clips.map(\.start), [0, 2], "作れなかった範囲は詰めて並べる")
        XCTAssertEqual(b.errors.count, 1)
    }

    func testPlaceUsesFreeLayerAndRegistersPool() throws {
        let clips = SubclipBatch.build([.init(src: "/m/intro.mov", inTime: 0, outTime: 4)], durations: [:], start: 2).clips
        var p = Project()
        var busy = Clip(); busy.id = "busy"; busy.type = .image; busy.start = 0; busy.duration = 10
        p.tracks[0].clips = [busy]
        let r = try XCTUnwrap(SubclipBatch.place(clips, in: p))
        XCTAssertEqual(r.trackIndex, 1)
        XCTAssertEqual(r.project.tracks[1].clips.map(\.id), clips.map(\.id))
        XCTAssertEqual(r.project.mediaPool, ["/m/intro.mov"])
        // 全部ふさがっていたらレイヤーを足す
        var full = Project()
        for i in full.tracks.indices { full.tracks[i].clips = [busy] }
        let r2 = try XCTUnwrap(SubclipBatch.place(clips, in: full))
        XCTAssertEqual(r2.project.tracks.count, full.tracks.count + 1)
        XCTAssertEqual(r2.trackIndex, full.tracks.count)
        XCTAssertNil(SubclipBatch.place([], in: p))
    }
}

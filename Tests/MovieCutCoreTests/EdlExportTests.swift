import XCTest
@testable import MovieCutCore

/// EDL(CMX 3600)書き出しの検証。形式の根拠は CMX 3600 の公開仕様
/// (TITLE / FCM ヘッダ、イベント行 = 番号・リール名 8 文字・トラック・C・
/// 素材イン/アウト・記録イン/アウト、タイムコード HH:MM:SS:FF)。
final class EdlExportTests: XCTestCase {

    private func clip(_ type: ClipType, src: String?, start: Double, duration: Double, offset: Double = 0) -> Clip {
        var c = Clip()
        c.type = type
        c.src = src
        c.start = start
        c.duration = duration
        c.offset = offset
        return c
    }

    private func project(fps: Double = 30, tracks: [Track]) -> Project {
        var p = Project()
        p.width = 1920
        p.height = 1080
        p.fps = fps
        p.tracks = tracks
        return p
    }

    private func track(_ name: String, _ clips: [Clip]) -> Track {
        var t = Track(name: name)
        t.clips = clips
        return t
    }

    private func eventLines(_ text: String) -> [String] {
        text.split(separator: "\n").map(String.init).filter { !$0.hasPrefix("TITLE:") && !$0.hasPrefix("FCM:") && !$0.hasPrefix("*") }
    }

    // MARK: 代表ケース

    func testBasicVideoEvents() {
        let p = project(tracks: [
            track("レイヤー1", [
                clip(.video, src: "/media/interview01.mp4", start: 0, duration: 2, offset: 1),
                clip(.video, src: "/media/broll.mp4", start: 2, duration: 3),
            ]),
        ])
        let out = EdlExporter.export(project: p, title: "テスト編集")
        let lines = out.text.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines[0], "TITLE: テスト編集")
        XCTAssertEqual(lines[1], "FCM: NON-DROP FRAME")
        let events = eventLines(out.text)
        XCTAssertEqual(events.count, 2)
        // リール名は 8 文字まで(interview01 → INTERVIE)、素材 1〜3 秒、記録 0〜2 秒(30fps)
        XCTAssertEqual(events[0], "001  INTERVIE V     C        00:00:01:00 00:00:03:00 00:00:00:00 00:00:02:00")
        XCTAssertEqual(events[1], "002  BROLL    V     C        00:00:00:00 00:00:03:00 00:00:02:00 00:00:05:00")
        // 再リンク用のコメント行
        XCTAssertTrue(out.text.contains("* FROM CLIP NAME: interview01.mp4"))
        XCTAssertTrue(out.text.contains("* SOURCE FILE: /media/interview01.mp4"))
        XCTAssertEqual(out.report.eventCount, 2)
        XCTAssertFalse(out.report.hasLoss)
    }

    func testAudioEventsAndOrdering() {
        // 音声イベントは記録イン順に映像と混ざって番号が振られる。
        let p = project(tracks: [
            track("レイヤー1", [clip(.video, src: "/media/v.mp4", start: 0, duration: 4)]),
            track("レイヤー2", [clip(.audio, src: "/media/bgm.wav", start: 0, duration: 4)]),
            track("レイヤー3", [clip(.audio, src: "/media/se.wav", start: 2, duration: 1)]),
        ])
        let out = EdlExporter.export(project: p)
        let events = eventLines(out.text)
        XCTAssertEqual(events.count, 3)
        XCTAssertTrue(events[0].contains(" V     "), events[0])
        XCTAssertTrue(events[1].contains(" A     "), events[1])
        XCTAssertTrue(events[2].contains(" A2    "), events[2])
        XCTAssertTrue(events[2].hasPrefix("003"))
        XCTAssertTrue(events[2].contains("00:00:02:00 00:00:03:00"), events[2]) // 記録イン/アウト
    }

    func testSecondVideoTrackIsSkippedWithReport() {
        var text = clip(.text, src: nil, start: 0, duration: 1)
        text.text = "テロップ"
        let p = project(tracks: [
            track("レイヤー1", [clip(.video, src: "/media/base.mp4", start: 0, duration: 4), text]),
            track("レイヤー2", [clip(.video, src: "/media/overlay.mp4", start: 1, duration: 2)]),
        ])
        let out = EdlExporter.export(project: p)
        XCTAssertEqual(out.report.eventCount, 1)
        XCTAssertTrue(out.report.skipped.contains { $0.label == "overlay.mp4" })
        XCTAssertTrue(out.report.skipped.contains { $0.reason.contains("EDL で表せる") })
        XCTAssertTrue(out.report.hasLoss)
    }

    // MARK: リール名

    func testReelNames() {
        var used: [String: String] = [:]
        XCTAssertEqual(EdlExporter.reelName(for: "/m/interview01.mp4", used: &used), "INTERVIE")
        XCTAssertEqual(EdlExporter.reelName(for: "/m/interview02.mp4", used: &used), "INTERVI2")
        XCTAssertEqual(EdlExporter.reelName(for: "/m/interview01.mp4", used: &used), "INTERVIE", "同じ素材は同じリール名")
        XCTAssertEqual(EdlExporter.reelName(for: nil, used: &used), "AX")
        XCTAssertEqual(EdlExporter.reelName(for: "/m/テスト.mp4", used: &used), "AX2", "AX が使われていれば連番で一意にする")
        var fresh: [String: String] = [:]
        XCTAssertEqual(EdlExporter.reelName(for: "/m/テスト.mp4", used: &fresh), "AX", "英数字にできない名前は AX")
        for (_, reel) in used { XCTAssertLessThanOrEqual(reel.count, 8) }
    }

    // MARK: タイムコード

    func testTimecodeNonDrop() {
        XCTAssertEqual(EdlExporter.timecode(frame: 0, nominal: 30, drop: false), "00:00:00:00")
        XCTAssertEqual(EdlExporter.timecode(frame: 30, nominal: 30, drop: false), "00:00:01:00")
        XCTAssertEqual(EdlExporter.timecode(frame: 30 * 60 + 15, nominal: 30, drop: false), "00:01:00:15")
        XCTAssertEqual(EdlExporter.timecode(frame: 25 * 3661 + 24, nominal: 25, drop: false), "01:01:01:24")
    }

    func testTimecodeDropFrame() {
        // 29.97(公称 30・ドロップ 2): 実時間 1 分 = 1800 フレーム弱 → 00:01:00:02 から始まる。
        XCTAssertEqual(EdlExporter.timecode(frame: 0, nominal: 30, drop: true), "00:00:00:00")
        XCTAssertEqual(EdlExporter.timecode(frame: 1799, nominal: 30, drop: true), "00:00:59:29")
        XCTAssertEqual(EdlExporter.timecode(frame: 1800, nominal: 30, drop: true), "00:01:00:02")
        // 10 分ちょうど(実フレーム 17982)は読み飛ばしのない分なので 00:10:00:00。
        XCTAssertEqual(EdlExporter.timecode(frame: 17982, nominal: 30, drop: true), "00:10:00:00")
        XCTAssertEqual(EdlExporter.timecode(frame: 17983, nominal: 30, drop: true), "00:10:00:01")
        // 1 時間(実フレーム 107892)は 01:00:00:00。
        XCTAssertEqual(EdlExporter.timecode(frame: 107892, nominal: 30, drop: true), "01:00:00:00")
        // 59.94(公称 60・ドロップ 4): 実時間 1 分 = 3600 フレーム弱 → 00:01:00:04。
        XCTAssertEqual(EdlExporter.timecode(frame: 3599, nominal: 60, drop: true), "00:00:59:59")
        XCTAssertEqual(EdlExporter.timecode(frame: 3600, nominal: 60, drop: true), "00:01:00:04")
    }

    func testDropFrameProjectHeader() {
        let p = project(fps: 29.97, tracks: [
            track("レイヤー1", [clip(.video, src: "/media/a.mp4", start: 60.06, duration: 1)]),
        ])
        let out = EdlExporter.export(project: p)
        XCTAssertTrue(out.text.contains("FCM: DROP FRAME"))
        // 60.06 秒 = 1800 フレーム → 記録インは 00:01:00:02
        XCTAssertTrue(out.text.contains("00:01:00:02"), out.text)
    }

    func testSpeedAffectsSourceRange() {
        var c = clip(.video, src: "/media/a.mp4", start: 0, duration: 2)
        c.speed = 2
        let p = project(tracks: [track("レイヤー1", [c])])
        let out = EdlExporter.export(project: p)
        let events = eventLines(out.text)
        XCTAssertEqual(events.count, 1)
        // 記録は 2 秒(60 フレーム)、素材は 2 倍速なので 4 秒(120 フレーム)分を使う
        XCTAssertTrue(events[0].contains("00:00:00:00 00:00:04:00 00:00:00:00 00:00:02:00"), events[0])
        XCTAssertTrue(out.report.notes.contains { $0.contains("速度") })
    }

    /// 非表示の映像トラックは代表(V)にならず、見えているトラックが書かれること。
    func testHiddenVideoTrackIsNotUsedAsRepresentative() {
        var hidden = track("隠し", [clip(.video, src: "/media/hidden.mp4", start: 0, duration: 2)])
        hidden.hidden = true
        let visible = track("見える", [clip(.video, src: "/media/visible.mp4", start: 0, duration: 2)])
        let out = EdlExporter.export(project: project(tracks: [hidden, visible]))
        let events = eventLines(out.text)
        XCTAssertEqual(events.count, 1)
        XCTAssertTrue(events[0].contains("VISIBLE"), events[0])
        XCTAssertTrue(out.report.skipped.contains { $0.label.contains("hidden") })
    }

    /// ミュートされている音声トラックは書かれず、報告に残ること。
    func testMutedAudioTrackIsSkipped() {
        var muted = track("消音", [clip(.audio, src: "/media/bgm.wav", start: 0, duration: 2)])
        muted.muted = true
        let live = track("音声", [clip(.audio, src: "/media/voice.wav", start: 0, duration: 2)])
        let out = EdlExporter.export(project: project(tracks: [muted, live]))
        let events = eventLines(out.text)
        XCTAssertEqual(events.count, 1)
        XCTAssertTrue(out.report.skipped.contains { $0.label.contains("bgm") })
    }

    /// 連続するクリップは記録側で重なり・隙間なく並ぶこと(記録アウトは開始+長さから数える)。
    func testContiguousClipsTileWithoutOverlap() {
        let p = project(tracks: [track("レイヤー1", [
            clip(.video, src: "/media/a.mp4", start: 0.05, duration: 0.05),
            clip(.video, src: "/media/b.mp4", start: 0.10, duration: 0.05),
        ])])
        let out = EdlExporter.export(project: p)
        let events = eventLines(out.text)
        XCTAssertEqual(events.count, 2)
        let f0 = events[0].split(separator: " ").map(String.init)
        let f1 = events[1].split(separator: " ").map(String.init)
        XCTAssertEqual(f0[7], f1[6], "前の記録アウトと次の記録インが一致する")
    }

    func testEmptyProject() {
        let p = project(tracks: [track("レイヤー1", [])])
        let out = EdlExporter.export(project: p)
        XCTAssertEqual(out.report.eventCount, 0)
        XCTAssertTrue(out.text.hasPrefix("TITLE: MovieCut\nFCM: NON-DROP FRAME\n"))
    }
}

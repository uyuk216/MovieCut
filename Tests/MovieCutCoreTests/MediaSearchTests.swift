import XCTest
@testable import MovieCutCore

/// メディアインテリジェンス検索 第 1 段: 文字起こしのキャッシュ、索引の構築、検索(部分一致・表記ゆれ・時刻の対応)。
final class MediaSearchTests: XCTestCase {

    // MARK: - テスト用の土台

    /// 目印(サイズ・更新日時)を差し替えられる保存庫。実ファイルは一時フォルダの JSON だけ使う。
    private func makeStore(stamps: [String: MediaFingerprintCache.FileStamp]) -> (store: MediaTranscriptStore, file: URL) {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("media-transcripts-\(UUID().uuidString).json")
        let store = MediaTranscriptStore(fileURL: file, stamp: { stamps[$0] })
        return (store, file)
    }

    private func stamp(_ size: Int64, _ modified: TimeInterval = 1_700_000_000) -> MediaFingerprintCache.FileStamp {
        MediaFingerprintCache.FileStamp(size: size, modified: Date(timeIntervalSince1970: modified))
    }

    private func seg(_ text: String, _ start: Double, _ end: Double) -> TranscriptSegment {
        TranscriptSegment(text: text, start: start, end: end)
    }

    private func project(mediaPool: [String], clips: [Clip]) -> Project {
        var p = Project.new()
        p.mediaPool = mediaPool
        var t = Track(name: "素材")
        t.clips = clips
        p.tracks = [t]
        return p
    }

    private func clip(src: String, type: ClipType = .video, start: Double = 0, duration: Double = 10, offset: Double = 0) -> Clip {
        var c = Clip()
        c.type = type
        c.src = src
        c.start = start
        c.duration = duration
        c.offset = offset
        return c
    }

    // MARK: - キャッシュ(登録・読み戻し・目印)

    func testStoreRoundTripAndPersistence() {
        let path = "/media/interview.mp4"
        let (store, file) = makeStore(stamps: [path: stamp(100)])
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertNil(store.segments(forPath: path), "未登録は nil")
        store.register(path: path, segments: [seg("今日は晴れです", 1, 3), seg("明日は雨でしょう", 4, 6)])
        let got = store.segments(forPath: path)
        XCTAssertEqual(got?.map(\.text), ["今日は晴れです", "明日は雨でしょう"])
        XCTAssertEqual(got?.map(\.start), [1, 4])
        XCTAssertEqual(store.count, 1)
        // 別のインスタンスでも、ディスクから読み戻せる
        let fixed = stamp(100)
        let again = MediaTranscriptStore(fileURL: file, stamp: { _ in fixed })
        XCTAssertEqual(again.segments(forPath: path)?.count, 2)
    }

    func testStoreDropsStaleEntryWhenFileChanged() {
        let path = "/media/a.wav"
        var current = stamp(100)
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("media-transcripts-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = MediaTranscriptStore(fileURL: file, stamp: { _ in current })
        store.register(path: path, segments: [seg("あ", 0, 1)])
        XCTAssertNotNil(store.segments(forPath: path))
        current = stamp(200) // サイズが変わった = 素材が差し替わった
        XCTAssertNil(store.segments(forPath: path), "目印が合わない記録は使わない")
        XCTAssertEqual(store.count, 0, "古い記録は捨てる")
    }

    func testStoreMergesPartialRegistrationsWithoutDuplicates() {
        let path = "/media/long.mp4"
        let (store, file) = makeStore(stamps: [path: stamp(100)])
        defer { try? FileManager.default.removeItem(at: file) }
        store.register(path: path, segments: [seg("前半の文", 0, 5)])
        store.register(path: path, segments: [seg("後半の文", 100, 105), seg("前半の文", 0, 5)])
        let got = store.segments(forPath: path)
        XCTAssertEqual(got?.map(\.text), ["前半の文", "後半の文"], "重ねて持ち、重複は除き、開始順")
    }

    func testStoreIgnoresEmptyAndBrokenSegments() {
        let path = "/media/b.mp4"
        let (store, file) = makeStore(stamps: [path: stamp(100)])
        defer { try? FileManager.default.removeItem(at: file) }
        store.register(path: path, segments: [seg("  ", 0, 1), seg("壊れた", .nan, 1)])
        XCTAssertNil(store.segments(forPath: path))
        XCTAssertEqual(store.count, 0)
        store.register(path: path, segments: [seg(" 前後の空白は取る ", 2, 3)])
        XCTAssertEqual(store.segments(forPath: path)?.first?.text, "前後の空白は取る")
    }

    func testStoreRemove() {
        let path = "/media/c.mp4"
        let (store, file) = makeStore(stamps: [path: stamp(100)])
        defer { try? FileManager.default.removeItem(at: file) }
        store.register(path: path, segments: [seg("消す", 0, 1)])
        store.remove(path: path)
        XCTAssertNil(store.segments(forPath: path))
        XCTAssertEqual(store.count, 0)
    }

    // MARK: - 索引の構築

    func testBuildIndexMediaAndUntranscribed() {
        let video = "/media/interview.mp4"
        let audio = "/media/voice.wav"
        let image = "/media/photo.png"
        let p = project(mediaPool: [video, audio, image],
                        clips: [clip(src: video), clip(src: "/media/broll.mp4")])
        let index = MediaSearch.buildIndex(project: p, transcripts: [
            video: [seg("今日は晴れです", 1, 3), seg("明日は雨でしょう", 4, 6)],
        ])
        // 動画・音声だけが対象。画像は索引にも対象外一覧にも入らない
        XCTAssertEqual(Set(index.media.map(\.src)), [video, audio, "/media/broll.mp4"])
        let v = index.media.first { $0.src == video }
        XCTAssertEqual(v?.hasTranscript, true)
        XCTAssertEqual(v?.segmentCount, 2)
        XCTAssertEqual(v?.name, "interview.mp4")
        // 文字起こしの無い素材は「対象外」として分かる
        XCTAssertEqual(Set(index.untranscribed.map(\.src)), [audio, "/media/broll.mp4"])
        XCTAssertTrue(index.hasSearchableMedia)
        XCTAssertEqual(index.entries.count, 2)
        XCTAssertEqual(index.entries.first?.kind, .transcript)
    }

    func testBuildIndexWithoutAnyTranscripts() {
        let p = project(mediaPool: ["/media/a.mp4"], clips: [])
        let index = MediaSearch.buildIndex(project: p, transcripts: [:])
        XCTAssertFalse(index.hasSearchableMedia)
        XCTAssertEqual(index.untranscribed.count, 1)
        XCTAssertTrue(MediaSearch.search("何か", in: index).isEmpty)
    }

    // MARK: - 検索(部分一致・表記ゆれ)

    private func searchIndex() -> MediaSearch.Index {
        let p = project(mediaPool: ["/media/interview.mp4", "/media/meeting.wav"], clips: [])
        return MediaSearch.buildIndex(project: p, transcripts: [
            "/media/interview.mp4": [
                seg("今日はキーボードを打つ手の話をします", 12.5, 16),
                seg("MovieCut の使い方を説明します。", 30, 34),
            ],
            "/media/meeting.wav": [
                seg("明日の会議は１０時からです", 3, 6),
            ],
        ])
    }

    func testSearchPartialMatchReturnsMediaAndStartTime() {
        let hits = MediaSearch.search("キーボード", in: searchIndex())
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.mediaName, "interview.mp4")
        XCTAssertEqual(hits.first?.start, 12.5)
        XCTAssertEqual(hits.first?.end, 16)
        XCTAssertEqual(hits.first?.text, "今日はキーボードを打つ手の話をします")
    }

    func testSearchKanaVariation() {
        // カタカナの文を、ひらがなで検索できる(逆も同じ正規化を通る)
        XCTAssertEqual(MediaSearch.search("きーぼーど", in: searchIndex()).count, 1)
        XCTAssertEqual(MediaSearch.search("キーボード", in: searchIndex()).count, 1)
    }

    func testSearchWidthAndCaseAndPunctuationVariation() {
        // 全角数字の文を半角で、英字の大文字小文字と文末の句読点を気にせず検索できる
        XCTAssertEqual(MediaSearch.search("10時", in: searchIndex()).count, 1)
        XCTAssertEqual(MediaSearch.search("moviecut", in: searchIndex()).count, 1)
        XCTAssertEqual(MediaSearch.search("使い方を説明します", in: searchIndex()).count, 1)
    }

    func testSearchMultipleTermsAreAND() {
        XCTAssertEqual(MediaSearch.search("キーボード 手", in: searchIndex()).count, 1)
        XCTAssertEqual(MediaSearch.search("キーボード 会議", in: searchIndex()).count, 0, "別の文・別の素材に分かれた語は一致しない")
    }

    func testSearchEmptyAndNoMatch() {
        let index = searchIndex()
        XCTAssertTrue(MediaSearch.search("", in: index).isEmpty)
        XCTAssertTrue(MediaSearch.search("   ", in: index).isEmpty)
        XCTAssertTrue(MediaSearch.search("存在しない言葉", in: index).isEmpty)
    }

    func testSearchSortsByMediaNameThenStart() {
        let hits = MediaSearch.search("は", in: searchIndex())
        XCTAssertEqual(hits.map(\.mediaName), ["interview.mp4", "meeting.wav"])
        XCTAssertEqual(hits.map(\.start), [12.5, 3])
    }

    func testNormalize() {
        XCTAssertEqual(MediaSearch.normalize("キーボード"), "きーぼーど")
        XCTAssertEqual(MediaSearch.normalize("ＡＢＣ１２３"), "abc123")
        XCTAssertEqual(MediaSearch.normalize("行きます。"), "行きます")
        XCTAssertEqual(MediaSearch.normalize("ｱｲｳ"), "あいう")
        XCTAssertEqual(MediaSearch.normalize(" 空 白 "), "空白")
    }

    // MARK: - 時刻の対応(素材内時刻 → タイムライン)

    func testTimelineLocationMapsThroughClipOffset() {
        // 素材の 40 秒から使うクリップが、タイムラインの 100 秒に置かれている
        let c = clip(src: "/media/interview.mp4", start: 100, duration: 20, offset: 40)
        let p = project(mediaPool: [], clips: [c])
        let hit = MediaSearch.Hit(src: "/media/interview.mp4", path: "/media/interview.mp4",
                                  mediaName: "interview.mp4", start: 45, end: 48, text: "文", kind: .transcript)
        let loc = MediaSearch.timelineLocation(for: hit, in: p)
        XCTAssertEqual(loc?.clipId, c.id)
        XCTAssertEqual(loc?.time, 105, "100 + (45 - 40)")
    }

    func testTimelineLocationNilWhenNotCoveredOrNotPlaced() {
        let c = clip(src: "/media/interview.mp4", start: 100, duration: 20, offset: 40)
        let p = project(mediaPool: ["/media/other.wav"], clips: [c])
        let outside = MediaSearch.Hit(src: "/media/interview.mp4", path: "/media/interview.mp4",
                                      mediaName: "interview.mp4", start: 90, end: 92, text: "文", kind: .transcript)
        XCTAssertNil(MediaSearch.timelineLocation(for: outside, in: p), "使う範囲の外は対応づけない")
        let notPlaced = MediaSearch.Hit(src: "/media/other.wav", path: "/media/other.wav",
                                        mediaName: "other.wav", start: 1, end: 2, text: "文", kind: .transcript)
        XCTAssertNil(MediaSearch.timelineLocation(for: notPlaced, in: p), "タイムラインに無い素材は nil")
    }
}

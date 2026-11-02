import XCTest
@testable import MovieCutCore

/// 素材ブラウザの一覧(種類・検索・並べ替え・走査)の純粋ロジック。
final class MediaBrowserTests: XCTestCase {
    private func item(_ name: String) -> MediaBrowser.Item {
        MediaBrowser.Item(url: URL(fileURLWithPath: "/x/\(name)"), name: name, kind: MediaBrowser.kind(forName: name) ?? .video)
    }

    func testKindFromExtensionIgnoresCaseAndHidden() {
        XCTAssertEqual(MediaBrowser.kind(forName: "clip.MP4"), .video)
        XCTAssertEqual(MediaBrowser.kind(forName: "bgm.m4a"), .audio)
        XCTAssertEqual(MediaBrowser.kind(forName: "pic.PNG"), .image)
        XCTAssertNil(MediaBrowser.kind(forName: "notes.txt"))
        XCTAssertNil(MediaBrowser.kind(forName: ".hidden.mp4"))
        XCTAssertNil(MediaBrowser.kind(forName: "noext"))
    }

    func testFilterByKind() {
        let items = ["a.mp4", "b.wav", "c.jpg", "d.mov"].map(item)
        XCTAssertEqual(MediaBrowser.filter(items, kind: .all, query: "").count, 4)
        XCTAssertEqual(MediaBrowser.filter(items, kind: .video, query: "").map(\.name), ["a.mp4", "d.mov"])
        XCTAssertEqual(MediaBrowser.filter(items, kind: .audio, query: "").map(\.name), ["b.wav"])
        XCTAssertEqual(MediaBrowser.filter(items, kind: .image, query: "").map(\.name), ["c.jpg"])
    }

    func testSearchByNameIsCaseAndWidthInsensitive() {
        let items = ["Intro_BGM.wav", "ｂｇｍ２.wav", "effect.wav", "bgm-end.wav"].map(item)
        XCTAssertEqual(Set(MediaBrowser.filter(items, kind: .all, query: "bgm").map(\.name)), ["Intro_BGM.wav", "ｂｇｍ２.wav", "bgm-end.wav"], "大文字小文字と全角を無視")
        XCTAssertEqual(MediaBrowser.filter(items, kind: .all, query: "ＢＧＭ").count, 3, "全角の検索語も半角の名前に当たる")
        XCTAssertEqual(MediaBrowser.filter(items, kind: .all, query: "  effect ").map(\.name), ["effect.wav"], "前後の空白は無視")
        XCTAssertEqual(MediaBrowser.filter(items, kind: .all, query: "   ").count, 4, "空白だけは全部")
        XCTAssertEqual(MediaBrowser.filter(items, kind: .all, query: "zzz").count, 0)
    }

    func testSortIsNaturalOrder() {
        let names = ["track10.wav", "Track2.wav", "a.mp3", "track1.wav"]
        XCTAssertEqual(MediaBrowser.sorted(names.map(item)).map(\.name), ["a.mp3", "track1.wav", "Track2.wav", "track10.wav"])
    }

    func testScanListsOnlyMediaDirectChildren() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mediabrowser-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for n in ["b.mp4", "a.wav", "c.png", "readme.txt", ".secret.mp3"] {
            try Data([0]).write(to: dir.appendingPathComponent(n))
        }
        let sub = dir.appendingPathComponent("sub.mp4")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)

        let list = MediaBrowser.scan(folder: dir)
        XCTAssertEqual(list.map(\.name), ["a.wav", "b.mp4", "c.png"], "対象の拡張子だけ・直下だけ・隠しファイルとフォルダは除く・自然順")
        XCTAssertEqual(list.map(\.kind), [.audio, .video, .image])
        XCTAssertEqual(MediaBrowser.scan(folder: dir.appendingPathComponent("missing")), [])
    }
}

/// 並べ方・長さ・読めるかの確認(2026-11-02)。
final class MediaBrowserSortAndProbeTests: XCTestCase {
    private func item(_ name: String, modified: Date? = nil, unreadable: Bool = false) -> MediaBrowser.Item {
        MediaBrowser.Item(url: URL(fileURLWithPath: "/x/\(name)"), name: name, kind: MediaBrowser.kind(forName: name) ?? .video,
                          modified: modified, unreadable: unreadable)
    }

    func testSortByModifiedNewestFirstAndUndatedLast() {
        let old = Date(timeIntervalSince1970: 1_000), new = Date(timeIntervalSince1970: 2_000)
        let items = [item("a.mp4", modified: old), item("b.mp4", modified: new), item("c.mp4")]
        XCTAssertEqual(MediaBrowser.sorted(items, by: .modified).map(\.name), ["b.mp4", "a.mp4", "c.mp4"])
    }

    func testSortByKindGroupsVideoAudioImage() {
        let items = ["z.png", "m.wav", "a.mov", "b.mp3"].map { item($0) }
        XCTAssertEqual(MediaBrowser.sorted(items, by: .kind).map(\.name), ["a.mov", "b.mp3", "m.wav", "z.png"], "動画・音声・画像の順、その中は名前順")
    }

    func testSortByNameMatchesDefault() {
        let items = ["track10.wav", "Track2.wav", "a.mp3"].map { item($0) }
        XCTAssertEqual(MediaBrowser.sorted(items, by: .name), MediaBrowser.sorted(items))
    }

    func testFilterAppliesSortKey() {
        let old = Date(timeIntervalSince1970: 1), new = Date(timeIntervalSince1970: 9)
        let items = [item("bgm-a.wav", modified: old), item("bgm-b.wav", modified: new), item("other.wav", modified: new)]
        XCTAssertEqual(MediaBrowser.filter(items, kind: .all, query: "bgm", sort: .modified).map(\.name), ["bgm-b.wav", "bgm-a.wav"])
    }

    func testApplyingProbeResultKeepsIdentity() {
        let i = item("clip.mp4")
        let withLen = MediaBrowser.applying((duration: 3.5, unreadable: false), to: i)
        XCTAssertEqual(withLen.duration, 3.5)
        XCTAssertFalse(withLen.unreadable)
        XCTAssertEqual(withLen.id, i.id)
        XCTAssertTrue(MediaBrowser.applying((duration: nil, unreadable: true), to: i).unreadable)
    }

    func testProbeFlagsGarbageFilesAsUnreadable() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let movie = dir.appendingPathComponent("broken.mp4"), picture = dir.appendingPathComponent("broken.png")
        try Data(repeating: 0x42, count: 64).write(to: movie)
        try Data(repeating: 0x42, count: 64).write(to: picture)
        let m = await MediaBrowser.probe(url: movie, kind: .video)
        XCTAssertTrue(m.unreadable, "中身が映像でないファイルは読めない扱い")
        XCTAssertNil(m.duration)
        let p = await MediaBrowser.probe(url: picture, kind: .image)
        XCTAssertTrue(p.unreadable)
        XCTAssertNil(p.duration, "画像は長さを持たない")
    }
}

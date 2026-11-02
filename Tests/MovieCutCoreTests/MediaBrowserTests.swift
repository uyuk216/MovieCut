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

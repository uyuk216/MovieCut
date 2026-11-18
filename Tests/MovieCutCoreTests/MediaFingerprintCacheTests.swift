import XCTest
@testable import MovieCutCore

final class MediaFingerprintCacheTests: XCTestCase {
    private var tmp: URL!
    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("fpcache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        tmp = tmp.resolvingSymlinksInPath()
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    /// compute の呼び出し回数を数える(実際のハッシュ計算はそのまま行う)。
    private final class Counter: @unchecked Sendable { var n = 0 }

    private func makeCache(_ counter: Counter) -> MediaFingerprintCache {
        MediaFingerprintCache(compute: { path in
            counter.n += 1
            return MediaFingerprint.compute(atPath: path)
        })
    }

    private func write(_ name: String, _ text: String) throws -> String {
        let u = tmp.appendingPathComponent(name)
        try Data(text.utf8).write(to: u)
        return u.path
    }

    func testFirstCallComputesAndReturnsFingerprint() throws {
        let path = try write("a.png", "hello")
        let counter = Counter()
        let cache = makeCache(counter)
        let fp = try XCTUnwrap(cache.fingerprint(atPath: path))
        XCTAssertEqual(fp, MediaFingerprint.compute(atPath: path))
        XCTAssertEqual(counter.n, 1)
        XCTAssertEqual(cache.count, 1)
    }

    func testUnchangedFileIsNotRecomputed() throws {
        let path = try write("a.png", "hello")
        let counter = Counter()
        let cache = makeCache(counter)
        let first = cache.fingerprint(atPath: path)
        let second = cache.fingerprint(atPath: path)
        let third = cache.fingerprint(atPath: path)
        XCTAssertEqual(counter.n, 1, "サイズと更新日時が同じなら計算し直さない")
        XCTAssertEqual(first, second)
        XCTAssertEqual(second, third)
    }

    func testChangedFileIsRecomputed() throws {
        let path = try write("a.png", "hello")
        let counter = Counter()
        let cache = makeCache(counter)
        _ = cache.fingerprint(atPath: path)
        // 中身を変える(サイズも変わる)
        try Data("hello, world".utf8).write(to: URL(fileURLWithPath: path))
        let fp = try XCTUnwrap(cache.fingerprint(atPath: path))
        XCTAssertEqual(counter.n, 2, "変わったら計算し直す")
        XCTAssertEqual(fp, MediaFingerprint.compute(atPath: path), "差し替えた新しい値を返す")
    }

    func testSameSizeButNewModificationDateIsRecomputed() throws {
        let path = try write("a.png", "aaaa")
        let counter = Counter()
        let cache = makeCache(counter)
        let before = try XCTUnwrap(cache.fingerprint(atPath: path))
        // サイズは同じ・中身は違う・更新日時だけ変わる
        try Data("bbbb".utf8).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 3600)],
                                              ofItemAtPath: path)
        let after = try XCTUnwrap(cache.fingerprint(atPath: path))
        XCTAssertEqual(counter.n, 2)
        XCTAssertNotEqual(before.sha256, after.sha256)
    }

    func testMissingFileIsNotInResultAndDropsRecord() throws {
        let path = try write("a.png", "hello")
        let counter = Counter()
        let cache = makeCache(counter)
        XCTAssertNotNil(cache.fingerprint(atPath: path))
        try FileManager.default.removeItem(atPath: path)
        XCTAssertNil(cache.fingerprint(atPath: path))
        XCTAssertEqual(cache.count, 0, "無くなった素材の記録は捨てる")
        XCTAssertEqual(counter.n, 1, "無いファイルは計算しない")
    }

    func testUnreadableFileIsNotStored() {
        let counter = Counter()
        let cache = MediaFingerprintCache(stamp: { _ in MediaFingerprintCache.FileStamp(size: 1, modified: nil) },
                                          compute: { _ in counter.n += 1; return nil })
        XCTAssertNil(cache.fingerprint(atPath: "/unreadable"))
        XCTAssertNil(cache.fingerprint(atPath: "/unreadable"))
        XCTAssertEqual(cache.count, 0)
        XCTAssertEqual(counter.n, 2, "読めなかったものは記録されないので、次回また試す")
    }

    func testAttachingUsesCacheForEachSourceOnce() throws {
        let a = try write("a.png", "aaa")
        let b = try write("b.png", "bbb")
        var p = Project.new()
        var c1 = Clip(); c1.type = .image; c1.src = a; c1.duration = 1
        var c2 = Clip(); c2.type = .image; c2.src = a; c2.duration = 1
        var c3 = Clip(); c3.type = .image; c3.src = b; c3.duration = 1
        var t = Track(name: "映像"); t.clips = [c1, c2, c3]
        p.tracks = [t]

        let counter = Counter()
        let cache = makeCache(counter)
        let first = MediaFingerprintCollector.attaching(to: p, compute: cache.fingerprint(atPath:))
        XCTAssertEqual(Set(first.mediaFingerprints.keys), [a, b])
        XCTAssertEqual(counter.n, 2, "同じ素材は 1 回だけ計算する")

        // 2 回目の保存: どちらも変わっていないので計算しない
        let second = MediaFingerprintCollector.attaching(to: p, compute: cache.fingerprint(atPath:))
        XCTAssertEqual(second.mediaFingerprints, first.mediaFingerprints)
        XCTAssertEqual(counter.n, 2)
    }
}

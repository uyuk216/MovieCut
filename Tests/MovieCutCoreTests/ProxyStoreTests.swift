import XCTest
import AVFoundation
import CoreGraphics
@testable import MovieCutCore

/// プロキシ編集: 鍵の安定性・大きさ・実際の動画からのプロキシ・プレビューだけが読むこと(書き出しは元の素材)。
final class ProxyStoreTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("proxy-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: 鍵

    func testKeyIsStableForSameInputs() {
        let d = Date(timeIntervalSince1970: 1_700_000_000.123)
        XCTAssertEqual(ProxyStore.key(path: "/a/b.mp4", modified: d, size: 100),
                       ProxyStore.key(path: "/a/b.mp4", modified: d, size: 100))
        XCTAssertEqual(ProxyStore.key(path: "/a/b.mp4", modified: d, size: 100).count, 32)
    }

    func testKeyChangesWithPathMtimeOrSize() {
        let d = Date(timeIntervalSince1970: 1_700_000_000)
        let base = ProxyStore.key(path: "/a/b.mp4", modified: d, size: 100)
        XCTAssertNotEqual(base, ProxyStore.key(path: "/a/c.mp4", modified: d, size: 100))
        XCTAssertNotEqual(base, ProxyStore.key(path: "/a/b.mp4", modified: d.addingTimeInterval(1), size: 100))
        XCTAssertNotEqual(base, ProxyStore.key(path: "/a/b.mp4", modified: d, size: 101))
    }

    func testProxyNameFollowsSourceFileChanges() throws {
        let src = dir.appendingPathComponent("src.mov")
        try Data("one".utf8).write(to: src)
        let first = try XCTUnwrap(ProxyStore.proxyURL(for: src, directory: dir))
        // 中身の大きさが変わると別の名前になる(古いプロキシを使わない)
        try Data("one, changed".utf8).write(to: src)
        let second = try XCTUnwrap(ProxyStore.proxyURL(for: src, directory: dir))
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first.deletingLastPathComponent().path, dir.path)
        XCTAssertEqual(first.pathExtension, "mp4")
    }

    func testMissingSourceHasNoProxyURL() {
        XCTAssertNil(ProxyStore.proxyURL(for: dir.appendingPathComponent("nope.mp4"), directory: dir))
        XCTAssertNil(ProxyStore.existingProxy(for: dir.appendingPathComponent("nope.mp4"), directory: dir))
    }

    // MARK: 大きさ

    func testOutputSizeIsShortSide540AndNeverUpscales() {
        XCTAssertEqual(ProxyStore.outputSize(for: CGSize(width: 1920, height: 1080)), CGSize(width: 960, height: 540))
        XCTAssertEqual(ProxyStore.outputSize(for: CGSize(width: 3840, height: 2160)), CGSize(width: 960, height: 540))
        XCTAssertEqual(ProxyStore.outputSize(for: CGSize(width: 1080, height: 1920)), CGSize(width: 540, height: 960))
        XCTAssertEqual(ProxyStore.outputSize(for: CGSize(width: 640, height: 480)), CGSize(width: 640, height: 480))
        // 偶数にそろえる(H.264 の要件)
        let odd = ProxyStore.outputSize(for: CGSize(width: 1001, height: 563))
        XCTAssertEqual(Int(odd.width) % 2, 0)
        XCTAssertEqual(Int(odd.height) % 2, 0)
        XCTAssertLessThanOrEqual(odd.height, 540)
    }

    // MARK: 実際の動画

    func testMakesH264ProxyAt540pFromRealVideoAndReusesIt() async throws {
        let src = dir.appendingPathComponent("source.mp4")
        try TestVideo.write(to: src, size: (1280, 720), frames: 10, rgb: (255, 0, 0))
        let seen = ProgressBox()
        let made = try await ProxyStore.make(source: src, directory: dir) { v in seen.add(v) }
        XCTAssertEqual(made, ProxyStore.existingProxy(for: src, directory: dir))
        XCTAssertTrue(FileManager.default.fileExists(atPath: made.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(made.deletingPathExtension().lastPathComponent + ".part.mp4").path))

        let asset = AVURLAsset(url: made)
        let track = try XCTUnwrap(asset.tracks(withMediaType: .video).first)
        XCTAssertEqual(track.naturalSize.width, 960)
        XCTAssertEqual(track.naturalSize.height, 540)
        let fd = try XCTUnwrap((track.formatDescriptions as? [CMFormatDescription])?.first)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(fd), kCMVideoCodecType_H264)
        XCTAssertTrue(asset.tracks(withMediaType: .audio).isEmpty, "プロキシは映像だけ")
        XCTAssertEqual(seen.values.last, 1)

        // 2 回目は作り直さず同じファイル
        let again = try await ProxyStore.make(source: src, directory: dir)
        XCTAssertEqual(again, made)
    }

    func testProxyOfPortraitVideoKeepsOrientation() async throws {
        let src = dir.appendingPathComponent("portrait.mp4")
        try TestVideo.write(to: src, size: (720, 1280), frames: 5, rgb: (0, 255, 0))
        let made = try await ProxyStore.make(source: src, directory: dir)
        let track = try XCTUnwrap(AVURLAsset(url: made).tracks(withMediaType: .video).first)
        XCTAssertEqual(track.naturalSize.width, 540)
        XCTAssertEqual(track.naturalSize.height, 960)
    }
}

/// 進み具合の記録(テスト用。進捗のコールバックは別のスレッドから来る)。
final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [Double] = []
    func add(_ v: Double) { lock.lock(); all.append(v); lock.unlock() }
    var values: [Double] { lock.lock(); defer { lock.unlock() }; return all }
}

/// 単色の動画を書く(テスト用)。BGRA の画素を埋めて H.264 の mp4 にする。
enum TestVideo {
    struct Failure: Error { let what: String }

    static func write(to url: URL, size: (Int, Int), frames: Int, fps: Int32 = 10, rgb: (UInt8, UInt8, UInt8)) throws {
        try? FileManager.default.removeItem(at: url)
        let w = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: size.0, AVVideoHeightKey: size.1,
        ])
        let ad = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: size.0, kCVPixelBufferHeightKey as String: size.1,
        ])
        w.add(input)
        guard w.startWriting() else { throw Failure(what: "startWriting: \(String(describing: w.error))") }
        w.startSession(atSourceTime: .zero)
        for i in 0..<frames {
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, ad.pixelBufferPool!, &pb)
            guard let buf = pb else { throw Failure(what: "pixel buffer") }
            CVPixelBufferLockBaseAddress(buf, [])
            let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
            let bpr = CVPixelBufferGetBytesPerRow(buf)
            for y in 0..<size.1 { for x in 0..<size.0 {
                let o = y * bpr + x * 4
                base[o] = rgb.2; base[o + 1] = rgb.1; base[o + 2] = rgb.0; base[o + 3] = 255
            } }
            CVPixelBufferUnlockBaseAddress(buf, [])
            guard ad.append(buf, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps))) else {
                throw Failure(what: "append \(i): \(String(describing: w.error))")
            }
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        w.finishWriting { done.signal() }
        done.wait()
        guard w.status == .completed else { throw Failure(what: "finish: \(String(describing: w.error))") }
    }
}

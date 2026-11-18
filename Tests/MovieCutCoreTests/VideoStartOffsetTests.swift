import XCTest
import AVFoundation
@testable import MovieCutCore

/// 映像トラックが遅れて始まる mp4(最初コマが 0 秒より後にあるファイル)の回帰テスト。
/// 以前は 0 秒のフレーム要求が許容幅の外になって失敗し、そのファイルが「見つからない」として
/// 記録されて、以後のフレームが全部取れずプレビューが黒くなっていた。
final class VideoStartOffsetTests: XCTestCase {
    private var dir: URL!
    private var normalPath: String!
    private var offsetPath: String!

    override func setUpWithError() throws {
        let ffmpeg = try Self.ffmpegPath()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("video-start-offset-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { [dir] in try? FileManager.default.removeItem(at: dir!) }
        let normal = dir.appendingPathComponent("normal.mp4")
        let offset = dir.appendingPathComponent("offset.mp4")
        try Self.run(ffmpeg, ["-y", "-v", "error", "-f", "lavfi", "-i", "testsrc2=duration=2:size=320x240:rate=30",
                              "-c:v", "libx264", "-pix_fmt", "yuv420p", normal.path])
        try Self.run(ffmpeg, ["-y", "-v", "error", "-i", normal.path, "-c", "copy", "-output_ts_offset", "0.023", offset.path])
        normalPath = normal.path
        offsetPath = offset.path
        // 素材の前提が崩れていないこと(先頭に空の区間があり、最初コマが 0.01 秒より後)を確認する。
        // これが成り立たないと、このテストは意味を持たない。
        let asset = AVURLAsset(url: offset)
        let first = asset.tracks(withMediaType: .video).first
            .flatMap { tr in tr.segments.first(where: { !$0.isEmpty })?.timeMapping.target.start.seconds } ?? 0
        XCTAssertGreaterThan(first, 0.01, "オフセット付き素材が作れていない(最初コマ: \(first))")
    }

    private static func ffmpegPath() throws -> String {
        for p in ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"] where FileManager.default.isExecutableFile(atPath: p) { return p }
        throw XCTSkip("ffmpeg が無いので素材を作れず飛ばします")
    }

    private static func run(_ exe: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.standardOutput = Pipe(); p.standardError = Pipe()
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 { throw XCTSkip("ffmpeg の実行に失敗しました(\(p.terminationStatus))") }
    }

    /// 遅れて始まる素材でも、0 秒(クリップの先頭)のフレームが取れる。
    func testFirstFrameIsReturnedForStartOffsetVideo() {
        let assets = RenderAssets()
        XCTAssertNotNil(assets.videoFrame(path: offsetPath, time: 0), "先頭のフレームが取れない")
    }

    /// 先頭で失敗して「見つからない」に記録され、後続のフレームまで全部黒になる、という連鎖が起きない。
    func testStartOffsetVideoIsNotPoisonedByFirstFrameRequest() {
        let assets = RenderAssets()
        XCTAssertNotNil(assets.videoFrame(path: offsetPath, time: 0))
        XCTAssertNotNil(assets.videoFrame(path: offsetPath, time: 0.5), "先頭の要求のあと、中ほどのフレームまで取れなくなっている")
        XCTAssertNotNil(assets.videoFrame(path: offsetPath, time: 1.0))
        XCTAssertNotNil(assets.videoFrame(path: offsetPath, time: 0), "先頭に戻っても取れる")
    }

    /// exact(許容幅 0)の経路でも先頭のフレームが取れる。
    func testExactFirstFrameIsReturnedForStartOffsetVideo() {
        let assets = RenderAssets()
        XCTAssertNotNil(assets.videoFrame(path: offsetPath, time: 0, exact: true))
        XCTAssertNotNil(assets.videoFrame(path: offsetPath, time: 1.0, exact: true))
    }

    /// 通常の素材(0 秒から始まる)は従来どおり。
    func testNormalVideoStillWorks() {
        let assets = RenderAssets()
        XCTAssertNotNil(assets.videoFrame(path: normalPath, time: 0))
        XCTAssertNotNil(assets.videoFrame(path: normalPath, time: 1.0))
    }

    /// 本当に無いファイルは従来どおり nil(「見つからない」扱いのまま)。
    func testMissingFileStillReturnsNil() {
        let assets = RenderAssets()
        let missing = dir.appendingPathComponent("no-such.mp4").path
        XCTAssertNil(assets.videoFrame(path: missing, time: 0))
        XCTAssertNil(assets.videoFrame(path: missing, time: 1.0))
    }
}

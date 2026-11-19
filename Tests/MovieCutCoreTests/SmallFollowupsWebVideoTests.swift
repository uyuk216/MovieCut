import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import MovieCutCore

/// バッチV F-7: WebVideo 書き出し(FFmpegVideoExporter)の中間描画にもプラグインエフェクトが効くこと。
/// ffmpeg と VP9/Opus エンコーダが無い環境ではスキップする(PngWavExoExportTests の F-3 テストと同じ流儀)。
final class SmallFollowupsWebVideoTests: XCTestCase {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("smallfix-v-web-\(UUID().uuidString)")
    override func setUpWithError() throws { try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    private func project() throws -> Project {
        let size = 160
        let c = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(CGColor(srgbRed: 200.0 / 255, green: 30.0 / 255, blue: 60.0 / 255, alpha: 1))
        c.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let url = tmp.appendingPathComponent("solid.png")
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, c.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        var clip = Clip(); clip.id = "i"; clip.type = .image; clip.src = url.path; clip.start = 0; clip.duration = 2
        clip.effects = [Effect(kind: InvertEffectPlugin.effectID, params: ["amount": 1])]
        var p = Project(); p.width = size; p.height = size; p.fps = 10; p.bg = "#000000"; p.characters = []
        var tr = Track(name: "L1"); tr.clips = [clip]; p.tracks = [tr]
        return p
    }

    private func centerRGB(ofWebm webm: URL, ffmpeg: URL, name: String) throws -> [Int] {
        let png = tmp.appendingPathComponent("\(name).png")
        let proc = Process()
        proc.executableURL = ffmpeg
        proc.arguments = ["-hide_banner", "-y", "-ss", "0.5", "-i", webm.path, "-frames:v", "1", png.path]
        proc.standardOutput = Pipe(); proc.standardError = Pipe()
        try proc.run(); proc.waitUntilExit()
        XCTAssertEqual(proc.terminationStatus, 0, "ffmpeg でコマを取り出せる")
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(png as CFURL, nil))
        let img = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
        var d = [UInt8](repeating: 0, count: img.width * img.height * 4)
        let ctx = CGContext(data: &d, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        let i = ((img.height / 2) * img.width + img.width / 2) * 4
        return [Int(d[i]), Int(d[i + 1]), Int(d[i + 2])]
    }

    func testWebVideoExportAppliesPluginEffect() async throws {
        guard let ffmpeg = FFmpegLocator.find() else { throw XCTSkip("ffmpeg が無い環境") }
        let encoders = FFmpegLocator.availableEncoders(at: ffmpeg)
        try XCTSkipIf(WebVideoFormat.webmVP9.unavailableReason(encoders: encoders, ffmpegFound: true) != nil, "VP9/Opus エンコーダが無い環境")
        let p = try project()

        let fxURL = tmp.appendingPathComponent("fx.webm")
        try await FFmpegVideoExporter.export(project: p, format: .webmVP9, to: fxURL,
                                             pluginEffectProviders: [InvertEffectProvider()])
        let fx = try centerRGB(ofWebm: fxURL, ffmpeg: ffmpeg, name: "fx-frame")
        XCTAssertLessThan(fx[0], 110, "反転で赤が下がる: \(fx)")
        XCTAssertGreaterThan(fx[1], 170, "反転で緑が上がる: \(fx)")

        let plainURL = tmp.appendingPathComponent("plain.webm")
        try await FFmpegVideoExporter.export(project: p, format: .webmVP9, to: plainURL)
        let plain = try centerRGB(ofWebm: plainURL, ffmpeg: ffmpeg, name: "plain-frame")
        XCTAssertGreaterThan(plain[0], 150, "プロバイダ無しでは従来どおり反転しない: \(plain)")
        XCTAssertLessThan(plain[1], 90, "プロバイダ無しでは従来どおり反転しない: \(plain)")
    }
}

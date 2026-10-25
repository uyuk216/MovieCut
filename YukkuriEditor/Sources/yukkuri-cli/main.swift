import Foundation
import YukkuriCore
import ImageIO
import UniformTypeIdentifiers

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(1)
}

let args = Array(CommandLine.arguments.dropFirst())

func optValue(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func parseSize(_ s: String) -> (Int, Int) {
    let parts = s.lowercased().split(separator: "x").compactMap { Int($0) }
    guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { fail("--size は WxH で指定してください") }
    return (parts[0], parts[1])
}

/// 書き出して、進み具合(約10%ごと)を stderr、最後に コマ数・秒・実時間比 を stdout に出す。
func runExport(_ p: Project, to url: URL) async throws {
    let exporter = Exporter(project: p, assets: RenderAssets())
    let frames = exporter.totalFrames
    var nextMark = 0.1
    let t0 = Date()
    try await exporter.export(to: url) { v in
        if v >= nextMark - 1e-9 {
            FileHandle.standardError.write(Data(String(format: "  %3.0f%%\n", v * 100).utf8))
            nextMark = (v * 10 + 1e-9).rounded(.down) / 10 + 0.1
        }
    }
    let wall = Date().timeIntervalSince(t0)
    let dur = p.endTime
    print(String(format: "wrote %@ frames=%d wall=%.2fs speed=%.2fx realtime (%.1f fps)", url.path, frames, wall, dur / max(wall, 1e-9), Double(frames) / max(wall, 1e-9)))
}
switch args.first {
case "info" where args.count == 2:
    do {
        let p = try Project.load(from: URL(fileURLWithPath: args[1]))
        print("size: \(p.width)x\(p.height)  fps: \(p.fps)  codec: \(p.codec)  bg: \(p.bg)")
        print("characters: \(p.characters.count)  tracks: \(p.tracks.count)")
        let clips = p.allClips
        print("clips: \(clips.count)")
        for t in ClipType.known {
            print("  \(t.rawValue): \(clips.filter { $0.type == t }.count)")
        }
        let other = clips.filter { !$0.type.isKnown }.count
        if other > 0 { print("  (unknown): \(other)") }
    } catch { fail("読めませんでした: \(error)") }
case "new" where args.count == 2:
    do { try Project.new().save(to: URL(fileURLWithPath: args[1])); print("wrote \(args[1])") }
    catch { fail("書けませんでした: \(error)") }
case "frame" where args.count >= 2:
    // frame <in.ymproj> --t <sec> --out <png> [--size WxH]
    func opt(_ name: String) -> String? { optValue(name) }
    guard let outPath = opt("--out") else { fail("--out が必要です") }
    let t = opt("--t").flatMap(Double.init) ?? 0
    do {
        var p = try Project.load(from: URL(fileURLWithPath: args[1]))
        if let s = opt("--size") {
            let parts = s.lowercased().split(separator: "x").compactMap { Int($0) }
            guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { fail("--size は WxH で指定してください") }
            p = p.scaledForResolution(newWidth: parts[0], newHeight: parts[1])
        }
        let renderer = Renderer(project: p, assets: RenderAssets())
        if let n = opt("--bench").flatMap(Int.init), n > 0 {
            // 描画時間の計測(最初の1回は暖機として除く)
            _ = renderer.renderImage(t: t)
            let t0 = Date()
            for _ in 0..<n { _ = renderer.renderImage(t: t) }
            print(String(format: "%.2f ms/frame (%d frames)", Date().timeIntervalSince(t0) * 1000 / Double(n), n))
        }
        guard let img = renderer.renderImage(t: t) else { fail("描画できませんでした") }
        guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: outPath) as CFURL, UTType.png.identifier as CFString, 1, nil) else { fail("書けませんでした: \(outPath)") }
        CGImageDestinationAddImage(dest, img, nil)
        guard CGImageDestinationFinalize(dest) else { fail("PNG を書けませんでした") }
        print("wrote \(outPath) (\(p.width)x\(p.height))")
    } catch { fail("読めませんでした: \(error)") }
case "export" where args.count >= 3:
    // export <in.ymproj> <out.mp4> [--size WxH] [--codec h264|hevc]
    do {
        var p = try Project.load(from: URL(fileURLWithPath: args[1]))
        if let s = optValue("--size") { let sz = parseSize(s); p = p.scaledForResolution(newWidth: sz.0, newHeight: sz.1) }
        if let c = optValue("--codec") { guard ["h264", "hevc"].contains(c) else { fail("--codec は h264 か hevc") }; p.codec = c }
        try await runExport(p, to: URL(fileURLWithPath: args[2]))
    } catch { fail("書き出せませんでした: \(error.localizedDescription)") }
case "smoke":
    // smoke --out <mp4> [--size WxH] [--codec h264|hevc] [--blur]
    guard let outPath = optValue("--out") else { fail("--out が必要です") }
    do {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("yukkuri-smoke-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let size = optValue("--size").map(parseSize)
        let codec = optValue("--codec")
        if let c = codec, !["h264", "hevc"].contains(c) { fail("--codec は h264 か hevc") }
        var p = try await ScriptTimeline.smokeProject(size: size.map { (width: $0.0, height: $0.1) }, codec: codec, blur: args.contains("--blur"), voice: ToneVoiceProvider(), directory: dir)
        // 計測用: 文字とぼかしの長さを伸ばす(--text-duration 10)
        if let d = optValue("--text-duration").flatMap(Double.init) {
            for ti in p.tracks.indices { for ci in p.tracks[ti].clips.indices where p.tracks[ti].clips[ci].type == .text || p.tracks[ti].clips[ci].type == .blur { p.tracks[ti].clips[ci].duration = d } }
        }
        if let f = optValue("--fps").flatMap(Int.init) { p.fps = f }
        if let sp = optValue("--save-project") { try p.save(to: URL(fileURLWithPath: sp)) }  // frame コマンドとの比較用
        print("clips: " + p.allClips.map { "\($0.type.rawValue)(\(String(format: "%.2f", $0.duration)))" }.joined(separator: " "))
        try await runExport(p, to: URL(fileURLWithPath: outPath))
    } catch { fail("書き出せませんでした: \(error.localizedDescription)") }
default:
    fail("usage:\n  yukkuri-cli info <file.ymproj>\n  yukkuri-cli new <out.ymproj>\n  yukkuri-cli export <in.ymproj> <out.mp4> [--size WxH] [--codec h264|hevc]\n  yukkuri-cli smoke --out <mp4> [--size WxH] [--codec h264|hevc] [--blur] [--save-project p.ymproj]\n  yukkuri-cli frame <in.ymproj> --t <sec> --out <png> [--size WxH] [--bench N]")
}

import Foundation
import YukkuriCore
import ImageIO
import UniformTypeIdentifiers

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(1)
}

let args = Array(CommandLine.arguments.dropFirst())
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
    func opt(_ name: String) -> String? {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
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
default:
    fail("usage:\n  yukkuri-cli info <file.ymproj>\n  yukkuri-cli new <out.ymproj>\n  yukkuri-cli frame <in.ymproj> --t <sec> --out <png> [--size WxH] [--bench N]")
}

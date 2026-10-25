import Foundation
import YukkuriCore

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
default:
    fail("usage:\n  yukkuri-cli info <file.ymproj>\n  yukkuri-cli new <out.ymproj>")
}

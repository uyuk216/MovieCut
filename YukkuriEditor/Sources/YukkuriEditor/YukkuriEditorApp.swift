import SwiftUI
import UniformTypeIdentifiers
import AppKit
import YukkuriCore

extension UTType {
    /// .ymproj(JSON)。Info.plist の UTExportedTypeDeclarations と同じ識別子。
    static let ymproj = UTType(exportedAs: "jp.local.yukkuri-editor.project", conformingTo: .json)
}

struct YukkuriDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.ymproj] }
    static var writableContentTypes: [UTType] { [.ymproj] }

    var project: Project

    init() { project = Project.new() }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        project = try Project.decode(from: data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try project.encoded())
    }
}

struct ContentView: View {
    @Binding var document: YukkuriDocument

    var body: some View {
        let p = document.project
        VStack(alignment: .leading, spacing: 10) {
            Text("ゆっくりエディタ").font(.title2).bold()
            Text("\(p.width)×\(p.height) · \(p.fps)fps · \(p.codec)")
            Text("キャラクター \(p.characters.count) 人 / レイヤー \(p.tracks.count) 本 / クリップ \(p.allClips.count) 個")
            Text("(M0: 仮の画面です。タイムラインとプレビューは次のマイルストーンで入ります)")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(minWidth: 480, maxWidth: .infinity, minHeight: 240, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// YE_SNAPSHOT_DIR があれば、起動 1.5 秒後にキーウィンドウの中身を PNG に書いて終了する。
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let dir = ProcessInfo.processInfo.environment["YE_SNAPSHOT_DIR"] else { return }
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            defer { NSApp.terminate(nil) }
            if ProcessInfo.processInfo.environment["YE_SNAPSHOT_DEBUG"] != nil {
                for w in NSApp.windows { FileHandle.standardError.write(Data("window: \(type(of: w)) title=\(w.title) visible=\(w.isVisible) content=\(String(describing: w.contentView.map { type(of: $0) })) frame=\(w.frame)\n".utf8)) }
            }
            let win = NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible && $0.contentView != nil }
            guard let view = win?.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                FileHandle.standardError.write(Data("snapshot: no window\n".utf8)); return
            }
            win?.displayIfNeeded()
            view.layoutSubtreeIfNeeded()
            view.display()
            view.cacheDisplay(in: view.bounds, to: rep)
            var png = rep.representation(using: .png, properties: [:])
            // SwiftUI のホスティングビューは cacheDisplay だと空白になることがあるので、レイヤーを直接描く
            if let layer = view.layer, let ctx = CGContext(
                data: nil, width: Int(view.bounds.width * 2), height: Int(view.bounds.height * 2), bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                ctx.scaleBy(x: 2, y: 2)
                ctx.setFillColor(NSColor.windowBackgroundColor.cgColor)
                ctx.fill(view.bounds)
                // ホスティングレイヤーは上下が逆に描かれるので反転して描く
                ctx.translateBy(x: 0, y: view.bounds.height)
                ctx.scaleBy(x: 1, y: -1)
                layer.render(in: ctx)
                if let img = ctx.makeImage() {
                    png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])
                }
            }
            guard let png else { return }
            let url = URL(fileURLWithPath: dir, isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try? png.write(to: url.appendingPathComponent("window.png"))
        }
    }
}

@main
struct YukkuriEditorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        DocumentGroup(newDocument: YukkuriDocument()) { file in
            ContentView(document: file.$document)
        }
    }
}

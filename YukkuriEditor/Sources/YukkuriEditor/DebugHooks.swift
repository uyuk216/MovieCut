import SwiftUI
import AppKit
import YukkuriCore

/// 検証用フック(環境変数があるときだけ動く。普段は何もしない)。
///
/// - `YE_SNAPSHOT_DIR=<dir>`  最初のプレビュー画面が描けるまで待ち、`YE_SNAPSHOT_DELAY` 秒(既定 0.5)後に
///   ウィンドウを `<dir>/window.png` に書いて終了する。シートが出ていれば `<dir>/sheet.png` も書く。
/// - `YE_OPEN=<path.ymproj>`  起動時にそのファイルを開き、スナップショットや下のフックはそのドキュメントに対して行う。
/// - `YE_DEBUG_SIZE=WxH`      解像度ピッカーと同じ経路(`selectResolution`)で解像度を変える。
/// - `YE_DEBUG_SCRIPT="行1\n行2"` 台本ボタンと同じ関数(`generateVoices`)を起動後に実行する(`\n` は改行として扱う)。
/// - `YE_DEBUG_EXPORT=<out.mp4>` ツールバーの書き出しと同じ関数(`runExport`)を保存パネルなしで実行し、
///   結果を標準出力に出して終了する。`YE_SNAPSHOT_DIR` も付けると、書き出し開始から DELAY 秒後に写真を撮る(進行シート確認用)。
/// - `YE_DEBUG_SHEET=settings` 設定シートを開いた状態にする。
@MainActor
final class DebugHooks {
    static let shared = DebugHooks()
    private let env = ProcessInfo.processInfo.environment
    private var started = false

    private var active: Bool {
        ["YE_SNAPSHOT_DIR", "YE_DEBUG_SIZE", "YE_DEBUG_SCRIPT", "YE_DEBUG_EXPORT", "YE_DEBUG_SHEET"].contains { env[$0] != nil }
    }

    func appDidLaunch() {
        guard env["YE_OPEN"] != nil || active else { return }
        NSApp.activate(ignoringOtherApps: true)
        if let path = env["YE_OPEN"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                NSDocumentController.shared.openDocument(withContentsOf: URL(fileURLWithPath: path), display: true) { _, _, error in
                    if let error { Self.out("YE_OPEN 失敗: \(error.localizedDescription)"); exit(2) }
                }
            }
        }
        // どのドキュメントも現れなかったときの保険
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            if !self.started { Self.out("debug: ドキュメントが現れませんでした"); exit(3) }
        }
    }

    /// ドキュメントの画面が出たときに呼ばれる。YE_OPEN があれば、そのファイルのものだけ相手にする。
    func attach(_ model: ProjectModel) {
        guard active, !started else { return }
        if let path = env["YE_OPEN"] {
            let want = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            guard model.fileURL?.resolvingSymlinksInPath().path == want else { return }
        }
        started = true
        Task { @MainActor in await self.run(model) }
    }

    private func run(_ model: ProjectModel) async {
        while model.window == nil { try? await Task.sleep(nanoseconds: 50_000_000) }
        NSApp.activate(ignoringOtherApps: true)
        model.window?.makeKeyAndOrderFront(nil)
        let delay = env["YE_SNAPSHOT_DELAY"].flatMap(Double.init) ?? 0.5

        if let s = env["YE_DEBUG_SIZE"] { model.selectResolution(s) }
        if let s = env["YE_DEBUG_SCRIPT"] {
            await model.generateVoices(from: s.replacingOccurrences(of: "\\n", with: "\n"))
            Self.out("script: \(model.statusText)\(model.errorMessage.map { " ERROR: \($0)" } ?? "")")
        }
        if env["YE_DEBUG_SHEET"] == "settings" { model.showSettings = true }

        if let out = env["YE_DEBUG_EXPORT"] {
            if env["YE_SNAPSHOT_DIR"] != nil {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    self.snapshot(model)
                }
            }
            let url = URL(fileURLWithPath: out)
            let t0 = Date()
            switch await model.runExport(to: url) {
            case .success(let u):
                let size = (try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? Int) ?? 0
                Self.out(String(format: "export: ok %@ (%d bytes, %.1fs)", u.path, size, Date().timeIntervalSince(t0)))
                Self.finish(0)
            case .cancelled:
                Self.out("export: cancelled"); Self.finish(1)
            case .failure(let e):
                Self.out("export: failed \(e.localizedDescription)"); Self.finish(1)
            }
        }

        if env["YE_SNAPSHOT_DIR"] != nil {
            // 最初のフレームが描けて、新しい要求が無くなるまで待つ(最大 30 秒)
            var waited = 0.0
            while !(model.previewFrameCount > 0 && model.previewIdle) && waited < 30 {
                try? await Task.sleep(nanoseconds: 50_000_000); waited += 0.05
            }
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            snapshot(model)
        }
        Self.finish(0)
    }

    // MARK: スナップショット

    private func snapshot(_ model: ProjectModel) {
        guard let dir = env["YE_SNAPSHOT_DIR"] else { return }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        guard let win = model.window else { Self.out("snapshot: no window"); return }
        if let png = Self.png(of: win) { try? png.write(to: url.appendingPathComponent("window.png")) }
        if let sheet = win.attachedSheet, let png = Self.png(of: sheet) {
            try? png.write(to: url.appendingPathComponent("sheet.png"))
        }
        Self.out("snapshot: wrote \(url.path)")
    }

    /// ウィンドウの中身を PNG にする(画面収録の許可に頼らず、レイヤーを直接描く)。
    static func png(of win: NSWindow) -> Data? {
        guard let view = win.contentView else { return nil }
        win.displayIfNeeded()
        view.layoutSubtreeIfNeeded()
        let scale: CGFloat = 2
        guard let ctx = CGContext(
            data: nil, width: Int(view.bounds.width * scale), height: Int(view.bounds.height * scale), bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        ctx.setFillColor(NSColor.windowBackgroundColor.cgColor)
        ctx.fill(view.bounds)
        if let layer = view.layer {
            // ホスティングレイヤーは上下が逆に描かれるので反転して描く
            ctx.translateBy(x: 0, y: view.bounds.height)
            ctx.scaleBy(x: 1, y: -1)
            layer.render(in: ctx)
        }
        guard let img = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])
    }

    private static func out(_ s: String) {
        FileHandle.standardOutput.write(Data((s + "\n").utf8))
    }

    /// 書き出しの未保存確認などで止まらないよう、エンジンだけ止めて直接終わる。
    private static func finish(_ code: Int32) -> Never {
        AppServices.engine.shutdown()
        exit(code)
    }
}

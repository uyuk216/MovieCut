import SwiftUI
import AppKit
@preconcurrency import MovieCutCore

/// 素材ブラウザの別ウインドウ(非モーダル)。書類ごとに 1 つ。
/// モーダルのシートだと、開いている間はタイムラインへドロップできないため、別ウインドウにしている。
/// `ProjectModel.showAudioLibrary` に合わせて開き・閉じる。利用者が閉じたら、フラグも下ろす。
@MainActor
final class MediaBrowserWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private weak var model: ProjectModel?
    /// テスト・試験で画面に出さないとき false。
    private let presents: Bool

    init(model: ProjectModel, presents: Bool = true) {
        self.model = model
        self.presents = presents
    }

    /// 開くべきなら開き、閉じるべきなら閉じる。
    func sync(open: Bool) {
        if open { show() } else { hide() }
    }

    /// 見えているか(試験用)。
    var isOpen: Bool { window?.isVisible == true }

    private func show() {
        guard let model else { return }
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 520),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable],
                             backing: .buffered, defer: true)
            w.title = "素材ブラウザ — \(model.window?.title ?? "Movie Cut")"
            w.isReleasedWhenClosed = false
            w.tabbingMode = .disallowed
            w.minSize = NSSize(width: 600, height: 420)
            w.delegate = self
            w.contentView = NSHostingView(rootView: AudioLibrarySheet(model: model))
            if presents {
                w.setFrameAutosaveName("MovieCut.mediaBrowser")
                if !w.setFrameUsingName(w.frameAutosaveName) { w.center() }
            }
            window = w
        }
        if presents { window?.makeKeyAndOrderFront(nil) }
    }

    private func hide() {
        window?.close()
    }

    /// 利用者が閉じたら、フラグを下ろす(こちらで閉じたときは既に下りている)。
    func windowWillClose(_ notification: Notification) {
        guard let model, model.showAudioLibrary else { return }
        model.showAudioLibrary = false
    }

    /// 書類を閉じるとき。
    func closeAll() {
        window?.delegate = nil
        window?.close()
        window?.contentView = nil
        window = nil
    }
}

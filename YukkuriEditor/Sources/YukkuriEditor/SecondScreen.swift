import SwiftUI
import AppKit
import YukkuriCore

/// 別画面に全画面で出すプレビュー(黒背景・縦横比を保って収める)。
private struct SecondScreenRoot: View {
    @ObservedObject var model: ProjectModel
    var body: some View {
        PreviewView(project: model.project, time: model.currentTime, assets: model.assets, model: model,
                    fullscreen: true, epoch: model.previewEpoch)
            .background(Color.black)
    }
}

/// Esc で閉じられる、枠なしウィンドウ。
final class FullscreenPreviewWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func cancelOperation(_ sender: Any?) { close() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { close() } else { super.keyDown(with: event) }
    }
}

@MainActor
final class SecondScreenController {
    private(set) var window: NSWindow?
    private var closeObserver: NSObjectProtocol?

    struct ScreenInfo { var isBuiltin: Bool; var area: Double }

    /// 内蔵ではない画面のうち最大のもの。無ければ nil(= メイン画面を使う)。
    static func pickTarget(_ screens: [ScreenInfo]) -> Int? {
        screens.indices.filter { !screens[$0].isBuiltin }.max { screens[$0].area < screens[$1].area }
    }

    static func isBuiltin(_ s: NSScreen) -> Bool {
        guard let id = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return false }
        return CGDisplayIsBuiltin(id) != 0
    }

    static func targetScreen() -> NSScreen? {
        let screens = NSScreen.screens
        let infos = screens.map { ScreenInfo(isBuiltin: isBuiltin($0), area: Double($0.frame.width * $0.frame.height)) }
        if let i = pickTarget(infos) { return screens[i] }
        return NSScreen.main ?? screens.first
    }

    var isOpen: Bool { window != nil }

    func toggle(model: ProjectModel) { isOpen ? close() : show(model: model) }

    func show(model: ProjectModel) {
        guard window == nil, let screen = Self.targetScreen() else { return }
        let w = FullscreenPreviewWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false, screen: screen)
        w.isReleasedWhenClosed = false
        w.backgroundColor = .black
        w.hasShadow = false
        w.level = .floating
        w.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]
        w.contentView = NSHostingView(rootView: SecondScreenRoot(model: model))
        w.setFrame(screen.frame, display: true)
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self, weak model] _ in
            MainActor.assumeIsolated {
                self?.window = nil
                if let o = self?.closeObserver { NotificationCenter.default.removeObserver(o); self?.closeObserver = nil }
                model?.isSecondScreenOpen = false
            }
        }
        window = w
        model.isSecondScreenOpen = true
        w.makeKeyAndOrderFront(nil)
    }

    func close() { window?.close() }
}

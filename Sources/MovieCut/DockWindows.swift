import SwiftUI
import AppKit
import Combine
@preconcurrency import MovieCutCore

/// 別ウインドウに出したパネルのウインドウ。UndoManager は書類のものを共有する(⌘Z が書類と同じ履歴に効く)。
final class DockPanelWindow: NSWindow {
    weak var model: ProjectModel?
    let panel: DockPanel
    override var undoManager: UndoManager? { MainActor.assumeIsolated { model?.effectiveUndoManager } ?? super.undoManager }
    override var canBecomeMain: Bool { true }

    init(panel: DockPanel, model: ProjectModel) {
        self.panel = panel
        self.model = model
        let size = DockWindowManager.defaultSize(of: panel)
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: true)
        isReleasedWhenClosed = false
        tabbingMode = .disallowed
        minSize = NSSize(width: 240, height: 160)
    }
}

/// 別ウインドウに出すパネルの中身(書類と同じ ProjectModel を見るので、編集もプレビューも同じ状態で動く)。
struct DockPanelWindowRoot: View {
    @ObservedObject var model: ProjectModel
    let panel: DockPanel
    var body: some View {
        DockPanelContent(panel: panel, model: model)
            .background(Color(nsColor: .windowBackgroundColor))
            .preferredColorScheme(.dark)
    }
}

/// 書類ごとに 1 つ。配置(`DockStore`)の `floating` に合わせて、別ウインドウを開き・閉じる。
/// ウインドウを利用者が閉じたら、そのパネルをドッキングに戻す(全書類の同じパネルのウインドウが閉じる)。
@MainActor
final class DockWindowManager {
    private(set) var windows: [DockPanel: DockPanelWindow] = [:]
    private weak var model: ProjectModel?
    private let store: DockStore
    /// false ならウインドウを作るだけで画面に出さない(試験用)。
    private let presents: Bool
    private var cancellable: AnyCancellable?
    private var observers: [DockPanel: [NSObjectProtocol]] = [:]
    private var closingByUs: Set<DockPanel> = []

    init(model: ProjectModel, store: DockStore, presents: Bool = true) {
        self.model = model
        self.store = store
        self.presents = presents
        sync(floating: store.layout.floating)
        // @Published は変更の直前に流れるので、渡された新しい値を使う
        cancellable = store.$layout.dropFirst().sink { [weak self] l in self?.sync(floating: l.floating) }
    }

    static func defaultSize(of p: DockPanel) -> NSSize {
        switch p {
        case .preview: return NSSize(width: 800, height: 520)
        case .timeline: return NSSize(width: 1000, height: 320)
        case .inspector: return NSSize(width: 300, height: 760)
        case .characters: return NSSize(width: 330, height: 640)
        }
    }

    /// キー入力を受けるウインドウ(KeyRouter に渡す)。
    var allWindows: [NSWindow?] { DockPanel.allCases.compactMap { windows[$0] } }
    var hasKeyWindow: Bool { windows.values.contains { $0.isKeyWindow } }

    /// 出すべきパネル(`floating`)にウインドウを合わせる。
    func sync(floating: [DockPanel]) {
        for p in windows.keys where !floating.contains(p) { close(p) }
        for p in floating where windows[p] == nil { open(p) }
    }

    private func open(_ p: DockPanel) {
        guard let model else { return }
        let w = DockPanelWindow(panel: p, model: model)
        w.title = "\(p.title) — \(model.window?.title ?? "Movie Cut")"
        w.contentView = NSHostingView(rootView: DockPanelWindowRoot(model: model, panel: p))
        if presents {
            w.setFrameAutosaveName("MovieCut.dock.\(p.rawValue)")
            if !w.setFrameUsingName(w.frameAutosaveName) { w.center() }
        }
        windows[p] = w
        let nc = NotificationCenter.default
        let closing = nc.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.windowWillClose(p) }
        }
        let main = nc.addObserver(forName: NSWindow.didBecomeMainNotification, object: w, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let m = self?.model { ActiveDocument.shared.activate(m) } }
        }
        observers[p] = [closing, main]
        if presents { w.makeKeyAndOrderFront(nil) }
    }

    /// 利用者が閉じた → ドッキングに戻す。こちらで閉じたときは何もしない。
    private func windowWillClose(_ p: DockPanel) {
        guard !closingByUs.contains(p) else { return }
        forget(p)
        // willClose の最中に配置を変えない(全書類のウインドウが閉じ合う)ので、次の run loop で
        DispatchQueue.main.async { [store] in MainActor.assumeIsolated { store.attach(p) } }
    }

    private func forget(_ p: DockPanel) {
        observers[p]?.forEach { NotificationCenter.default.removeObserver($0) }
        observers[p] = nil
        windows[p]?.contentView = nil
        windows[p] = nil
    }

    private func close(_ p: DockPanel) {
        guard let w = windows[p] else { return }
        closingByUs.insert(p)
        w.close()
        closingByUs.remove(p)
        forget(p)
    }

    /// 書類を閉じるとき。ドッキングへは戻さない(配置はそのまま)。
    func closeAll() {
        cancellable = nil
        for p in Array(windows.keys) { close(p) }
    }
}

extension ProjectModel {
    /// 書類の画面が出たときに 1 回。別ウインドウに出ているパネルがあれば開く。
    @MainActor func installDock(store: DockStore? = nil, presents: Bool = true) {
        guard dockWindows == nil else { return }
        dockWindows = DockWindowManager(model: self, store: store ?? AppServices.panelDock, presents: presents)
    }

    /// 書類のウインドウか、別ウインドウに出したパネルのどれかが前面。
    var isDocumentKeyWindow: Bool {
        window?.isKeyWindow == true || MainActor.assumeIsolated { dockWindows?.hasKeyWindow == true }
    }
}

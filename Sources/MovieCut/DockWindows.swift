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
/// 上に「ウインドウに戻す」(ドッキングへ戻す。戻し先は記録どおり)。
struct DockPanelWindowRoot: View {
    @ObservedObject var model: ProjectModel
    let panel: DockPanel
    let store: DockStore
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer(minLength: 0)
                Button("ウインドウに戻す") { store.attach(panel) }
                    .controlSize(.small)
                    .accessibilityIdentifier("dock-panel-restore")
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            Divider()
            DockPanelContent(panel: panel, model: model)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(.dark)
    }
}

/// タブを掴んで書類のウインドウの外へ引き出す追跡(`DockTearOff` の状態機械を、マウスの位置で動かす)。
/// ドラッグ中だけ 60 Hz で見る。離したら止める。切り離したウインドウはカーソルに付いてくる。
@MainActor
final class DockTearOffTracker {
    private var machine = DockTearOff()
    private var timer: Timer?
    /// 切り離したウインドウの、カーソルからのずれ(左・上)。切り離した瞬間のまま保つ。
    private let grab = NSPoint(x: 60, y: 14)
    private let store: DockStore
    private weak var model: ProjectModel?
    private let place: (DockPanel, NSPoint) -> Void
    private let tearOff: (DockPanel) -> Void

    init(store: DockStore, model: ProjectModel, place: @escaping (DockPanel, NSPoint) -> Void, tearOff: @escaping (DockPanel) -> Void) {
        self.store = store
        self.model = model
        self.place = place
        self.tearOff = tearOff
    }

    func begin(_ p: DockPanel) {
        guard timer == nil else { return }
        machine = DockTearOff()
        machine.press(p, docked: store.layout.location(of: p) == .docked)
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        machine = DockTearOff()
    }

    private func tick() {
        guard let mainWindow = model?.window else { cancel(); return }
        let cursor = NSEvent.mouseLocation
        let down = NSEvent.pressedMouseButtons & 1 != 0
        let overMain = mainWindow.frame.contains(cursor)
        if down {
            switch machine.drag(overMainWindow: overMain) {
            case .none, .redock:
                break
            case .tearOff(let p):
                tearOff(p)
                place(p, NSPoint(x: cursor.x - grab.x, y: cursor.y + grab.y))
            case .follow(let p):
                place(p, NSPoint(x: cursor.x - grab.x, y: cursor.y + grab.y))
            }
        } else {
            let outer = overMain ? Self.outerEdge(of: mainWindow, at: cursor) : nil
            if case .redock(let p, let e) = machine.release(overMainWindow: overMain, outer: outer) {
                store.redock(p, outer: e)
            }
            cancel()
            DockDrag.current = nil
        }
    }

    /// 書類のウインドウの中の、ドック全体の端の帯(`DockDropTarget` と同じ判定)。端でなければ nil。
    static func outerEdge(of window: NSWindow, at screenPoint: NSPoint) -> DockEdge? {
        guard let content = window.contentView else { return nil }
        let inWindow = window.convertPoint(fromScreen: screenPoint)
        let p = content.convert(inWindow, from: nil)
        let w = Double(content.bounds.width), h = Double(content.bounds.height)
        let y = content.isFlipped ? Double(p.y) : h - Double(p.y)
        guard case .outer(let e) = DockDropTarget.resolve(x: Double(p.x), y: y, width: w, height: h,
                                                         groupX: 0, groupY: 0, hostWidth: w, hostHeight: h) else { return nil }
        return e
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
        tearOffTracker = DockTearOffTracker(store: store, model: model,
                                            place: { [weak self] p, origin in self?.windows[p]?.setFrameTopLeftPoint(origin) },
                                            tearOff: { p in store.detach(p) })
        dragObserver = NotificationCenter.default.addObserver(forName: DockDrag.didBegin, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, self.model?.window?.isKeyWindow == true,
                      let raw = note.userInfo?["panel"] as? String, let p = DockPanel(rawValue: raw) else { return }
                self.tearOffTracker?.begin(p)
            }
        }
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

    /// タブのドラッグを切り離しの追跡へつなぐ(書類のウインドウが key のときだけ)。
    private var dragObserver: NSObjectProtocol?
    private var tearOffTracker: DockTearOffTracker?

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
        w.title = "\(L10n.t(p.title)) — \(model.window?.title ?? "Movie Cut")"
        w.contentView = NSHostingView(rootView: DockPanelWindowRoot(model: model, panel: p, store: store))
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
        tearOffTracker?.cancel()
        tearOffTracker = nil
        if let dragObserver { NotificationCenter.default.removeObserver(dragObserver) }
        dragObserver = nil
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

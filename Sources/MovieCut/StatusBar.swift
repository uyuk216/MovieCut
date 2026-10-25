import AppKit
import MovieCutCore

// メニューバー右側の状態アイコン(M7)。ロジック(状態 → メニューの中身)は NSStatusItem から切り離してあり、
// 小さなプロトコル(StatusItemPresenting)の向こうに本物の NSStatusItem を置く。単体テストでは偽物を差す。

// MARK: - 書き出しの進み具合(アプリ全体で 1 つの出どころ)

/// 書き出しの進み具合の共有。ProjectModel.runExport が `begin` / `update` / `end` を呼び、メニューバーのアイコンが見る。
/// ドキュメントごとに書き出せるので、複数あれば一番新しく始めたものを見せる。
@MainActor
final class ExportStatusCenter {
    struct Snapshot: Equatable {
        var fileName: String
        var fraction: Double
    }

    private struct Entry { var fileName: String; var fraction: Double; var cancel: () -> Void }
    private var entries: [(key: ObjectIdentifier, entry: Entry)] = []
    private var observers: [UUID: (Snapshot?) -> Void] = [:]

    /// いま見せる書き出し(無ければ nil)。
    var current: Snapshot? {
        entries.last.map { Snapshot(fileName: $0.entry.fileName, fraction: $0.entry.fraction) }
    }

    func begin(owner: AnyObject, fileName: String, cancel: @escaping () -> Void) {
        let k = ObjectIdentifier(owner)
        entries.removeAll { $0.key == k }
        entries.append((k, Entry(fileName: fileName, fraction: 0, cancel: cancel)))
        notify()
    }

    func update(owner: AnyObject, fraction: Double) {
        let k = ObjectIdentifier(owner)
        guard let i = entries.firstIndex(where: { $0.key == k }) else { return }
        let f = DockProgressController.clamp(fraction)
        guard entries[i].entry.fraction != f else { return }
        entries[i].entry.fraction = f
        notify()
    }

    func end(owner: AnyObject) {
        let k = ObjectIdentifier(owner)
        let before = entries.count
        entries.removeAll { $0.key == k }
        if entries.count != before { notify() }
    }

    /// 見せている書き出しをキャンセルする。
    func cancelCurrent() { entries.last?.entry.cancel() }

    @discardableResult
    func observe(_ f: @escaping (Snapshot?) -> Void) -> UUID {
        let id = UUID()
        observers[id] = f
        return id
    }

    func removeObserver(_ id: UUID) { observers[id] = nil }

    private func notify() {
        let c = current
        for f in observers.values { f(c) }
    }
}

// MARK: - 状態とメニューの中身

enum EngineRunState: Equatable {
    case runningByUs, runningByOther, stopped
}

struct RecentProject: Equatable {
    var name: String
    var url: URL
}

enum StatusAction: Equatable {
    case cancelExport, startEngine, stopEngine
    case openRecent(URL)
    case newDocument, openDocument, showApp, quit
}

/// アイコンのメニューの 1 行(または仕切り)。
enum StatusMenuEntry: Equatable {
    case title(String)
    case action(title: String, StatusAction, enabled: Bool)
    case recents([RecentProject])
    case separator
}

struct StatusBarState: Equatable {
    var export: ExportStatusCenter.Snapshot?
    var engine: EngineRunState = .stopped
    var recents: [RecentProject] = []
    /// VOICEVOX のエンジンの実行ファイルがあるか(無ければ「起動」は押せない)。
    var engineInstalled = true
}

enum StatusMenuBuilder {
    static let appTitle = "Movie Cut"

    static func percent(_ fraction: Double) -> Int { Int(((fraction.isNaN ? 0 : min(1, max(0, fraction))) * 100).rounded()) }

    static func exportLine(_ e: ExportStatusCenter.Snapshot?) -> String {
        guard let e else { return "書き出し: なし" }
        return "書き出し中 \(percent(e.fraction))% — \(e.fileName)"
    }

    /// アイコンの横に出す文字(書き出し中だけ「37%」)。
    static func buttonTitle(_ e: ExportStatusCenter.Snapshot?) -> String {
        guard let e else { return "" }
        return " \(percent(e.fraction))%"
    }

    static func engineLine(_ s: EngineRunState) -> String {
        switch s {
        case .runningByUs: return "VOICEVOX: 起動中（このアプリが起動）"
        case .runningByOther: return "VOICEVOX: 起動中（ほかのアプリが起動）"
        case .stopped: return "VOICEVOX: 停止中"
        }
    }

    static let stopExplanation = "このアプリが起動したエンジンだけ停止できます"

    static func entries(for s: StatusBarState) -> [StatusMenuEntry] {
        var out: [StatusMenuEntry] = [.title(appTitle), .title(exportLine(s.export))]
        if s.export != nil { out.append(.action(title: "キャンセル", .cancelExport, enabled: true)) }
        out.append(.separator)
        out.append(.title(engineLine(s.engine)))
        out.append(.action(title: "起動", .startEngine, enabled: s.engine == .stopped && s.engineInstalled))
        out.append(.action(title: "停止", .stopEngine, enabled: s.engine == .runningByUs))
        if s.engine == .runningByOther { out.append(.title("　" + stopExplanation)) }
        if s.engine == .stopped && !s.engineInstalled { out.append(.title("　VOICEVOX が見つかりません")) }
        out.append(.separator)
        out.append(.recents(s.recents))
        out.append(.action(title: "新規", .newDocument, enabled: true))
        out.append(.action(title: "開く…", .openDocument, enabled: true))
        out.append(.action(title: "Movie Cut を表示", .showApp, enabled: true))
        out.append(.separator)
        out.append(.action(title: "終了", .quit, enabled: true))
        return out
    }

    /// 検証用(MC_DEBUG_STATUS): メニューの中身を字下げなしの行にする。
    static func lines(_ entries: [StatusMenuEntry]) -> [String] {
        entries.flatMap { e -> [String] in
            switch e {
            case .title(let t): return ["[ラベル] \(t)"]
            case .action(let t, let a, let en): return ["\(t)\(en ? "" : "  (無効)")  → \(a)"]
            case .recents(let r):
                if r.isEmpty { return ["最近開いたプロジェクト ▸  (なし・無効)"] }
                return ["最近開いたプロジェクト ▸"] + r.map { "    \($0.name)  → openRecent" }
            case .separator: return ["----"]
            }
        }
    }
}

// MARK: - 設定(表示する / しない)

protocol StatusItemPreferenceStore: AnyObject {
    var isEnabled: Bool { get set }
}

/// 本番: UserDefaults(既定は ON)。
final class UserDefaultsStatusPreference: StatusItemPreferenceStore {
    static let key = "showMenuBarIcon"
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    var isEnabled: Bool {
        get { defaults.object(forKey: Self.key) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.key) }
    }
}

/// 試験・静かな検証用: 保存しない(利用者の設定を書き換えないため)。
final class MemoryStatusPreference: StatusItemPreferenceStore {
    var isEnabled: Bool
    init(_ v: Bool = true) { isEnabled = v }
}

// MARK: - 外とのつなぎ(プロトコル)

/// メニューバーのアイコンの見せ方。本物は NSStatusItem、試験・静かな検証では偽物。
@MainActor
protocol StatusItemPresenting: AnyObject {
    var isVisible: Bool { get set }
    var buttonTitle: String { get set }
    func render(_ entries: [StatusMenuEntry])
    var onAction: ((StatusAction) -> Void)? { get set }
    var onMenuOpen: (() -> Void)? { get set }
    var onMenuClose: (() -> Void)? { get set }
}

/// VOICEVOX が動いているかの確認(GET /version)。
protocol EngineProbing: AnyObject {
    func isAlive() async -> Bool
    var startedByUs: Bool { get }
    var isInstalled: Bool { get }
}

@MainActor
protocol StatusActionHandling: AnyObject {
    func perform(_ action: StatusAction)
}

// MARK: - 本体

@MainActor
final class MenuBarStatusController {
    /// メニューを開いている間に VOICEVOX を確かめる間隔(秒)。
    static let pollInterval: TimeInterval = 3

    private(set) var state = StatusBarState()
    private(set) var entries: [StatusMenuEntry] = []
    let presenter: StatusItemPresenting
    private let export: ExportStatusCenter
    private let probe: EngineProbing
    private let recentURLs: () -> [URL]
    private let preferences: StatusItemPreferenceStore
    private let handler: StatusActionHandling
    private(set) var isMenuOpen = false
    private var lastPoll: Date?
    private var exportObserver: UUID?
    private var pollTask: Task<Void, Never>?
    private var polling = false
    /// 確認の回数(試験用)。
    private(set) var pollCount = 0
    /// 次の確認までの待ち(試験で差し替える)。
    var sleep: (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }

    init(presenter: StatusItemPresenting, export: ExportStatusCenter, probe: EngineProbing, recentURLs: @escaping () -> [URL],
         preferences: StatusItemPreferenceStore, handler: StatusActionHandling) {
        self.presenter = presenter
        self.export = export
        self.probe = probe
        self.recentURLs = recentURLs
        self.preferences = preferences
        self.handler = handler
        presenter.onAction = { [weak self] a in self?.perform(a) }
        presenter.onMenuOpen = { [weak self] in self?.menuWillOpen() }
        presenter.onMenuClose = { [weak self] in self?.menuDidClose() }
    }

    var isEnabled: Bool { preferences.isEnabled }

    /// 起動時に 1 回: 表示の設定を反映し、書き出しの進み具合を見はじめる。
    func start() {
        guard exportObserver == nil else { return }
        exportObserver = export.observe { [weak self] snap in self?.exportChanged(snap) }
        state.export = export.current
        state.engineInstalled = probe.isInstalled
        refreshRecents()
        presenter.isVisible = preferences.isEnabled
        rebuild()
        Task { await self.pollEngine(force: true) }
    }

    /// 「メニューバーアイコンを表示」の切り替え(すぐ反映)。
    func setEnabled(_ on: Bool) {
        preferences.isEnabled = on
        presenter.isVisible = on
        rebuild()
    }

    func exportChanged(_ snap: ExportStatusCenter.Snapshot?) {
        state.export = snap
        rebuild()
    }

    private func refreshRecents() {
        state.recents = recentURLs().map { RecentProject(name: $0.deletingPathExtension().lastPathComponent, url: $0) }
    }

    private func rebuild() {
        entries = StatusMenuBuilder.entries(for: state)
        presenter.buttonTitle = StatusMenuBuilder.buttonTitle(state.export)
        presenter.render(entries)
    }

    // MARK: メニューの開閉

    func menuWillOpen() {
        isMenuOpen = true
        refreshRecents()
        state.engineInstalled = probe.isInstalled
        rebuild()
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            // 開いている間、3 秒ごとに確かめる(閉じたら止まる)。主スレッドは待たせない(確認は async)。
            while let self, self.isMenuOpen, !Task.isCancelled {
                await self.pollEngine(force: false)
                await self.sleep(Self.pollInterval)
            }
        }
    }

    func menuDidClose() {
        isMenuOpen = false
        pollTask?.cancel()
        pollTask = nil
    }

    /// VOICEVOX の状態を確かめる。前回から `pollInterval` 秒たっていなければ何もしない(`force` なら必ず確かめる)。
    /// 確かめたら true。
    @discardableResult
    func pollEngine(force: Bool, now: Date = Date()) async -> Bool {
        if !force, let last = lastPoll, now.timeIntervalSince(last) < Self.pollInterval - 1e-9 { return false }
        guard !polling else { return false }
        polling = true
        lastPoll = now
        pollCount += 1
        let alive = await probe.isAlive()
        polling = false
        applyEngine(alive: alive)
        return true
    }

    func applyEngine(alive: Bool) {
        let s: EngineRunState = alive ? (probe.startedByUs ? .runningByUs : .runningByOther) : .stopped
        guard s != state.engine else { return }
        state.engine = s
        rebuild()
    }

    // MARK: 項目を選んだとき

    func perform(_ a: StatusAction) {
        switch a {
        case .cancelExport: export.cancelCurrent()
        default: handler.perform(a)
        }
    }

    /// 起動・停止のあと、すぐ状態を読み直す。
    func engineCommandFinished() async { await pollEngine(force: true) }
}

// MARK: - 本物

/// 何も表示しない代わり(静かな検証・試験)。NSStatusItem を作らない。
@MainActor
final class NullStatusItemPresenter: StatusItemPresenting {
    var isVisible = false
    var buttonTitle = ""
    private(set) var lastEntries: [StatusMenuEntry] = []
    var onAction: ((StatusAction) -> Void)?
    var onMenuOpen: (() -> Void)?
    var onMenuClose: (() -> Void)?
    func render(_ entries: [StatusMenuEntry]) { lastEntries = entries }
}

/// 本物の NSStatusItem。表示する間だけ作り、隠すときは取り除く。
@MainActor
final class NSStatusItemPresenter: NSObject, StatusItemPresenting, NSMenuDelegate {
    private var item: NSStatusItem?
    private var entries: [StatusMenuEntry] = []
    private let menu = NSMenu()
    var onAction: ((StatusAction) -> Void)?
    var onMenuOpen: (() -> Void)?
    var onMenuClose: (() -> Void)?

    var isVisible: Bool {
        get { item != nil }
        set {
            if newValue, item == nil {
                let it = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                it.button?.image = Self.icon()
                it.button?.imagePosition = .imageLeft
                it.button?.title = buttonTitle
                it.button?.toolTip = "Movie Cut"
                menu.delegate = self
                menu.autoenablesItems = false
                it.menu = menu
                item = it
                fill()
            } else if !newValue, let it = item {
                NSStatusBar.system.removeStatusItem(it)
                item = nil
            }
        }
    }

    var buttonTitle: String = "" {
        didSet { item?.button?.title = buttonTitle }
    }

    /// SF Symbol「film」。無ければ小さな絵を描いた代わり。
    static func icon() -> NSImage {
        let img = NSImage(systemSymbolName: "film", accessibilityDescription: "Movie Cut") ?? {
            let i = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { r in
                NSColor.black.setStroke()
                let p = NSBezierPath(roundedRect: r.insetBy(dx: 2, dy: 3), xRadius: 2, yRadius: 2)
                p.lineWidth = 1.5; p.stroke()
                return true
            }
            return i
        }()
        img.isTemplate = true
        return img
    }

    func render(_ entries: [StatusMenuEntry]) {
        self.entries = entries
        fill()
    }

    private func fill() {
        guard item != nil else { return }
        menu.removeAllItems()
        for e in entries {
            switch e {
            case .separator: menu.addItem(.separator())
            case .title(let t):
                let m = NSMenuItem(title: t, action: nil, keyEquivalent: "")
                m.isEnabled = false
                menu.addItem(m)
            case .action(let t, let a, let en):
                let m = NSMenuItem(title: t, action: #selector(fire(_:)), keyEquivalent: "")
                m.target = self
                m.isEnabled = en
                m.representedObject = Box(a)
                menu.addItem(m)
            case .recents(let r):
                let m = NSMenuItem(title: "最近開いたプロジェクト", action: nil, keyEquivalent: "")
                if r.isEmpty {
                    m.isEnabled = false
                } else {
                    let sub = NSMenu()
                    sub.autoenablesItems = false
                    for p in r {
                        let it = NSMenuItem(title: p.name, action: #selector(fire(_:)), keyEquivalent: "")
                        it.target = self
                        it.representedObject = Box(.openRecent(p.url))
                        sub.addItem(it)
                    }
                    m.submenu = sub
                }
                menu.addItem(m)
            }
        }
    }

    private final class Box: NSObject {
        let action: StatusAction
        init(_ a: StatusAction) { action = a }
    }

    @objc private func fire(_ sender: NSMenuItem) {
        if let b = sender.representedObject as? Box { onAction?(b.action) }
    }

    func menuWillOpen(_ menu: NSMenu) { onMenuOpen?() }
    func menuDidClose(_ menu: NSMenu) { onMenuClose?() }
}

/// VOICEVOX の確認の本物(GET /version は async で、主スレッドを止めない)。
final class VoicevoxProbe: EngineProbing {
    private let engine: VoicevoxEngine
    private let baseURL: () -> String
    init(engine: VoicevoxEngine, baseURL: @escaping () -> String) { self.engine = engine; self.baseURL = baseURL }
    func isAlive() async -> Bool { await VoicevoxEngine.isAlive(baseURL: baseURL(), timeout: 0.8) }
    var startedByUs: Bool { engine.startedByUs }
    var isInstalled: Bool { FileManager.default.isExecutableFile(atPath: engine.binaryPath) }
}

/// 項目を選んだときの本物の処理。
@MainActor
final class AppStatusActions: StatusActionHandling {
    var engine: VoicevoxEngine
    var baseURL: () -> String
    var afterEngineCommand: () async -> Void = {}
    init(engine: VoicevoxEngine, baseURL: @escaping () -> String) { self.engine = engine; self.baseURL = baseURL }

    func perform(_ action: StatusAction) {
        switch action {
        case .startEngine:
            let url = baseURL(), engine = engine
            Task { _ = await engine.ensureRunning(baseURL: url); await self.afterEngineCommand() }
        case .stopEngine:
            let engine = engine
            // 止めるのは自分で起動したものだけ。待ちが入るので主スレッドでは呼ばない
            Task.detached { engine.shutdown(); await self.afterEngineCommand() }
        case .openRecent(let u):
            NSDocumentController.shared.openDocument(withContentsOf: u, display: true) { _, _, _ in }
        case .newDocument: NSApp.activate(ignoringOtherApps: true); NSDocumentController.shared.newDocument(nil)
        case .openDocument: NSApp.activate(ignoringOtherApps: true); NSDocumentController.shared.openDocument(nil)
        case .showApp:
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) })?.makeKeyAndOrderFront(nil)
        case .quit: NSApp.terminate(nil)
        case .cancelExport: break
        }
    }
}

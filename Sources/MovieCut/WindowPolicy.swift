import AppKit
import MovieCutCore

// MARK: - 起動時のウィンドウ数

/// 起動直後の書類 1 つ分の要約(ウィンドウ数の方針を決めるためだけに使う)。
struct LaunchDocInfo: Equatable {
    /// まだファイルに保存されていない(名称未設定)。
    var isUntitled: Bool
    /// 何も編集されていない(未保存の点が付いていない)。
    var isPristine: Bool
    /// 空の名称未設定書類か。
    var isBlankUntitled: Bool { isUntitled && isPristine }
}

/// 起動時のウィンドウ数の方針。
///
/// 背景: SwiftUI の DocumentGroup は、起動のたびに(`AppWindowsController.showInitialWindows`)名称未設定の書類を 1 つ必ず作る。
/// 書類を渡して起動した(ダブルクリック・`open -a`)ときも、前回の状態が復元されるときも同じで、
/// そのあとに「渡された書類」や「復元された書類」が加わるため、ウィンドウが 2 つ以上になっていた。
/// 方針: 中身のある書類(ファイルを開いた・編集済み)が 1 つでもあれば、空の名称未設定は全部閉じる。
/// 中身のある書類が無ければ、空の名称未設定を 1 つだけ残す(= 普通の起動では名称未設定が 1 つ)。
enum LaunchWindowPolicy {
    /// 閉じるべき書類の添字(昇順)。`docs` は `NSDocumentController.documents` の順。
    static func indicesToClose(_ docs: [LaunchDocInfo]) -> [Int] {
        let hasSubstantial = docs.contains { !$0.isBlankUntitled }
        var keptBlank = false
        var out: [Int] = []
        for (i, d) in docs.enumerated() where d.isBlankUntitled {
            if hasSubstantial || keptBlank { out.append(i) } else { keptBlank = true }
        }
        return out
    }
}

/// Dock のアイコンをクリックしたとき(reopen)の方針。
enum ReopenPolicy {
    /// ウィンドウが 1 つも無いときだけ、名称未設定を 1 つ新しく開く。
    /// (SwiftUI の既定は「開く」パネルを出すだけで、Mac 標準の「新規書類」にならない。)
    static func shouldOpenNewDocument(hasVisibleWindows: Bool, documentCount: Int) -> Bool {
        !hasVisibleWindows && documentCount == 0
    }
}

// MARK: - ウィンドウの位置と大きさ

/// ウィンドウの位置・大きさの記憶と、画面の外に出ていないかの補正。
enum WindowFramePolicy {
    /// 書類ウィンドウの最小の中身の大きさ(ContentView の `.frame(minWidth:minHeight:)` と同じ)。
    static let minContentSize = NSSize(width: 1100, height: 700)

    /// 記憶したフレームを、いまの画面の並びに合わせて直す。
    /// - 画面のどれにも十分(幅・高さとも 1/4 以上)かからないときは、いちばん近い画面の中央に置き直す。
    /// - 画面より大きいときは画面に収める。最小の大きさ(`minSize`)は割らない。
    /// - `visibleFrames` が空(画面が取れない)ならそのまま返す。
    static func sanitize(_ frame: NSRect, minSize: NSSize, visibleFrames: [NSRect]) -> NSRect {
        guard !visibleFrames.isEmpty, frame.width.isFinite, frame.height.isFinite, frame.origin.x.isFinite, frame.origin.y.isFinite else {
            return frame
        }
        var f = frame
        f.size.width = max(f.width, minSize.width)
        f.size.height = max(f.height, minSize.height)

        // いちばん重なりの大きい画面
        func overlapArea(_ a: NSRect, _ b: NSRect) -> CGFloat {
            let r = a.intersection(b)
            return r.isNull ? 0 : r.width * r.height
        }
        let best = visibleFrames.max { overlapArea(f, $0) < overlapArea(f, $1) }!
        let o = f.intersection(best)
        let enoughOnScreen = !o.isNull && o.width >= f.width / 4 && o.height >= min(f.height / 4, 100)

        if !enoughOnScreen {
            // 画面から外れている: 画面の中央へ
            let target = visibleFrames.min { dist(f, $0) < dist(f, $1) }!
            f.size.width = min(f.width, max(target.width, minSize.width))
            f.size.height = min(f.height, max(target.height, minSize.height))
            f.origin.x = target.midX - f.width / 2
            f.origin.y = target.midY - f.height / 2
            return f
        }
        // 画面に収まるように(最小の大きさは割らない)
        f.size.width = min(f.width, max(best.width, minSize.width))
        f.size.height = min(f.height, max(best.height, minSize.height))
        f.origin.x = min(max(f.origin.x, best.minX), max(best.minX, best.maxX - f.width))
        // 上端がメニューバーの下に隠れないように
        f.origin.y = min(max(f.origin.y, best.minY), max(best.minY, best.maxY - f.height))
        return f
    }

    private static func dist(_ a: NSRect, _ b: NSRect) -> CGFloat {
        let dx = a.midX - b.midX, dy = a.midY - b.midY
        return (dx * dx + dy * dy).squareRoot()
    }

    // 記憶の置き場(UserDefaults)。書類ごと(ファイルの URL)と、全体の「最後に使った」の 2 段。
    static let lastKey = "windowFrame.last"
    static func key(forDocument url: URL) -> String { "windowFrame.doc." + url.standardizedFileURL.path }

    static func save(_ frame: NSRect, forDocument url: URL?, defaults: UserDefaults = DataLocations.current.defaults) {
        let s = NSStringFromRect(frame)
        defaults.set(s, forKey: lastKey)
        if let url { defaults.set(s, forKey: key(forDocument: url)) }
    }

    /// 書類のフレーム → なければ最後に使ったフレーム → なければ nil。
    static func load(forDocument url: URL?, defaults: UserDefaults = DataLocations.current.defaults) -> NSRect? {
        if let url, let s = defaults.string(forKey: key(forDocument: url)) { return rect(from: s) }
        if let s = defaults.string(forKey: lastKey) { return rect(from: s) }
        return nil
    }

    private static func rect(from s: String) -> NSRect? {
        let r = NSRectFromString(s)
        return (r.width > 0 && r.height > 0) ? r : nil
    }
}

/// 書類ウィンドウ 1 枚ぶんの「位置と大きさの記憶」(最初に window が取れたときに 1 度だけ付ける)。
@MainActor
final class WindowFrameKeeper {
    private static var keepers: [ObjectIdentifier: WindowFrameKeeper] = [:]
    private weak var window: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var pending: DispatchWorkItem?

    /// 何度呼ばれても、同じウィンドウには 1 回しか付けない。
    static func attach(to window: NSWindow) {
        let id = ObjectIdentifier(window)
        guard keepers[id] == nil else { return }
        if DebugHooks.isQuiet {   // 検証の起動は位置を覚えない・触らない(画面の外に置くため)
            window.setFrameOrigin(NSPoint(x: -30000, y: -30000)); window.orderBack(nil); return
        }
        let k = WindowFrameKeeper(window)
        keepers[id] = k
        k.restore()
    }

    /// すべての書類ウィンドウの位置を保存する(終了の直前)。
    static func saveAll() {
        for k in keepers.values { k.saveNow() }
    }

    private init(_ w: NSWindow) {
        window = w
        w.contentMinSize = WindowFramePolicy.minContentSize
        let nc = NotificationCenter.default
        for name in [NSWindow.didMoveNotification, NSWindow.didEndLiveResizeNotification, NSWindow.didResizeNotification] {
            observers.append(nc.addObserver(forName: name, object: w, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleSave() }
            })
        }
        observers.append(nc.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.closing() }
        })
    }

    private var documentURL: URL? {
        window.flatMap { NSDocumentController.shared.document(for: $0)?.fileURL }
    }

    private static var visibleFrames: [NSRect] { NSScreen.screens.map(\.visibleFrame) }

    /// 保存してあるフレームを(画面に合わせて直してから)当てる。書類の記録が無ければ「最後に使った」大きさだけ使う。
    private func restore() {
        guard let w = window, !w.styleMask.contains(.fullScreen) else { return }
        let url = documentURL
        let perDoc = url.flatMap { WindowFramePolicy.load(forDocument: $0, defaults: DataLocations.current.defaults) }
        let hasPerDocRecord = url.map { DataLocations.current.defaults.string(forKey: WindowFramePolicy.key(forDocument: $0)) != nil } ?? false
        guard let saved = perDoc ?? WindowFramePolicy.load(forDocument: nil) else { return }
        var target = saved
        if !hasPerDocRecord {
            // 書類の記録が無い(新規・初めて開く): 大きさだけ受け継ぎ、位置は SwiftUI が決めたもの(重ねて並べる)
            target = NSRect(origin: w.frame.origin, size: saved.size)
        }
        let fixed = WindowFramePolicy.sanitize(target, minSize: Self.minFrameSize(w), visibleFrames: Self.visibleFrames)
        if fixed != w.frame { w.setFrame(fixed, display: true) }
    }

    /// フレームとしての最小の大きさ(タイトルバー分を足す)。
    private static func minFrameSize(_ w: NSWindow) -> NSSize {
        w.frameRect(forContentRect: NSRect(origin: .zero, size: WindowFramePolicy.minContentSize)).size
    }

    private func scheduleSave() {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.saveNow() } }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    func saveNow() {
        pending?.cancel(); pending = nil
        guard let w = window, w.isVisible, !w.styleMask.contains(.fullScreen), !w.isZoomed else { return }
        WindowFramePolicy.save(w.frame, forDocument: documentURL)
    }

    private func closing() {
        saveNow()
        let nc = NotificationCenter.default
        observers.forEach(nc.removeObserver)
        observers = []
        if let w = window { Self.keepers[ObjectIdentifier(w)] = nil }
    }
}

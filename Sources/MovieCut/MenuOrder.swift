import AppKit

/// メニューバーの並びを固定する。SwiftUI は `CommandMenu` を「表示」の後ろに置いてしまう(M5 の結果: 再生が表示の後ろ)ので、
/// 起動後とメニューが組み直されるたびに、トップレベルの項目を決めた順に並べ直す。
/// 順番: ファイル / 編集 / クリップ / 再生 / 移動 / 出力 / 表示 / ウィンドウ / ヘルプ(ヘルプは必ず最後。先頭のアプリメニューはそのまま)。
enum MenuOrder {
    static let desired = ["ファイル", "編集", "クリップ", "再生", "移動", "出力", "表示", "ウィンドウ", "ヘルプ"]
    /// 英語表記のとき(システムの言語が日本語以外)や、macOS の表記ゆれ(ウインドウ)でも並べられるように。
    private static let aliases: [String: String] = ["File": "ファイル", "Edit": "編集", "View": "表示", "Window": "ウィンドウ", "Help": "ヘルプ",
                                                    "ウインドウ": "ウィンドウ",
                                                    "Clip": "クリップ", "Playback": "再生", "Go": "移動", "Output": "出力"]
    private static let windowKey = "ウィンドウ", helpKey = "ヘルプ"

    static func rank(of title: String) -> Int? {
        desired.firstIndex(of: aliases[title] ?? title)
    }

    /// 並べ替えたあとの題の並び(先頭は動かさない)。ヘルプは必ず最後。
    /// 知らない題は、知っている(ヘルプ以外の)ものの後ろ・ヘルプの前に元の順で置く。純粋関数で試せる。
    static func ordered(_ titles: [String]) -> [String] {
        guard titles.count > 1 else { return titles }
        func group(_ t: String, _ offset: Int) -> (Int, Int, Int) {
            guard let r = rank(of: t) else { return (1, 0, offset) }        // 知らない題
            if desired[r] == helpKey { return (2, 0, offset) }              // ヘルプは最後
            return (0, r, offset)                                           // 決めた順
        }
        let rest = Array(titles.dropFirst().enumerated())
        let sorted = rest.sorted { a, b in group(a.element, a.offset) < group(b.element, b.offset) }
        return [titles[0]] + sorted.map(\.element)
    }

    /// トップレベル項目の題(サブメニューの題を優先)。
    static func title(of item: NSMenuItem) -> String {
        if let t = item.submenu?.title, !t.isEmpty { return t }
        return item.title
    }

    /// 並べ替えに使う名前。ウィンドウ / ヘルプは NSApp の windowsMenu / helpMenu と同一かどうかで決める(表記に依らない)。
    @MainActor static func key(of item: NSMenuItem, windowsMenu: NSMenu?, helpMenu: NSMenu?) -> String {
        if let sub = item.submenu {
            if let w = windowsMenu, sub === w { return windowKey }
            if let h = helpMenu, sub === h { return helpKey }
        }
        return title(of: item)
    }

    /// 並べ直す。変えたら true。項目そのもの(サブメニューごと)を移すだけで作り直さない。
    @MainActor @discardableResult
    static func fix(_ menu: NSMenu, windowsMenu: NSMenu? = NSApp?.windowsMenu, helpMenu: NSMenu? = NSApp?.helpMenu) -> Bool {
        let items = menu.items
        let keys = items.map { key(of: $0, windowsMenu: windowsMenu, helpMenu: helpMenu) }
        let want = ordered(keys)
        guard want != keys else { return false }
        // 同じ題が複数あっても壊れないよう、題ごとに先頭から取り出す
        var pool = Array(zip(keys, items))
        var out: [NSMenuItem] = []
        for t in want {
            if let i = pool.firstIndex(where: { $0.0 == t }) { out.append(pool.remove(at: i).1) }
        }
        for it in items.dropFirst() { menu.removeItem(it) }
        for it in out.dropFirst() { menu.addItem(it) }
        return true
    }

    private static var observers: [NSObjectProtocol] = []
    private(set) static var fixCount = 0
    private static var fixing = false
    private static var pending = false

    /// メインメニューが組み直されたらすぐ(次の run loop で)、アプリが更新されるたびにも(軽く)確かめて、崩れていたら直す。
    /// SwiftUI は状態が変わるとメニューの項目を並べ直すことがあるので、項目の追加・削除・変更の通知にも付き合う。
    /// 通知の中ではいじらず、次の run loop に回す(SwiftUI が更新している最中に触らないため)。
    @MainActor static func install(menu: @escaping @MainActor () -> NSMenu? = { NSApp?.mainMenu }) {
        guard observers.isEmpty else { return }
        let nc = NotificationCenter.default
        let structural = [NSMenu.didAddItemNotification, NSMenu.didRemoveItemNotification, NSMenu.didChangeItemNotification]
        for name in structural {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { n in
                MainActor.assumeIsolated {
                    guard !fixing, !pending, let m = menu(), (n.object as? NSMenu) === m else { return }
                    pending = true
                    DispatchQueue.main.async { MainActor.assumeIsolated { pending = false; fixMenu(menu()) } }
                }
            })
        }
        observers.append(nc.addObserver(forName: NSApplication.didUpdateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { fixMenu(menu()) }
        })
        fixMenu(menu())
    }

    /// 試験用: 監視を外す。
    @MainActor static func uninstall() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []; pending = false; fixing = false
    }

    @MainActor @discardableResult
    static func fixMenu(_ m: NSMenu?) -> Bool {
        guard let m, !fixing else { return false }
        fixing = true
        defer { fixing = false }
        guard fix(m) else { return false }
        fixCount += 1
        return true
    }

    @MainActor @discardableResult
    static func fixMainMenu() -> Bool { fixMenu(NSApp?.mainMenu) }
}

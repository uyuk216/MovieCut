import SwiftUI
import AppKit
import MovieCutCore

/// 起動と終了の面倒を見る。終了時に VOICEVOX エンジン(自分で起動したもの)を止める。
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        AppWindowPolicy.disableTabbing()
        DebugHooks.enterQuietModeIfNeeded()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 前の起動が残した再生用の一時ファイル(1 日より古いもの)を消す
        DispatchQueue.global(qos: .utility).async { PlaybackTempFiles.removeStale() }
        // メニューの並び(クリップ / 再生 / 移動 を表示の前へ)
        MainActor.assumeIsolated {
            MenuOrder.install()
        }
        DebugHooks.trace("applicationDidFinishLaunching docs=\(NSDocumentController.shared.documents.count) windows=\(NSApp.windows.count)")
        // 書類を渡して起動された(ダブルクリック・open -a file)ときは、SwiftUI が作った空の名称未設定をすぐ閉じる
        let launchedWithDocuments = NSAppleEventManager.shared().currentAppleEvent?.eventID == AEEventID(kAEOpenDocuments)
        Self.settleLaunchWindows(closeAllBlank: launchedWithDocuments)
        // 状態の復元や、渡された書類は少し遅れて届くので、起動直後の数秒だけ数え直す
        for delay in [0.3, 0.8, 1.6, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { Self.settleLaunchWindows(closeAllBlank: false) }
        }
        // 起動時の画面(最近使ったプロジェクト)。状態の復元や渡された書類が届いたあとで 1 回だけ判断する
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            MainActor.assumeIsolated { WelcomeWindow.showAtLaunchIfNeeded(launchedWithDocuments: launchedWithDocuments) }
        }
        DebugHooks.shared.appDidLaunch()
        // 配布版だけ、アップデートの自動確認を始める(個人版・鍵なしの試作では何もしない)
        MainActor.assumeIsolated { AppUpdater.shared.start() }
        // 異常終了で残った自動保存の写しがあれば、復元するかを聞く(静かな検証では聞かない)
        if !DebugHooks.isQuiet {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { MainActor.assumeIsolated { RecoveryPrompt.offerIfNeeded() } }
        }
    }

    /// 起動時のウィンドウ数を整える(方針は `LaunchWindowPolicy`)。
    static func settleLaunchWindows(closeAllBlank: Bool) {
        let docs = NSDocumentController.shared.documents
        let infos = docs.map { LaunchDocInfo(isUntitled: $0.fileURL == nil, isPristine: !$0.isDocumentEdited) }
        var close = LaunchWindowPolicy.indicesToClose(infos)
        if closeAllBlank { close = infos.indices.filter { infos[$0].isBlankUntitled } }
        guard !close.isEmpty else { return }
        DebugHooks.trace("settleLaunchWindows closing \(close) of \(infos.count)")
        for i in close.reversed() { docs[i].close() }
    }

    /// 名称未設定の書類を作るのは SwiftUI だが、Dock のクリックでウィンドウが 0 のときは「開く」パネルしか出さないので、
    /// Mac 標準どおり新しい書類を 1 つ開く。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        DebugHooks.trace("applicationShouldHandleReopen visible=\(flag) docs=\(NSDocumentController.shared.documents.count)")
        if ReopenPolicy.shouldOpenNewDocument(hasVisibleWindows: flag, documentCount: NSDocumentController.shared.documents.count) {
            NSDocumentController.shared.newDocument(nil)
            return false
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { WindowFrameKeeper.saveAll() }
        PlaybackTempFiles.removeCurrent()
        if HangWatch.enabled { HangWatch.shared.printSummary() }
        DebugHooks.logQuit(engineStartedByUs: AppServices.engine.startedByUs)
        AppServices.engine.shutdown()
        DebugHooks.logQuit(engineStartedByUs: AppServices.engine.startedByUs, after: true)
    }

    /// Dock のアイコンを右クリックしたときのメニュー(menu.js dockMenu と同じ: 新規 / 開く…)。
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? { makeDockMenu() }

    func makeDockMenu() -> NSMenu {
        let m = NSMenu()
        let new = NSMenuItem(title: "新規", action: #selector(dockNew), keyEquivalent: "")
        let open = NSMenuItem(title: "開く…", action: #selector(dockOpen), keyEquivalent: "")
        new.target = self; open.target = self
        m.addItem(new); m.addItem(open)
        return m
    }

    @objc func dockNew() { NSDocumentController.shared.newDocument(nil) }
    @objc func dockOpen() { NSDocumentController.shared.openDocument(nil) }
}

/// ウィンドウのタブ機能は使わない。
/// 理由: 書類ウィンドウをタブにまとめたあとでタブをドラッグすると、スピニングカーソル(ビーチボール)が出て固まることがあったため。
/// 1 つの書類 = 1 つのウィンドウだけにして、ウィンドウメニューの「タブバーを表示」「すべてのウインドウを結合」なども出さない。
enum AppWindowPolicy {
    /// 最初のウィンドウより前に呼ぶ(App.init と applicationWillFinishLaunching の両方から)。
    static func disableTabbing() {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    /// 書類ウィンドウごとに、タブにまとめられないようにする。
    static func apply(to window: NSWindow) {
        window.tabbingMode = .disallowed
        MainActor.assumeIsolated { WindowFrameKeeper.attach(to: window) }
    }
}

@main
struct MovieCutApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    init() {
        AppWindowPolicy.disableTabbing()
        DebugHooks.suppressStateRestorationIfDebugging()
        // 利用者が追加したフォントを登録し、テキストのフォント一覧に出す(Application Support/MovieCut/Fonts)
        let fontDir = FontLibrary.defaultDirectory()
        FontLibrary.registerAll(in: fontDir)
        FontChoices.userFamilies = FontLibrary.families(in: fontDir)
    }

    var body: some Scene {
        DocumentGroup(newDocument: { ProjectDocument() }) { file in
            ContentView(model: file.document.model, fileURL: file.fileURL)
        }
        .commands { AppCommands() }
    }
}

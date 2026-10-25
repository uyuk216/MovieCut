import SwiftUI
import AppKit
import MovieCutCore

/// 起動と終了の面倒を見る。終了時に VOICEVOX エンジン(自分で起動したもの)を止める。
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        AppWindowPolicy.disableTabbing()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DebugHooks.shared.appDidLaunch()
    }

    func applicationWillTerminate(_ notification: Notification) {
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
    }
}

@main
struct MovieCutApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    init() {
        AppWindowPolicy.disableTabbing()
    }

    var body: some Scene {
        DocumentGroup(newDocument: { ProjectDocument() }) { file in
            ContentView(model: file.document.model, fileURL: file.fileURL)
        }
        .commands { AppCommands() }
    }
}

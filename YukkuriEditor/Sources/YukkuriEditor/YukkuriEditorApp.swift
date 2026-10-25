import SwiftUI
import AppKit
import YukkuriCore

/// 起動と終了の面倒を見る。終了時に VOICEVOX エンジン(自分で起動したもの)を止める。
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        DebugHooks.shared.appDidLaunch()
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppServices.engine.shutdown()
    }
}

@main
struct YukkuriEditorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        DocumentGroup(newDocument: { ProjectDocument() }) { file in
            ContentView(model: file.document.model, fileURL: file.fileURL)
        }
    }
}

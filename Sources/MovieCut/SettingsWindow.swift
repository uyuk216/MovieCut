import SwiftUI
import AppKit
import MovieCutCore

/// 設定の独立ウィンドウ。プロジェクトウィンドウのシートではなく、常に単独のウィンドウとして出す
/// (プロジェクトが無くても開け、プロジェクトの開閉・切り替えの影響を受けない)。
/// beginSheet は使わない。
@MainActor
enum SettingsWindowController {
    private static var window: NSWindow?
    /// 表示要求の回数(テスト・デバッグ用の印。実ウィンドウを出さない検証でも数える)。
    private(set) static var showRequestCount = 0

    /// true の間は実ウィンドウを作らない(単体テスト用。要求の回数だけ数える)。
    static var suppressWindow = false

    /// 設定ウィンドウを出す(あれば前面へ)。`present: false` は要求だけ数えて実ウィンドウを作らない(テスト・静かな検証用)。
    static func show(present: Bool = true) {
        showRequestCount += 1
        guard present, !suppressWindow else { return }
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            return
        }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 720), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = L10n.t("設定")
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: SettingsView())
        w.contentMinSize = NSSize(width: 600, height: 360)
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
    }
}

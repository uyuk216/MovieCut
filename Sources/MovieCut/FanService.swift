import SwiftUI
import AppKit
import MovieCutCore

/// 書き出し中のファン最大化(アプリ側)。設定の保持、使えるかどうかの検出、書き出しの開始・終了・中断での FanGuard の面倒、
/// ヘルパーのインストール(管理者権限の確認つき)をまとめる。実際の判断は Core の FanGuard / FanModelPolicy にあり、ここは薄く保つ。
@MainActor
final class FanService: ObservableObject {
    static let defaultsKey = "fanMaxDuringExport"

    /// nil = まだ調べていない。
    @Published private(set) var availability: FanAvailability?
    @Published private(set) var enabled: Bool
    /// 書き出しシートとツールバーに出す 1 行(「ファン: 最大(6550 rpm)」「ファン: 自動」)。使っていないときは空。
    @Published private(set) var statusLine = ""
    /// 温度の上限などのお知らせ(書き出しシートに出す)。
    @Published private(set) var notice = ""
    @Published private(set) var helperInstalled = false
    @Published private(set) var busy = false

    private let defaults: UserDefaults?
    private var activeGuard: FanGuard?
    private let signals = FanSignalHandlers()
    /// 静かな検証(MC_DEBUG_*)や試験で差し替える。nil なら FanControlCenter を使う。
    var prepare: (Bool, ((FanGuard.Event) -> Void)?) -> (availability: FanAvailability, guard: FanGuard?) = { enabled, onEvent in
        FanControlCenter.prepare(enabled: enabled, onEvent: onEvent)
    }
    var onChange: () -> Void = { ActiveDocument.shared.refresh() }

    init(defaults: UserDefaults? = DebugHooks.isQuiet ? nil : .standard) {
        self.defaults = defaults
        self.enabled = defaults?.bool(forKey: Self.defaultsKey) ?? false
        self.helperInstalled = FileManager.default.fileExists(atPath: FanHelperInstaller.installedBinary)
    }

    // MARK: 設定と検出

    /// 使えるときだけ変えられる(使えないのにオンにしない)。オフにするのはいつでもできる。
    func setEnabled(_ on: Bool) {
        if on && availability?.isAvailable != true { return }
        enabled = on
        defaults?.set(on, forKey: Self.defaultsKey)
        onChange()
    }

    /// 機種とサービスを調べ直す(バックグラウンド。system_profiler と HTTP を使うので数百 ms かかる)。
    func refresh() {
        helperInstalled = FileManager.default.fileExists(atPath: FanHelperInstaller.installedBinary)
        let prep = prepare
        Task {
            let a = await Task.detached { prep(false, nil).availability }.value
            self.availability = a
            if !a.isAvailable, self.enabled { self.enabled = false; self.defaults?.set(false, forKey: Self.defaultsKey) }
            self.onChange()
        }
    }

    /// 設定画面に出す 1 行の理由(使えるときは nil)。
    var reason: String? { availability?.reason }
    var isAvailable: Bool { availability?.isAvailable == true }
    /// 機種が対象か(インストールの案内を出してよいか)。
    var machineSupported: Bool { availability != .unsupportedMachine }

    // MARK: 書き出しの前後

    /// 書き出しを始める直前。オンで使えるなら最大にする(ブロックしないようバックグラウンドで)。
    func beginExport() async {
        notice = ""
        statusLine = ""
        guard enabled else { return }
        let prep = prepare
        let enabledNow = enabled
        let handler: (FanGuard.Event) -> Void = { [weak self] ev in Task { @MainActor in self?.handle(ev) } }
        let result: (FanAvailability, FanGuard?, FanGuard.EngageResult?) = await Task.detached {
            let p = prep(enabledNow, handler)
            return (p.availability, p.guard, p.guard?.engage())
        }.value
        availability = result.0
        guard let g = result.1, let r = result.2 else { onChange(); return }
        switch r {
        case .engaged(let rpm):
            activeGuard = g
            statusLine = FanControlCenter.statusLine(maximumRPM: rpm)
        case .skipped(let why):
            notice = "ファンは自動のままです: \(why)"
        case .failed(let why):
            notice = "ファンを最大にできませんでした(自動のままです): \(why)"
        }
        onChange()
    }

    /// FanGuard からの通知(温度の上限での解放など。バックグラウンドから届くのでメインに戻して受ける)。
    private func handle(_ ev: FanGuard.Event) {
        switch ev {
        case .notice(let m): notice = m
        case .released(.overTemperature): statusLine = FanControlCenter.autoStatusLine
        default: break
        }
        onChange()
    }

    /// 書き出しの終了・中断・失敗。必ず自動に戻す。
    func endExport(_ reason: FanGuard.ReleaseReason) async {
        guard let g = activeGuard else { return }
        activeGuard = nil
        let ok = await Task.detached { g.release(reason) }.value
        if ok { statusLine = FanControlCenter.autoStatusLine }
        else { statusLine = "ファン: 自動に戻せません"; notice = "ファンを自動に戻せませんでした。Movie Cut を終了すると再試行します" }
        onChange()
    }

    /// アプリ終了・SIGTERM/SIGINT。生きている FanGuard をすべて自動に戻す。
    func releaseAllNow(_ reason: FanGuard.ReleaseReason) {
        FanGuardRegistry.shared.releaseAll(reason)
    }

    /// 起動時に 1 度。シグナルで終了されるときも自動に戻す。
    func installSignalHandlers() {
        signals.install { FanGuardRegistry.shared.releaseAll(.signal) }
    }

    // MARK: ヘルパーのインストール / 削除(管理者権限)

    static var bundledHelperURL: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/moviecut-fanhelper") }
    static var bundledPlistURL: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/com.moviecut.fanhelper.plist") }

    func install() {
        guard !busy else { return }
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: Self.bundledHelperURL.path), fm.fileExists(atPath: Self.bundledPlistURL.path) else {
            Self.alert("この Movie Cut にはファン制御ヘルパーが入っていません", "配布版のアプリからインストールしてください。")
            return
        }
        let ok = Self.confirm(
            title: "ファン制御サービスを有効にしますか?",
            message: "書き出し中にファンを最大にするため、バックグラウンドのサービス(com.moviecut.fanhelper)を Mac に追加します。管理者のパスワードが必要です。\n\n・/usr/local/libexec にプログラム、/Library/LaunchDaemons に設定ファイルが置かれます\n・Mac の起動時に自動で開始し、ファンの制御だけを行います(127.0.0.1 からの要求のみ)\n・Movie Cut が応答しなくなると、ヘルパーが約 15 秒でファンを自動に戻します\n・「出力 ▸ ファン制御を無効にする…」でいつでも削除できます",
            button: "有効にする…")
        guard ok else { return }
        run(FanHelperInstaller.installScript(helperSource: Self.bundledHelperURL.path, plistSource: Self.bundledPlistURL.path), done: "ファン制御サービスを有効にしました")
    }

    func uninstall() {
        guard !busy else { return }
        guard Self.confirm(title: "ファン制御サービスを無効にしますか?",
                           message: "バックグラウンドのサービスを止めて削除します(止まるとき、ファンは自動に戻ります)。管理者のパスワードが必要です。",
                           button: "無効にする…") else { return }
        run(FanHelperInstaller.uninstallScript(), done: "ファン制御サービスを無効にしました")
    }

    private func run(_ shell: String, done: String) {
        busy = true
        let source = FanHelperInstaller.appleScript(shell: shell)
        Task {
            // NSAppleScript は管理者パスワードのダイアログを出して待つので、メインを塞がないよう別スレッドで実行する
            let error: String? = await Task.detached {
                var info: NSDictionary?
                _ = NSAppleScript(source: source)?.executeAndReturnError(&info)
                return (info?[NSAppleScript.errorMessage] as? String) ?? (info != nil ? "実行できませんでした" : nil)
            }.value
            busy = false
            // 少し待ってから(サービスの起動を待つ)調べ直す
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            refresh()
            if let error {
                if !error.contains("User canceled") && !error.contains("ユーザによってキャンセル") { Self.alert("ファン制御サービスを設定できませんでした", error) }
            } else {
                Self.alert(done, "")
            }
        }
    }

    private static func confirm(title: String, message: String, button: String) -> Bool {
        let a = NSAlert()
        a.messageText = title; a.informativeText = message
        a.addButton(withTitle: button); a.addButton(withTitle: "キャンセル")
        return a.runModal() == .alertFirstButtonReturn
    }

    private static func alert(_ title: String, _ message: String) {
        let a = NSAlert()
        a.messageText = title; a.informativeText = message
        a.runModal()
    }
}

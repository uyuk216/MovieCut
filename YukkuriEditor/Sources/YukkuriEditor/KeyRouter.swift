import AppKit

/// ウィンドウ全体のキー操作。入力欄にフォーカスがあるときは何もしない(台本やシートの入力を壊さない)。
enum KeyCommand: Hashable {
    case playPause, stepBack, stepForward, toStart
    /// M4 で使う(いまは割り当てだけ。ハンドラが無ければキーはそのまま素通りする)。
    case split, delete
}

@MainActor
final class KeyRouter {
    /// キーコード → コマンド(US/JIS 共通の仮想キーコード)。
    static let keyMap: [UInt16: KeyCommand] = [
        49: .playPause,        // Space
        123: .stepBack,        // ←
        124: .stepForward,     // →
        115: .toStart,         // Home
        1: .split,             // S
        51: .delete,           // Delete(Backspace)
        117: .delete,          // Forward Delete
    ]

    /// テキスト入力中か(NSText / NSTextView / NSTextField のフィールドエディタ、NSTextInputClient)。
    static func isTextInput(_ responder: NSResponder?) -> Bool {
        guard let r = responder else { return false }
        return r is NSText || r is NSTextField || r is NSTextInputClient
    }

    /// Command / Option / Control が押されていなければ OK(Shift は許す。矢印キーの numericPad / function フラグは無視)。
    static func hasBlockingModifier(_ flags: NSEvent.ModifierFlags) -> Bool {
        !flags.intersection([.command, .option, .control]).isEmpty
    }

    /// このキーをコマンドとして扱うか。入力欄・修飾キーのときは nil。
    static func command(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, firstResponder: NSResponder?) -> KeyCommand? {
        guard !hasBlockingModifier(modifiers), !isTextInput(firstResponder) else { return nil }
        return keyMap[keyCode]
    }

    /// コマンドごとの処理。true を返すとキーを消費する。
    var handlers: [KeyCommand: () -> Bool] = [:]
    /// このルーターが受け持つウィンドウ(第二画面も含められる)。
    var windows: () -> [NSWindow?] = { [] }
    private var monitor: Any?

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return MainActor.assumeIsolated { self.handle(event) ? nil : event }
        }
    }

    func uninstall() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
    }

    deinit { if let m = monitor { NSEvent.removeMonitor(m) } }

    /// 受け持つウィンドウのキー入力だけ処理する(他のドキュメントやシートのものは触らない)。
    func handle(_ event: NSEvent) -> Bool {
        guard let w = event.window, windows().contains(where: { $0 === w }) else { return false }
        return dispatch(keyCode: event.keyCode, modifiers: event.modifierFlags, firstResponder: w.firstResponder, isRepeat: event.isARepeat)
    }

    /// テストしやすいよう、イベントから切り離した入口。
    @discardableResult
    func dispatch(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, firstResponder: NSResponder?, isRepeat: Bool = false) -> Bool {
        guard let cmd = Self.command(keyCode: keyCode, modifiers: modifiers, firstResponder: firstResponder),
              let h = handlers[cmd] else { return false }
        // Space の長押しで再生/停止が連打されないようにする(矢印のコマ送りは長押しで続ける)
        if isRepeat && (cmd == .playPause || cmd == .toStart) { return true }
        return h()
    }
}

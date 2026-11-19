import AppKit

/// ウィンドウ全体のキー操作。入力欄にフォーカスがあるときは何もしない(台本やシートの入力を壊さない)。
enum KeyCommand: Hashable, CaseIterable {
    case playPause, stepBack, stepForward, toStart, toEnd
    /// S = 分割、Delete / Backspace = 削除、Escape = 選択を外す(ハンドラが無ければキーはそのまま素通りする)。
    case split, delete, deselect
    /// ⌘= (US 配列の「⌘+」の押し方)。メニューの ⌘+ とは別に、キーボードの = でも拡大できるようにする。
    case zoomIn
    /// J = 逆へ(遅く)、K = 停止、L = 速く(順 1 倍 / 2 倍 / 4 倍)。素のキーで、メニューのショートカットにはしない。
    case shuttleBack, shuttleStop, shuttleForward
    /// Premiere互換プリセットでだけ割り当てる通常キー(既定ではキーなし。上書きが付いたときだけ効く)。
    /// I = 書き出し開始、O = 書き出し終了、Q = 頭のリップルトリム、W = 尻のリップルトリム(Premiere Pro と同じ並び)。
    case markIn, markOut, rippleHead, rippleTail
}

@MainActor
final class KeyRouter {
    /// キーコード → コマンド(US/JIS 共通の仮想キーコード)。
    static let keyMap: [UInt16: KeyCommand] = [
        49: .playPause,        // Space
        123: .stepBack,        // ←
        124: .stepForward,     // →
        115: .toStart,         // Home
        119: .toEnd,           // End
        1: .split,             // S
        51: .delete,           // Delete(Backspace)
        117: .delete,          // Forward Delete
        53: .deselect,         // Escape
        38: .shuttleBack,      // J
        40: .shuttleStop,      // K
        37: .shuttleForward,   // L
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

    /// 既定の対応をコマンド別に見たもの(削除は ⌫ と ⌦ の両方)。
    static let defaultKeyCodes: [KeyCommand: [UInt16]] = [
        .playPause: [49], .stepBack: [123], .stepForward: [124], .toStart: [115], .toEnd: [119],
        .split: [1], .delete: [51, 117], .deselect: [53],
        .shuttleBack: [38], .shuttleStop: [40], .shuttleForward: [37],
    ]

    /// ショートカットの上書きの置き場(テストでは差し替える)。
    static var shortcutStore: ShortcutStore = .shared

    /// 上書きを反映した実効の対応表(キーコード → コマンド)。
    /// 上書きされたコマンドの既定キーは外れ、上書きで指定されたキーは元の持ち主から移る。
    static func effectiveKeyMap(store: ShortcutStore) -> [UInt16: KeyCommand] {
        var map: [UInt16: KeyCommand] = [:]
        for cmd in KeyCommand.allCases where store.plainOverride(for: cmd) == nil {
            for code in defaultKeyCodes[cmd] ?? [] { map[code] = cmd }
        }
        for cmd in KeyCommand.allCases {
            if let b = store.plainOverride(for: cmd) { map[b.keyCode] = cmd }
        }
        return map
    }

    /// キー入力 → コマンド。FirstResponder がテキスト入力中、または対象外のウインドウでは nil。
    static func command(keyCode: UInt16, modifiers: NSEvent.ModifierFlags,
                        firstResponder: NSResponder?) -> KeyCommand? {
        guard !hasBlockingModifier(modifiers), !isTextInput(firstResponder) else { return nil }
        return effectiveKeyMap(store: shortcutStore)[keyCode]
    }

    /// ⌘= か ⌘+(Shift は許す)か。配列によって「+」の押し方が違うので、文字で見る。
    static func isCommandEquals(modifiers: NSEvent.ModifierFlags, charactersIgnoringModifiers: String?, characters: String? = nil) -> Bool {
        guard modifiers.intersection([.command, .option, .control]) == .command else { return false }
        return charactersIgnoringModifiers == "=" || charactersIgnoringModifiers == "+" || characters == "+"
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
            nonisolated(unsafe) let e = event
            let consumed = MainActor.assumeIsolated { self.handle(e) }
            return consumed ? nil : event
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
        if Self.isCommandEquals(modifiers: event.modifierFlags, charactersIgnoringModifiers: event.charactersIgnoringModifiers, characters: event.characters), let h = handlers[.zoomIn] { return h() }
        return dispatch(keyCode: event.keyCode, modifiers: event.modifierFlags, firstResponder: w.firstResponder, isRepeat: event.isARepeat)
    }

    /// テストしやすいよう、イベントから切り離した入口。
    @discardableResult
    func dispatch(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, firstResponder: NSResponder?, isRepeat: Bool = false) -> Bool {
        guard let cmd = Self.command(keyCode: keyCode, modifiers: modifiers, firstResponder: firstResponder),
              let h = handlers[cmd] else { return false }
        // Space の長押しで再生/停止が連打されないようにする(矢印のコマ送りは長押しで続ける)
        if isRepeat && (cmd == .playPause || cmd == .toStart || cmd == .toEnd || cmd == .shuttleBack || cmd == .shuttleStop || cmd == .shuttleForward) { return true }
        return h()
    }
}

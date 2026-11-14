import Foundation
import SwiftUI
import AppKit

/// キーボードショートカットの上書き(カスタマイズ)の置き場。UserDefaults に JSON で保存する。
/// - メニューの項目: コマンド ID(`id(for:)`)→ `MenuShortcut`。`MenuItemView` が項目表の値より優先して使う。
/// - 通常キー(KeyRouter): コマンド名 → (キーコード, 表示名)。`KeyRouter.effectiveKeyMap` が既定と合成する。
/// 変えたら `ActiveDocument` を更新して、開いているメニューを作り直させる。
/// 既存の読み取り専用の一覧(`ShortcutList.menuRows` / `plainKeys`)は項目表そのままなので、ここでは触らない。
final class ShortcutStore: ObservableObject {
    static let shared = ShortcutStore()

    /// 通常キー 1 件の上書き。
    struct PlainBinding: Equatable, Codable {
        var keyCode: UInt16
        var display: String
    }

    private struct MenuEntry: Codable { var key: String; var modifiers: Int }
    private struct PlainEntry: Codable { var keyCode: UInt16; var display: String }

    private let defaults: UserDefaults
    private static let menuKey = "shortcut.menuOverrides.v1"
    private static let plainKey = "shortcut.plainOverrides.v1"

    @Published private(set) var menuOverrides: [String: MenuShortcut] = [:]
    @Published private(set) var plainOverrides: [String: PlainBinding] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.menuKey),
           let raw = try? JSONDecoder().decode([String: MenuEntry].self, from: data) {
            menuOverrides = raw.compactMapValues { e in
                guard let ch = e.key.first else { return nil }
                return MenuShortcut(key: KeyEquivalent(ch), modifiers: EventModifiers(rawValue: e.modifiers))
            }
        }
        if let data = defaults.data(forKey: Self.plainKey),
           let raw = try? JSONDecoder().decode([String: PlainEntry].self, from: data) {
            plainOverrides = raw.mapValues { PlainBinding(keyCode: $0.keyCode, display: $0.display) }
        }
    }

    /// メニュー項目のコマンド ID。関連値の無いケースはケース名、その他は値まで含めた文字列表現(決定的)。
    static func id(for command: MenuCommand) -> String { String(describing: command) }

    // MARK: メニューの項目

    func menuOverride(for id: String) -> MenuShortcut? { menuOverrides[id] }

    func setMenuOverride(_ shortcut: MenuShortcut?, for id: String) {
        if let shortcut { menuOverrides[id] = shortcut } else { menuOverrides.removeValue(forKey: id) }
        save()
    }

    // MARK: 通常キー

    func plainOverride(for command: KeyCommand) -> PlainBinding? { plainOverrides[String(describing: command)] }

    func setPlainOverride(_ binding: PlainBinding?, for command: KeyCommand) {
        let id = String(describing: command)
        if let binding { plainOverrides[id] = binding } else { plainOverrides.removeValue(forKey: id) }
        save()
    }

    // MARK: 全部戻す

    func resetAll() {
        menuOverrides = [:]
        plainOverrides = [:]
        save()
    }

    var hasAnyOverride: Bool { !menuOverrides.isEmpty || !plainOverrides.isEmpty }

    private func save() {
        let menu = menuOverrides.mapValues { MenuEntry(key: String($0.key), modifiers: $0.modifiersRaw) }
        if let data = try? JSONEncoder().encode(menu) { defaults.set(data, forKey: Self.menuKey) }
        let plain = plainOverrides.mapValues { PlainEntry(keyCode: $0.keyCode, display: $0.display) }
        if let data = try? JSONEncoder().encode(plain) { defaults.set(data, forKey: Self.plainKey) }
        Task { @MainActor in ActiveDocument.shared.refresh() }
    }

    // MARK: キー入力の変換

    /// NSEvent の修飾キー → メニューのショートカットの修飾キー。
    static func eventModifiers(_ flags: NSEvent.ModifierFlags) -> EventModifiers {
        var m: EventModifiers = []
        if flags.contains(.command) { m.insert(.command) }
        if flags.contains(.option) { m.insert(.option) }
        if flags.contains(.shift) { m.insert(.shift) }
        if flags.contains(.control) { m.insert(.control) }
        return m
    }

    /// キーコードの表示名(特殊キー)。それ以外は押した文字を使う。
    static func keyDisplay(keyCode: UInt16, characters: String?) -> String {
        switch keyCode {
        case 49: return "Space"
        case 123: return "←"
        case 124: return "→"
        case 126: return "↑"
        case 125: return "↓"
        case 115: return "Home"
        case 119: return "End"
        case 51: return "⌫"
        case 117: return "⌦"
        case 53: return "Esc"
        case 36: return "⏎"
        case 48: return "Tab"
        default:
            if let c = characters?.first, !c.isWhitespace { return String(c).uppercased() }
            return "Key\(keyCode)"
        }
    }
}

/// ショートカットの記録中だけ、キー入力を横取りする(ローカルモニタ。ボタン等のキー処理より先に受ける)。
@MainActor
final class ShortcutCapture {
    struct Captured {
        var keyCode: UInt16
        var characters: String?
        var modifiers: NSEvent.ModifierFlags
    }

    private var monitor: Any?
    private weak var window: NSWindow?
    var onCapture: ((Captured) -> Void)?

    func start() {
        stop()
        window = NSApp.keyWindow
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self else { return e }
            if let w = self.window, e.window !== w { return e }
            let c = Captured(keyCode: e.keyCode, characters: e.charactersIgnoringModifiers, modifiers: e.modifierFlags)
            let cb = self.onCapture
            self.stop()
            cb?(c)
            return nil
        }
    }

    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }

    deinit { if let m = monitor { NSEvent.removeMonitor(m) } }
}

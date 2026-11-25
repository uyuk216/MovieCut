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
        if let binding {
            plainOverrides[id] = binding
            // 同じキーを持つ他のコマンドからは外す(最後に割り当てたコマンドが勝つ)
            for k in Array(plainOverrides.keys) where k != id && plainOverrides[k]?.keyCode == binding.keyCode {
                plainOverrides.removeValue(forKey: k)
            }
        } else { plainOverrides.removeValue(forKey: id) }
        save()
    }

    // MARK: Premiere互換プリセット

    private static let backupKey = "shortcut.prePresetBackup.v1"
    private struct Backup: Codable { var menu: [String: MenuEntry]; var plain: [String: PlainEntry] }

    /// プリセットの通常キー(Premiere Pro の主要キー割り当て)。J/K/L・Space・矢印は既定の時点で Premiere と同じなので含めない。
    static let premierePlain: [(command: KeyCommand, keyCode: UInt16, display: String)] = [
        (.split, 8, "C"),        // レーザーツールで分割
        (.markIn, 34, "I"),      // イン点(書き出し開始)
        (.markOut, 31, "O"),     // アウト点(書き出し終了)
        (.rippleHead, 12, "Q"),  // 再生位置までリップルトリム(頭)
        (.rippleTail, 13, "W"),  // 再生位置までリップルトリム(尻)
    ]

    /// プリセットのメニューの項目。
    static let premiereMenu: [(command: MenuCommand, shortcut: MenuShortcut)] = [
        (.split, MenuShortcut(key: "k", modifiers: [.command])),           // 編集点を追加
        (.rippleDelete, MenuShortcut(key: .delete, modifiers: [.shift])),  // リップル削除
    ]

    /// プリセット適用前の控えがあるか。
    var hasPrePresetBackup: Bool { defaults.data(forKey: Self.backupKey) != nil }

    /// プリセットの割り当てがすべて効いているか。
    var isPremierePresetApplied: Bool {
        Self.premierePlain.allSatisfy { plainOverride(for: $0.command) == PlainBinding(keyCode: $0.keyCode, display: $0.display) }
            && Self.premiereMenu.allSatisfy { menuOverride(for: Self.id(for: $0.command)) == $0.shortcut }
    }

    /// プリセットを適用する。書き換えるのはプリセットが触る割り当てだけで、それ以外のカスタムはそのまま残す。
    /// 初めて適用するときだけ、適用前の割り当てを丸ごと控える(下の復元で戻せる)。
    func applyPremierePreset() {
        if !hasPrePresetBackup {
            let backup = Backup(menu: menuOverrides.mapValues { MenuEntry(key: String($0.key), modifiers: $0.modifiersRaw) },
                                plain: plainOverrides.mapValues { PlainEntry(keyCode: $0.keyCode, display: $0.display) })
            if let data = try? JSONEncoder().encode(backup) { defaults.set(data, forKey: Self.backupKey) }
        }
        // setPlainOverride と同じ規則: 同じキー・同じショートカットを持つ他の項目の上書きは外す(重複させない)
        for p in Self.premierePlain {
            let id = String(describing: p.command)
            plainOverrides[id] = PlainBinding(keyCode: p.keyCode, display: p.display)
            for k in Array(plainOverrides.keys) where k != id && plainOverrides[k]?.keyCode == p.keyCode { plainOverrides.removeValue(forKey: k) }
        }
        for m in Self.premiereMenu {
            let id = Self.id(for: m.command)
            menuOverrides[id] = m.shortcut
            for k in Array(menuOverrides.keys) where k != id && menuOverrides[k] == m.shortcut { menuOverrides.removeValue(forKey: k) }
        }
        save()
    }

    /// プリセット適用前の割り当てに戻す。控えが無ければ何もしない。
    func restorePrePresetBackup() {
        guard let data = defaults.data(forKey: Self.backupKey),
              let backup = try? JSONDecoder().decode(Backup.self, from: data) else { return }
        menuOverrides = backup.menu.compactMapValues { e in
            guard let ch = e.key.first else { return nil }
            return MenuShortcut(key: KeyEquivalent(ch), modifiers: EventModifiers(rawValue: e.modifiers))
        }
        plainOverrides = backup.plain.mapValues { PlainBinding(keyCode: $0.keyCode, display: $0.display) }
        defaults.removeObject(forKey: Self.backupKey)
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

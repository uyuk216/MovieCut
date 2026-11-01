import SwiftUI
import AppKit

/// キーボードショートカット一覧の 1 行(表示の文字だけ持つ。読み取り専用)。
struct ShortcutRow: Equatable, Identifiable {
    var id: Int
    var title: String
    var keys: String
}

enum ShortcutList {
    /// メニューの項目表(AppMenuSpec.all)のうち、ショートカットを持つ項目をメニューの並び順で。
    /// ショートカットは表示状態(有効・チェック)に依らないので、既定の MenuState で作る。
    static func menuRows(_ items: [MenuItemSpec] = AppMenuSpec.all(MenuState())) -> [ShortcutRow] {
        numbered(items.compactMap { item in item.shortcut.map { (item.title, $0.display) } })
    }

    /// メニューの項目にしない通常キー(S・Space・矢印など。KeyRouter が受ける)。
    static let plainKeys: [(title: String, keys: String)] = [
        ("再生 / 停止", "Space"),
        ("1コマ戻る", "←"),
        ("1コマ進む", "→"),
        ("先頭へ", "Home"),
        ("末尾へ", "End"),
        ("クリップを分割", "S"),
        ("クリップを削除", "⌫"),
        ("選択を外す", "Esc"),
        ("逆再生(J を押すたびに速く・遅く)", "J"),
        ("停止", "K"),
        ("速く再生(L を押すたびに 1・2・4 倍)", "L"),
    ]

    private static func numbered(_ pairs: [(String, String)]) -> [ShortcutRow] {
        pairs.enumerated().map { ShortcutRow(id: $0.offset, title: $0.element.0, keys: $0.element.1) }
    }
}

struct ShortcutSheetView: View {
    let menuRows: [ShortcutRow]
    let plainRows: [ShortcutRow]
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("キーボードショートカット一覧").font(.headline)
            Text("メニューの項目に割り当てたショートカットと、メニューに出ない通常キーです。変更はできません。")
                .font(.caption).foregroundStyle(.secondary)
            List {
                Section("通常キー") {
                    ForEach(plainRows) { row in
                        HStack { Text(row.title); Spacer(); Text(row.keys).monospaced().foregroundStyle(.secondary) }
                    }
                }
                Section("メニューの項目") {
                    ForEach(menuRows) { row in
                        HStack { Text(row.title); Spacer(); Text(row.keys).monospaced().foregroundStyle(.secondary) }
                    }
                }
            }
            HStack {
                Spacer()
                Button("閉じる", action: onClose).keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(width: 460, height: 560)
    }
}

/// ヘルプ ▸ キーボードショートカット一覧。前面のウインドウにシートとして出す(無ければ単独のウインドウ)。
@MainActor
enum ShortcutSheet {
    private static var window: NSWindow?

    static func show() {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            return
        }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 560), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "キーボードショートカット一覧"
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: ShortcutSheetView(
            menuRows: ShortcutList.menuRows(),
            plainRows: ShortcutList.plainKeys.enumerated().map { ShortcutRow(id: $0.offset, title: $0.element.title, keys: $0.element.keys) },
            onClose: { close() }))
        window = w
        if let host = NSApp.keyWindow ?? NSApp.mainWindow, host.isVisible, host.attachedSheet == nil {
            host.beginSheet(w)
        } else {
            w.center()
            w.makeKeyAndOrderFront(nil)
        }
    }

    static func close() {
        guard let w = window else { return }
        if let p = w.sheetParent { p.endSheet(w) } else { w.orderOut(nil) }
        window = nil
    }
}

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
        ("ロール編集(隣り合うクリップの境界を動かす)", "⌥ + 端をドラッグ"),
        ("スリップ編集(使う素材の区間をずらす)", "⌥⇧ + クリップをドラッグ"),
        ("速く再生(L を押すたびに 1・2・4 倍)", "L"),
    ]

    /// 通常キーのうち、割り当てを変えられるもの(KeyRouter のコマンドと対応。plainKeys と並び・表示を合わせる)。
    static let plainKeyDefs: [(command: KeyCommand, title: String, keys: String)] = [
        (.playPause, "再生 / 停止", "Space"),
        (.stepBack, "1コマ戻る", "←"),
        (.stepForward, "1コマ進む", "→"),
        (.toStart, "先頭へ", "Home"),
        (.toEnd, "末尾へ", "End"),
        (.split, "クリップを分割", "S"),
        (.delete, "クリップを削除", "⌫"),
        (.deselect, "選択を外す", "Esc"),
        (.shuttleBack, "逆再生(J を押すたびに速く・遅く)", "J"),
        (.shuttleStop, "停止", "K"),
        (.shuttleForward, "速く再生(L を押すたびに 1・2・4 倍)", "L"),
        // 既定ではキーなし。Premiere互換プリセットを適用すると I / O / Q / W が付く(個別に変更もできる)
        (.markIn, "書き出し開始を現在位置に", "I"),
        (.markOut, "書き出し終了を現在位置に", "O"),
        (.rippleHead, "リップルトリム(頭)を再生位置へ", "Q"),
        (.rippleTail, "リップルトリム(尻)を再生位置へ", "W"),
    ]

    /// ドラッグ操作の行(キー割り当ての対象ではない)。
    static let mouseRows: [(title: String, keys: String)] = [
        ("ロール編集(隣り合うクリップの境界を動かす)", "⌥ + 端をドラッグ"),
        ("スリップ編集(使う素材の区間をずらす)", "⌥⇧ + クリップをドラッグ"),
        ("スライド編集(前後のクリップが連動する)", "⌥ + クリップをドラッグ"),
    ]

    private static func numbered(_ pairs: [(String, String)]) -> [ShortcutRow] {
        pairs.enumerated().map { ShortcutRow(id: $0.offset, title: $0.element.0, keys: $0.element.1) }
    }
}

/// ショートカットの一覧と変更。変更は `ShortcutStore`(UserDefaults)に残り、メニューと KeyRouter の両方に効く。
/// 既存の読み取り専用の行データ(`ShortcutList.menuRows` / `plainKeys`)はそのまま別に残してある。
struct ShortcutSheetView: View {
    @ObservedObject var store = ShortcutStore.shared
    let onClose: () -> Void
    @State private var captureTarget: CaptureTarget?
    @State private var message: String?
    @State private var capture = ShortcutCapture()

    enum CaptureTarget: Equatable {
        case menu(id: String, title: String)
        case plain(KeyCommand, title: String)
        var title: String { switch self { case .menu(_, let t), .plain(_, let t): return t } }
    }

    private struct MenuEntry: Identifiable { var id: String; var title: String; var display: String }

    /// メニューの項目(実効のショートカット表示)。同じコマンドが複数あれば最初の 1 件だけ。
    private var menuEntries: [MenuEntry] {
        var seen = Set<String>()
        return AppMenuSpec.all(MenuState()).compactMap { item in
            let id = ShortcutStore.id(for: item.command)
            guard seen.insert(id).inserted else { return nil }
            guard let eff = store.menuOverride(for: id) ?? item.shortcut else { return nil }
            return MenuEntry(id: id, title: item.title, display: eff.display)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("キーボードショートカット一覧").font(.headline)
            Text("「変更」を押してから割り当てたいキーを押すと、変更できます(この Mac のこのアプリに保存されます)。通常キーは修飾キーなし、メニューの項目は ⌘・⌥・⌃ のどれかと一緒に押してください。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let t = captureTarget {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("「\(t.title)」のキーを押してください…").font(MCDesign.Font.calloutSemibold)
                    Spacer()
                    Button("やめる") { endCapture() }
                }
                .padding(8).background(Color.accentColor.opacity(0.12)).cornerRadius(6)
            }
            if let message {
                Text(message).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            List {
                Section("通常キー") {
                    ForEach(ShortcutList.plainKeyDefs.indices, id: \.self) { i in
                        let def = ShortcutList.plainKeyDefs[i]
                        editRow(title: def.title, keys: plainDisplay(def),
                                overridden: store.plainOverride(for: def.command) != nil,
                                onChange: { beginCapture(.plain(def.command, title: def.title)) },
                                onReset: { store.setPlainOverride(nil, for: def.command) })
                    }
                    ForEach(ShortcutList.mouseRows.indices, id: \.self) { i in
                        let r = ShortcutList.mouseRows[i]
                        HStack { Text(r.title); Spacer(); Text(r.keys).monospaced().foregroundStyle(.secondary) }
                    }
                }
                Section("メニューの項目") {
                    ForEach(menuEntries) { entry in
                        editRow(title: entry.title, keys: entry.display,
                                overridden: store.menuOverride(for: entry.id) != nil,
                                onChange: { beginCapture(.menu(id: entry.id, title: entry.title)) },
                                onReset: { store.setMenuOverride(nil, for: entry.id) })
                    }
                }
            }
            HStack(spacing: 8) {
                Button("Premiere互換プリセットを適用") { store.applyPremierePreset(); message = "Premiere互換プリセットを適用しました(C = 分割、I / O = 書き出し範囲、Q / W = リップルトリム、⌘K = 分割、⇧⌫ = すき間を詰めて削除)。プリセットが触らない割り当てはそのまま残ります" }
                    .disabled(store.isPremierePresetApplied)
                if store.hasPrePresetBackup {
                    Button("プリセット適用前に戻す") { store.restorePrePresetBackup(); message = "プリセット適用前の割り当てに戻しました" }
                }
                Spacer()
            }
            HStack {
                Button("すべて既定に戻す") { store.resetAll(); message = "すべて既定に戻しました" }
                    .disabled(!store.hasAnyOverride)
                Spacer()
                Button("閉じる", action: onClose).keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(width: 520, height: 560)
        .onDisappear { capture.stop() }
    }

    private func editRow(title: String, keys: String, overridden: Bool,
                         onChange: @escaping () -> Void, onReset: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Text(title)
            Spacer()
            Text(keys).monospaced().foregroundStyle(overridden ? .primary : .secondary)
            if overridden {
                Button("既定に戻す", action: onReset).buttonStyle(.borderless).font(.caption)
            }
            Button("変更", action: onChange).font(.caption)
        }
    }

    /// その通常キーの実効の表示(上書き > 既定)。既定キーを他の上書きに取られていたら「なし」。
    private func plainDisplay(_ def: (command: KeyCommand, title: String, keys: String)) -> String {
        if let b = store.plainOverride(for: def.command) { return b.display }
        return KeyRouter.effectiveKeyMap(store: store).values.contains(def.command) ? def.keys : "なし"
    }

    private func beginCapture(_ target: CaptureTarget) {
        captureTarget = target
        message = nil
        capture.onCapture = { c in handleCaptured(c, for: target) }
        capture.start()
    }

    private func endCapture() {
        capture.stop()
        captureTarget = nil
    }

    private func handleCaptured(_ c: ShortcutCapture.Captured, for target: CaptureTarget) {
        captureTarget = nil
        switch target {
        case .plain(let cmd, _):
            if c.modifiers.contains(.command) || c.modifiers.contains(.option) || c.modifiers.contains(.control) {
                message = "通常キーには ⌘・⌥・⌃ を付けられません(修飾キーつきはメニューの項目の担当です)"
                return
            }
            let display = ShortcutStore.keyDisplay(keyCode: c.keyCode, characters: c.characters)
            let prior = KeyRouter.effectiveKeyMap(store: store)[c.keyCode]
            store.setPlainOverride(.init(keyCode: c.keyCode, display: display), for: cmd)
            if let prior, prior != cmd, let t = ShortcutList.plainKeyDefs.first(where: { $0.command == prior })?.title {
                message = "「\(t)」からキーを移しました(「\(t)」はキーなしになりました。「既定に戻す」で元に戻せます)"
            }
        case .menu(let id, _):
            let mods = ShortcutStore.eventModifiers(c.modifiers)
            guard mods.contains(.command) || mods.contains(.option) || mods.contains(.control) else {
                message = "メニューのショートカットには ⌘・⌥・⌃ のどれかが必要です"
                return
            }
            guard let ch = c.characters?.first else { message = "そのキーは使えませんでした"; return }
            let key = KeyEquivalent(ch.isLetter ? Character(ch.lowercased()) : ch)
            let shortcut = MenuShortcut(key: key, modifiers: mods)
            store.setMenuOverride(shortcut, for: id)
            let dup = AppMenuSpec.all(MenuState()).first { item in
                let other = ShortcutStore.id(for: item.command)
                return other != id && (store.menuOverride(for: other) ?? item.shortcut)?.display == shortcut.display
            }
            if let dup { message = "「\(dup.title)」と同じキーです(メニューでは先に見つかった項目が優先されます)" }
        }
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
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 560), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "キーボードショートカット一覧"
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: ShortcutSheetView(onClose: { close() }))
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

import SwiftUI

/// 項目表(MenuItemSpec)を SwiftUI のメニュー項目にする。ラジオは Toggle(✓)で表す。
struct MenuItemView: View {
    let spec: MenuItemSpec
    let perform: (MenuCommand) -> Void

    var body: some View {
        if let checked = spec.checked {
            Toggle(spec.title, isOn: Binding(get: { checked }, set: { _ in perform(spec.command) }))
                .keyboardShortcut(spec.shortcut?.keyboardShortcut)
                .disabled(!spec.enabled)
        } else {
            Button(spec.title) { perform(spec.command) }
                .keyboardShortcut(spec.shortcut?.keyboardShortcut)
                .disabled(!spec.enabled)
        }
    }
}

/// メニューの中身を作る View。前面のドキュメント(ActiveDocument)の状態が変わると描き直される。
/// (Commands 自身の @ObservedObject は更新が届かないので、中身を View にして観察する。)
struct MenuSection<Content: View>: View {
    @ObservedObject var active = ActiveDocument.shared
    @ViewBuilder let content: (MenuState, @escaping (MenuCommand) -> Void) -> Content

    var body: some View {
        let _ = DebugHooks.trace("MenuSection body hasDocument=\(active.state.hasDocument)")
        content(active.state) { c in AppMenu.perform(c, model: ActiveDocument.shared.model) }
    }
}

private func items(_ list: [MenuItemSpec], _ run: @escaping (MenuCommand) -> Void) -> some View {
    ForEach(Array(list.enumerated()), id: \.offset) { _, s in MenuItemView(spec: s, perform: run) }
}

/// メニューバー。前面のドキュメントの ProjectModel(ActiveDocument)を操作する。
struct AppCommands: Commands {
    var body: some Commands {
        // アプリメニュー
        CommandGroup(replacing: .appInfo) {
            MenuSection { _, run in MenuItemView(spec: AppMenuSpec.about, perform: run) }
        }
        CommandGroup(replacing: .appSettings) {
            MenuSection { s, run in MenuItemView(spec: AppMenuSpec.settings(s), perform: run) }
        }

        // ファイル(⌘P のプリントは menu.js に無く、別画面表示と衝突するので、その場所に素材追加と書き出しを置く)
        CommandGroup(replacing: .printItem) {
            MenuSection { s, run in items(AppMenuSpec.file(s), run) }
        }

        // 編集
        CommandGroup(after: .pasteboard) {
            MenuSection { s, run in
                Divider()
                items(AppMenuSpec.editSelection(s), run)
                Divider()
                items(AppMenuSpec.editAdd(s), run)
            }
        }

        // 再生
        CommandMenu("再生") {
            MenuSection { s, run in items(AppMenuSpec.playback(s), run) }
        }

        // 表示
        CommandGroup(before: .toolbar) {
            MenuSection { s, run in
                items(AppMenuSpec.zoom(s), run)
                Divider()
                Menu("解像度") {
                    items(AppMenuSpec.resolutions(s), run)
                    Divider()
                    MenuItemView(spec: AppMenuSpec.customResolution(s), perform: run)
                }
                Menu("書き出し形式") { items(AppMenuSpec.codecItems(s), run) }
                Menu("背景色") { items(AppMenuSpec.backgroundItems(s), run) }
                Divider()
                MenuItemView(spec: AppMenuSpec.secondScreen(s), perform: run)
                Divider()
            }
        }

        CommandGroup(after: .toolbar) {
            MenuSection { s, run in MenuItemView(spec: AppMenuSpec.fullScreen(s), perform: run) }
        }

        // ヘルプ
        CommandGroup(replacing: .help) {
            MenuSection { _, run in
                items(AppMenuSpec.help[0], run)
                Divider()
                items(AppMenuSpec.help[1], run)
            }
        }
    }
}

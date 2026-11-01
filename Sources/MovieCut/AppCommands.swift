import SwiftUI

/// 項目表(MenuItemSpec)を SwiftUI のメニュー項目にする。ラジオは Toggle(✓)で表す。
struct MenuItemView: View {
    let spec: MenuItemSpec
    let perform: (MenuCommand) -> Void

    var body: some View {
        if let checked = spec.checked {
            Toggle(spec.displayTitle, isOn: Binding(get: { checked }, set: { _ in perform(spec.command) }))
                .keyboardShortcut(spec.shortcut?.keyboardShortcut)
                .disabled(!spec.enabled)
        } else {
            Button(spec.displayTitle) { perform(spec.command) }
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

        // ファイル(⌘P のプリントは使わない。その場所に素材追加などを置く)
        CommandGroup(replacing: .printItem) {
            MenuSection { s, run in
                items(AppMenuSpec.file(s), run)
                MenuItemView(spec: AppMenuSpec.subtitleImport(s), perform: run)
                MenuItemView(spec: AppMenuSpec.mediaRelink(s), perform: run)
                Divider()
                MenuItemView(spec: AppMenuSpec.templateSave(s), perform: run)
                Menu("テンプレートから新規作成") {
                    if s.templateNames.isEmpty {
                        Text("テンプレートはありません")
                    } else {
                        items(AppMenuSpec.templateNewItems(s), run)
                    }
                }
                Divider()
                MenuItemView(spec: AppMenuSpec.aiScript(s), perform: run)
                MenuItemView(spec: AppMenuSpec.aiSettings(s), perform: run)
            }
        }

        // 編集(分割・削除などクリップの操作はクリップメニューへ移した)
        CommandGroup(after: .pasteboard) {
            MenuSection { s, run in
                Divider()
                items(AppMenuSpec.clipboardItems(s), run)
                Divider()
                MenuItemView(spec: AppMenuSpec.findReplace(s), perform: run)
                Divider()
                items(AppMenuSpec.editAdd(s), run)
            }
        }

        // クリップ / 再生 / 移動 / 出力。SwiftUI は CommandMenu を「表示」の後ろへ置くので、順番は MenuOrder が起動後に直す。
        CommandMenu("クリップ") {
            MenuSection { s, run in
                let groups = AppMenuSpec.clipMenu(s)
                ForEach(Array(groups.enumerated()), id: \.offset) { i, g in
                    if i > 0 { Divider() }
                    items(g, run)
                }
                Divider()
                Menu("レイヤー") {
                    items(AppMenuSpec.layerItems(s), run)
                    Divider()
                    items(AppMenuSpec.layerHeightItems(s), run)
                }
                Divider()
                Menu("キーフレーム") { items(AppMenuSpec.keyframeItems(s), run) }
                Menu("アニメーション") { items(AppMenuSpec.animationItems(s), run) }
                Menu("配置") { items(AppMenuSpec.pipItems(s), run) }
                Divider()
                Menu("トランジション") {
                    Menu("開始") { items(AppMenuSpec.transitionKindItems(s, edge: .in), run) }
                    Menu("終了") { items(AppMenuSpec.transitionKindItems(s, edge: .out), run) }
                    Divider()
                    items(AppMenuSpec.transitionActions(s), run)
                }
                items(AppMenuSpec.transitionQuick(s), run)
                Divider()
                Menu("速度") {
                    items(AppMenuSpec.speedItems(s), run)
                    Divider()
                    MenuItemView(spec: AppMenuSpec.freezeFrameItem(s), perform: run)
                }
                MenuItemView(spec: AppMenuSpec.freezeFrameItem(s), perform: run)
                Divider()
                Menu("音声") { items(AppMenuSpec.audioItems(s), run) }
                MenuItemView(spec: AppMenuSpec.silenceCutItem(s), perform: run)
                MenuItemView(spec: AppMenuSpec.fillerCutItem(s), perform: run)
                MenuItemView(spec: AppMenuSpec.transcriptEditItem(s), perform: run)
                Divider()
                Menu("テキスト") {
                    Menu("スタイルを適用") { items(AppMenuSpec.textStyleItems(s), run) }
                    Menu("スタイルを一括適用") { items(AppMenuSpec.textStyleAllItems(s), run) }
                    Menu("文字アニメーション") { items(AppMenuSpec.textAnimItems(s), run) }
                    MenuItemView(spec: AppMenuSpec.textCounterItem(s), perform: run)
                }
                Divider()
                Menu("エフェクト") {
                    items(AppMenuSpec.effectKindItems(s), run)
                    Divider()
                    Menu("プリセット") { items(AppMenuSpec.effectPresetItems(s), run) }
                    Divider()
                    items(AppMenuSpec.effectActions(s), run)
                }
                MenuItemView(spec: AppMenuSpec.lutLoadItem(s), perform: run)
            }
        }

        CommandMenu("再生") {
            MenuSection { s, run in items(AppMenuSpec.playback(s), run) }
        }

        CommandMenu("移動") {
            MenuSection { s, run in
                items(AppMenuSpec.gotoEnds(s), run)
                Divider()
                items(AppMenuSpec.gotoNeighbours(s), run)
                Divider()
                MenuItemView(spec: AppMenuSpec.gotoTime(s), perform: run)
                Divider()
                items(AppMenuSpec.markerItems(s), run)
                Menu("マーカーの色") { items(AppMenuSpec.markerColorItems(s), run) }
                Menu("マーカー一覧") {
                    if s.markers.isEmpty {
                        Text("マーカーはありません")
                    } else {
                        items(AppMenuSpec.markerList(s), run)
                    }
                }
            }
        }

        // 出力(解像度・FPS・書き出し形式・背景色・動画の設定・書き出し)
        CommandMenu("出力") {
            MenuSection { s, run in
                Menu("解像度") {
                    items(AppMenuSpec.resolutions(s), run)
                    Divider()
                    if !AppMenuSpec.recentResolutions(s).isEmpty {
                        Text("最近使ったカスタム")
                        items(AppMenuSpec.recentResolutions(s), run)
                        Divider()
                    }
                    MenuItemView(spec: AppMenuSpec.customResolution(s), perform: run)
                    MenuItemView(spec: AppMenuSpec.swapResolution(s), perform: run)
                }
                Menu("FPS") {
                    items(AppMenuSpec.fpsItems(s), run)
                    Divider()
                    if !AppMenuSpec.recentFpsItems(s).isEmpty {
                        Text("最近使ったカスタム")
                        items(AppMenuSpec.recentFpsItems(s), run)
                        Divider()
                    }
                    MenuItemView(spec: AppMenuSpec.customFps(s), perform: run)
                }
                Menu("書き出し形式") { items(AppMenuSpec.codecItems(s), run) }
                Menu("背景色") { items(AppMenuSpec.backgroundItems(s), run) }
                Divider()
                MenuItemView(spec: AppMenuSpec.videoSettings(s), perform: run)
                Divider()
                MenuItemView(spec: AppMenuSpec.exportCurrent(s), perform: run)
                Menu("書き出しプリセット") { items(AppMenuSpec.exportPresets(s), run) }
                Divider()
                items(AppMenuSpec.exportQueueItems(s), run)
                Divider()
                MenuItemView(spec: AppMenuSpec.makeProxies(s), perform: run)
                Divider()
                items(AppMenuSpec.rangeItems(s), run)
                Divider()
                items(AppMenuSpec.imageExportItems(s), run)
                Divider()
                MenuItemView(spec: AppMenuSpec.gifExport(s), perform: run)
                Divider()
                MenuItemView(spec: AppMenuSpec.fanMaxToggle(s), perform: run)
                MenuItemView(spec: AppMenuSpec.fanInstall(s), perform: run)
                MenuItemView(spec: AppMenuSpec.fanUninstall(s), perform: run)
                Divider()
                MenuItemView(spec: AppMenuSpec.subtitleExport(s), perform: run)
                MenuItemView(spec: AppMenuSpec.subtitleGenerate(s), perform: run)
                MenuItemView(spec: AppMenuSpec.transcribeSubtitles(s), perform: run)
                MenuItemView(spec: AppMenuSpec.chapterCopy(s), perform: run)
                MenuItemView(spec: AppMenuSpec.aiChapters(s), perform: run)
                MenuItemView(spec: AppMenuSpec.aiTitles(s), perform: run)
            }
        }

        // 表示
        CommandGroup(before: .toolbar) {
            MenuSection { s, run in
                items(AppMenuSpec.zoom(s), run)
                Divider()
                Menu("パネル") { items(AppMenuSpec.dockPanels(s), run) }
                Menu("レイアウト") { items(AppMenuSpec.dockLayouts(s), run) }
                Divider()
                Menu("プレビューの背景") { items(AppMenuSpec.previewBackgroundItems(s), run) }
                MenuItemView(spec: AppMenuSpec.previewProxy(s), perform: run)
                Divider()
            }
        }

        CommandGroup(after: .toolbar) {
            MenuSection { s, run in MenuItemView(spec: AppMenuSpec.fullScreen(s), perform: run) }
        }

        // ヘルプ
        CommandGroup(replacing: .help) {
            MenuSection { _, run in
                ForEach(Array(AppMenuSpec.help.enumerated()), id: \.offset) { i, g in
                    if i > 0 { Divider() }
                    items(g, run)
                }
            }
        }
    }
}

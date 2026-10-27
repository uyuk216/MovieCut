import SwiftUI
import MovieCutCore

/// メニューバーの項目が呼ぶ操作(ツールバーと同じモデルの関数に行き着く)。
enum MenuCommand: Hashable {
    case about, settings, videoSettings
    case addMedia, export, exportPreset(ExportPreset)
    case split, delete, addText, addBlur, addCharacter, makeVoices
    // クリップ(M7)
    case duplicate, rippleDelete, trimBefore, trimAfter, prevClip, nextClip, moveLayerUp, moveLayerDown, addLayer, regenerateVoice
    case playPause, toStart, stepBack, stepForward
    // 移動(M7)
    case goStart, goEnd, prevEdit, nextEdit, prevLine, nextLine, jumpToTime
    case addMarker, renameMarker, prevMarker, nextMarker, deleteMarker, clearMarkers, jumpToMarker(String)
    case zoomIn, zoomOut, zoomFit
    case resolution(String), fps(Int), codec(String), background(String)
    case toggleSecondScreen, fullScreen, toggleStatusItem
    case helpVoicevox, helpAquestalk, helpLicense, helpThirdParty
}

/// メニューのショートカット(キーと修飾キー)。
struct MenuShortcut: Hashable {
    var key: Swift.Character
    var modifiersRaw: Int
    init(key: KeyEquivalent, modifiers: EventModifiers) {
        self.key = key.character
        self.modifiersRaw = modifiers.rawValue
    }
    var modifiers: EventModifiers { EventModifiers(rawValue: modifiersRaw) }
    var keyboardShortcut: KeyboardShortcut { KeyboardShortcut(KeyEquivalent(key), modifiers: modifiers) }

    /// 表示用(⇧⌘T)。
    var display: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s + Self.keyName(key)
    }

    /// キー 1 つの表示名(矢印・⏎・⌫ などは記号に)。
    static func keyName(_ key: Swift.Character) -> String {
        switch key {
        case KeyEquivalent.return.character: return "⏎"
        case KeyEquivalent.leftArrow.character: return "←"
        case KeyEquivalent.rightArrow.character: return "→"
        case KeyEquivalent.upArrow.character: return "↑"
        case KeyEquivalent.downArrow.character: return "↓"
        case KeyEquivalent.delete.character: return "⌫"
        case KeyEquivalent.space.character: return "Space"
        default: return String(key).uppercased()
        }
    }
}

/// メニュー 1 項目の見た目と状態。
struct MenuItemSpec: Equatable {
    var command: MenuCommand
    var title: String
    var shortcut: MenuShortcut?
    var enabled: Bool
    /// nil = チェックなしの普通の項目、true/false = ラジオ(✓)。
    var checked: Bool?
    /// 通常キーのヒント(S・Home など)。メニューの文字の後ろに添えるだけで、ショートカットは登録しない(KeyRouter が受ける)。
    var hint: String? = nil

    /// メニューに出す題(ヒントつき)。
    var displayTitle: String { hint.map { "\(title)  (\($0))" } ?? title }

    static func == (a: MenuItemSpec, b: MenuItemSpec) -> Bool {
        a.command == b.command && a.title == b.title && a.shortcut == b.shortcut && a.enabled == b.enabled && a.checked == b.checked && a.hint == b.hint
    }
}

/// 前面のドキュメントの、メニューの有効・チェックに効く状態。
struct MenuState: Equatable {
    var hasDocument = false
    var isLocked = false
    var canExport = false
    var hasSelection = false
    var canSplit = false
    var resolutionKey = ""
    var fps = 0
    var codec = ""
    var bg = ""
    var isSecondScreenOpen = false
    // クリップ(M7)
    var canTrim = false              // 再生位置が選択クリップの中
    var isVoiceSelected = false
    var canMoveUp = false
    var canMoveDown = false
    var hasPrevClip = false
    var hasNextClip = false
    // 移動(M7)
    var hasPrevEdit = false
    var hasNextEdit = false
    var hasPrevLine = false
    var hasNextLine = false
    var markers: [MarkerItem] = []
    var markerAtPlayhead = false
    var hasPrevMarker = false
    var hasNextMarker = false
    /// メニューバーのアイコンを出す設定(「表示」メニューの切り替え)。
    var statusItemShown = true

    struct MarkerItem: Equatable {
        var id: String
        var time: Double
        var name: String
    }

    init() {}

    @MainActor
    init(model: ProjectModel?) {
        statusItemShown = AppServices.statusBar.isEnabled
        guard let m = model else { return }
        hasDocument = true
        isLocked = m.isLocked
        canExport = m.canExport
        hasSelection = m.selectedClip != nil
        canSplit = m.canSplit
        resolutionKey = m.resolutionKey
        fps = m.project.fps
        codec = m.project.codec
        bg = m.project.bg
        isSecondScreenOpen = m.isSecondScreenOpen
        let p = m.project, t = m.currentTime
        if let c = m.selectedClip {
            canTrim = ClipEditing.canTrim(c, at: t)
            isVoiceSelected = c.type == .voice
            if let loc = ClipEditing.locate(c.id, in: p) {
                canMoveUp = loc.track > 0
                canMoveDown = loc.track < p.tracks.count - 1
            }
        }
        hasPrevClip = ClipEditing.hasAdjacentClip(in: p, from: m.selectedClipId, forward: false, playhead: t)
        hasNextClip = ClipEditing.hasAdjacentClip(in: p, from: m.selectedClipId, forward: true, playhead: t)
        hasPrevEdit = ClipEditing.hasEditPoint(p, before: t)
        hasNextEdit = ClipEditing.hasEditPoint(p, after: t)
        var firstVoice = Double.infinity, lastVoice = -Double.infinity
        for c in p.allClips where c.type == .voice { firstVoice = min(firstVoice, c.start); lastVoice = max(lastVoice, c.start) }
        hasPrevLine = firstVoice < t - ClipEditing.timeEpsilon
        hasNextLine = lastVoice > t + ClipEditing.timeEpsilon
        markers = p.markers.map { MarkerItem(id: $0.id, time: $0.time, name: $0.name) }
        markerAtPlayhead = m.markerNearPlayhead != nil
        hasPrevMarker = p.markers.contains { $0.time < t - MarkerEditing.epsilon }
        hasNextMarker = p.markers.contains { $0.time > t + MarkerEditing.epsilon }
    }

    /// 編集してよい状態(ドキュメントがあり、書き出し・音声生成の最中でない)。
    var canEdit: Bool { hasDocument && !isLocked }
}

/// menu.js と同じ構成の項目表。表示(SwiftUI)と試験の両方がこれを見る。
enum AppMenuSpec {
    static let backgrounds: [(key: String, label: String)] = [("#000000", "黒"), ("#ffffff", "白"), ("#00b140", "緑（クロマキー）")]
    static let codecs: [(key: String, label: String)] = [("h264", "H.264"), ("hevc", "HEVC")]

    private static func cmd(_ k: KeyEquivalent, shift: Bool = false) -> MenuShortcut {
        MenuShortcut(key: k, modifiers: shift ? [.command, .shift] : .command)
    }

    static let about = MenuItemSpec(command: .about, title: "Movie Cut について", shortcut: nil, enabled: true, checked: nil)

    static func settings(_ s: MenuState) -> MenuItemSpec {
        MenuItemSpec(command: .settings, title: "設定…", shortcut: cmd(","), enabled: s.canEdit, checked: nil)
    }

    /// 出力 ▸ 動画の設定…(設定シート。⌘, の「設定…」と同じ操作でショートカットは持たない)。
    static func videoSettings(_ s: MenuState) -> MenuItemSpec {
        MenuItemSpec(command: .videoSettings, title: "動画の設定…", shortcut: nil, enabled: s.canEdit, checked: nil)
    }

    static let fpsPresets = [24, 30, 60]

    /// FPS のラジオ。24 / 30 / 60 以外のときは、チェック付きの項目がもう 1 つ増える。
    static func fpsItems(_ s: MenuState) -> [MenuItemSpec] {
        var items = fpsPresets.map {
            MenuItemSpec(command: .fps($0), title: "\($0) fps", shortcut: nil, enabled: s.canEdit, checked: $0 == s.fps)
        }
        if s.hasDocument, s.fps > 0, !fpsPresets.contains(s.fps) {
            items.append(MenuItemSpec(command: .fps(s.fps), title: "\(s.fps) fps", shortcut: nil, enabled: s.canEdit, checked: true))
        }
        return items
    }

    static func file(_ s: MenuState) -> [MenuItemSpec] {
        [MenuItemSpec(command: .addMedia, title: "素材を追加…", shortcut: cmd("i"), enabled: s.canEdit, checked: nil)]
    }

    /// 出力 ▸ MP4 を書き出す…(⌘E)と、書き出しプリセット。
    static func exportCurrent(_ s: MenuState) -> MenuItemSpec {
        MenuItemSpec(command: .export, title: "MP4 を書き出す…", shortcut: cmd("e"), enabled: s.canEdit && s.canExport, checked: nil)
    }

    static func exportPresets(_ s: MenuState) -> [MenuItemSpec] {
        ExportPreset.allCases.map {
            MenuItemSpec(command: .exportPreset($0), title: $0.title, shortcut: nil, enabled: s.canEdit && s.canExport, checked: nil, hint: $0.summary)
        }
    }

    // MARK: クリップメニュー

    /// 追加(テキスト・ぼかし範囲)。
    static func clipAdd(_ s: MenuState) -> [MenuItemSpec] {
        [MenuItemSpec(command: .addText, title: "テキストを追加", shortcut: cmd("t", shift: true), enabled: s.canEdit, checked: nil),
         MenuItemSpec(command: .addBlur, title: "ぼかし範囲を追加", shortcut: cmd("b", shift: true), enabled: s.canEdit, checked: nil)]
    }

    /// 分割・複製・削除(S / Delete は KeyRouter が受けるので、メニューにはキーを付けずヒントだけ添える)。
    static func clipEdit(_ s: MenuState) -> [MenuItemSpec] {
        [MenuItemSpec(command: .split, title: "クリップを分割", shortcut: nil, enabled: s.canEdit && s.canSplit, checked: nil, hint: "S"),
         MenuItemSpec(command: .duplicate, title: "クリップを複製", shortcut: cmd("d"), enabled: s.canEdit && s.hasSelection, checked: nil),
         MenuItemSpec(command: .delete, title: "クリップを削除", shortcut: nil, enabled: s.canEdit && s.hasSelection, checked: nil, hint: "⌫"),
         MenuItemSpec(command: .rippleDelete, title: "すき間を詰めて削除", shortcut: MenuShortcut(key: .delete, modifiers: [.option, .command]), enabled: s.canEdit && s.hasSelection, checked: nil)]
    }

    static func clipTrim(_ s: MenuState) -> [MenuItemSpec] {
        [MenuItemSpec(command: .trimBefore, title: "再生位置より前を切り落とす", shortcut: MenuShortcut(key: "[", modifiers: [.option, .command]), enabled: s.canEdit && s.canTrim, checked: nil),
         MenuItemSpec(command: .trimAfter, title: "再生位置より後ろを切り落とす", shortcut: MenuShortcut(key: "]", modifiers: [.option, .command]), enabled: s.canEdit && s.canTrim, checked: nil)]
    }

    static func clipNavigate(_ s: MenuState) -> [MenuItemSpec] {
        [MenuItemSpec(command: .prevClip, title: "前のクリップを選択", shortcut: MenuShortcut(key: "[", modifiers: .command), enabled: s.canEdit && s.hasPrevClip, checked: nil),
         MenuItemSpec(command: .nextClip, title: "次のクリップを選択", shortcut: MenuShortcut(key: "]", modifiers: .command), enabled: s.canEdit && s.hasNextClip, checked: nil),
         MenuItemSpec(command: .moveLayerUp, title: "選択クリップを上のレイヤーへ", shortcut: MenuShortcut(key: "[", modifiers: [.shift, .command]), enabled: s.canEdit && s.canMoveUp, checked: nil),
         MenuItemSpec(command: .moveLayerDown, title: "選択クリップを下のレイヤーへ", shortcut: MenuShortcut(key: "]", modifiers: [.shift, .command]), enabled: s.canEdit && s.canMoveDown, checked: nil)]
    }

    static func clipLayerAndVoice(_ s: MenuState) -> [MenuItemSpec] {
        [MenuItemSpec(command: .addLayer, title: "レイヤーを追加", shortcut: cmd("l", shift: true), enabled: s.canEdit, checked: nil),
         MenuItemSpec(command: .regenerateVoice, title: "選択クリップの音声を作り直す", shortcut: MenuShortcut(key: "r", modifiers: [.command, .option]), enabled: s.canEdit && s.isVoiceSelected, checked: nil)]
    }

    /// クリップメニューの全項目(区切りごとのグループ)。
    static func clipMenu(_ s: MenuState) -> [[MenuItemSpec]] {
        [clipAdd(s), clipEdit(s), clipTrim(s), clipNavigate(s), clipLayerAndVoice(s)]
    }

    /// 編集メニューに残すもの(キャラクターと台本)。
    static func editAdd(_ s: MenuState) -> [MenuItemSpec] {
        [MenuItemSpec(command: .addCharacter, title: "キャラクターを追加", shortcut: cmd("c", shift: true), enabled: s.canEdit, checked: nil),
         MenuItemSpec(command: .makeVoices, title: "台本から音声を作る", shortcut: cmd(.return), enabled: s.canEdit, checked: nil)]
    }

    /// 再生(Space / Home / ← / → は KeyRouter が受けるので、キーは付けない)。
    static func playback(_ s: MenuState) -> [MenuItemSpec] {
        [MenuItemSpec(command: .playPause, title: "再生 / 停止", shortcut: nil, enabled: s.canEdit, checked: nil),
         MenuItemSpec(command: .toStart, title: "先頭へ戻る", shortcut: nil, enabled: s.canEdit, checked: nil),
         MenuItemSpec(command: .stepBack, title: "1コマ戻る", shortcut: nil, enabled: s.canEdit, checked: nil),
         MenuItemSpec(command: .stepForward, title: "1コマ進む", shortcut: nil, enabled: s.canEdit, checked: nil)]
    }

    // MARK: 移動メニュー

    private static func opt(_ k: KeyEquivalent, command: Bool = false) -> MenuShortcut {
        MenuShortcut(key: k, modifiers: command ? [.option, .command] : .option)
    }

    /// 先頭・末尾(Home / End は KeyRouter が受けるのでヒントだけ)。
    static func gotoEnds(_ s: MenuState) -> [MenuItemSpec] {
        [MenuItemSpec(command: .goStart, title: "先頭へ", shortcut: nil, enabled: s.canEdit, checked: nil, hint: "Home"),
         MenuItemSpec(command: .goEnd, title: "末尾へ", shortcut: nil, enabled: s.canEdit, checked: nil, hint: "End")]
    }

    static func gotoNeighbours(_ s: MenuState) -> [MenuItemSpec] {
        [MenuItemSpec(command: .prevEdit, title: "前のクリップの境目へ", shortcut: opt(.leftArrow, command: true), enabled: s.canEdit && s.hasPrevEdit, checked: nil),
         MenuItemSpec(command: .nextEdit, title: "次のクリップの境目へ", shortcut: opt(.rightArrow, command: true), enabled: s.canEdit && s.hasNextEdit, checked: nil),
         MenuItemSpec(command: .prevLine, title: "前のセリフへ", shortcut: MenuShortcut(key: .leftArrow, modifiers: [.control, .command]), enabled: s.canEdit && s.hasPrevLine, checked: nil),
         MenuItemSpec(command: .nextLine, title: "次のセリフへ", shortcut: MenuShortcut(key: .rightArrow, modifiers: [.control, .command]), enabled: s.canEdit && s.hasNextLine, checked: nil)]
    }

    static func gotoTime(_ s: MenuState) -> MenuItemSpec {
        MenuItemSpec(command: .jumpToTime, title: "時間を指定して移動…", shortcut: cmd("j"), enabled: s.canEdit, checked: nil)
    }

    static func markerItems(_ s: MenuState) -> [MenuItemSpec] {
        [MenuItemSpec(command: .addMarker, title: "マーカーを追加", shortcut: MenuShortcut(key: "m", modifiers: [.control, .command]), enabled: s.canEdit && !s.markerAtPlayhead, checked: nil),
         MenuItemSpec(command: .renameMarker, title: "マーカーを名前変更…", shortcut: nil, enabled: s.canEdit && s.markerAtPlayhead, checked: nil),
         MenuItemSpec(command: .prevMarker, title: "前のマーカーへ", shortcut: opt(.upArrow, command: true), enabled: s.canEdit && s.hasPrevMarker, checked: nil),
         MenuItemSpec(command: .nextMarker, title: "次のマーカーへ", shortcut: opt(.downArrow, command: true), enabled: s.canEdit && s.hasNextMarker, checked: nil),
         MenuItemSpec(command: .deleteMarker, title: "マーカーを削除", shortcut: nil, enabled: s.canEdit && s.markerAtPlayhead, checked: nil),
         MenuItemSpec(command: .clearMarkers, title: "すべてのマーカーを消去", shortcut: nil, enabled: s.canEdit && !s.markers.isEmpty, checked: nil)]
    }

    /// マーカー一覧の 1 項目の題(時刻と名前)。
    static func markerTitle(_ m: MenuState.MarkerItem) -> String { "\(timecode(m.time))  \(m.name)" }

    static func markerList(_ s: MenuState) -> [MenuItemSpec] {
        s.markers.map { MenuItemSpec(command: .jumpToMarker($0.id), title: markerTitle($0), shortcut: nil, enabled: s.canEdit, checked: nil) }
    }

    static func zoom(_ s: MenuState) -> [MenuItemSpec] {
        [MenuItemSpec(command: .zoomIn, title: "タイムラインを拡大", shortcut: cmd("+"), enabled: s.canEdit, checked: nil),
         MenuItemSpec(command: .zoomOut, title: "タイムラインを縮小", shortcut: cmd("-"), enabled: s.canEdit, checked: nil),
         MenuItemSpec(command: .zoomFit, title: "全体表示", shortcut: cmd("0"), enabled: s.canEdit, checked: nil)]
    }

    /// 解像度のラジオ。プリセット以外のサイズのときは、チェック付きの項目がもう 1 つ増える。
    static func resolutions(_ s: MenuState) -> [MenuItemSpec] {
        var items = ResolutionPresets.items.map {
            MenuItemSpec(command: .resolution($0.key), title: $0.label, shortcut: nil, enabled: s.canEdit, checked: $0.key == s.resolutionKey)
        }
        if s.hasDocument, !ResolutionPresets.isPreset(s.resolutionKey), !s.resolutionKey.isEmpty {
            let label = s.resolutionKey.replacingOccurrences(of: "x", with: "×")
            items.append(MenuItemSpec(command: .resolution(s.resolutionKey), title: label, shortcut: nil, enabled: s.canEdit, checked: true))
        }
        return items
    }

    static func customResolution(_ s: MenuState) -> MenuItemSpec {
        MenuItemSpec(command: .resolution(ResolutionPresets.customKey), title: "自由…", shortcut: nil, enabled: s.canEdit, checked: nil)
    }

    static func codecItems(_ s: MenuState) -> [MenuItemSpec] {
        codecs.map { MenuItemSpec(command: .codec($0.key), title: $0.label, shortcut: nil, enabled: s.canEdit, checked: s.codec == $0.key) }
    }

    static func backgroundItems(_ s: MenuState) -> [MenuItemSpec] {
        backgrounds.map { MenuItemSpec(command: .background($0.key), title: $0.label, shortcut: nil, enabled: s.canEdit, checked: s.bg.lowercased() == $0.key) }
    }

    static func secondScreen(_ s: MenuState) -> MenuItemSpec {
        MenuItemSpec(command: .toggleSecondScreen, title: s.isSecondScreenOpen ? "別画面を閉じる" : "プレビューを別画面に表示", shortcut: cmd("p"), enabled: s.canEdit, checked: nil)
    }

    static func statusItemToggle(_ s: MenuState) -> MenuItemSpec {
        MenuItemSpec(command: .toggleStatusItem, title: "メニューバーアイコンを表示", shortcut: nil, enabled: true, checked: s.statusItemShown)
    }

    /// 標準の「全画面表示」(⌃⌘F)。ウィンドウがあれば使える(書き出し中でも構わない)。
    static func fullScreen(_ s: MenuState) -> MenuItemSpec {
        MenuItemSpec(command: .fullScreen, title: "全画面表示", shortcut: MenuShortcut(key: "f", modifiers: [.command, .control]), enabled: s.hasDocument, checked: nil)
    }

    static var help: [[MenuItemSpec]] {
        [[MenuItemSpec(command: .helpVoicevox, title: "VOICEVOX 公式サイト", shortcut: nil, enabled: true, checked: nil),
          MenuItemSpec(command: .helpAquestalk, title: "AquesTalkPlayer 公式サイト", shortcut: nil, enabled: true, checked: nil)],
         [MenuItemSpec(command: .helpLicense, title: "ライセンス", shortcut: nil, enabled: true, checked: nil),
          MenuItemSpec(command: .helpThirdParty, title: "第三者の規約", shortcut: nil, enabled: true, checked: nil)]]
    }

    /// 私たちが足す項目すべて(重複するショートカットが無いかの確認用)。
    static func all(_ s: MenuState) -> [MenuItemSpec] {
        [about, settings(s), videoSettings(s)] + file(s) + [exportCurrent(s)] + exportPresets(s) + clipMenu(s).flatMap { $0 } + editAdd(s) + playback(s)
            + gotoEnds(s) + gotoNeighbours(s) + [gotoTime(s)] + markerItems(s) + markerList(s)
            + zoom(s) + resolutions(s) + [customResolution(s)] + fpsItems(s) + codecItems(s) + backgroundItems(s)
            + [secondScreen(s), statusItemToggle(s), fullScreen(s)] + help.flatMap { $0 }
    }
}

/// 項目を選んだときの処理。ここで model の関数を呼ぶだけ(ロジックは複製しない)。
enum AppMenu {
    static let zoomStep = 1.25

    @MainActor
    static func perform(_ c: MenuCommand, model: ProjectModel?) {
        switch c {
        case .about: AppInfo.showAboutPanel()
        case .helpVoicevox: openURL(DependencyStatus.voicevoxURL)
        case .helpAquestalk: openURL(DependencyStatus.aquestalkURL)
        case .helpLicense: HelpDocs.open(.license)
        case .helpThirdParty: HelpDocs.open(.thirdParty)
        case .toggleStatusItem:
            AppServices.statusBar.setEnabled(!AppServices.statusBar.isEnabled)
            ActiveDocument.shared.refresh()
        default:
            guard let m = model else { return }
            switch c {
            case .settings, .videoSettings: m.openSettings()
            case .addMedia: m.chooseAndAddMedia()
            case .export: m.chooseAndExport()
            case .exportPreset(let p): m.chooseAndExport(preset: p)
            case .split: m.splitSelected()
            case .duplicate: m.duplicateSelected()
            case .rippleDelete: m.rippleDeleteSelected()
            case .trimBefore: m.trimSelectedBeforePlayhead()
            case .trimAfter: m.trimSelectedAfterPlayhead()
            case .prevClip: m.selectAdjacentClip(forward: false)
            case .nextClip: m.selectAdjacentClip(forward: true)
            case .moveLayerUp: m.moveSelectedToAdjacentLayer(up: true)
            case .moveLayerDown: m.moveSelectedToAdjacentLayer(up: false)
            case .addLayer: m.addTrack()
            case .regenerateVoice: Task { await m.regenerateSelectedVoice() }
            case .goStart: m.playback.goToStart()
            case .goEnd: m.goToEnd()
            case .prevEdit: m.seekEditPoint(forward: false)
            case .nextEdit: m.seekEditPoint(forward: true)
            case .prevLine: m.seekVoiceLine(forward: false)
            case .nextLine: m.seekVoiceLine(forward: true)
            case .jumpToTime: m.openJumpSheet()
            case .addMarker: m.addMarkerAtPlayhead()
            case .renameMarker: m.openRenameMarker()
            case .prevMarker: m.seekMarker(forward: false)
            case .nextMarker: m.seekMarker(forward: true)
            case .deleteMarker: m.deleteMarkerAtPlayhead()
            case .clearMarkers: m.clearMarkers()
            case .jumpToMarker(let id): m.jumpToMarker(id: id)
            case .delete: m.deleteSelected()
            case .addText: m.addTextClip()
            case .addBlur: m.addBlurClip()
            case .addCharacter: m.addCharacter()
            case .makeVoices: Task { await m.generateVoicesFromScript() }
            case .playPause: m.playback.togglePlay()
            case .toStart: m.playback.goToStart()
            case .stepBack: m.playback.step(frames: -1)
            case .stepForward: m.playback.step(frames: 1)
            case .zoomIn: m.zoomTimeline(by: zoomStep)
            case .zoomOut: m.zoomTimeline(by: 1 / zoomStep)
            case .zoomFit: m.onFitTimeline()
            case .resolution(let key): m.selectResolution(key)
            case .fps(let f): m.setFps(f)
            case .codec(let k): m.setCodec(k)
            case .background(let k): m.setBackground(k)
            case .toggleSecondScreen: m.toggleSecondScreen()
            case .fullScreen: m.window?.toggleFullScreen(nil)
            default: break
            }
        }
    }

    private static func openURL(_ s: String) {
        if let u = URL(string: s) { NSWorkspace.shared.open(u) }
    }
}

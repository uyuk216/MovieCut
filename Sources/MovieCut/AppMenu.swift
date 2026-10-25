import SwiftUI
import MovieCutCore

/// メニューバーの項目が呼ぶ操作(ツールバーと同じモデルの関数に行き着く)。
enum MenuCommand: Hashable {
    case about, settings
    case addMedia, export
    case split, delete, addText, addBlur, addCharacter, makeVoices
    case playPause, toStart, stepBack, stepForward
    case zoomIn, zoomOut, zoomFit
    case resolution(String), codec(String), background(String)
    case toggleSecondScreen, fullScreen
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
        return s + (key == KeyEquivalent.return.character ? "⏎" : String(key).uppercased())
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

    static func == (a: MenuItemSpec, b: MenuItemSpec) -> Bool {
        a.command == b.command && a.title == b.title && a.shortcut == b.shortcut && a.enabled == b.enabled && a.checked == b.checked
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
    var codec = ""
    var bg = ""
    var isSecondScreenOpen = false

    init() {}

    @MainActor
    init(model: ProjectModel?) {
        guard let m = model else { return }
        hasDocument = true
        isLocked = m.isLocked
        canExport = m.canExport
        hasSelection = m.selectedClip != nil
        canSplit = m.canSplit
        resolutionKey = m.resolutionKey
        codec = m.project.codec
        bg = m.project.bg
        isSecondScreenOpen = m.isSecondScreenOpen
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

    static func file(_ s: MenuState) -> [MenuItemSpec] {
        [MenuItemSpec(command: .addMedia, title: "素材を追加…", shortcut: cmd("i"), enabled: s.canEdit, checked: nil),
         MenuItemSpec(command: .export, title: "MP4 を書き出す…", shortcut: cmd("e"), enabled: s.canEdit && s.canExport, checked: nil)]
    }

    /// 分割・削除(S / Delete は KeyRouter が受けるので、メニューにはキーを付けない)。
    static func editSelection(_ s: MenuState) -> [MenuItemSpec] {
        [MenuItemSpec(command: .split, title: "クリップを分割", shortcut: nil, enabled: s.canEdit && s.canSplit, checked: nil),
         MenuItemSpec(command: .delete, title: "クリップを削除", shortcut: nil, enabled: s.canEdit && s.hasSelection, checked: nil)]
    }

    static func editAdd(_ s: MenuState) -> [MenuItemSpec] {
        [MenuItemSpec(command: .addText, title: "テキストを追加", shortcut: cmd("t", shift: true), enabled: s.canEdit, checked: nil),
         MenuItemSpec(command: .addBlur, title: "ぼかし範囲を追加", shortcut: cmd("b", shift: true), enabled: s.canEdit, checked: nil),
         MenuItemSpec(command: .addCharacter, title: "キャラクターを追加", shortcut: cmd("c", shift: true), enabled: s.canEdit, checked: nil),
         MenuItemSpec(command: .makeVoices, title: "台本から音声を作る", shortcut: cmd(.return), enabled: s.canEdit, checked: nil)]
    }

    /// 再生(Space / Home / ← / → は KeyRouter が受けるので、キーは付けない)。
    static func playback(_ s: MenuState) -> [MenuItemSpec] {
        [MenuItemSpec(command: .playPause, title: "再生 / 停止", shortcut: nil, enabled: s.canEdit, checked: nil),
         MenuItemSpec(command: .toStart, title: "先頭へ戻る", shortcut: nil, enabled: s.canEdit, checked: nil),
         MenuItemSpec(command: .stepBack, title: "1コマ戻る", shortcut: nil, enabled: s.canEdit, checked: nil),
         MenuItemSpec(command: .stepForward, title: "1コマ進む", shortcut: nil, enabled: s.canEdit, checked: nil)]
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
        [about, settings(s)] + file(s) + editSelection(s) + editAdd(s) + playback(s) + zoom(s)
            + resolutions(s) + [customResolution(s)] + codecItems(s) + backgroundItems(s) + [secondScreen(s), fullScreen(s)] + help.flatMap { $0 }
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
        default:
            guard let m = model else { return }
            switch c {
            case .settings: m.openSettings()
            case .addMedia: m.chooseAndAddMedia()
            case .export: m.chooseAndExport()
            case .split: m.splitSelected()
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

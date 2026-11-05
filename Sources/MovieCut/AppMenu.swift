import SwiftUI
import MovieCutCore

/// メニューバーの項目が呼ぶ操作(ツールバーと同じモデルの関数に行き着く)。
enum MenuCommand: Hashable {
    case about, settings, videoSettings
    case addMedia, importPSD, importRigFolder, importRigPSD, export, exportPreset(ExportPreset), exportCustomPreset(String), saveCustomPreset
    // 出力 ▸ 書き出し中のファン最大化(設定と、ヘルパーのインストール / 削除)
    case fanMaxToggle, fanInstall, fanUninstall
    // 字幕(B3)とチャプター
    case importSubtitles, exportSubtitles, generateSubtitles, copyChapters, copyChaptersColor(MarkerColor)
    // 字幕を AI で翻訳して SRT に書き出す(ショートカットは持たない)
    case translateSubtitles
    // クリップ ▸ ロール編集… / スリップ編集…(シートでコマ数を指定。ショートカットは持たない)
    case rollEdit, slipEdit
    // 音声から字幕を作る(オンデバイスの音声認識。選んでいるクリップ)
    case transcribeSubtitles
    // 素材(欠落の再指定)
    case relinkMedia
    // ファイル ▸ 未使用の素材…(ショートカットは持たない)
    case unusedMedia
    case packageSave
    case addFont
    case addSubtitle
    case removeBackground
    case imageChroma
    // 範囲ループ再生(再生メニュー)
    case toggleRangeLoop
    // トリム点 / 選択クリップの反復再生と、前後の幅(秒。0.5 / 1 / 2)
    case toggleTrimLoop, toggleClipLoop
    case trimLoopWidth(Double)
    // 再生 ▸ 重なったクリップの音だけ試聴(オン/オフ)・次のクリップへ(ショートカットは持たない)
    case toggleAudition, cycleAudition
    // クリップ ▸ 音声の作り直しで後続を詰める(アプリの設定のオン/オフ。ショートカットなし)
    case toggleVoiceRipple
    case aiScript, aiChapters, aiTitles, aiRewrite, aiSettings
    // 書き出し範囲(イン / アウト / 解除)と、静止画・連番画像の書き出し
    case rangeIn, rangeOut, rangeClear, exportStill, exportSequence
    // タイムラインの問い合わせ: 前後の空白(黒穴)へ・再生位置のクリップを選ぶ・短いクリップを選ぶ・選んだ範囲を書き出し範囲に
    case prevGap, nextGap, selectClipAtPlayhead, cycleOverlapping, selectShortClips, rangeFromSelection, speechShare
    // 選んだクリップの元素材の使用範囲(ソースの使用範囲)を表示し、その頭へ移す
    case sourceUsage
    // 出力 ▸ 使用クリップ一覧…(表・TSV コピー・CSV 書き出し。ショートカットは持たない)
    case clipList
    // 出力 ▸ 台本を書き出す(声のセリフを「名前: セリフ」で)/ 絵コンテを書き出す(代表フレームの PNG)。ショートカットなし
    case exportScript, exportStoryboard
    // 出力 ▸ 注記一覧…(注記のあるクリップの表・テキストと CSV。ショートカットは持たない)
    case noteList
    // 出力 ▸ サムネイル画像を書き出す…(1280×720。ショートカットは持たない)
    case exportThumbnail
    // 出力 ▸ サムネイル候補を書き出す…(点数の高いコマを 5 枚。ショートカットは持たない)
    case exportThumbnailCandidates
    // 出力 ▸ GIFとして書き出す…(ショートカットは持たない)
    case exportGIF
    // 出力 ▸ 書き出しキュー(今の設定の MP4 を積む / キューを表示)と、ファイル ▸ 素材ブラウザ(ショートカットは持たない)
    case queueExport, showExportQueue, audioLibrary
    // 出力 ▸ ラウドネスを測る…、表示 ▸ スコープ…(ショートカットは持たない)
    case measureLoudness, showScopes
    // ファイル ▸ プロジェクトテンプレート(テンプレートとして保存 / テンプレートから新規作成。ショートカットは持たない)
    case saveTemplate, newFromTemplate(String)
    // A6: クリップのコピー / 切り取り / 貼り付け / 全選択(ショートカットは持たない: ⌘C ⌘X ⌘V ⌘A は responder chain が受ける)と、レイヤー
    case copyClips, cutClips, pasteClips, selectAllClips, layerLock, layerSolo, layerTarget, layerDelete, layerHeight(LayerHeight)
    case clipLock
    case split, delete, addText, addBlur, addAdjustment, addVisualizer, addQRCode, addCharacter, makeVoices
    // 図形(クリップ ▸ 図形を追加 ▸ 種類。ショートカットは持たない)
    case addShape(FigureKind)
    // スタンプ(クリップ ▸ スタンプを追加 ▸ 絵文字。ショートカットは持たない)
    case addStamp(String)
    // クリップ(M7)
    case duplicate, rippleDelete, trimBefore, trimAfter, prevClip, nextClip, moveLayerUp, moveLayerDown, addLayer, regenerateVoice
    // クリップ ▸ 選択クリップを再生ヘッドに揃える / つなげて並べる(ショートカットは持たない。1 回の Undo)
    case alignToPlayhead, concatenateClips
    // クリップ ▸ 分割点を統合(連続する同じ素材の分割点を一括で。選んでいればその周り、無ければ全体。ショートカットなし)
    case mergeSplits
    // クリップ ▸ 同じセリフのテイクを比較…(シート。ショートカットなし)
    case compareTakes
    // クリップ ▸ 候補クリップを比較して差し替え…(シート。ショートカットなし)
    case candidateSwap
    // クリップ ▸ 選択クリップを別プロジェクトへ複製…(元の配置のまま。ショートカットなし)
    case transferClips
    // クリップ ▸ 範囲を指定してサブクリップを一括作成…(シート。ショートカットなし)
    case subclipBatch
    case playPause, toStart, stepBack, stepForward
    // 移動(M7)
    case goStart, goEnd, prevEdit, nextEdit, prevLine, nextLine, jumpToTime
    case addMarker, renameMarker, prevMarker, nextMarker, deleteMarker, clearMarkers, jumpToMarker(String)
    // マーカーの色(再生位置のマーカー)
    case markerColor(MarkerColor)
    // キーフレーム / アニメーション
    case toggleKeyframe, prevKeyframe, nextKeyframe, clearKeyframes, animationPreset(AnimationPreset)
    // トランジション(kind が nil = なし)
    case transitionIn(TransitionKind?), transitionOut(TransitionKind?), fadeBoth, clearTransitions, crossfade, fadeInOut
    // エフェクト
    case effectAdd(EffectKind), effectPreset(EffectPreset), effectClear, effectCopy, effectPaste, lutLoad, autoWhiteBalance
    // 文字(スタイルを適用 = id、文字アニメーション)
    case textStyleApply(String), textStyleApplyAll(String), textAnim(TextAnimKind), toggleCounter
    // 配置(ピクチャー・イン・ピクチャーの角)
    case pip(PipCorner)
    // 速度・逆再生・フリーズフレーム
    case speed(Double), toggleReverse, freezeFrame
    // 音声(ノーマライズ・音量の段階・ボイス向けプリセット・エフェクトを外す)
    case audioNormalize, audioVolumeUp, audioVolumeDown, audioVoicePreset, audioClear
    // 無音カット(シートを開く)と、BGM の自動ダッキングの切り替え
    case silenceCut, fillerCut, transcriptEdit, audioDuckToggle, audioAutoSync
    // ビートにマーカーを打つ(選んでいる音のクリップ。ショートカットは持たない)
    case beatMarkers, scaleDuplicate, beatPlace
    // 手ぶれ補正の切り替え(映像クリップ。ショートカットは持たない)
    case stabilizeToggle
    // 縦動画に自動リフレーム(映像・画像。ショートカットは持たない)
    case autoReframe
    // 動きに追従させる(文字・図形・画像。ショートカットは持たない)
    case motionTrack
    // 複合クリップ: まとめる・解除(ショートカットは持たない)
    case compoundGroup, compoundUngroup
    // 編集 ▸ 検索と置換(テロップとセリフの一括置換。ショートカットは持たない)
    case findReplace
    case zoomIn, zoomOut, zoomFit, zoomSelection
    // クリップ ▸ 1 コマ前へ / 後ろへ(ショートカットは持たない: ⌥← は文字欄の単語移動と競合するため)
    case nudgeEarlier, nudgeLater
    case resolution(String), swapResolution, fps(Double), fpsCustom, codec(String), background(String)
    case fullScreen
    // プロキシ編集(表示 ▸ プロキシで編集 は設定の切り替え、出力 ▸ プロキシを作成 はショートカットなし)
    case previewProxyToggle, makeProxies
    // クリップ ▸ AIで画像を作る…(ショートカットは持たない)
    case aiImage
    // 表示 ▸ プレビューの背景(アプリ全体の設定)
    case previewBackground(PreviewBackground)
    // 表示 ▸ ガイド線(プレビューだけ。ショートカットは持たない)
    case guide(PreviewGuide)
    // 画面のドッキング(パネルの表示と、配置のプリセット)
    case dockPanel(DockPanel), dockLayout(DockPreset)
    // ファイル ▸ 最近使った項目 / 起動時の画面を表示(書類がなくても使える。ショートカットは持たない)
    case openRecent(String), clearRecents, welcomeAtLaunchToggle
    case helpShortcuts, helpVoicevox, helpAquestalk, helpLicense, helpThirdParty
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
    /// 書き出し範囲を指定できる / ルーラーに印がある
    var canMarkRange = false
    var hasRange = false
    var rangeLoop = false
    /// 反復再生中(トリム点 / 選択クリップ)と、設定の半幅(秒)
    var trimLoopActive = false
    var trimLoopHalfWidth = TrimLoop.defaultHalfWidth
    /// 音だけの試聴がオン / 再生位置で鳴っているクリップの数
    var auditionActive = false
    var auditionCandidateCount = 0
    /// 音声を作り直したとき後ろのクリップをずらす設定
    var voiceRipple = false
    var hasSelection = false
    /// 文字クリップかボイスクリップがある(検索と置換の対象)
    var hasTextTargets = false
    /// 文字クリップがある(スタイルの一括適用の対象)
    var hasTextClips = false
    /// A6: 選んでいるクリップの数 / 貼り付けられるものがある / クリップが 1 つでもある
    var selectionCount = 0
    var canPasteClips = false
    var hasClips = false
    /// 注記のあるクリップが 1 つ以上ある(注記一覧を押せる)。
    var hasNotes = false
    /// B3: 書き出せる字幕がある / マーカーがある
    var canExportSubtitles = false
    var canGenerateSubtitles = false
    /// 選んでいるクリップが音声認識の対象(音のある素材で、速度・逆再生なし)
    var canTranscribe = false
    var hasMissingMedia = false
    var hasUnusedMedia = false
    var hasGaps = false
    /// 再生位置に画面で重なって見えているクリップの数(巡回選択は 2 つ以上で使える)
    var overlapCount = 0
    var hasShortClips = false
    /// 統合できる分割点がある(選んでいればその周り、無ければ全体)
    var hasMergeableSplits = false
    /// 同じセリフのボイスクリップが 2 つ以上ある(テイクの比較)
    var hasTakeGroups = false
    /// 選んだクリップに、差し替えの候補(同じ種類の素材)がある
    var canCandidateSwap = false
    /// 選んでいるクリップ 1 つが、元素材の使用範囲を持つ(動画・音声・画像で、フリーズでない)。
    var hasSourceUsage = false
    /// 声のクリップが 1 つ以上ある(台本の書き出し)。
    var hasVoiceClips = false
    var hasSelectionSpan = false
    /// 選んでいるのが src のある静止画(背景抜き・クロマキーに使える)。
    var selectedIsStill = false
    var hasMarkers = false
    var markerColorCounts: [MarkerColor: Int] = [:]   // 色ごとのマーカーの数(チャプターを色でコピー)
    /// ファイル ▸ テンプレートから新規作成 の一覧(保存されている名前・名前順)
    var templateNames: [String] = []
    /// ファイル ▸ 最近使った項目(新しい順)と、起動時の画面を出す設定
    var recentItems: [RecentMenuItem] = []
    var welcomeAtLaunch = true
    /// A6: メニューの対象のレイヤー(選んだクリップのレイヤー、無ければヘッダーで選んだレイヤー)の状態
    var hasLayerTarget = false
    var layerLocked = false
    /// 選んだクリップが全部ロック済み(メニューは「ロックを解除」になる)
    var clipsLocked = false
    var layerSolo = false
    /// 対象のレイヤーがトラックターゲット(新しく足すクリップの行き先)
    var layerIsTarget = false
    /// 選んだクリップ 1 つが、隣り合うクリップとのロールができる / スリップできる
    var canRoll = false
    var canSlip = false
    /// 対象のレイヤーを消せない理由(消せるなら nil)。レイヤーがなければ nil で hasLayerTarget が false
    var layerDeleteBlocked: String?
    var layerHeight = LayerHeight.normal
    var canSplit = false
    var resolutionKey = ""
    var fps = 0.0
    /// 「最近使ったカスタム」(新しい順・最大 3 件)。
    var recentResolutions: [String] = []
    var recentFps: [Double] = []
    /// 今のサイズが H.264 の上限を超える(書き出しは HEVC になる)。
    var h264Unsupported = false
    var codec = ""
    var bg = ""
    /// 画面に出ているパネル(ドッキング or 別ウインドウ)。アプリ全体の設定。
    var dockVisible = Set(DockPanel.allCases)
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
    /// 再生位置のマーカーの色(無ければ既定の色)。
    var playheadMarkerColor = MarkerColor.default
    var hasPrevMarker = false
    var hasNextMarker = false
    // キーフレーム
    var canKeyframe = false          // 選択クリップが動かせる種類で、再生位置がその中
    var hasKeyframes = false         // 選択クリップにキーが 1 つでもある
    var hasPrevKeyframe = false
    var hasNextKeyframe = false
    var canAnimatePreset = false     // 画像・動画・文字のクリップを選んでいる
    // トランジション
    var canTransition = false        // 映像のクリップ(画像・動画・文字)を選んでいる
    var hasTransitions = false
    var canFadeInOut = false         // 映像か音声のクリップを選んでいる
    var transitionInKind: String?    // 選択クリップの頭・終わりの種類(なければ nil)
    var transitionOutKind: String?
    // エフェクト
    var canEffect = false            // 映像のクリップ(画像・動画・文字)を選んでいる
    var hasEffects = false           // 選択クリップにエフェクトが 1 つでもある
    var canPasteEffects = false      // コピーしたエフェクトがある
    var canAutoColor = false         // 画像か動画のクリップを選んでいる(自動ホワイトバランスの対象)
    // 文字
    var isTextClip = false           // 文字クリップを選んでいる
    var textAnimKind: TextAnimKind = .none
    var hasCounter = false           // 選択中の文字クリップにカウントダウンが付いている
    var canPip = false               // 映像に見える素材(画像・動画・文字)を選んでいる
    var textStyleChoices: [TextStyleChoice] = []
    struct TextStyleChoice: Equatable { var id: String; var name: String; var builtin: Bool }
    // 速度
    var canSpeed = false             // 動画か音声のクリップ(フリーズ以外)を選んでいる
    var speedValue = 1.0             // 選択クリップの速度
    var isReversed = false
    var canFreezeFrame = false       // 動画クリップを選び、再生位置がその中
    // 音声
    var canAudioFx = false           // 音声・ボイス・動画(フリーズ以外)のクリップを選んでいる
    var hasAudioFx = false           // 選択クリップに音声エフェクトかパンがある
    var canSilenceCut = false        // 無音カットできるクリップ(音のある素材。速度・逆再生なし)を選んでいる
    var canAudioAutoSync = false     // 動画 1 つと音声 1 つを選んでいる(音で自動同期できる)
    var canPitchLayout = false       // 音程を変えて並べられるクリップ(音のある・ロックでない)を選んでいる
    var canBeatPlace = false         // 上に加えて、クリップの位置以降にマーカーがある
    var canBeatMarkers = false       // ビートを測れるクリップ(無音カットと同じ条件)を選んでいる
    var canDuck = false              // BGM(音声クリップ)を選んでいる
    var isDucking = false            // 選択クリップの自動ダッキングがオン
    var canStabilize = false         // 映像クリップを選んでいる(手ぶれ補正ができる)
    var isStabilized = false         // 選択クリップの手ぶれ補正がオン
    var canAutoReframe = false       // 映像・画像を選んでいる(縦動画に自動リフレームできる)
    var canMotionTrack = false       // 文字・図形・画像を選んでいて、下に映像・画像のレイヤーがある(動きに追従できる)
    var canCompoundGroup = false     // 2 つ以上のクリップを選んでいる(まとめられる)
    var canCompoundUngroup = false   // 選択が複合クリップ(解除できる)
    /// 表示 ▸ プレビューの背景(アプリ全体の設定)。
    var previewBackground = PreviewBackground.default
    /// 表示 ▸ ガイド線: 出しているガイド(アプリ全体の設定)。
    var previewGuides: Set<PreviewGuide> = []
    /// 出力 ▸ ファン(アプリ全体の設定)。使える / オン / 使えない理由 / 対象機種でヘルパー未導入 / ヘルパー導入済み。
    var fanAvailable = false
    var fanEnabled = false
    var fanReason: String?
    var fanCanInstall = false
    var fanInstalled = false
    /// プロキシ編集: 表示のチェック / 映像の素材があって作れる
    var previewProxyEnabled = false
    var canMakeProxies = false

    struct MarkerItem: Equatable {
        var id: String
        var time: Double
        var name: String
    }

    init() {}

    @MainActor
    init(model: ProjectModel?) {
        previewBackground = PreviewBackgroundStore.current
        previewGuides = PreviewGuideStore.current
        templateNames = ProjectTemplateLibrary.names
        let rc = RecentProjectsController.shared
        recentItems = rc.recents.entries.map { RecentMenuItem(path: $0.path, name: $0.name, missing: rc.isMissing($0)) }
        welcomeAtLaunch = WelcomeSettings.showAtLaunch()
        let fan = AppServices.fan
        fanAvailable = fan.isAvailable
        fanEnabled = fan.enabled
        fanReason = fan.reason
        fanCanInstall = fan.machineSupported && fan.availability != nil && !fan.helperInstalled && !fan.busy
        fanInstalled = fan.helperInstalled && !fan.busy
        previewProxyEnabled = ProxySettings.enabled()
        dockVisible = Set(DockPanel.allCases.filter { AppServices.panelDock.layout.isVisible($0) })
        guard let m = model else { return }
        hasDocument = true
        isLocked = m.isLocked
        canExport = m.canExport
        canMarkRange = m.canMarkRange
        hasRange = m.hasRangeMarks
        rangeLoop = m.rangeLoop
        trimLoopActive = m.trimLoop != nil
        trimLoopHalfWidth = TrimLoopSettings.halfWidth
        voiceRipple = VoiceRippleSettings.enabled
        auditionActive = m.auditionOn
        auditionCandidateCount = m.auditionCandidates.count
        hasSelection = m.selectedClip != nil
        hasTextTargets = m.project.allClips.contains { $0.type == .text || $0.type == .voice }
        hasTextClips = m.project.allClips.contains { $0.type == .text }
        canMakeProxies = !m.videoSourcePaths.isEmpty
        selectionCount = m.selectedClipIDs.count
        canPasteClips = m.canPasteClips
        hasClips = !m.project.allClips.isEmpty
        hasNotes = m.project.allClips.contains { $0.note != nil }
        canExportSubtitles = m.canExportSubtitles
        canGenerateSubtitles = SubtitleGeneration.hasTargets(m.project)
        hasMissingMedia = !MissingMedia.find(in: m.project).isEmpty
        hasUnusedMedia = !UnusedMedia.find(in: m.project).isEmpty
        hasGaps = !TimelineQuery.gapStarts(in: m.project).isEmpty
        overlapCount = PreviewPicking.stack(in: m.project, at: m.currentTime).count
        hasShortClips = !TimelineQuery.shortClipIds(in: m.project).isEmpty
        hasMergeableSplits = ClipMerge.hasMergeable(in: m.project, scope: m.mergeScope)
        hasTakeGroups = !TakeCompare.groups(in: m.project).isEmpty
        canCandidateSwap = m.canOpenCandidateSwap
        hasSourceUsage = m.selectedClip.flatMap { SourceUsage.range(of: $0) } != nil
        hasVoiceClips = m.project.allClips.contains { $0.type == .voice }
        hasSelectionSpan = TimelineQuery.span(ofClipIds: m.selectedClipIDs, in: m.project) != nil
        selectedIsStill = m.selectedClip.map { $0.type == .image && $0.src != nil } ?? false
        hasMarkers = !m.project.markers.isEmpty
        markerColorCounts = Chapters.colorCounts(m.project.markers)
        if let li = m.targetLayerIndex, m.project.tracks.indices.contains(li) {
            hasLayerTarget = true
            layerLocked = m.project.tracks[li].isLocked
            layerSolo = m.project.tracks[li].isSolo
            layerIsTarget = m.project.targetTrackId == m.project.tracks[li].id
            layerDeleteBlocked = LayerEditing.deleteBlockedReason(in: m.project, index: li)
            layerHeight = LayerHeight.of(m.project.tracks[li])
        }
        clipsLocked = LayerEditing.allClipsLocked(m.selectedClipIDs, in: m.project)
        canSplit = m.canSplit
        canRoll = m.canRoll
        canSlip = m.canSlip
        resolutionKey = m.resolutionKey
        fps = m.project.fps
        recentResolutions = RecentCustoms.resolutions().items
        recentFps = RecentCustoms.frameRates().rates
        h264Unsupported = !OutputPlan.h264Supports(width: m.project.width, height: m.project.height)
        codec = m.project.codec
        bg = m.project.bg
        let p = m.project, t = m.currentTime
        if let c = m.selectedClip {
            canTrim = ClipEditing.canTrim(c, at: t)
            isVoiceSelected = c.type == .voice
            if let loc = ClipEditing.locate(c.id, in: p) {
                canMoveUp = loc.track > 0
                canMoveDown = loc.track < p.tracks.count - 1
            }
        }
        if let c = m.selectedClip {
            let ks = m.keyframeTargetKey
            canKeyframe = !Animation.keys(for: c).isEmpty && t >= c.start - ClipEditing.timeEpsilon && t <= c.start + c.duration + ClipEditing.timeEpsilon
            hasKeyframes = c.hasKeyframes
            let tol = m.keyTolerance, rel = t - c.start
            hasPrevKeyframe = KeyframeEditing.previousKeyTime(c, key: ks, before: rel, tolerance: tol) != nil
            hasNextKeyframe = KeyframeEditing.nextKeyTime(c, key: ks, after: rel, tolerance: tol) != nil
            canAnimatePreset = [ClipType.image, .video, .text].contains(c.type)
            canTransition = TransitionEditing.supportsVideo(c.type)
            hasTransitions = c.hasTransition
            canFadeInOut = TransitionEditing.supportsVideo(c.type) || TransitionEditing.supportsAudio(c.type)
            transitionInKind = c.transitionIn?.kind
            transitionOutKind = c.transitionOut?.kind
            canEffect = EffectEditing.supports(c.type)
            hasEffects = !c.effects.isEmpty
            canAutoColor = c.type == .image || c.type == .video
            isTextClip = c.type == .text
            textAnimKind = c.textAnim?.known ?? .none
            hasCounter = c.counter != nil
            canPip = PictureInPicture.supports(c.type)
            canSpeed = SpeedEditing.supports(c)
            speedValue = c.effectiveSpeed
            isReversed = c.effectiveReverse
            canFreezeFrame = SpeedEditing.canFreeze(c, at: t)
            canAudioFx = AudioFxEditing.supports(c)
            hasAudioFx = AudioFxEditing.hasAnyFx(c)
            canSilenceCut = SilenceDetector.supports(c)
            canBeatMarkers = BeatDetector.supports(c)
            canPitchLayout = m.selectedClipIDs.count <= 1 && PitchLayout.supports(c, in: p)
            canBeatPlace = canPitchLayout && !PitchLayout.markerTimes(in: p, from: c.start, beatsOnly: false).isEmpty
            canTranscribe = TranscriptionSupport.supports(c)
            canDuck = DuckEditing.supports(c)
            isDucking = c.hasDuck
            canStabilize = StabilizeEditing.supports(c)
            isStabilized = c.stabilizeStrength > 0
            canAutoReframe = m.canAutoReframe(c)
            canMotionTrack = m.canTrackMotion(c)
            canCompoundUngroup = CompoundEditing.supports(c)
        }
        canCompoundGroup = m.selectedClipIDs.count >= 2
        canAudioAutoSync = AudioSyncEditing.isAvailable(in: p, ids: m.selectedClipIDs)
        canPasteEffects = !m.effectClipboard.isEmpty
        textStyleChoices = m.textStyles.all.map { TextStyleChoice(id: $0.id, name: $0.name, builtin: $0.isBuiltin) }
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
        playheadMarkerColor = MarkerColor.resolved(m.markerNearPlayhead?.color)
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
    // 出力 ▸ ファン(書き出し中はファンを最大にする)。アプリ全体の設定なので書類がなくても押せる。
    static func fanMaxToggle(_ s: MenuState) -> MenuItemSpec {
        MenuItemSpec(command: .fanMaxToggle, title: "書き出し中はファンを最大にする", shortcut: nil, enabled: s.fanAvailable || s.fanEnabled, checked: s.fanEnabled, hint: s.fanAvailable ? nil : s.fanReason)
    }
    static func fanInstall(_ s: MenuState) -> MenuItemSpec {
        MenuItemSpec(command: .fanInstall, title: "ファン制御を有効にする…", shortcut: nil, enabled: s.fanCanInstall, checked: nil)
    }
    static func fanUninstall(_ s: MenuState) -> MenuItemSpec {
        MenuItemSpec(command: .fanUninstall, title: "ファン制御を無効にする…", shortcut: nil, enabled: s.fanInstalled, checked: nil)
    }

    static func videoSettings(_ s: MenuState) -> MenuItemSpec {
        MenuItemSpec(command: .videoSettings, title: "動画の設定…", shortcut: nil, enabled: s.canEdit, checked: nil)
    }

    static let fpsPresets = FrameRate.presets

    static func fpsTitle(_ v: Double) -> String { "\(FrameRate.label(v)) fps" }

    /// FPS のラジオ(定番のレート)。今のレートに ✓。
    static func fpsItems(_ s: MenuState) -> [MenuItemSpec] {
        fpsPresets.map {
            MenuItemSpec(command: .fps($0), title: fpsTitle($0), shortcut: nil, enabled: s.canEdit, checked: s.hasDocument && FrameRate.same($0, s.fps))
        }
    }

    /// 「最近使ったカスタム」のレート。今のレートが定番でも履歴にもなければ、✓ 付きでここに足す。
    static func recentFpsItems(_ s: MenuState) -> [MenuItemSpec] {
        var list = s.recentFps.filter { v in !fpsPresets.contains { FrameRate.same($0, v) } }
        if s.hasDocument, s.fps > 0, !fpsPresets.contains(where: { FrameRate.same($0, s.fps) }), !list.contains(where: { FrameRate.same($0, s.fps) }) {
            list.insert(s.fps, at: 0)
        }
        return list.map {
            MenuItemSpec(command: .fps($0), title: fpsTitle($0), shortcut: nil, enabled: s.canEdit, checked: s.hasDocument && FrameRate.same($0, s.fps))
        }
    }

    static func customFps(_ s: MenuState) -> MenuItemSpec {
        MenuItemSpec(command: .fpsCustom, title: "カスタム…", shortcut: nil, enabled: s.canEdit, checked: nil)
    }

    static func file(_ s: MenuState) -> [MenuItemSpec] {
        [MenuItemSpec(command: .addMedia, title: "素材を追加…", shortcut: cmd("i"), enabled: s.canEdit, checked: nil),
         MenuItemSpec(command: .importPSD, title: "PSDを読み込む…", shortcut: nil, enabled: s.canEdit, checked: nil, hint: "レイヤーごとに画像クリップへ"),
         MenuItemSpec(command: .importRigFolder, title: "立ち絵パーツのフォルダを読み込む…", shortcut: nil, enabled: s.canEdit, checked: nil, hint: "眉・目・口などを重ねて動かす"),
         MenuItemSpec(command: .importRigPSD, title: "PSDから立ち絵を作る…", shortcut: nil, enabled: s.canEdit, checked: nil, hint: "グループ名からパーツに分ける"),
         MenuItemSpec(command: .audioLibrary, title: "素材ブラウザを開く…", shortcut: nil, enabled: s.canEdit, checked: nil, hint: "BGM・効果音のフォルダ"),
         MenuItemSpec(command: .addFont, title: "フォントを追加…", shortcut: nil, enabled: true, checked: nil, hint: "テキストで使えるようにする")]
    }

    /// ファイル ▸ 字幕を読み込む…(ショートカットは持たない)。
    static func subtitleImport(_ s: MenuState) -> MenuItemSpec {
        MenuItemSpec(command: .importSubtitles, title: "字幕を読み込む…", shortcut: nil, enabled: s.canEdit, checked: nil)
    }

    /// 出力 ▸ 字幕を書き出す… / チャプターをコピー(ショートカットは持たない)。
    static func subtitleExport(_ s: MenuState) -> MenuItemSpec {
        MenuItemSpec(command: .exportSubtitles, title: "字幕を書き出す…", shortcut: nil, enabled: s.canEdit && s.canExportSubtitles, checked: nil, hint: "SRT / VTT")
    }

    /// 出力 ▸ 字幕を翻訳して書き出す…(AI。送る前と保存の前に内容を見せる)
    static func subtitleTranslate(_ s: MenuState) -> MenuItemSpec {
        MenuItemSpec(command: .translateSubtitles, title: "字幕を翻訳して書き出す…", shortcut: nil, enabled: s.canEdit && s.canExportSubtitles, checked: nil, hint: "AI で訳して SRT")
    }

    /// 出力 ▸ 字幕を自動生成(台本のセリフから字幕の文字クリップを作る。ショートカットなし)。
    static func subtitleGenerate(_ s: MenuState) -> MenuItemSpec {
        MenuItemSpec(command: .generateSubtitles, title: "字幕を自動生成", shortcut: nil, enabled: s.canEdit && s.canGenerateSubtitles, checked: nil, hint: "セリフから")
    }

    /// 出力 ▸ 音声から字幕を作る…(選んでいる音のあるクリップを音声認識し、字幕レイヤーに文字クリップを足す。ショートカットなし)。
    static func transcribeSubtitles(_ s: MenuState) -> MenuItemSpec {
        MenuItemSpec(command: .transcribeSubtitles, title: "音声から字幕を作る…", shortcut: nil, enabled: s.canEdit && s.canTranscribe, checked: nil, hint: "音声認識")
    }

    /// ファイル ▸ 素材の場所を再指定…(欠けている素材があるときだけ。フォルダを選んで探し直す)。
    static func mediaRelink(_ s: MenuState) -> MenuItemSpec {
        MenuItemSpec(command: .relinkMedia, title: "素材の場所を再指定…", shortcut: nil, enabled: s.canEdit && s.hasMissingMedia, checked: nil, hint: "欠けた素材")
    }

    /// ファイル ▸ 未使用の素材…(どのクリップにも使われていない取り込み済みの素材を整理する。ショートカットなし)。
    static func unusedMediaItem(_ s: MenuState) -> MenuItemSpec {
        MenuItemSpec(command: .unusedMedia, title: "未使用の素材…", shortcut: nil, enabled: s.canEdit && s.hasUnusedMedia, checked: nil, hint: "使っていない素材を整理")
    }

    /// 静止画の背景抜き(Vision)と、色で抜く(クロマキー)。どちらも静止画のクリップを選んでいるときだけ使える。
    static func cutoutItems(_ s: MenuState) -> [MenuItemSpec] {
        [MenuItemSpec(command: .removeBackground, title: "静止画の背景を抜く", shortcut: nil, enabled: s.canEdit && s.selectedIsStill, checked: nil, hint: "人物などを自動で切り抜く"),
         MenuItemSpec(command: .imageChroma, title: "静止画の背景を色で抜く(クロマキー)", shortcut: nil, enabled: s.canEdit && s.selectedIsStill, checked: nil, hint: "緑などの背景を透明に")]
    }

    /// 字幕 ▸ 字幕を追加…(再生位置に字幕を足す。選んだ文字クリップがあれば、その文を直す)。
    static func addSubtitle(_ s: MenuState) -> MenuItemSpec {
        MenuItemSpec(command: .addSubtitle, title: "字幕を追加…", shortcut: nil, enabled: s.canEdit, checked: nil, hint: "再生位置に字幕")
    }

    /// ファイル ▸ パッケージとして保存…(プロジェクトと使っている素材を 1 つのフォルダへ)。
    static func packageSave(_ s: MenuState) -> MenuItemSpec {
        MenuItemSpec(command: .packageSave, title: "パッケージとして保存…", shortcut: nil, enabled: s.canEdit, checked: nil, hint: "素材ごとフォルダへ")
    }

    /// ファイル ▸ 最近使った項目 ▸ 各プロジェクト(見つからないものは無効)。
    static func recentItems(_ s: MenuState) -> [MenuItemSpec] {
        s.recentItems.map { MenuItemSpec(command: .openRecent($0.path), title: $0.name, shortcut: nil, enabled: !$0.missing, checked: nil, hint: $0.missing ? "見つかりません" : nil) }
    }

    /// ファイル ▸ 最近使った項目 ▸ メニューを消去(履歴があるときだけ有効)。
    static func recentClear(_ s: MenuState) -> MenuItemSpec {
        MenuItemSpec(command: .clearRecents, title: "メニューを消去", shortcut: nil, enabled: !s.recentItems.isEmpty, checked: nil)
    }

    /// ファイル ▸ 起動時の画面を表示(✓ のとき、起動時に最近使ったプロジェクトの画面を出す。書類がなくても使える)。
    static func welcomeToggle(_ s: MenuState) -> MenuItemSpec {
        MenuItemSpec(command: .welcomeAtLaunchToggle, title: "起動時の画面を表示", shortcut: nil, enabled: true, checked: s.welcomeAtLaunch)
    }

    /// ファイル ▸ テンプレートとして保存…(含める項目を選べる。ショートカットなし)。
    static func templateSave(_ s: MenuState) -> MenuItemSpec {
        MenuItemSpec(command: .saveTemplate, title: "テンプレートとして保存…", shortcut: nil, enabled: s.canEdit, checked: nil, hint: "含める項目を選べる")
    }

    /// ファイル ▸ テンプレートから新規作成 ▸ の各テンプレート(開くと無題の書類になる)。
    static func templateNewItems(_ s: MenuState) -> [MenuItemSpec] {
        s.templateNames.map { MenuItemSpec(command: .newFromTemplate($0), title: $0, shortcut: nil, enabled: true, checked: nil) }
    }

    /// 出力 ▸ チャプターを色でコピー ▸ ○○のマーカーだけ(その色のマーカーが 1 つ以上あるときだけ有効)。ショートカットなし。
    static func chapterColorItems(_ s: MenuState) -> [MenuItemSpec] {
        MarkerColor.allCases.map { c in
            MenuItemSpec(command: .copyChaptersColor(c), title: "\(c.title)のマーカーだけ", shortcut: nil,
                         enabled: s.canEdit && (s.markerColorCounts[c] ?? 0) > 0, checked: nil, hint: (s.markerColorCounts[c] ?? 0) > 0 ? "\(s.markerColorCounts[c] ?? 0) 件" : nil)
        }
    }

    static func chapterCopy(_ s: MenuState) -> MenuItemSpec {
        MenuItemSpec(command: .copyChapters, title: "チャプターをコピー", shortcut: nil, enabled: s.canEdit && s.hasMarkers, checked: nil, hint: "YouTube")
    }

    /// AI 連携(ショートカットなし。どれもメニューを選んだときだけ働く)。
    static func aiScript(_ s: MenuState) -> MenuItemSpec {
        MenuItemSpec(command: .aiScript, title: "AIで台本を作る…", shortcut: nil, enabled: s.canEdit, checked: nil)
    }
    static func aiSettings(_ s: MenuState) -> MenuItemSpec {
        MenuItemSpec(command: .aiSettings, title: "AI の設定…", shortcut: nil, enabled: s.canEdit, checked: nil)
    }
    static func aiChapters(_ s: MenuState) -> MenuItemSpec {
        MenuItemSpec(command: .aiChapters, title: "チャプター案をAIで作る…", shortcut: nil, enabled: s.canEdit && s.canExportSubtitles, checked: nil)
    }
    static func aiTitles(_ s: MenuState) -> MenuItemSpec {
        MenuItemSpec(command: .aiTitles, title: "タイトル案をAIで作る…", shortcut: nil, enabled: s.canEdit && (s.canExportSubtitles || s.hasMarkers), checked: nil)
    }
    static func aiRewrite(_ s: MenuState) -> MenuItemSpec {
        MenuItemSpec(command: .aiRewrite, title: "AIでセリフを直す…", shortcut: nil, enabled: s.canEdit && s.isVoiceSelected, checked: nil)
    }

    /// 出力 ▸ MP4 を書き出す…(⌘E)と、書き出しプリセット。
    static func exportCurrent(_ s: MenuState) -> MenuItemSpec {
        MenuItemSpec(command: .export, title: "MP4 を書き出す…", shortcut: cmd("e"), enabled: s.canEdit && s.canExport, checked: nil)
    }

    /// 出力 ▸ 書き出し範囲(開始 / 終了を現在位置に・解除)。ショートカットは持たない。
    static func rangeItems(_ s: MenuState) -> [MenuItemSpec] {
        [MenuItemSpec(command: .rangeIn, title: "書き出し開始を現在位置に", shortcut: nil, enabled: s.canEdit && s.canMarkRange, checked: nil),
         MenuItemSpec(command: .rangeOut, title: "書き出し終了を現在位置に", shortcut: nil, enabled: s.canEdit && s.canMarkRange, checked: nil),
         MenuItemSpec(command: .rangeClear, title: "範囲を解除", shortcut: nil, enabled: s.canEdit && s.canMarkRange && s.hasRange, checked: nil),
         MenuItemSpec(command: .rangeFromSelection, title: "選択クリップの範囲を書き出し範囲に", shortcut: nil, enabled: s.canEdit && s.canMarkRange && s.hasSelectionSpan, checked: nil, hint: "頭から終わりまで")]
    }

    /// 出力 ▸ 現在のフレームを画像で書き出す… / 連番画像を書き出す…
    static func imageExportItems(_ s: MenuState) -> [MenuItemSpec] {
        [MenuItemSpec(command: .exportStill, title: "現在のフレームを画像で書き出す…", shortcut: nil, enabled: s.canEdit && s.canExport, checked: nil, hint: "PNG / JPEG"),
         MenuItemSpec(command: .exportSequence, title: "連番画像を書き出す…", shortcut: nil, enabled: s.canEdit && s.canExport, checked: nil, hint: "name_00001.png"),
         MenuItemSpec(command: .exportThumbnail, title: "サムネイル画像を書き出す…", shortcut: nil, enabled: s.canEdit && s.canExport, checked: nil, hint: "1280×720"),
         MenuItemSpec(command: .exportThumbnailCandidates, title: "サムネイル候補を書き出す…", shortcut: nil, enabled: s.canEdit && s.canExport, checked: nil, hint: "自動で 5 枚")]
    }

    /// 出力 ▸ GIFとして書き出す…(保存パネルで fps・幅・範囲を決める。ショートカットは持たない)。
    static func gifExport(_ s: MenuState) -> MenuItemSpec {
        MenuItemSpec(command: .exportGIF, title: "GIFとして書き出す…", shortcut: nil, enabled: s.canEdit && s.canExport, checked: nil, hint: "アニメーション GIF")
    }

    /// 出力 ▸ 書き出しキューに追加… / 書き出しキューを表示…(ショートカットは持たない)。
    static func scopeItem(_ s: MenuState) -> MenuItemSpec {
        MenuItemSpec(command: .showScopes, title: "スコープ…", shortcut: nil, enabled: true, checked: nil, hint: "波形・ヒストグラム(今のコマ)")
    }

    /// 出力 ▸ 使用クリップ一覧…(クリップが 1 つ以上あるとき。ショートカットは持たない)。
    static func noteListItem(_ s: MenuState) -> MenuItemSpec {
        MenuItemSpec(command: .noteList, title: "注記一覧…", shortcut: nil, enabled: s.hasNotes, checked: nil, hint: "クリップのメモの表")
    }

    /// 出力 ▸ 台本を書き出す… / 絵コンテを書き出す…(ショートカットなし)。
    static func scriptStoryboardItems(_ s: MenuState) -> [MenuItemSpec] {
        [MenuItemSpec(command: .exportScript, title: "台本を書き出す…", shortcut: nil, enabled: s.hasVoiceClips, checked: nil, hint: "声のセリフを「名前: セリフ」で"),
         MenuItemSpec(command: .exportStoryboard, title: "絵コンテを書き出す…", shortcut: nil, enabled: s.canEdit && s.canExport, checked: nil, hint: "代表フレーム 12 枚の PNG")]
    }

    static func clipListItem(_ s: MenuState) -> MenuItemSpec {
        MenuItemSpec(command: .clipList, title: "使用クリップ一覧…", shortcut: nil, enabled: s.hasClips, checked: nil, hint: "レイヤー・時間・素材の表")
    }

    static func loudnessItem(_ s: MenuState) -> MenuItemSpec {
        MenuItemSpec(command: .measureLoudness, title: "ラウドネスを測る…", shortcut: nil, enabled: s.canEdit && s.canExport, checked: nil, hint: "LUFS と真のピーク")
    }

    static func exportQueueItems(_ s: MenuState) -> [MenuItemSpec] {
        [MenuItemSpec(command: .queueExport, title: "書き出しキューに追加…", shortcut: nil, enabled: s.canEdit && s.canExport, checked: nil, hint: "今の設定で MP4"),
         MenuItemSpec(command: .showExportQueue, title: "書き出しキューを表示…", shortcut: nil, enabled: s.canEdit, checked: nil)]
    }

    /// 出力 ▸ 書き出しプリセット: 組み込み + 保存したプリセット(`custom` は呼び出し側が読んで渡す)。
    static func exportPresets(_ s: MenuState, custom: [CustomExportPreset] = []) -> [MenuItemSpec] {
        ExportPreset.allCases.map {
            MenuItemSpec(command: .exportPreset($0), title: $0.title, shortcut: nil, enabled: s.canEdit && s.canExport, checked: nil, hint: $0.summary)
        } + custom.map {
            MenuItemSpec(command: .exportCustomPreset($0.name), title: $0.name, shortcut: nil, enabled: s.canEdit && s.canExport, checked: nil,
                         hint: "\($0.width)×\($0.height) · \($0.codec == "hevc" ? "HEVC" : "H.264")")
        }
    }

    /// 出力 ▸ 書き出しプリセット ▸ 現在の設定をプリセットに保存…(ショートカットは持たない)。
    static func saveCustomPreset(_ s: MenuState) -> MenuItemSpec {
        MenuItemSpec(command: .saveCustomPreset, title: "現在の設定をプリセットに保存…", shortcut: nil, enabled: s.canEdit, checked: nil, hint: "名前を付けて保存")
    }

    // MARK: クリップメニュー

    /// 追加(テキスト・ぼかし範囲)。
    static func addQRCode(_ s: MenuState) -> MenuItemSpec {
        MenuItemSpec(command: .addQRCode, title: "QRコードを追加…", shortcut: nil, enabled: s.canEdit, checked: nil)
    }
    static func clipAdd(_ s: MenuState) -> [MenuItemSpec] {
        [MenuItemSpec(command: .addText, title: "テキストを追加", shortcut: cmd("t", shift: true), enabled: s.canEdit, checked: nil),
         MenuItemSpec(command: .addBlur, title: "ぼかし範囲を追加", shortcut: cmd("b", shift: true), enabled: s.canEdit, checked: nil),
         MenuItemSpec(command: .addAdjustment, title: "調整レイヤーを追加", shortcut: nil, enabled: s.canEdit, checked: nil, hint: "下の全レイヤーに効く"),
         MenuItemSpec(command: .addVisualizer, title: "音声ビジュアライザを追加", shortcut: nil, enabled: s.canEdit, checked: nil, hint: "合成音声の大きさで動く"),
         addQRCode(s),
         aiImage(s)]
    }

    /// クリップ ▸ 図形を追加 ▸ 四角形・楕円・線・矢印・星(ショートカットは持たない)。
    static func shapeItems(_ s: MenuState) -> [MenuItemSpec] {
        FigureKind.allCases.map {
            MenuItemSpec(command: .addShape($0), title: $0.title, shortcut: nil, enabled: s.canEdit, checked: nil)
        }
    }

    /// クリップ ▸ スタンプを追加 ▸ 組み込みの 24 種(ショートカットは持たない)。
    static func stampItems(_ s: MenuState) -> [MenuItemSpec] {
        StampCatalog.items.map {
            MenuItemSpec(command: .addStamp($0.emoji), title: "\($0.emoji) \($0.title)", shortcut: nil, enabled: s.canEdit, checked: nil)
        }
    }

    /// クリップ ▸ AIで画像を作る…(ローカルのコマンドが画像を書く。送る前に内容を確認。ショートカットは持たない)
    static func aiImage(_ s: MenuState) -> MenuItemSpec {
        MenuItemSpec(command: .aiImage, title: "AIで画像を作る…", shortcut: nil, enabled: s.canEdit, checked: nil, hint: "ローカルのコマンド")
    }

    /// 分割・複製・削除(S / Delete は KeyRouter が受けるので、メニューにはキーを付けずヒントだけ添える)。
    static func clipEdit(_ s: MenuState) -> [MenuItemSpec] {
        [MenuItemSpec(command: .split, title: "クリップを分割", shortcut: nil, enabled: s.canEdit && s.canSplit, checked: nil, hint: "S"),
         MenuItemSpec(command: .duplicate, title: "クリップを複製", shortcut: cmd("d"), enabled: s.canEdit && s.hasSelection, checked: nil),
         clipLockItem(s),
         MenuItemSpec(command: .delete, title: "クリップを削除", shortcut: nil, enabled: s.canEdit && s.hasSelection, checked: nil, hint: "⌫"),
         MenuItemSpec(command: .rippleDelete, title: "すき間を詰めて削除", shortcut: MenuShortcut(key: .delete, modifiers: [.option, .command]), enabled: s.canEdit && s.hasSelection, checked: nil),
         MenuItemSpec(command: .alignToPlayhead, title: "選択クリップを再生ヘッドに揃える", shortcut: nil, enabled: s.canEdit && s.hasSelection, checked: nil, hint: "一番手前の頭を再生ヘッドへ"),
         MenuItemSpec(command: .concatenateClips, title: "選択クリップをつなげて並べる", shortcut: nil, enabled: s.canEdit && s.selectionCount >= 2, checked: nil, hint: "2 つ以上選ぶ"),
         MenuItemSpec(command: .nudgeEarlier, title: "1 コマ前へ動かす", shortcut: nil, enabled: s.canEdit && s.hasSelection, checked: nil),
         MenuItemSpec(command: .nudgeLater, title: "1 コマ後ろへ動かす", shortcut: nil, enabled: s.canEdit && s.hasSelection, checked: nil),
         MenuItemSpec(command: .stabilizeToggle, title: "手ぶれ補正（映像を滑らかにする）", shortcut: nil, enabled: s.canEdit && s.canStabilize, checked: s.canStabilize ? s.isStabilized : nil),
         MenuItemSpec(command: .autoReframe, title: "縦動画に自動リフレーム", shortcut: nil, enabled: s.canEdit && s.canAutoReframe, checked: nil),
         MenuItemSpec(command: .motionTrack, title: "動きに追従させる", shortcut: nil, enabled: s.canEdit && s.canMotionTrack, checked: nil),
         MenuItemSpec(command: .compoundGroup, title: "複合クリップにまとめる", shortcut: nil, enabled: s.canEdit && s.canCompoundGroup, checked: nil),
         MenuItemSpec(command: .compoundUngroup, title: "複合クリップを解除", shortcut: nil, enabled: s.canEdit && s.canCompoundUngroup, checked: nil)]
    }

    /// クリップ ▸ クリップをロック / ロックを解除(選択の状態でラベルが変わる。ショートカットなし)。
    static func clipLockItem(_ s: MenuState) -> MenuItemSpec {
        MenuItemSpec(command: .clipLock, title: s.clipsLocked ? "クリップのロックを解除" : "クリップをロック", shortcut: nil,
                     enabled: s.canEdit && s.hasSelection, checked: nil, hint: "移動・トリム・分割・削除を防ぐ")
    }

    static func clipTrim(_ s: MenuState) -> [MenuItemSpec] {
        [MenuItemSpec(command: .trimBefore, title: "再生位置より前を切り落とす", shortcut: MenuShortcut(key: "[", modifiers: [.option, .command]), enabled: s.canEdit && s.canTrim, checked: nil),
         MenuItemSpec(command: .trimAfter, title: "再生位置より後ろを切り落とす", shortcut: MenuShortcut(key: "]", modifiers: [.option, .command]), enabled: s.canEdit && s.canTrim, checked: nil),
         rollEditItem(s), slipEditItem(s),
         MenuItemSpec(command: .mergeSplits, title: "分割点を統合", shortcut: nil, enabled: s.canEdit && s.hasMergeableSplits, checked: nil, hint: "同じ素材の続きを 1 つに")]
    }

    /// クリップ ▸ ロール編集…(隣り合う 2 つのクリップの境界を動かす)。タイムラインでは境界を ⌥ ドラッグでも。
    static func rollEditItem(_ s: MenuState) -> MenuItemSpec {
        MenuItemSpec(command: .rollEdit, title: "ロール編集…", shortcut: nil, enabled: s.canEdit && s.canRoll, checked: nil, hint: "境界を動かす。⌥ ドラッグでも")
    }

    /// クリップ ▸ スリップ編集…(位置と長さはそのままで、使う素材の区間をずらす)。タイムラインではクリップ本体を ⌥⇧ ドラッグでも。
    static func slipEditItem(_ s: MenuState) -> MenuItemSpec {
        MenuItemSpec(command: .slipEdit, title: "スリップ編集…", shortcut: nil, enabled: s.canEdit && s.canSlip, checked: nil, hint: "素材の区間をずらす。⌥⇧ ドラッグでも")
    }

    static func clipNavigate(_ s: MenuState) -> [MenuItemSpec] {
        [MenuItemSpec(command: .prevClip, title: "前のクリップを選択", shortcut: MenuShortcut(key: "[", modifiers: .command), enabled: s.canEdit && s.hasPrevClip, checked: nil),
         MenuItemSpec(command: .nextClip, title: "次のクリップを選択", shortcut: MenuShortcut(key: "]", modifiers: .command), enabled: s.canEdit && s.hasNextClip, checked: nil),
         MenuItemSpec(command: .moveLayerUp, title: "選択クリップを上のレイヤーへ", shortcut: MenuShortcut(key: "[", modifiers: [.shift, .command]), enabled: s.canEdit && s.canMoveUp, checked: nil),
         MenuItemSpec(command: .moveLayerDown, title: "選択クリップを下のレイヤーへ", shortcut: MenuShortcut(key: "]", modifiers: [.shift, .command]), enabled: s.canEdit && s.canMoveDown, checked: nil),
         MenuItemSpec(command: .selectClipAtPlayhead, title: "再生位置のクリップを選ぶ", shortcut: MenuShortcut(key: .upArrow, modifiers: [.control, .option]), enabled: s.canEdit && s.hasClips, checked: nil, hint: "手前のクリップ"),
         MenuItemSpec(command: .cycleOverlapping, title: "重なったクリップを巡回選択", shortcut: nil, enabled: s.canEdit && s.overlapCount >= 2, checked: nil, hint: "プレビューを ⌥ クリックでも"),
         MenuItemSpec(command: .selectShortClips, title: "短いクリップを選ぶ", shortcut: nil, enabled: s.canEdit && s.hasShortClips, checked: nil, hint: "6 コマ未満"),
         MenuItemSpec(command: .sourceUsage, title: "元素材の使用範囲を表示", shortcut: nil, enabled: s.hasSourceUsage, checked: nil, hint: "選んだクリップが使う素材の区間")]
    }

    static func clipLayerAndVoice(_ s: MenuState) -> [MenuItemSpec] {
        [MenuItemSpec(command: .addLayer, title: "レイヤーを追加", shortcut: cmd("l", shift: true), enabled: s.canEdit, checked: nil),
         MenuItemSpec(command: .regenerateVoice, title: "選択クリップの音声を作り直す", shortcut: MenuShortcut(key: "r", modifiers: [.command, .option]), enabled: s.canEdit && s.isVoiceSelected, checked: nil),
         MenuItemSpec(command: .toggleVoiceRipple, title: "音声の作り直しで後続を詰める", shortcut: nil, enabled: s.canEdit, checked: s.voiceRipple, hint: "尺が変わった分だけ後ろをずらす"),
         aiRewrite(s),
         MenuItemSpec(command: .speechShare, title: "話者ごとの発話時間を表示", shortcut: nil, enabled: s.canEdit && s.hasClips, checked: nil, hint: "セリフの長さから")]
    }

    /// クリップ ▸ 比べる・写す・まとめて作る(テイク比較・候補の差し替え・別プロジェクトへ複製・サブクリップの一括作成。ショートカットなし)。
    static func clipCompareAndTransfer(_ s: MenuState) -> [MenuItemSpec] {
        [MenuItemSpec(command: .compareTakes, title: "同じセリフのテイクを比較…", shortcut: nil, enabled: s.canEdit && s.hasTakeGroups, checked: nil, hint: "長さ・音量・無音を並べて試聴"),
         MenuItemSpec(command: .candidateSwap, title: "候補クリップを比較して差し替え…", shortcut: nil, enabled: s.canEdit && s.canCandidateSwap, checked: nil, hint: "素材だけを取り替えて見比べる"),
         MenuItemSpec(command: .transferClips, title: "選択クリップを別プロジェクトへ複製…", shortcut: nil, enabled: s.canEdit && s.selectionCount > 0, checked: nil, hint: "レイヤーと時刻をそのまま"),
         MenuItemSpec(command: .subclipBatch, title: "範囲を指定してサブクリップを一括作成…", shortcut: nil, enabled: s.canEdit, checked: nil, hint: "複数の素材から、再生位置へ順に並べる")]
    }

    /// クリップメニューの全項目(区切りごとのグループ)。
    static func clipMenu(_ s: MenuState) -> [[MenuItemSpec]] {
        [clipAdd(s), clipEdit(s), clipTrim(s), clipNavigate(s), clipLayerAndVoice(s), clipCompareAndTransfer(s)]
    }

    /// 編集メニューのクリップのコピー / 切り取り / 貼り付け / 全選択。ショートカットは付けない(⌘C ⌘X ⌘V ⌘A は標準の項目が responder chain で
    /// 受けるので、入力欄のコピーと貼り付けを壊さない)。このメニュー項目は、フォーカスがどこにあってもクリップに対して働く。
    static func clipboardItems(_ s: MenuState) -> [MenuItemSpec] {
        [MenuItemSpec(command: .copyClips, title: "クリップをコピー", shortcut: nil, enabled: s.canEdit && s.selectionCount > 0, checked: nil),
         MenuItemSpec(command: .cutClips, title: "クリップを切り取り", shortcut: nil, enabled: s.canEdit && s.selectionCount > 0, checked: nil),
         MenuItemSpec(command: .pasteClips, title: "クリップを貼り付け", shortcut: nil, enabled: s.canEdit && s.canPasteClips, checked: nil),
         MenuItemSpec(command: .selectAllClips, title: "すべてのクリップを選択", shortcut: nil, enabled: s.canEdit && s.hasClips, checked: nil)]
    }

    /// クリップメニュー ▸ レイヤー(ロック・ソロ・高さ)。対象は選んだクリップのレイヤー(無ければヘッダーで選んだレイヤー)。
    static func layerItems(_ s: MenuState) -> [MenuItemSpec] {
        let on = s.canEdit && s.hasLayerTarget
        return [MenuItemSpec(command: .layerLock, title: "レイヤーをロック", shortcut: nil, enabled: on, checked: on ? s.layerLocked : false),
                MenuItemSpec(command: .layerSolo, title: "レイヤーをソロ", shortcut: nil, enabled: on, checked: on ? s.layerSolo : false),
                MenuItemSpec(command: .layerTarget, title: "トラックターゲットにする", shortcut: nil, enabled: on, checked: on ? s.layerIsTarget : false, hint: "素材・テキスト・字幕の行き先")]
    }

    /// クリップメニュー ▸ レイヤー ▸ レイヤーを削除…(確認ダイアログが出る。ショートカットなし)。
    static func layerDeleteItem(_ s: MenuState) -> MenuItemSpec {
        MenuItemSpec(command: .layerDelete, title: "レイヤーを削除…", shortcut: nil,
                     enabled: s.canEdit && s.hasLayerTarget && s.layerDeleteBlocked == nil, checked: nil)
    }

    static func layerHeightItems(_ s: MenuState) -> [MenuItemSpec] {
        let on = s.canEdit && s.hasLayerTarget
        return LayerHeight.allCases.map {
            MenuItemSpec(command: .layerHeight($0), title: "高さ: \($0.title)", shortcut: nil, enabled: on, checked: on && s.layerHeight == $0)
        }
    }

    /// 編集 ▸ 検索と置換…(文字とセリフの一括置換)。⌘F は標準の検索に任せ、ショートカットは付けない。
    static func findReplace(_ s: MenuState) -> MenuItemSpec {
        MenuItemSpec(command: .findReplace, title: "検索と置換…", shortcut: nil, enabled: s.canEdit && s.hasTextTargets, checked: nil)
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
         MenuItemSpec(command: .stepForward, title: "1コマ進む", shortcut: nil, enabled: s.canEdit, checked: nil),
         MenuItemSpec(command: .toggleRangeLoop, title: "範囲をループ再生", shortcut: nil, enabled: s.canEdit && s.hasRange, checked: s.rangeLoop, hint: "書き出し範囲")]
            + trimLoopItems(s) + auditionItems(s)
    }

    /// 再生 ▸ 重なったクリップの音だけ試聴(スクラブで対象だけが鳴る)・次の重なったクリップへ(ショートカットなし)。
    static func auditionItems(_ s: MenuState) -> [MenuItemSpec] {
        [MenuItemSpec(command: .toggleAudition, title: "重なったクリップの音だけ試聴", shortcut: nil,
                      enabled: s.canEdit && (s.auditionActive || s.auditionCandidateCount >= 1), checked: s.auditionActive ? true : nil,
                      hint: "再生位置を動かすと、選んだクリップだけが鳴る"),
         MenuItemSpec(command: .cycleAudition, title: "次の重なったクリップを試聴", shortcut: nil,
                      enabled: s.canEdit && s.auditionCandidateCount >= 2, checked: nil)]
    }

    /// 再生 ▸ トリム点 / 選択クリップの反復再生(ショートカットなし)。
    static func trimLoopItems(_ s: MenuState) -> [MenuItemSpec] {
        let w = TrimLoop.normalizedHalfWidth(s.trimLoopHalfWidth)
        let wl = w == 0.5 ? "0.5" : String(Int(w))
        return [MenuItemSpec(command: .toggleTrimLoop, title: "トリム点を反復再生", shortcut: nil, enabled: s.canEdit && s.hasClips, checked: s.trimLoopActive ? true : nil, hint: "再生位置の前後 \(wl) 秒"),
                MenuItemSpec(command: .toggleClipLoop, title: "選択クリップを反復再生", shortcut: nil, enabled: s.canEdit && s.hasSelection, checked: nil)]
    }

    /// 再生 ▸ 反復再生の幅(前後 0.5 / 1 / 2 秒。現在の選択にチェック)。
    static func trimLoopWidthItems(_ s: MenuState) -> [MenuItemSpec] {
        let cur = TrimLoop.normalizedHalfWidth(s.trimLoopHalfWidth)
        return TrimLoop.halfWidthChoices.map { w in
            MenuItemSpec(command: .trimLoopWidth(w), title: "前後 \(w == 0.5 ? "0.5" : String(Int(w))) 秒", shortcut: nil, enabled: s.canEdit, checked: w == cur)
        }
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
         MenuItemSpec(command: .prevGap, title: "前の空白へ", shortcut: MenuShortcut(key: .leftArrow, modifiers: [.control, .option]), enabled: s.canEdit && s.hasGaps, checked: nil, hint: "何も映らない区間"),
         MenuItemSpec(command: .nextGap, title: "次の空白へ", shortcut: MenuShortcut(key: .rightArrow, modifiers: [.control, .option]), enabled: s.canEdit && s.hasGaps, checked: nil, hint: "何も映らない区間"),
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

    /// 移動 ▸ マーカーの色(再生位置のマーカーに効く。ショートカットは持たない)。
    static func markerColorItems(_ s: MenuState) -> [MenuItemSpec] {
        MarkerColor.allCases.map { c in
            MenuItemSpec(command: .markerColor(c), title: c.title, shortcut: nil, enabled: s.canEdit && s.markerAtPlayhead,
                         checked: s.markerAtPlayhead && s.playheadMarkerColor == c)
        }
    }

    static func markerList(_ s: MenuState) -> [MenuItemSpec] {
        s.markers.map { MenuItemSpec(command: .jumpToMarker($0.id), title: markerTitle($0), shortcut: nil, enabled: s.canEdit, checked: nil) }
    }

    // MARK: キーフレーム / アニメーション(クリップメニューのサブメニュー)

    static func keyframeItems(_ s: MenuState) -> [MenuItemSpec] {
        [MenuItemSpec(command: .toggleKeyframe, title: "キーフレームを追加/削除", shortcut: MenuShortcut(key: "k", modifiers: [.option, .command]), enabled: s.canEdit && s.canKeyframe, checked: nil),
         MenuItemSpec(command: .prevKeyframe, title: "前のキーフレームへ", shortcut: MenuShortcut(key: ",", modifiers: [.option, .command]), enabled: s.canEdit && s.hasPrevKeyframe, checked: nil),
         MenuItemSpec(command: .nextKeyframe, title: "次のキーフレームへ", shortcut: MenuShortcut(key: ".", modifiers: [.option, .command]), enabled: s.canEdit && s.hasNextKeyframe, checked: nil),
         MenuItemSpec(command: .clearKeyframes, title: "すべてのキーフレームを消去", shortcut: nil, enabled: s.canEdit && s.hasKeyframes, checked: nil)]
    }

    static func animationItems(_ s: MenuState) -> [MenuItemSpec] {
        AnimationPreset.allCases.map {
            MenuItemSpec(command: .animationPreset($0), title: $0.title, shortcut: nil, enabled: s.canEdit && s.canAnimatePreset, checked: nil)
        }
    }

    // MARK: トランジション(クリップメニューのサブメニュー)

    /// 開始 / 終了の種類の選択(なし + 全種類。いまの種類に ✓)。
    static func transitionKindItems(_ s: MenuState, edge: TransitionEdge) -> [MenuItemSpec] {
        let current = edge == .in ? s.transitionInKind : s.transitionOutKind
        func cmd(_ k: TransitionKind?) -> MenuCommand { edge == .in ? .transitionIn(k) : .transitionOut(k) }
        let none = MenuItemSpec(command: cmd(nil), title: "なし", shortcut: nil, enabled: s.canEdit && s.canTransition, checked: current == nil)
        return [none] + TransitionKind.allCases.map {
            MenuItemSpec(command: cmd($0), title: $0.label, shortcut: nil, enabled: s.canEdit && s.canTransition, checked: current == $0.rawValue)
        }
    }

    static func transitionActions(_ s: MenuState) -> [MenuItemSpec] {
        [MenuItemSpec(command: .fadeBoth, title: "両方にフェードを付ける", shortcut: MenuShortcut(key: "f", modifiers: [.option, .command]), enabled: s.canEdit && s.canTransition, checked: nil),
         MenuItemSpec(command: .clearTransitions, title: "トランジションをすべて外す", shortcut: nil, enabled: s.canEdit && s.hasTransitions, checked: nil)]
    }

    /// クリップメニュー直下の 2 項目。
    static func transitionQuick(_ s: MenuState) -> [MenuItemSpec] {
        [MenuItemSpec(command: .crossfade, title: "クロスフェードにする", shortcut: nil, enabled: s.canEdit && s.canTransition, checked: nil),
         MenuItemSpec(command: .fadeInOut, title: "フェードイン・アウトを付ける", shortcut: nil, enabled: s.canEdit && s.canFadeInOut, checked: nil)]
    }

    // MARK: エフェクト(クリップメニューのサブメニュー。ショートカットは付けない: ⌘C/⌘V は文字入力と衝突するため)

    static func effectKindItems(_ s: MenuState) -> [MenuItemSpec] {
        EffectKind.allCases.map { MenuItemSpec(command: .effectAdd($0), title: $0.label, shortcut: nil, enabled: s.canEdit && s.canEffect, checked: nil) }
    }

    static func effectPresetItems(_ s: MenuState) -> [MenuItemSpec] {
        EffectPreset.allCases.map { MenuItemSpec(command: .effectPreset($0), title: $0.title, shortcut: nil, enabled: s.canEdit && s.canEffect, checked: nil) }
    }

    /// クリップ ▸ テキスト ▸ スタイルを適用(組み込み → 保存したもの)。文字クリップを選んでいるときだけ使える。
    static func textStyleItems(_ s: MenuState) -> [MenuItemSpec] {
        s.textStyleChoices.map { MenuItemSpec(command: .textStyleApply($0.id), title: $0.name, shortcut: nil, enabled: s.canEdit && s.isTextClip, checked: nil) }
    }

    /// テキスト ▸ 一括適用 ▸ ○○(文字クリップすべて。複数選んでいればその分だけ)。
    static func textStyleAllItems(_ s: MenuState) -> [MenuItemSpec] {
        s.textStyleChoices.map { MenuItemSpec(command: .textStyleApplyAll($0.id), title: $0.name, shortcut: nil, enabled: s.canEdit && s.hasTextClips, checked: nil) }
    }

    /// クリップ ▸ テキスト ▸ 文字アニメーション(ラジオ)。
    /// クリップ ▸ 配置 ▸ 右上・右下・左上・左下に小さく(ショートカットは付けない)。
    static func pipItems(_ s: MenuState) -> [MenuItemSpec] {
        PipCorner.allCases.map { MenuItemSpec(command: .pip($0), title: $0.label, shortcut: nil, enabled: s.canEdit && s.canPip, checked: nil) }
    }

    /// テキスト ▸ カウントダウンにする(チェックで付いている表示。ショートカットは付けない)。
    static func textCounterItem(_ s: MenuState) -> MenuItemSpec {
        MenuItemSpec(command: .toggleCounter, title: "カウントダウンにする", shortcut: nil, enabled: s.canEdit && s.isTextClip, checked: s.isTextClip ? s.hasCounter : nil)
    }

    static func textAnimItems(_ s: MenuState) -> [MenuItemSpec] {
        TextAnimKind.allCases.map { MenuItemSpec(command: .textAnim($0), title: $0.label, shortcut: nil, enabled: s.canEdit && s.isTextClip, checked: s.isTextClip && s.textAnimKind == $0) }
    }

    static func effectActions(_ s: MenuState) -> [MenuItemSpec] {
        [MenuItemSpec(command: .effectClear, title: "エフェクトをすべて外す", shortcut: nil, enabled: s.canEdit && s.hasEffects, checked: nil),
         MenuItemSpec(command: .effectCopy, title: "エフェクトのコピー", shortcut: nil, enabled: s.canEdit && s.hasEffects, checked: nil),
         MenuItemSpec(command: .effectPaste, title: "エフェクトの貼り付け", shortcut: nil, enabled: s.canEdit && s.canEffect && s.canPasteEffects, checked: nil)]
    }

    // MARK: 速度(クリップメニューのサブメニュー。ショートカットは付けない)

    static let speedChoices: [(value: Double, title: String)] = [(0.25, "0.25倍"), (0.5, "0.5倍"), (1, "通常（1倍）"), (2, "2倍"), (4, "4倍")]

    static func speedItems(_ s: MenuState) -> [MenuItemSpec] {
        speedChoices.map { MenuItemSpec(command: .speed($0.value), title: $0.title, shortcut: nil, enabled: s.canEdit && s.canSpeed, checked: s.canSpeed ? abs(s.speedValue - $0.value) < 1e-9 : nil) }
        + [MenuItemSpec(command: .toggleReverse, title: "逆再生にする", shortcut: nil, enabled: s.canEdit && s.canSpeed, checked: s.canSpeed ? s.isReversed : nil)]
    }

    static func freezeFrameItem(_ s: MenuState) -> MenuItemSpec {
        MenuItemSpec(command: .freezeFrame, title: "フリーズフレーム（静止画にする）", shortcut: nil, enabled: s.canEdit && s.canFreezeFrame, checked: nil)
    }

    // MARK: 音声(クリップメニューのサブメニュー。ショートカットは付けない)

    static func audioItems(_ s: MenuState) -> [MenuItemSpec] {
        let on = s.canEdit && s.canAudioFx
        return [MenuItemSpec(command: .audioNormalize, title: "ノーマライズ（ピーク −1 dB）", shortcut: nil, enabled: on, checked: nil),
                MenuItemSpec(command: .audioVolumeUp, title: "音量を上げる（+3 dB）", shortcut: nil, enabled: on, checked: nil),
                MenuItemSpec(command: .audioVolumeDown, title: "音量を下げる（−3 dB）", shortcut: nil, enabled: on, checked: nil),
                MenuItemSpec(command: .audioVoicePreset, title: "ボイス向けプリセット（EQ + コンプレッサー）", shortcut: nil, enabled: on, checked: nil),
                MenuItemSpec(command: .audioDuckToggle, title: "自動ダッキングを切り替え（声があるとき BGM を下げる）", shortcut: nil, enabled: s.canEdit && s.canDuck, checked: s.canDuck ? s.isDucking : nil),
                MenuItemSpec(command: .audioClear, title: "音声エフェクトをすべて外す", shortcut: nil, enabled: s.canEdit && s.hasAudioFx, checked: nil)]
    }

    /// クリップ ▸ 無音をカット…(シートを開く)。
    /// クリップ ▸ LUT を読み込む…(.cube を選ぶ)。
    static func autoWhiteBalanceItem(_ s: MenuState) -> MenuItemSpec {
        MenuItemSpec(command: .autoWhiteBalance, title: "自動ホワイトバランス", shortcut: nil, enabled: s.canEdit && s.canAutoColor, checked: nil)
    }

    static func lutLoadItem(_ s: MenuState) -> MenuItemSpec {
        MenuItemSpec(command: .lutLoad, title: "LUT を読み込む…", shortcut: nil, enabled: s.canEdit && s.canEffect, checked: nil)
    }

    /// クリップ ▸ フィラー語をカット…(音声認識を使うのでメニューの音声の項目と同じ条件。ショートカットは付けない)。
    static func fillerCutItem(_ s: MenuState) -> MenuItemSpec {
        MenuItemSpec(command: .fillerCut, title: "フィラー語をカット…", shortcut: nil, enabled: s.canEdit && s.canTranscribe, checked: nil)
    }

    /// クリップ ▸ 文字起こしで編集…(音声認識を使うのでフィラー語と同じ条件。ショートカットは付けない)。
    static func transcriptEditItem(_ s: MenuState) -> MenuItemSpec {
        MenuItemSpec(command: .transcriptEdit, title: "文字起こしで編集…", shortcut: nil, enabled: s.canEdit && s.canTranscribe, checked: nil)
    }
    /// クリップ ▸ 音声で映像と音声を自動同期(動画 1 つ + 音声 1 つを選んでいるとき。1 回の Undo。ショートカットなし)。
    static func audioAutoSyncItem(_ s: MenuState) -> MenuItemSpec {
        MenuItemSpec(command: .audioAutoSync, title: "音声で映像と音声を自動同期", shortcut: nil, enabled: s.canEdit && s.canAudioAutoSync, checked: nil)
    }
    static func silenceCutItem(_ s: MenuState) -> MenuItemSpec {
        MenuItemSpec(command: .silenceCut, title: "無音をカット…", shortcut: nil, enabled: s.canEdit && s.canSilenceCut, checked: nil)
    }
    /// クリップ ▸ ビートにマーカーを打つ(音のクリップを選んでいるとき。1 回の Undo。ショートカットは持たない)。
    static func beatMarkersItem(_ s: MenuState) -> MenuItemSpec {
        MenuItemSpec(command: .beatMarkers, title: "ビートにマーカーを打つ", shortcut: nil, enabled: s.canEdit && s.canBeatMarkers, checked: nil, hint: "テンポを測る")
    }

    /// クリップ ▸ 選択クリップを音階で複製…(音MAD 用。シートで音階・移調・個数を選ぶ。1 回の Undo。ショートカットは持たない)。
    static func scaleDuplicateItem(_ s: MenuState) -> MenuItemSpec {
        MenuItemSpec(command: .scaleDuplicate, title: "選択クリップを音階で複製…", shortcut: nil, enabled: s.canEdit && s.canPitchLayout, checked: nil, hint: "音MAD")
    }
    /// クリップ ▸ ビートに合わせてクリップを並べる…(マーカーの位置に繰り返し置く。1 回の Undo。ショートカットは持たない)。
    static func beatPlaceItem(_ s: MenuState) -> MenuItemSpec {
        MenuItemSpec(command: .beatPlace, title: "ビートに合わせてクリップを並べる…", shortcut: nil, enabled: s.canEdit && s.canBeatPlace, checked: nil, hint: "音MAD")
    }

    static func zoom(_ s: MenuState) -> [MenuItemSpec] {
        [MenuItemSpec(command: .zoomIn, title: "タイムラインを拡大", shortcut: cmd("+"), enabled: s.canEdit, checked: nil),
         MenuItemSpec(command: .zoomOut, title: "タイムラインを縮小", shortcut: cmd("-"), enabled: s.canEdit, checked: nil),
         MenuItemSpec(command: .zoomFit, title: "タイムラインを全体表示", shortcut: cmd("0"), enabled: s.canEdit, checked: nil),
         MenuItemSpec(command: .zoomSelection, title: "選択クリップにズーム", shortcut: nil, enabled: s.canEdit && s.hasSelection, checked: nil)]
    }

    /// 解像度のラジオ(定番のサイズ)。今のサイズに ✓。
    static func resolutions(_ s: MenuState) -> [MenuItemSpec] {
        ResolutionPresets.items.map {
            MenuItemSpec(command: .resolution($0.key), title: $0.label, shortcut: nil, enabled: s.canEdit, checked: s.hasDocument && $0.key == s.resolutionKey)
        }
    }

    /// 「最近使ったカスタム」のサイズ。今のサイズが定番でも履歴にもなければ、✓ 付きでここに足す。
    static func recentResolutions(_ s: MenuState) -> [MenuItemSpec] {
        var list = s.recentResolutions.filter { !ResolutionPresets.isPreset($0) }
        if s.hasDocument, !s.resolutionKey.isEmpty, !ResolutionPresets.isPreset(s.resolutionKey), !list.contains(s.resolutionKey) {
            list.insert(s.resolutionKey, at: 0)
        }
        return list.map {
            MenuItemSpec(command: .resolution($0), title: $0.replacingOccurrences(of: "x", with: "×"), shortcut: nil, enabled: s.canEdit, checked: s.hasDocument && $0 == s.resolutionKey)
        }
    }

    static func customResolution(_ s: MenuState) -> MenuItemSpec {
        MenuItemSpec(command: .resolution(ResolutionPresets.customKey), title: "カスタム…", shortcut: nil, enabled: s.canEdit, checked: nil)
    }

    static func swapResolution(_ s: MenuState) -> MenuItemSpec {
        MenuItemSpec(command: .swapResolution, title: "縦横を入れ替える", shortcut: nil, enabled: s.canEdit, checked: nil)
    }

    static func codecItems(_ s: MenuState) -> [MenuItemSpec] {
        codecs.map {
            // 今のサイズが H.264 の上限を超えるときは、H.264 の横に注意を添える(書き出しは自動で HEVC になる)
            let hint = ($0.key == "h264" && s.hasDocument && s.h264Unsupported) ? "このサイズは HEVC で書き出し" : nil
            return MenuItemSpec(command: .codec($0.key), title: $0.label, shortcut: nil, enabled: s.canEdit, checked: s.codec == $0.key, hint: hint)
        }
    }

    static func backgroundItems(_ s: MenuState) -> [MenuItemSpec] {
        backgrounds.map { MenuItemSpec(command: .background($0.key), title: $0.label, shortcut: nil, enabled: s.canEdit, checked: s.bg.lowercased() == $0.key) }
    }

    /// 表示 ▸ パネル: 出ていれば ✓。選ぶと閉じる / 開く。
    static func dockPanels(_ s: MenuState) -> [MenuItemSpec] {
        DockPanel.allCases.map { MenuItemSpec(command: .dockPanel($0), title: $0.title, shortcut: nil, enabled: s.canEdit, checked: s.dockVisible.contains($0)) }
    }

    /// 表示 ▸ レイアウト: 初期配置に戻す / 1つのタブにまとめる / すべて分離 / プレビューを大きく。
    static func dockLayouts(_ s: MenuState) -> [MenuItemSpec] {
        DockPreset.allCases.map { MenuItemSpec(command: .dockLayout($0), title: $0.title, shortcut: nil, enabled: s.canEdit, checked: nil) }
    }

    /// 表示 ▸ プレビューの背景: 暗い灰色 / 黒 / 白 / 中間グレー / 緑 / 青(ラジオ)。
    /// 表示 ▸ プロキシで編集(チェック付き。アプリ全体の設定。プレビューだけに効き、書き出しは元の素材)。
    static func previewProxy(_ s: MenuState) -> MenuItemSpec {
        MenuItemSpec(command: .previewProxyToggle, title: "プロキシで編集", shortcut: nil, enabled: true, checked: s.previewProxyEnabled, hint: "プレビューを軽く")
    }

    /// 出力 ▸ プロキシを作成(映像の素材ごとに 540p。作成中は編集をロック)。
    static func makeProxies(_ s: MenuState) -> MenuItemSpec {
        MenuItemSpec(command: .makeProxies, title: "プロキシを作成", shortcut: nil, enabled: s.canEdit && s.canMakeProxies, checked: nil, hint: "540p・背景で")
    }

    /// 表示 ▸ ガイド線 ▸ タイトルセーフ・アクションセーフ・中心線・三分割線(チェックで出す。ショートカットは持たない)。
    static func guideItems(_ s: MenuState) -> [MenuItemSpec] {
        PreviewGuide.allCases.map { MenuItemSpec(command: .guide($0), title: $0.title, shortcut: nil, enabled: true, checked: s.previewGuides.contains($0)) }
    }

    static func previewBackgroundItems(_ s: MenuState) -> [MenuItemSpec] {
        PreviewBackground.allCases.map { MenuItemSpec(command: .previewBackground($0), title: $0.title, shortcut: nil, enabled: true, checked: s.previewBackground == $0) }
    }

    /// 標準の「全画面表示」(⌃⌘F)。ウィンドウがあれば使える(書き出し中でも構わない)。
    static func fullScreen(_ s: MenuState) -> MenuItemSpec {
        MenuItemSpec(command: .fullScreen, title: "全画面表示", shortcut: MenuShortcut(key: "f", modifiers: [.command, .control]), enabled: s.hasDocument, checked: nil)
    }

    static var help: [[MenuItemSpec]] {
        [[MenuItemSpec(command: .helpShortcuts, title: "キーボードショートカット一覧", shortcut: nil, enabled: true, checked: nil)],
         [MenuItemSpec(command: .helpVoicevox, title: "VOICEVOX 公式サイト", shortcut: nil, enabled: true, checked: nil),
          MenuItemSpec(command: .helpAquestalk, title: "AquesTalkPlayer 公式サイト", shortcut: nil, enabled: true, checked: nil)],
         [MenuItemSpec(command: .helpLicense, title: "ライセンス", shortcut: nil, enabled: true, checked: nil),
          MenuItemSpec(command: .helpThirdParty, title: "第三者の規約", shortcut: nil, enabled: true, checked: nil)]]
    }

    /// 字幕と素材の項目(ファイル ▸ 字幕・素材のまとまり。式が長すぎて型検査が遅くなるので分けてある)。
    static func mediaSubtitleItems(_ s: MenuState) -> [MenuItemSpec] {
        [subtitleImport(s), mediaRelink(s), unusedMediaItem(s), packageSave(s), addSubtitle(s), subtitleExport(s), subtitleTranslate(s), subtitleGenerate(s), transcribeSubtitles(s), chapterCopy(s)]
            + cutoutItems(s)
    }

    /// 私たちが足す項目すべて(重複するショートカットが無いかの確認用)。
    static func all(_ s: MenuState) -> [MenuItemSpec] {
        [about, settings(s), videoSettings(s)] + file(s) + recentItems(s) + [recentClear(s), welcomeToggle(s)] + mediaSubtitleItems(s) + chapterColorItems(s) + [ aiScript(s), aiSettings(s), aiChapters(s), aiTitles(s), exportCurrent(s)] + rangeItems(s) + imageExportItems(s) + [gifExport(s)] + exportPresets(s, custom: CustomExportPresetStore.load(from: CustomExportPresetStore.defaultURL())) + exportQueueItems(s) + [loudnessItem(s), clipListItem(s), noteListItem(s)] + scriptStoryboardItems(s) + [makeProxies(s)] + [fanMaxToggle(s), fanInstall(s), fanUninstall(s)] + clipMenu(s).flatMap { $0 } + keyframeItems(s) + animationItems(s) + transitionKindItems(s, edge: .in) + transitionKindItems(s, edge: .out) + transitionActions(s) + transitionQuick(s) + effectKindItems(s) + effectPresetItems(s) + effectActions(s) + textStyleItems(s) + textStyleAllItems(s) + textAnimItems(s) + [textCounterItem(s)] + pipItems(s) + speedItems(s) + [freezeFrameItem(s)] + audioItems(s) + [silenceCutItem(s), audioAutoSyncItem(s), beatMarkersItem(s), scaleDuplicateItem(s), beatPlaceItem(s), fillerCutItem(s), transcriptEditItem(s), lutLoadItem(s), autoWhiteBalanceItem(s)] + editAdd(s) + clipboardItems(s) + [findReplace(s)] + layerItems(s) + [layerDeleteItem(s)] + layerHeightItems(s) + playback(s) + trimLoopWidthItems(s)
            + gotoEnds(s) + gotoNeighbours(s) + [gotoTime(s)] + markerItems(s) + markerColorItems(s) + markerList(s)
            + zoom(s) + resolutions(s) + recentResolutions(s) + [customResolution(s), swapResolution(s)] + fpsItems(s) + recentFpsItems(s) + [customFps(s)] + codecItems(s) + backgroundItems(s)
            + dockPanels(s) + dockLayouts(s) + previewBackgroundItems(s) + guideItems(s) + [previewProxy(s), fullScreen(s)] + help.flatMap { $0 }
    }
}

/// 項目を選んだときの処理。ここで model の関数を呼ぶだけ(ロジックは複製しない)。
enum AppMenu {
    static let zoomStep = 1.25

    @MainActor
    static func perform(_ c: MenuCommand, model: ProjectModel?) {
        switch c {
        case .about: AppInfo.showAboutPanel()
        case .fanMaxToggle: AppServices.fan.setEnabled(!AppServices.fan.enabled)
        case .fanInstall: AppServices.fan.install()
        case .fanUninstall: AppServices.fan.uninstall()
        case .helpShortcuts: ShortcutSheet.show()
        case .openRecent(let path): WelcomeActions.open(path: path)
        case .clearRecents: RecentProjectsController.shared.clear()
        case .welcomeAtLaunchToggle:
            WelcomeSettings.setShowAtLaunch(!WelcomeSettings.showAtLaunch())
            ActiveDocument.shared.refresh()
        case .newFromTemplate(let name): ProjectTemplateActions.newDocument(fromTemplate: name)
        case .helpVoicevox: openURL(DependencyStatus.voicevoxURL)
        case .helpAquestalk: openURL(DependencyStatus.aquestalkURL)
        case .helpLicense: HelpDocs.open(.license)
        case .helpThirdParty: HelpDocs.open(.thirdParty)
        case .dockPanel(let p): AppServices.panelDock.toggle(p)
        case .dockLayout(let pr): AppServices.panelDock.apply(pr)
        case .previewBackground(let b):
            PreviewBackgroundStore.set(b)
            ActiveDocument.shared.refresh()
        case .guide(let g):
            PreviewGuideStore.toggle(g)
            ActiveDocument.shared.refresh()
        case .previewProxyToggle:
            ProxySettings.set(!ProxySettings.enabled())
            ActiveDocument.shared.refresh()
        default:
            guard let m = model else { return }
            switch c {
            case .settings, .videoSettings: m.openSettings()
            case .addMedia: m.chooseAndAddMedia()
            case .importPSD: m.chooseAndImportPSD()
            case .importRigFolder: m.chooseAndImportRigFolder()
            case .importRigPSD: m.chooseAndImportRigPSD()
            case .export: m.chooseAndExport()
            case .exportPreset(let p): m.chooseAndExport(preset: p)
            case .exportCustomPreset(let name):
                if let c = CustomExportPresetStore.load(from: CustomExportPresetStore.defaultURL()).first(where: { $0.name == name }) { m.chooseAndExport(spec: c.spec) }
            case .saveCustomPreset: m.saveCurrentAsCustomPreset()
            case .importSubtitles: m.chooseAndImportSubtitles()
            case .exportSubtitles: m.chooseAndExportSubtitles()
            case .translateSubtitles: m.openAITranslateSubtitles()
            case .generateSubtitles: m.generateSubtitlesFromScript()
            case .transcribeSubtitles: Task { await m.transcribeSelectedToSubtitles() }
            case .relinkMedia: m.chooseAndRelinkMedia()
            case .unusedMedia: m.showUnusedMediaSheet = true
            case .packageSave: m.saveAsPackage()
            case .addFont: m.chooseAndAddFonts()
            case .addSubtitle: m.openSubtitleSheet()
            case .rollEdit: m.openRollSheet()
            case .slipEdit: m.openSlipSheet()
            case .removeBackground: m.removeBackgroundSelected()
            case .imageChroma: m.addEffectSelected(.chromaKey)
            case .toggleRangeLoop: m.rangeLoop.toggle()
            case .toggleTrimLoop: m.toggleTrimLoop()
            case .toggleClipLoop: m.toggleClipLoop()
            case .trimLoopWidth(let w): TrimLoopSettings.halfWidth = w
            case .toggleAudition: m.toggleAudition()
            case .cycleAudition: m.cycleAuditionTarget()
            case .toggleVoiceRipple: VoiceRippleSettings.enabled.toggle()
            case .copyChapters: m.copyChapters()
            case .copyChaptersColor(let c): m.copyChapters(color: c)
            case .aiScript: m.openAIScriptDialog()
            case .aiChapters: m.openAIChapters()
            case .aiTitles: m.openAITitles()
            case .aiRewrite: m.openAIRewrite()
            case .aiSettings: AIDialogs.editSettings()
            case .rangeIn: m.setRangeInAtCurrent()
            case .rangeOut: m.setRangeOutAtCurrent()
            case .rangeClear: m.clearExportRange()
            case .rangeFromSelection: m.setRangeFromSelection()
            case .prevGap: m.seekGap(forward: false)
            case .nextGap: m.seekGap(forward: true)
            case .selectClipAtPlayhead: m.selectClipAtPlayhead()
            case .cycleOverlapping: m.cycleOverlappingAtPlayhead()
            case .selectShortClips: m.selectShortClips()
            case .sourceUsage: m.showSourceUsage()
            case .speechShare: m.showSpeechShareStatus()
            case .clipList: m.showClipListSheet = true
            case .exportScript: m.chooseAndExportScript()
            case .exportStoryboard: m.chooseAndExportStoryboard()
            case .noteList: m.showNoteListSheet = true
            case .exportStill: m.chooseAndExportStill()
            case .exportThumbnail: m.chooseAndExportThumbnail()
            case .exportThumbnailCandidates: m.chooseAndExportThumbnailCandidates()
            case .exportSequence: m.chooseAndExportSequence()
            case .exportGIF: m.chooseAndExportGIF()
            case .queueExport: m.chooseAndQueueExport()
            case .showExportQueue: m.showExportQueueSheet = true
            case .makeProxies: m.makeProxies()
            case .measureLoudness: m.showLoudnessSheet = true
            case .showScopes: m.showScopeSheet = true
            case .aiImage: m.openAIImage()
            case .audioLibrary: m.showAudioLibrary = true
            case .saveTemplate: m.saveAsTemplate()
            case .split: m.splitSelected()
            case .duplicate: m.duplicateSelected()
            case .rippleDelete: m.rippleDeleteSelected()
            case .alignToPlayhead: m.alignSelectedToPlayhead()
            case .concatenateClips: m.concatenateSelectedClips()
            case .mergeSplits: m.mergeSplitPoints()
            case .compareTakes: m.openTakeCompare()
            case .candidateSwap: m.openCandidateSwap()
            case .transferClips: m.chooseTransferDestination()
            case .subclipBatch: m.openSubclipSheet()
            case .copyClips: m.copySelection()
            case .cutClips: m.cutSelection()
            case .pasteClips: m.pasteClips()
            case .selectAllClips: m.selectAllClips()
            case .clipLock: m.toggleClipLockSelected()
            case .layerLock: if let i = m.targetLayerIndex { m.toggleLayerLock(i) }
            case .layerSolo: if let i = m.targetLayerIndex { m.toggleLayerSolo(i) }
            case .layerTarget: if let i = m.targetLayerIndex { m.toggleTrackTarget(i) }
            case .layerDelete: if let i = m.targetLayerIndex { m.requestDeleteLayer(i) }
            case .layerHeight(let h): if let i = m.targetLayerIndex { m.setLayerHeight(i, h) }
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
            case .markerColor(let c): m.setMarkerColorAtPlayhead(c)
            case .jumpToMarker(let id): m.jumpToMarker(id: id)
            case .toggleKeyframe: m.toggleKeyframeFromMenu()
            case .prevKeyframe: m.seekKeyframe(forward: false)
            case .nextKeyframe: m.seekKeyframe(forward: true)
            case .clearKeyframes: m.clearKeyframes()
            case .animationPreset(let p): m.applyAnimationPreset(p)
            case .transitionIn(let k): m.setTransitionKind(k, edge: .in)
            case .transitionOut(let k): m.setTransitionKind(k, edge: .out)
            case .fadeBoth: m.fadeBothSelected()
            case .clearTransitions: m.clearTransitionsSelected()
            case .crossfade: m.crossfadeSelected()
            case .fadeInOut: m.fadeInOutSelected()
            case .effectAdd(let k): m.addEffectSelected(k)
            case .effectPreset(let p): m.applyEffectPreset(p)
            case .effectClear: m.clearEffectsSelected()
            case .effectCopy: m.copyEffectsSelected()
            case .effectPaste: m.pasteEffectsSelected()
            case .lutLoad: m.chooseAndLoadLUT()
            case .autoWhiteBalance: m.autoWhiteBalanceSelected()
            case .textStyleApply(let id): m.applyTextStyleSelected(id)
            case .textStyleApplyAll(let id): m.applyTextStyleToAll(id: id)
            case .textAnim(let k): m.setTextAnim(k)
            case .toggleCounter: m.toggleCounterSelected()
            case .pip(let k): m.setPipCorner(k)
            case .speed(let v): m.setSpeedSelected(v)
            case .toggleReverse: m.toggleReverseSelected()
            case .freezeFrame: m.freezeFrameSelected()
            case .audioNormalize: m.normalizePeakSelected()
            case .audioVolumeUp: m.stepVolumeSelected(db: 3)
            case .audioVolumeDown: m.stepVolumeSelected(db: -3)
            case .audioVoicePreset: m.applyVoicePresetSelected()
            case .audioClear: m.clearAudioFxSelected()
            case .audioDuckToggle: m.toggleDuckSelected()
            case .stabilizeToggle: m.toggleStabilizeSelected()
            case .autoReframe: m.autoReframeSelected()
            case .motionTrack: m.trackMotionSelected()
            case .compoundGroup: m.groupSelectedCompound()
            case .compoundUngroup: m.ungroupSelectedCompound()
            case .silenceCut: m.openSilenceSheet()
            case .audioAutoSync: m.autoSyncSelectedClips()
            case .beatMarkers: m.addBeatMarkersToSelectedClip()
            case .scaleDuplicate: m.openScaleSheet()
            case .beatPlace: m.openBeatPlaceSheet()
            case .fillerCut: m.openFillerSheet()
            case .transcriptEdit: m.openTranscriptEditSheet()
            case .findReplace: m.openFindReplace()
            case .delete: m.deleteSelected()
            case .addText: m.addTextClip()
            case .addBlur: m.addBlurClip()
            case .addAdjustment: m.addAdjustmentClip()
            case .addVisualizer: m.addVisualizerClip()
            case .addShape(let k): m.addShapeClip(kind: k)
            case .addStamp(let e): m.addStampClip(emoji: e)
            case .addQRCode: m.openAddQRCode()
            case .addCharacter: m.addCharacter()
            case .makeVoices: Task { await m.generateVoicesFromScript() }
            case .playPause: m.playback.togglePlay()
            case .toStart: m.playback.goToStart()
            case .stepBack: m.playback.step(frames: -1)
            case .stepForward: m.playback.step(frames: 1)
            case .zoomIn: m.zoomTimeline(by: zoomStep)
            case .zoomOut: m.zoomTimeline(by: 1 / zoomStep)
            case .zoomFit: m.onFitTimeline()
            case .zoomSelection: m.onZoomSelection()
            case .nudgeEarlier: m.nudgeSelectedClips(frames: -1)
            case .nudgeLater: m.nudgeSelectedClips(frames: 1)
            case .resolution(let key): m.selectResolution(key)
            case .swapResolution: m.swapResolution()
            case .fps(let f): m.setFps(f)
            case .fpsCustom: m.openFpsSheet()
            case .codec(let k): m.setCodec(k)
            case .background(let k): m.setBackground(k)
            case .fullScreen: m.window?.toggleFullScreen(nil)
            default: break
            }
        }
    }

    private static func openURL(_ s: String) {
        if let u = URL(string: s) { NSWorkspace.shared.open(u) }
    }
}

import Foundation
import Combine
import AppKit
import AVFoundation
import MovieCutCore

/// アプリ全体で 1 つだけ持つもの(VOICEVOX エンジンは終了時に止める)。
enum AppServices {
    static let engine = VoicevoxEngine()
    /// 画面のドッキング(パネルの配置)。アプリ全体で 1 つ。静かな検証(MC_DEBUG_*)では UserDefaults に書かない。試験は差し替える。
    @MainActor static var panelDock: DockStore = makePanelDock()
    @MainActor static func makePanelDock(defaults: UserDefaults? = DebugHooks.isQuiet ? nil : .standard) -> DockStore {
        let s = DockStore(defaults: defaults)
        s.onChange = { ActiveDocument.shared.refresh() }
        return s
    }
    /// VOICEVOX の話者一覧(キャラの一覧とプロパティ欄で共有)。
    @MainActor static let speakers = SpeakerCatalog()
    /// 一度だけ出すお知らせ(Kyoko の代用など)。アプリを起動している間に 1 回。
    @MainActor static let notices = OneTimeNotices()
    /// Dock アイコンの進行バー(書き出し中)。
    @MainActor static let dock = DockProgressController(tile: NSApp?.dockTile)
    /// 書き出し中のファン最大化(設定・検出・ヘルパーのインストール)。アプリ全体で 1 つ。
    @MainActor static var fan = FanService()
    /// 書き出しキュー(アプリ全体で 1 つ。書類を切り替えても、待っている件は続く)。
    @MainActor static let exportQueue = ExportQueueController()
    /// 起動時の依存チェックとバナー(アプリ全体で 1 つ。閉じたらこの起動中は出さない)。
    @MainActor static let deps = DependencyNoticeCenter(checker: DependencyNoticeCenter.debugChecker() ?? { p in await DependencyStatus.check(project: p) })
}

/// 解像度のプリセット(renderer.js の #res-select と同じ並び)。
enum ResolutionPresets {
    static let items: [(key: String, label: String)] = [
        ("1366x768", "1366×768"),
        ("1280x720", "HD 1280×720"),
        ("1920x1080", "FHD 1920×1080"),
        ("2560x1440", "WQHD 2560×1440"),
        ("3840x2160", "4K 3840×2160"),
        ("5120x2880", "5K 5120×2880"),
        ("7680x4320", "8K 7680×4320"),
    ]
    static let customKey = "custom"
    static func isPreset(_ key: String) -> Bool { items.contains { $0.key == key } }
}

/// 書き出しの結果。
enum ExportOutcome {
    case success(URL)
    case cancelled
    case failure(Error)
}

/// 動画設定シートの下書き。
struct VideoSettingsDraft: Equatable {
    var width: Int
    var height: Int
    var fps: Double
    var bg: String
    var codec: String
    var voicevoxUrl: String
    var aquestalkCommand: String

    init(_ p: Project) {
        width = p.width; height = p.height; fps = p.fps; bg = p.bg; codec = p.codec
        voicevoxUrl = p.voicevoxUrl; aquestalkCommand = p.aquestalkCommand
    }
}

/// 声を作る間、進み具合を知らせるためにくるむ VoiceProvider。
final class ProgressVoiceProvider: VoiceProvider {
    let inner: VoiceProvider
    let total: Int
    let report: (String) -> Void
    private var index = 0
    private let lock = NSLock()

    init(inner: VoiceProvider, total: Int, report: @escaping (String) -> Void) {
        self.inner = inner; self.total = total; self.report = report
    }

    func synthesize(character: Character, text: String, in directory: URL) async throws -> VoiceResult {
        let n: Int = lock.withLock { index += 1; return index }
        let shown = text.count > 40 ? String(text.prefix(40)) + "…" : text
        report("音声を作っています \(n)/\(total)\n\(character.name): \(shown)")
        return try await inner.synthesize(character: character, text: text, in: directory)
    }
}

/// プロジェクトの写し(どのスレッドからでも読める)。保存は SwiftUI が主スレッド以外から snapshot を呼び、
/// そのあいだ主スレッドは保存の完了を待つので、snapshot が主スレッドを待つとデッドロックする。そのための写し。
final class ProjectMirror: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Project
    init(_ p: Project) { value = p }
    func set(_ p: Project) { lock.withLock { value = p } }
    func get() -> Project { lock.withLock { value } }
}

/// 1 つのドキュメントの状態。すべての編集は `edit(_:_:)` を通し、UndoManager に登録する(Project 全体のスナップショット式)。
@MainActor
final class ProjectModel: ObservableObject {
    @Published var project: Project {
        // タイムラインが「変わったか」を安く調べるための通し番号
        didSet { projectRevision &+= 1; mirror.set(project) }
    }
    nonisolated let mirror: ProjectMirror
    private(set) var projectRevision = 0
    /// 自動保存(復元の写し)の持ち主の番号と、最後に写したときの版・タイマー。
    let recoverySessionID = UUID().uuidString
    var recoveryWrittenRevision: Int?
    var recoveryTimer: Timer?
    /// 復元で開いた書類は、保存するまで「編集済み」扱い(写しを消さない)。
    var restoredFromRecovery = false
    /// ドラッグ中の編集の出発点(M4a。ドラッグの間は Undo に積まず、離したときに 1 回だけ登録する)。
    var gestureBase: Project?
    @Published var selectedClipId: String? {
        // クリップを選んだら、プロパティ欄はキャラの表示をやめてクリップの表示にする
        didSet {
            if selectedClipId != nil { characterPanelActive = false; selectedLayerIndex = nil }
            if selectedClipId != oldValue { focusedAnimatableKey = nil }
            // A6: 複数選択。主(selectedClipId)を直接入れ替えたときは単一選択に戻す(setSelection は先に集合を入れるので、含まれていれば残す)
            if let id = selectedClipId {
                if !selectedClipIDs.contains(id) { selectedClipIDs = [id] }
            } else if !selectedClipIDs.isEmpty {
                selectedClipIDs = []
            }
        }
    }
    /// A6: 選んでいるクリップの全部(主を含む)。単一選択のときは主だけ。主が nil なら空。
    @Published var selectedClipIDs: Set<String> = []
    /// クリップのダブルクリックで増える。プロパティ欄の文字入力が、増えたらフォーカスを取る。
    @Published var textFocusRequest = 0
    /// A6: ヘッダーを押して選んだレイヤー(貼り付けの行き先)。クリップを選ぶと外れる。
    @Published var selectedLayerIndex: Int?
    /// A6: コピーしたクリップ(アプリ内。一般のペーストボードにも JSON で書く)。
    var clipClipboard: ClipClipboard?
    /// A6: クリップをコピーする先のペーストボード(テストでは専用のものに差し替える)。
    var clipPasteboard: NSPasteboard = .general
    /// 最後に触った(◇ を押した・値を編集した)動かせる項目。メニューの「キーフレームを追加/削除」などの対象(無ければ全項目)。
    @Published var focusedAnimatableKey: String?
    /// 文字スタイルの保存先(アプリ全体で共有。テストでは専用のものに差し替える)。
    var textStyles: TextStyleStore = .shared
    /// 「エフェクトのコピー」で覚えたエフェクト(貼り付けで、選択クリップの後ろに足す。キーフレームは付いてこない)。
    @Published var effectClipboard: [Effect] = []
    @Published var selectedCharId: String?
    /// 左の一覧でキャラを選んだ状態(クリップが選ばれていなければ、プロパティ欄にキャラの設定が出る)。
    @Published var characterPanelActive = false
    /// 「このキャラを消す」の確認待ち(確認の警告を出す)。
    @Published var pendingDeleteCharId: String?
    @Published var currentTime: Double = 0
    @Published var isExporting = false
    @Published var statusText = ""
    @Published var exportProgress: Double = 0
    /// 声を作っている間のメッセージ(nil なら作っていない)。
    @Published var busyMessage: String?
    @Published var errorMessage: String?
    @Published var errorTitle = "エラー"
    @Published var showSettings = false
    /// 「解像度を入力」「フレームレートを入力」のシート。
    @Published var showResolutionSheet = false
    @Published var showFpsSheet = false
    /// 出力 ▸ ラウドネスを測る…(プロジェクトの音の全体を測って見せる)
    @Published var showLoudnessSheet = false
    /// 表示 ▸ スコープ…(今のプレビューのコマの波形・ヒストグラム)
    @Published var showScopeSheet = false
    /// 出力 ▸ 書き出しキューを表示… / 素材ブラウザ(ファイル ▸ 素材ブラウザを開く…)のシート。
    @Published var showExportQueueSheet = false
    @Published var showAudioLibrary = false
    /// 「時間を指定して移動…」のシート。
    @Published var showJumpSheet = false
    /// 「字幕を追加…」のシート。直すときは対象の文字クリップの id を入れる(新規なら nil)。
    @Published var showSubtitleSheet = false
    var subtitleSheetTargetId: String?
    /// 「無音をカット…」のシートと、その対象のクリップ。
    @Published var showSilenceSheet = false
    var silenceClipId: String?
    /// 「選択クリップを音階で複製…」「ビートに合わせてクリップを並べる…」のシートと、その対象のクリップ。
    @Published var showScaleSheet = false
    var scaleClipId: String?
    @Published var showBeatPlaceSheet = false
    var beatPlaceClipId: String?
    @Published var showFillerSheet = false
    var fillerClipId: String?
    @Published var showTranscriptEditSheet = false
    var transcriptEditClipId: String?
    /// 「検索と置換…」のシート(テロップとセリフの一括置換)。
    @Published var showFindSheet = false
    /// 出力 ▸ 使用クリップ一覧…(表・TSV コピー・CSV 書き出し)のシート。
    @Published var showClipListSheet = false
    /// 同じセリフのテイク比較シート(表示の状態)と、試聴の出口・鳴らしているテイクの id
    @Published var showTakeSheet = false
    @Published var takePlayingId: String?
    @Published var showSubclipSheet = false
    /// 候補クリップの比較(オーディション)中の状態と、素材の長さを測る手段(テストでは差し替える)
    @Published var candidateSession: CandidateSession?
    var candidateProbe: (URL, ClipType) async -> Double? = { url, kind in await ClipEditing.probeDuration(url: url, kind: kind) }
    var takePlayer: AuditionPlaying = AVAuditionPlayer()
    /// 出力 ▸ 注記一覧…(注記のあるクリップの表・テキストと CSV の書き出し)のシート。
    @Published var showNoteListSheet = false
    @Published var showUnusedMediaSheet = false
    /// 名前を変えているマーカー(シートを出す)。
    @Published var renamingMarkerId: String?
    /// 左の台本欄の文字(ツールバー・メニューの「台本から音声を作る」が読む)。
    @Published var scriptText = ""
    /// タイムラインの拡大率(pt/秒)と吸着(M4 のドラッグで使う)。
    @Published var pps: Double = TimelineLayout.defaultPps
    @Published var snapEnabled = true
    @Published var isPlaying = false
    /// 書き出し範囲だけをループ再生する(表示の状態。プロジェクトには保存せず、Undo にも載せない)。
    @Published var rangeLoop = false
    /// トリム点・選択クリップの反復再生の範囲(表示の状態。保存せず Undo にも載せない。止まると nil に戻る)。
    @Published var trimLoop: ExportRange?
    /// 重なったクリップの音だけの試聴(表示の状態。保存せず Undo にも載せない)。オンの間、止まっている再生位置を動かすと対象のクリップだけが短く鳴る。
    @Published var auditionOn = false
    /// 試聴している(solo にしている)クリップの id。
    @Published var auditionClipId: String?
    /// 試聴の音の出口(テストでは差し替える)と、鳴らす準備の仕事・通し番号・いま鳴らしている一時ファイル。
    var auditionPlayer: AuditionPlaying = AVAuditionPlayer()
    var auditionTask: Task<Void, Never>?
    var auditionSeq = 0
    var auditionFile: URL?
    /// 増やすと、同じ時刻でもプレビューを描き直す(再生を止めたとき)。
    @Published var previewEpoch = 0

    /// 保存先(ドキュメントから渡される。無題なら nil)。
    var fileURL: URL?
    /// 開いたときの「欠けた素材」案内を出したか(書類ごとに 1 回だけ)。
    var offeredMissingMediaOnOpen = false
    weak var window: NSWindow?
    /// ドキュメントウィンドウの UndoManager(ビューが渡す)。無ければ自前のもの(テスト用)。
    var undoManager: UndoManager?
    let fallbackUndoManager: UndoManager = {
        let u = UndoManager()
        u.groupsByEvent = false
        return u
    }()
    /// プレビューと共有する素材キャッシュ(書き出しは別に作る: 書き出し専用モードがあるため)。
    let assets = RenderAssets()
    /// AI 連携の画面部品(テストで差し替える)と、問い合わせ中のキャンセル。
    var aiUI = AIUI()
    var aiCancel: (() -> Void)?
    /// 音声認識(出力 ▸ 音声から字幕を作る)の取り消し。
    var transcribeCancel: (() -> Void)?
    /// プロキシの作成(出力 ▸ プロキシを作成)と AI 画像生成(クリップ ▸ AIで画像を作る)の取り消し。
    var proxyCancel: (() -> Void)?
    var imageGenCancel: (() -> Void)?
    var voiceProviderFactory: (Project) -> VoiceProvider = { RealVoiceProvider(project: $0, engine: AppServices.engine) }
    /// タイムラインの「全体表示」(タイムラインのビューが差し込む)。
    var onFitTimeline: () -> Void = {}
    /// 表示 ▸ 選択クリップにズーム(キャンバスが実装する)。
    var onZoomSelection: () -> Void = {}
    /// プレビューの状態(検証用)。
    var previewFrameCount = 0
    var previewIdle = false
    /// 描画が間に合わず、描かれずに捨てられたフレームの数(再生中の検証用)。
    var previewDropped = 0
    /// 再生・キー操作(ドキュメントを閉じるときに手放す)。
    var playback: PlaybackController!
    /// 別ウインドウに出したパネル(画面のドッキング)。
    var dockWindows: DockWindowManager?
    /// 素材ブラウザの別ウインドウ(非モーダル。`showAudioLibrary` に合わせる)。
    var mediaBrowserWindow: MediaBrowserWindow?
    /// 編集済みの通知の差し替え(テスト用)。nil なら NSDocument に伝える。
    var editedTimer: Timer?
    var documentChangeHook: ((NSDocument.ChangeType) -> Void)?
    /// 一度だけ出すお知らせの入れ物(テストでは差し替える。nil ならアプリ全体のもの)。
    var notices: OneTimeNotices?
    /// Dock の進行バー(テストでは差し替える。nil ならアプリ全体のもの)。
    var dockOverride: DockProgressController?
    /// 書き出しキューの差し替え(テスト用。通常は `AppServices.exportQueue`)。
    var exportQueueOverride: ExportQueueController?
    let keyRouter = KeyRouter()

    private var exportTask: Task<Void, Error>?
    /// 書き出し中のファイル名(メニューバーのアイコンに出す)。
    private(set) var exportFileName = ""
    /// 書き出しシートの見出し(プリセットや音声のみのとき変わる)。
    private(set) var exportTitle = "MP4 を書き出しています"
    /// 書き出しシートの補足(H.264 で書けない大きさのとき「HEVC で書き出します」など)。なければ空。
    private(set) var exportNotice = ""
    /// 書き出しの進み具合の共有(テストでは差し替える。nil ならアプリ全体のもの)。
    /// スライダー以外の連続した編集(ステッパー・色・文字入力)を 1 回の Undo にまとめるための待ち。
    var coalesceTask: Task<Void, Never>?
    var coalesceName: String?
    /// 「試しに読み上げる」の再生中のもの。
    var testPlayer: AVAudioPlayer?
    /// 試し読み上げの再生を差し替える(テスト用。nil なら AVAudioPlayer で鳴らす)。
    var playTestAudio: ((URL) throws -> Void)?

    init(project: Project = .new()) {
        self.mirror = ProjectMirror(project)
        self.project = project
        self.selectedCharId = project.characters.first?.id
        self.playback = PlaybackController(model: self)
        OpenProjects.register(self)
        // プロキシ編集の設定(アプリ全体)を、この書類の素材キャッシュへ。設定が変わったら付け直す。
        assets.setPreviewProxies(ProxySettings.enabled(), lookup: ProjectModel.previewProxyPath)
        nonisolated(unsafe) weak let a: RenderAssets? = assets
        NotificationCenter.default.addObserver(forName: ProxySettings.didChange, object: nil, queue: .main) { _ in
            a?.setPreviewProxies(ProxySettings.enabled(), lookup: ProjectModel.previewProxyPath)
        }
    }

    var documentName: String {
        fileURL?.deletingPathExtension().lastPathComponent ?? "無題"
    }

    var effectiveUndoManager: UndoManager { undoManager ?? fallbackUndoManager }

    /// 編集中は触らせない(書き出し・音声生成)。
    var isLocked: Bool { isExporting || busyMessage != nil }

    var effectiveSelectedCharId: String? {
        if let id = selectedCharId, project.characters.contains(where: { $0.id == id }) { return id }
        return project.characters.first?.id
    }

    // MARK: 編集 / Undo

    /// すべての編集の入口。変化があれば Undo に登録する。
    /// ロックされたレイヤーのクリップに触れる編集は、`enforcesLock` が true(既定)のとき断る(状態欄に理由を出す)。
    /// 解像度の変更のように、ロックされたレイヤーも含めて全体を直す編集だけ false で呼ぶ。
    @discardableResult
    func edit(_ name: String, enforcesLock: Bool = true, _ body: (inout Project) -> Void) -> Bool {
        var p = project
        body(&p)
        guard p != project else { return false }
        UnusedMedia.adoptRemoved(from: project, into: &p)
        if enforcesLock, LayerEditing.violatesLock(old: project, new: p) {
            statusText = Self.lockedNotice
            return false
        }
        replace(with: p, name: name)
        return true
    }

    static let lockedNotice = "ロックされたレイヤー・クリップは編集できません"

    private func replace(with new: Project, name: String) {
        let old = project
        project = new
        // Undo / Redo でクリップが無くなったら、選択も外す
        if let id = selectedClipId, !new.allClips.contains(where: { $0.id == id }) {
            let s = TimelineSelection.pruned(selection, in: new)
            if s.primary == nil { selectedClipId = nil } else { setSelection(s) }
        } else if selectedClipIDs.count > 1 {
            let s = TimelineSelection.pruned(selection, in: new)
            if s != selection { setSelection(s) }
        }
        // レイヤーの選択(行番号)は、その行が別のレイヤーになったら外す(削除とその Undo)
        if let li = selectedLayerIndex,
           !(old.tracks.indices.contains(li) && new.tracks.indices.contains(li) && old.tracks[li].id == new.tracks[li].id) {
            selectedLayerIndex = nil
        }
        playback?.projectDidChange()   // 編集したら再生は止める
        let um = effectiveUndoManager
        um.beginUndoGrouping()
        um.registerUndo(withTarget: self) { m in
            MainActor.assumeIsolated { m.replace(with: old, name: name) }
        }
        um.setActionName(name)
        um.endUndoGrouping()
        noteDocumentChanged(undoing: um.isUndoing, redoing: um.isRedoing)
    }

    /// 書類を「編集済み」にする(ウィンドウのタイトルの点・閉じる/終了時の保存確認)。
    /// SwiftUI の ReferenceFileDocument は Undo の登録だけでは編集済みにならなかったので、NSDocument に直接伝える。
    /// Undo / Redo のときは NSDocument の数え方(changeUndone / changeRedone)に合わせ、元に戻れば編集済みが消える。
    func noteDocumentChanged(undoing: Bool, redoing: Bool) {
        let kind: NSDocument.ChangeType = undoing ? .changeUndone : (redoing ? .changeRedone : .changeDone)
        if let hook = documentChangeHook { hook(kind); return }
        guard let w = window, let d = NSDocumentController.shared.document(for: w) else { return }
        d.updateChangeCount(kind)
        // タイトルバーの点(SwiftUI のウィンドウは自動では変わらない)。書類の編集済み(保存で消えるのも)を 0.25 秒ごとに写す
        if editedTimer == nil {
            editedTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak w, weak d] t in
                guard let w, let d else { t.invalidate(); return }
                if w.isDocumentEdited != d.isDocumentEdited { w.isDocumentEdited = d.isDocumentEdited }
            }
        }
        w.isDocumentEdited = d.isDocumentEdited
    }

    // MARK: レイヤー

    /// ＋レイヤー: 末尾に「レイヤー{n+1}」を足す。
    func addTrack() {
        edit("レイヤーの追加") { $0.tracks.append(Track(name: "レイヤー\($0.tracks.count + 1)")) }
    }

    enum TrackFlag { case hidden, muted }

    /// 行ヘッダーの「隠す」「消音」。
    func toggleTrack(_ index: Int, _ flag: TrackFlag) {
        guard project.tracks.indices.contains(index) else { return }
        edit(flag == .hidden ? "レイヤーを隠す/表示" : "レイヤーの消音") { p in
            switch flag {
            case .hidden: p.tracks[index].hidden = p.tracks[index].isHidden ? nil : true
            case .muted: p.tracks[index].muted = p.tracks[index].isMuted ? nil : true
            }
        }
    }

    // MARK: ウィンドウの付き合い(キー操作・終了)

    /// ドキュメントの画面が出たときに 1 回。Space / ←→ / Home を受ける。
    func installKeyboard() {
        keyRouter.windows = { [weak self] in [self?.window] + (self?.dockWindows?.allWindows ?? []) }
        keyRouter.handlers = [
            .playPause: { [weak self] in guard let m = self, !m.isLocked else { return false }; m.playback.togglePlay(); return true },
            .stepBack: { [weak self] in guard let m = self, !m.isLocked else { return false }; m.playback.step(frames: -1); return true },
            .stepForward: { [weak self] in guard let m = self, !m.isLocked else { return false }; m.playback.step(frames: 1); return true },
            .toStart: { [weak self] in guard let m = self, !m.isLocked else { return false }; m.playback.goToStart(); return true },
            .shuttleBack: { [weak self] in guard let m = self, !m.isLocked else { return false }; m.playback.shuttle(by: -1); return true },
            .shuttleStop: { [weak self] in guard let m = self, !m.isLocked else { return false }; m.playback.shuttleStop(); return true },
            .shuttleForward: { [weak self] in guard let m = self, !m.isLocked else { return false }; m.playback.shuttle(by: 1); return true },
            .toEnd: { [weak self] in guard let m = self, !m.isLocked else { return false }; m.goToEnd(); return true },
            // 分割 / 削除 / 選択解除は、ドキュメントのウィンドウが前面のときだけ
            .split: { [weak self] in guard let m = self, !m.isLocked, m.isDocumentKeyWindow, m.canSplit else { return false }; return m.splitSelected() },
            .delete: { [weak self] in guard let m = self, !m.isLocked, m.isDocumentKeyWindow, m.selectedClip != nil else { return false }; return m.deleteSelected() },
            .zoomIn: { [weak self] in guard let m = self, !m.isLocked, m.isDocumentKeyWindow else { return false }; m.zoomTimeline(by: AppMenu.zoomStep); return true },
            .deselect: { [weak self] in guard let m = self, m.isDocumentKeyWindow, m.selectedClipId != nil else { return false }; m.selectedClipId = nil; return true },
        ]
        keyRouter.install()
        playback.warmUp()
    }

    /// ドキュメントを閉じるとき: 再生・エンジン・キー監視を手放す。
    func shutdown() {
        editedTimer?.invalidate(); editedTimer = nil
        keyRouter.uninstall()
        dockWindows?.closeAll(); dockWindows = nil
        mediaBrowserWindow?.closeAll(); mediaBrowserWindow = nil
        stopAudition()
        takePlayer.stop()
        OpenProjects.unregister(self)
        playback.shutdown()
    }

    // MARK: 解像度

    var resolutionKey: String { "\(project.width)x\(project.height)" }

    /// renderer.js applyVideoSize: 文字・字幕・ぼかしを面積比の平方根で直し、4K 以上(または H.264 の上限を超えるサイズ)は HEVC にする。
    /// 書き出せない大きさ(8192×4320 相当の面積を超える)は断って理由を出す。Undo は 1 回。
    func applyVideoSize(_ w: Int, _ h: Int) {
        let w = max(16, w), h = max(16, h)
        guard w != project.width || h != project.height else { return }
        guard OutputPlan.hevcSupports(width: w, height: h) else {
            errorTitle = "解像度を変えられません"
            errorMessage = "このサイズ(\(w)×\(h))は大きすぎて書き出せません。8192×4320 相当の面積までです。"
            return
        }
        edit("解像度の変更", enforcesLock: false) { p in
            p = p.scaledForResolution(newWidth: w, newHeight: h)
            if w * h >= 3840 * 2160 || !OutputPlan.h264Supports(width: w, height: h) { p.codec = "hevc" }
        }
    }

    /// 「解像度を入力」シートの適用。定番でないサイズは「最近使ったカスタム」に残す。
    func applyCustomResolution(width: Int, height: Int) {
        guard !isLocked else { return }
        if let msg = ResolutionInput.validate(width: width, height: height) {
            errorTitle = "解像度を変えられません"; errorMessage = msg; return
        }
        applyVideoSize(width, height)
        rememberCustomResolution(width: width, height: height)
    }

    func rememberCustomResolution(width: Int, height: Int) {
        if !ResolutionPresets.isPreset("\(width)x\(height)") { RecentCustoms.resolutions().addSize(width: width, height: height) }
        ActiveDocument.shared.refresh()
    }

    /// Picker(と MC_DEBUG_SIZE)の入口。"WxH" か "custom"(= 「解像度を入力」シートを開く)。
    func selectResolution(_ key: String) {
        if key == ResolutionPresets.customKey { openResolutionSheet(); return }
        guard let sz = ResolutionInput.parseSize(key) else { return }
        applyVideoSize(sz.width, sz.height)
    }

    /// 出力 ▸ 解像度 ▸ 縦横を入れ替える。いまの幅と高さを入れ替える(文字の大きさ直しも同じ道。Undo は 1 回)。
    func swapResolution() {
        guard !isLocked, project.width != project.height else { return }
        applyVideoSize(project.height, project.width)
    }

    func openResolutionSheet() { if !isLocked { showResolutionSheet = true } }

    /// 設定シートの「適用」。1 回の Undo にまとめる。
    func applySettings(_ d: VideoSettingsDraft, original: VideoSettingsDraft) {
        edit("動画設定", enforcesLock: false) { p in
            let w = max(16, d.width), h = max(16, d.height)
            if w != p.width || h != p.height, OutputPlan.hevcSupports(width: w, height: h) {
                p = p.scaledForResolution(newWidth: w, newHeight: h)
                if w * h >= 3840 * 2160 || !OutputPlan.h264Supports(width: w, height: h) { p.codec = "hevc" }
            }
            if d.codec != original.codec { p.codec = d.codec }
            p.fps = FrameRate.canonical(d.fps)
            p.bg = d.bg
            p.voicevoxUrl = d.voicevoxUrl
            p.aquestalkCommand = d.aquestalkCommand
        }
        if d.width != original.width || d.height != original.height { rememberCustomResolution(width: d.width, height: d.height) }
        if !FrameRate.same(d.fps, original.fps) { rememberCustomFps(d.fps) }
    }

    // MARK: キャラクター

    /// renderer.js btn-add-char と同じ。
    func addCharacter() {
        var c = Character()
        c.name = "キャラ\(project.characters.count + 1)"
        c.engine = "voicevox"
        c.speaker = 3; c.speed = 1; c.pitch = 0; c.intonation = 1
        c.color = "#4f8cff"
        c.x = 0.5; c.flip = false   // charDefaults(9)
        edit("キャラクターの追加") { $0.characters.append(c) }
        selectCharacter(c.id)
    }

    // MARK: 台本 → タイムライン

    /// 台本ボタンの処理。全体で 1 回の Undo。
    func generateVoices(from script: String) async {
        guard !isLocked else { return }
        let lines = script.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return }
        busyMessage = "音声を作っています 0/\(lines.count)"
        defer { busyMessage = nil }
        var work = project
        let provider = ProgressVoiceProvider(inner: voiceProviderFactory(work), total: lines.count) { [weak self] msg in
            Task { @MainActor in self?.busyMessage = msg }
        }
        do {
            let added = try await ScriptTimeline.add(lines: lines, to: &work, voice: provider, directory: FileManager.default.temporaryDirectory, selectedCharId: effectiveSelectedCharId)
            edit("台本から音声を作る", enforcesLock: false) { $0.tracks = work.tracks }
            statusText = "\(added.count) 個のセリフを並べました"
            onFitTimeline()
            noteFallbackIfUsed(provider.inner)
        } catch {
            errorTitle = "音声を作れませんでした"
            errorMessage = error.localizedDescription
        }
    }

    // MARK: 書き出し

    /// 書き出し(ツールバーのボタンも MC_DEBUG_EXPORT もこれを呼ぶ)。
    /// `preset` があれば、プロジェクトの「写し」にプリセットを当てて書き出す(ドキュメント自体は変えない)。
    func runExport(to url: URL, preset: ExportPreset? = nil, spec: ExportSpec? = nil, bitrateMbps: Double? = nil, range: ExportRange? = nil) async -> ExportOutcome {
        guard !directExportBlocked() else { return .failure(ExportError.writerFailed(nil)) }
        // 素材が欠けたまま書き出すと、その部分が静かに抜けるので止める(保存パネルの前にも同じ確認をする)
        if reportMissingMediaForExport() { return .failure(ExportError.writerFailed(nil)) }
        let chosen = spec ?? preset?.spec
        let exporting = chosen?.apply(to: project) ?? project
        let plan = OutputPlan.make(width: exporting.width, height: exporting.height, codec: exporting.codec)
        let isVideo = chosen?.audioOnly != true
        var notices: [String] = []
        if isVideo, plan.error == nil {
            if plan.usesFallbackCodec { notices.append(OutputPlan.fallbackNotice) }
            if let h = OutputPlan.heavyWarning(width: plan.width, height: plan.height, fps: exporting.fps) { notices.append(h) }
        }
        let snapshot = project
        let title = (chosen.map { $0.audioOnly ? "音声を書き出しています" : "\($0.name) で書き出しています" } ?? "MP4 を書き出しています")
        return await runJob(title: title, fileName: url.lastPathComponent, notices: notices,
                            success: "\(url.lastPathComponent) に書き出しました" + (plan.usesFallbackCodec && isVideo ? "(HEVC)" : ""), result: url) { progress in
            try await ExportJob.run(project: snapshot, preset: preset, spec: spec, bitrateMbps: bitrateMbps, range: range, to: url, progress: progress)
        }
    }

    /// 連番画像を `directory` に書き出す(進み具合とキャンセルは動画の書き出しと同じ)。
    func runSequenceExport(to directory: URL, base: String, format: StillFormat, range: ExportRange?) async -> ExportOutcome {
        guard !directExportBlocked() else { return .failure(ExportError.writerFailed(nil)) }
        let snapshot = project
        let n = ImageSequenceExporter.plan(project: snapshot, range: range, base: base, format: format).frames
        return await runJob(title: "連番画像(\(format.title))を書き出しています", fileName: directory.lastPathComponent, notices: [],
                            success: "\(directory.lastPathComponent) に \(n) 枚書き出しました", result: directory) { progress in
            try await ImageSequenceExporter.export(project: snapshot, range: range, to: directory, base: base, format: format, progress: progress)
        }
    }

    /// 直接の書き出しを始めてよいか。書き出し中、またはキューの件が動いている間は始めない(同時に 2 つ走らせない)。
    func directExportBlocked() -> Bool {
        if isExporting { return true }
        if (exportQueueOverride ?? AppServices.exportQueue).queue.isBusy {
            statusText = "書き出しキューが動いています。終わってから書き出してください"
            return true
        }
        return false
    }

    func runJob(title: String, fileName: String, notices: [String], success: String, result: URL,
                        _ job: @escaping (@escaping (Double) -> Void) async throws -> Void) async -> ExportOutcome {
        isExporting = true
        // 直接の書き出しの間は、キューの待っている件を始めない(終わったら自動で再開する)
        let queue = exportQueueOverride ?? AppServices.exportQueue
        queue.queue.isHeld = true
        exportProgress = 0
        exportFileName = fileName
        exportTitle = title
        statusText = "書き出し中…"
        exportNotice = notices.joined(separator: "\n")
        let dock = dockOverride ?? AppServices.dock
        dock.update(0)
        defer { isExporting = false; exportTask = nil; queue.queue.isHeld = false }
        // ファン最大化(オンのときだけ)。開始・終了・キャンセル・失敗のどれでも必ず自動に戻す(下の endExport)
        await AppServices.fan.beginExport()
        let task = Task { [weak self] in
            try await job { v in
                Task { @MainActor in
                    // 終わったあとに遅れて届いた進み具合では Dock を出し直さない
                    guard let self, self.isExporting else { return }
                    self.exportProgress = v
                    dock.update(v)
                }
            }
        }
        exportTask = task
        do {
            try await task.value
            await AppServices.fan.endExport(.finished)
            exportProgress = 1
            statusText = success
            dock.finish(notify: true)
            return .success(result)
        } catch is CancellationError {
            await AppServices.fan.endExport(.cancelled)
            statusText = "書き出しをキャンセルしました"
            dock.finish(notify: false)
            return .cancelled
        } catch {
            await AppServices.fan.endExport(.failed)
            statusText = "書き出しに失敗しました"
            errorTitle = "書き出せませんでした"
            errorMessage = error.localizedDescription
            dock.finish(notify: true)
            return .failure(error)
        }
    }

    func cancelExport() { exportTask?.cancel() }

    // MARK: プレビューからの通知(検証用)

    func previewRequested() { previewIdle = false }
    func previewDisplayed(idle: Bool) { previewFrameCount += 1; if idle { previewIdle = true } }
}

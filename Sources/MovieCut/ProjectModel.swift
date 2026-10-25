import Foundation
import Combine
import AppKit
import AVFoundation
import MovieCutCore

/// アプリ全体で 1 つだけ持つもの(VOICEVOX エンジンは終了時に止める)。
enum AppServices {
    static let engine = VoicevoxEngine()
    /// VOICEVOX の話者一覧(キャラの一覧とプロパティ欄で共有)。
    @MainActor static let speakers = SpeakerCatalog()
    /// 一度だけ出すお知らせ(Kyoko の代用など)。アプリを起動している間に 1 回。
    @MainActor static let notices = OneTimeNotices()
    /// Dock アイコンの進行バー(書き出し中)。
    @MainActor static let dock = DockProgressController(tile: NSApp?.dockTile)
    /// 起動時の依存チェックとバナー(アプリ全体で 1 つ。閉じたらこの起動中は出さない)。
    @MainActor static let deps = DependencyNoticeCenter(checker: DependencyNoticeCenter.debugChecker() ?? { p in await DependencyStatus.check(project: p) })
}

/// 解像度のプリセット(renderer.js の #res-select と同じ並び)。
enum ResolutionPresets {
    static let items: [(key: String, label: String)] = [
        ("1920x1080", "1920×1080"),
        ("2560x1440", "2560×1440"),
        ("3840x2160", "3840×2160"),
        ("1080x1920", "縦 1080×1920"),
        ("720x1280", "縦 720×1280"),
        ("1080x1080", "正方形 1080×1080"),
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
    var fps: Int
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
    /// ドラッグ中の編集の出発点(M4a。ドラッグの間は Undo に積まず、離したときに 1 回だけ登録する)。
    var gestureBase: Project?
    @Published var selectedClipId: String? {
        // クリップを選んだら、プロパティ欄はキャラの表示をやめてクリップの表示にする
        didSet { if selectedClipId != nil { characterPanelActive = false } }
    }
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
    /// 左の台本欄の文字(ツールバー・メニューの「台本から音声を作る」が読む)。
    @Published var scriptText = ""
    /// タイムラインの拡大率(pt/秒)と吸着(M4 のドラッグで使う)。
    @Published var pps: Double = TimelineLayout.defaultPps
    @Published var snapEnabled = true
    @Published var isPlaying = false
    @Published var isSecondScreenOpen = false
    /// 増やすと、同じ時刻でもプレビューを描き直す(再生を止めたとき)。
    @Published var previewEpoch = 0

    /// 保存先(ドキュメントから渡される。無題なら nil)。
    var fileURL: URL?
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
    var voiceProviderFactory: (Project) -> VoiceProvider = { RealVoiceProvider(project: $0, engine: AppServices.engine) }
    /// タイムラインの「全体表示」(タイムラインのビューが差し込む)。
    var onFitTimeline: () -> Void = {}
    /// プレビューの状態(検証用)。
    var previewFrameCount = 0
    var previewIdle = false
    /// 描画が間に合わず、描かれずに捨てられたフレームの数(再生中の検証用)。
    var previewDropped = 0
    /// 再生・別画面・キー操作(ドキュメントを閉じるときに手放す)。
    var playback: PlaybackController!
    let secondScreen = SecondScreenController()
    /// 編集済みの通知の差し替え(テスト用)。nil なら NSDocument に伝える。
    var editedTimer: Timer?
    var documentChangeHook: ((NSDocument.ChangeType) -> Void)?
    /// 一度だけ出すお知らせの入れ物(テストでは差し替える。nil ならアプリ全体のもの)。
    var notices: OneTimeNotices?
    /// Dock の進行バー(テストでは差し替える。nil ならアプリ全体のもの)。
    var dockOverride: DockProgressController?
    let keyRouter = KeyRouter()

    private var exportTask: Task<Void, Error>?
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
    func edit(_ name: String, _ body: (inout Project) -> Void) {
        var p = project
        body(&p)
        guard p != project else { return }
        replace(with: p, name: name)
    }

    private func replace(with new: Project, name: String) {
        let old = project
        project = new
        // Undo / Redo でクリップが無くなったら、選択も外す
        if let id = selectedClipId, !new.allClips.contains(where: { $0.id == id }) { selectedClipId = nil }
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

    // MARK: ウィンドウの付き合い(キー操作・別画面・終了)

    /// ドキュメントの画面が出たときに 1 回。Space / ←→ / Home を受ける。
    func installKeyboard() {
        keyRouter.windows = { [weak self] in [self?.window, self?.secondScreen.window] }
        keyRouter.handlers = [
            .playPause: { [weak self] in guard let m = self, !m.isLocked else { return false }; m.playback.togglePlay(); return true },
            .stepBack: { [weak self] in guard let m = self, !m.isLocked else { return false }; m.playback.step(frames: -1); return true },
            .stepForward: { [weak self] in guard let m = self, !m.isLocked else { return false }; m.playback.step(frames: 1); return true },
            .toStart: { [weak self] in guard let m = self, !m.isLocked else { return false }; m.playback.goToStart(); return true },
            // 分割 / 削除 / 選択解除は、ドキュメントのウィンドウが前面のときだけ(別画面の Esc は別画面が閉じる)
            .split: { [weak self] in guard let m = self, !m.isLocked, m.window?.isKeyWindow == true, m.canSplit else { return false }; return m.splitSelected() },
            .delete: { [weak self] in guard let m = self, !m.isLocked, m.window?.isKeyWindow == true, m.selectedClip != nil else { return false }; return m.deleteSelected() },
            .zoomIn: { [weak self] in guard let m = self, !m.isLocked, m.window?.isKeyWindow == true else { return false }; m.zoomTimeline(by: AppMenu.zoomStep); return true },
            .deselect: { [weak self] in guard let m = self, m.window?.isKeyWindow == true, m.selectedClipId != nil else { return false }; m.selectedClipId = nil; return true },
        ]
        keyRouter.install()
        playback.warmUp()
    }

    func toggleSecondScreen() { secondScreen.toggle(model: self) }

    /// ドキュメントを閉じるとき: 再生・エンジン・別画面・キー監視を手放す。
    func shutdown() {
        editedTimer?.invalidate(); editedTimer = nil
        keyRouter.uninstall()
        secondScreen.close()
        playback.shutdown()
    }

    // MARK: 解像度

    var resolutionKey: String { "\(project.width)x\(project.height)" }

    /// renderer.js applyVideoSize: 文字・字幕・ぼかしを面積比の平方根で直し、4K 以上は HEVC にする。
    func applyVideoSize(_ w: Int, _ h: Int) {
        let w = max(16, w), h = max(16, h)
        guard w != project.width || h != project.height else { return }
        edit("解像度の変更") { p in
            p = p.scaledForResolution(newWidth: w, newHeight: h)
            if w * h >= 3840 * 2160 { p.codec = "hevc" }
        }
    }

    /// Picker(と MC_DEBUG_SIZE)の入口。"WxH" か "custom"(= 設定シートを開く)。
    func selectResolution(_ key: String) {
        if key == ResolutionPresets.customKey { showSettings = true; return }
        let parts = key.lowercased().split(separator: "x").compactMap { Int($0) }
        guard parts.count == 2 else { return }
        applyVideoSize(parts[0], parts[1])
    }

    /// 設定シートの「適用」。1 回の Undo にまとめる。
    func applySettings(_ d: VideoSettingsDraft, original: VideoSettingsDraft) {
        edit("動画設定") { p in
            let w = max(16, d.width), h = max(16, d.height)
            if w != p.width || h != p.height {
                p = p.scaledForResolution(newWidth: w, newHeight: h)
                if w * h >= 3840 * 2160 { p.codec = "hevc" }
            }
            if d.codec != original.codec { p.codec = d.codec }
            p.fps = d.fps
            p.bg = d.bg
            p.voicevoxUrl = d.voicevoxUrl
            p.aquestalkCommand = d.aquestalkCommand
        }
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
            edit("台本から音声を作る") { $0.tracks = work.tracks }
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
    func runExport(to url: URL) async -> ExportOutcome {
        guard !isExporting else { return .failure(ExportError.writerFailed(nil)) }
        isExporting = true
        exportProgress = 0
        statusText = "書き出し中…"
        let dock = dockOverride ?? AppServices.dock
        dock.update(0)
        defer { isExporting = false; exportTask = nil }
        let exporter = Exporter(project: project, assets: RenderAssets())
        let task = Task { [weak self] in
            try await exporter.export(to: url) { v in
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
            exportProgress = 1
            statusText = "\(url.lastPathComponent) に書き出しました"
            dock.finish(notify: true)
            return .success(url)
        } catch is CancellationError {
            statusText = "書き出しをキャンセルしました"
            dock.finish(notify: false)
            return .cancelled
        } catch {
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

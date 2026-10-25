import Foundation
import Combine
import AppKit
import YukkuriCore

/// アプリ全体で 1 つだけ持つもの(VOICEVOX エンジンは終了時に止める)。
enum AppServices {
    static let engine = VoicevoxEngine()
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

/// 1 つのドキュメントの状態。すべての編集は `edit(_:_:)` を通し、UndoManager に登録する(Project 全体のスナップショット式)。
@MainActor
final class ProjectModel: ObservableObject {
    @Published var project: Project
    @Published var selectedClipId: String?
    @Published var selectedCharId: String?
    @Published var currentTime: Double = 0
    @Published var isExporting = false
    @Published var statusText = ""
    @Published var exportProgress: Double = 0
    /// 声を作っている間のメッセージ(nil なら作っていない)。
    @Published var busyMessage: String?
    @Published var errorMessage: String?
    @Published var errorTitle = "エラー"
    @Published var showSettings = false

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
    /// タイムラインの「全体表示」(M3b で実体を入れる)。
    var onFitTimeline: () -> Void = {}
    /// プレビューの状態(検証用)。
    var previewFrameCount = 0
    var previewIdle = false

    private var exportTask: Task<Void, Error>?

    init(project: Project = .new()) {
        self.project = project
        self.selectedCharId = project.characters.first?.id
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
        let um = effectiveUndoManager
        um.beginUndoGrouping()
        um.registerUndo(withTarget: self) { m in
            MainActor.assumeIsolated { m.replace(with: old, name: name) }
        }
        um.setActionName(name)
        um.endUndoGrouping()
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

    /// Picker(と YE_DEBUG_SIZE)の入口。"WxH" か "custom"(= 設定シートを開く)。
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
        selectedCharId = c.id
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
        } catch {
            errorTitle = "音声を作れませんでした"
            errorMessage = error.localizedDescription
        }
    }

    // MARK: 書き出し

    /// 書き出し(ツールバーのボタンも YE_DEBUG_EXPORT もこれを呼ぶ)。
    func runExport(to url: URL) async -> ExportOutcome {
        guard !isExporting else { return .failure(ExportError.writerFailed(nil)) }
        isExporting = true
        exportProgress = 0
        statusText = "書き出し中…"
        defer { isExporting = false; exportTask = nil }
        let exporter = Exporter(project: project, assets: RenderAssets())
        let task = Task { [weak self] in
            try await exporter.export(to: url) { v in
                Task { @MainActor in self?.exportProgress = v }
            }
        }
        exportTask = task
        do {
            try await task.value
            exportProgress = 1
            statusText = "\(url.lastPathComponent) に書き出しました"
            return .success(url)
        } catch is CancellationError {
            statusText = "書き出しをキャンセルしました"
            return .cancelled
        } catch {
            statusText = "書き出しに失敗しました"
            errorTitle = "書き出せませんでした"
            errorMessage = error.localizedDescription
            return .failure(error)
        }
    }

    func cancelExport() { exportTask?.cancel() }

    // MARK: プレビューからの通知(検証用)

    func previewRequested() { previewIdle = false }
    func previewDisplayed(idle: Bool) { previewFrameCount += 1; if idle { previewIdle = true } }
}

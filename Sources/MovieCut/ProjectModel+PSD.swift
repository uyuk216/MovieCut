import AppKit
import UniformTypeIdentifiers
import MovieCutCore

/// ファイル ▸ PSDを読み込む…(と、素材の追加・ドロップで .psd を受けたとき)。
/// 見えるレイヤーを 1 枚ずつ画像クリップにする(または統合して 1 枚)。画像は Application Support の PSDCache に、
/// パス + 更新日時 + サイズで決まるフォルダへ PNG で書く。Undo は 1 回。
extension ProjectModel {
    static var psdCacheRoot: URL? {
        guard let support = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else { return nil }
        return support.appendingPathComponent("MovieCut/PSDCache", isDirectory: true)
    }

    func chooseAndImportPSD() {
        guard !isLocked else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if let t = UTType(filenameExtension: "psd") { panel.allowedContentTypes = [t] }
        panel.title = "PSDを読み込む"
        let run: (NSApplication.ModalResponse) -> Void = { [weak self] resp in
            guard resp == .OK else { return }
            let urls = panel.urls
            Task { @MainActor in _ = await self?.importPSDFiles(urls: urls) }
        }
        if let w = window { panel.beginSheetModal(for: w, completionHandler: run) } else { panel.begin(completionHandler: run) }
    }

    /// 選択肢のシートを出して取り込む(ファイルごと)。置いたクリップの id を返す。
    @discardableResult
    func importPSDFiles(urls: [URL], at time: Double? = nil) async -> [String] {
        var all: [String] = []
        for u in urls where PSDImporter.isPSD(path: u.path) {
            guard !isLocked else { break }
            let doc: PSDDocument
            do { doc = try await Self.loadPSD(u) } catch {
                errorTitle = "PSDを読み込めませんでした"
                errorMessage = "\(u.lastPathComponent): \((error as? PSDError)?.description ?? error.localizedDescription)"
                continue
            }
            guard let mode = await askPSDMode(url: u, doc: doc) else { continue }
            all += await importPSD(document: doc, url: u, mode: mode, at: time)
        }
        return all
    }

    nonisolated static func loadPSD(_ url: URL) async throws -> PSDDocument {
        try await Task.detached { try PSDParser.parse(Data(contentsOf: url, options: .mappedIfSafe)) }.value
    }

    /// シートなしで取り込む(テスト・自動化用)。
    @discardableResult
    func importPSD(url: URL, mode: PSDImportMode, at time: Double? = nil, cacheRoot: URL? = nil) async -> [String] {
        guard !isLocked else { return [] }
        do {
            let doc = try await Self.loadPSD(url)
            return await importPSD(document: doc, url: url, mode: mode, at: time, cacheRoot: cacheRoot)
        } catch {
            errorTitle = "PSDを読み込めませんでした"
            errorMessage = "\(url.lastPathComponent): \((error as? PSDError)?.description ?? error.localizedDescription)"
            return []
        }
    }

    @discardableResult
    func importPSD(document doc: PSDDocument, url: URL, mode: PSDImportMode, at time: Double? = nil, cacheRoot: URL? = nil) async -> [String] {
        guard !isLocked else { return [] }
        guard let root = cacheRoot ?? Self.psdCacheRoot else { statusText = "PSDの画像を置く場所を作れませんでした"; return [] }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let key = PSDImporter.cacheKey(path: url.path, modified: attrs?[.modificationDate] as? Date, size: (attrs?[.size] as? NSNumber)?.int64Value)
        let dir = root.appendingPathComponent(key, isDirectory: true)
        let (w, h) = (project.width, project.height)
        let plan: PSDImportPlan
        do {
            plan = try await Task.detached { try PSDImporter.prepare(doc, mode: mode, canvasWidth: w, canvasHeight: h, cacheDir: dir) }.value
        } catch {
            errorTitle = "PSDを読み込めませんでした"
            errorMessage = "\(url.lastPathComponent): \((error as? PSDError)?.description ?? error.localizedDescription)"
            return []
        }
        guard !plan.items.isEmpty else {
            statusText = plan.hiddenSkipped > 0 ? "見えるレイヤーがありません(非表示 \(plan.hiddenSkipped) 枚)" : "読み込めるレイヤーがありません"
            return []
        }
        let t = max(0, time ?? currentTime)
        var ids: [String] = []
        edit("PSDの読み込み") { p in
            ids = PSDImporter.place(plan.items, at: t, in: &p)
            UnusedMedia.register(plan.items.map(\.path), in: &p)
        }
        guard !ids.isEmpty else { return [] }
        selectedClipId = ids.last
        var s = mode == .flattened ? "PSDを統合して 1 枚で読み込みました" : "PSDのレイヤーを \(ids.count) 枚読み込みました"
        if plan.usedComposite { s += "(レイヤーを読めなかったため統合画像で代用)" }
        if plan.hiddenSkipped > 0 { s += "。非表示 \(plan.hiddenSkipped) 枚は読み込みませんでした" }
        statusText = s
        return ids
    }

    /// 「レイヤーを分けて読み込む」「統合して1枚」を選ぶシート。キャンセルは nil。
    private func askPSDMode(url: URL, doc: PSDDocument) async -> PSDImportMode? {
        let layers = doc.contentLayers
        let hidden = layers.filter { !$0.effectivelyVisible }.count
        let alert = NSAlert()
        alert.messageText = "PSDを読み込む"
        var info = "\(url.lastPathComponent)(\(doc.width)×\(doc.height))"
        if layers.isEmpty {
            info += "\nレイヤーを読み取れなかったため、統合した 1 枚で読み込みます。"
        } else {
            info += "\nレイヤー \(layers.count) 枚(うち非表示 \(hidden) 枚は読み込みません)"
        }
        alert.informativeText = info
        alert.addButton(withTitle: layers.isEmpty ? "読み込む" : "レイヤーを分けて読み込む")
        if !layers.isEmpty { alert.addButton(withTitle: "統合して1枚") }
        alert.addButton(withTitle: "キャンセル")
        let resp: NSApplication.ModalResponse
        if let w = window {
            resp = await withCheckedContinuation { c in alert.beginSheetModal(for: w) { c.resume(returning: $0) } }
        } else {
            resp = alert.runModal()
        }
        if layers.isEmpty { return resp == .alertFirstButtonReturn ? .flattened : nil }
        switch resp {
        case .alertFirstButtonReturn: return .layers
        case .alertSecondButtonReturn: return .flattened
        default: return nil
        }
    }
}

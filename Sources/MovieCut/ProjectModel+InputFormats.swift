import AppKit
import UniformTypeIdentifiers
import MovieCutCore

/// ファイル ▸ SVGを読み込む… / MIDIを読み込む… / 連番画像を読み込む…(と、素材の追加・ドロップでの振り分け)。
/// 変換したファイル(PNG / WAV / APNG)は Application Support の InputCache に、
/// 元ファイルのパス + 更新日時 + サイズで決まるフォルダへ書く(PSD と同じ流儀)。Undo は取り込みごとに 1 回。
extension ProjectModel {
    static var inputCacheRoot: URL? {
        DataLocations.current.inputCache
    }

    // MARK: - SVG(#4)

    func chooseAndImportSVG() {
        guard !isLocked else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if let t = UTType(filenameExtension: "svg") { panel.allowedContentTypes = [t] }
        panel.title = "SVGを読み込む"
        let run: (NSApplication.ModalResponse) -> Void = { [weak self] resp in
            guard resp == .OK else { return }
            let urls = panel.urls
            Task { @MainActor in _ = await self?.importSVGFiles(urls: urls) }
        }
        if let w = window { panel.beginSheetModal(for: w, completionHandler: run) } else { panel.begin(completionHandler: run) }
    }

    @discardableResult
    func importSVGFiles(urls: [URL], at time: Double? = nil) async -> [String] {
        var all: [String] = []
        for u in urls where SVGImporter.isSVG(path: u.path) {
            guard !isLocked else { break }
            all += await importSVG(url: u, at: time)
        }
        return all
    }

    /// シートなしで取り込む(テスト・自動化用)。解像度はプロジェクトのキャンバスに収まる大きさ
    /// (ベクターなので拡大もする)。すでに同じ変換があればキャッシュを使う。
    @discardableResult
    func importSVG(url: URL, at time: Double? = nil, cacheRoot: URL? = nil) async -> [String] {
        guard !isLocked else { return [] }
        guard let root = cacheRoot ?? Self.inputCacheRoot else { statusText = "SVGの画像を置く場所を作れませんでした"; return [] }
        guard let info = SVGParser.info(atPath: url.path) else {
            errorTitle = "SVGを読み込めませんでした"
            errorMessage = "\(url.lastPathComponent): SVG として読み取れませんでした"
            return []
        }
        let size = SVGImporter.fittedPixelSize(info: info, maxWidth: project.width, maxHeight: project.height)
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let key = SVGImporter.cacheKey(path: url.path, modified: attrs?[.modificationDate] as? Date,
                                       size: (attrs?[.size] as? NSNumber)?.int64Value,
                                       pixelWidth: Int(size.width), pixelHeight: Int(size.height))
        let dir = root.appendingPathComponent("svg-\(key)", isDirectory: true)
        let png: String
        do {
            png = try await Task.detached {
                try SVGImporter.prepare(atPath: url.path, pixelWidth: Int(size.width), pixelHeight: Int(size.height), cacheDir: dir)
            }.value
        } catch {
            errorTitle = "SVGを読み込めませんでした"
            errorMessage = "\(url.lastPathComponent): \((error as? SVGError)?.description ?? error.localizedDescription)"
            return []
        }
        let t = max(0, time ?? currentTime)
        var ids: [String] = []
        edit("SVGの読み込み") { p in
            ids = SVGImporter.place(pngPath: png, at: t, in: &p)
            UnusedMedia.register([png], in: &p)
        }
        guard !ids.isEmpty else { return [] }
        selectedClipId = ids.last
        statusText = "SVGを \(Int(size.width))×\(Int(size.height)) で画像化して読み込みました"
        return ids
    }

    // MARK: - MIDI(#5)

    func chooseAndImportMIDI() {
        guard !isLocked else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = ["mid", "midi"].compactMap { UTType(filenameExtension: $0) }
        panel.title = "MIDIを読み込む"
        let run: (NSApplication.ModalResponse) -> Void = { [weak self] resp in
            guard resp == .OK else { return }
            let urls = panel.urls
            Task { @MainActor in _ = await self?.importMIDIFiles(urls: urls) }
        }
        if let w = window { panel.beginSheetModal(for: w, completionHandler: run) } else { panel.begin(completionHandler: run) }
    }

    @discardableResult
    func importMIDIFiles(urls: [URL], at time: Double? = nil) async -> [String] {
        var all: [String] = []
        for u in urls where MidiImporter.isMIDI(path: u.path) {
            guard !isLocked else { break }
            all += await importMIDI(url: u, at: time)
        }
        return all
    }

    /// シートなしで取り込む(テスト・自動化用)。ノートを音声化した WAV の音声クリップと、
    /// ノート開始のマーカーを、合わせて 1 回の Undo で置く。
    @discardableResult
    func importMIDI(url: URL, at time: Double? = nil, cacheRoot: URL? = nil) async -> [String] {
        guard !isLocked else { return [] }
        guard let root = cacheRoot ?? Self.inputCacheRoot else { statusText = "MIDIの音声を置く場所を作れませんでした"; return [] }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let key = MidiImporter.cacheKey(path: url.path, modified: attrs?[.modificationDate] as? Date,
                                        size: (attrs?[.size] as? NSNumber)?.int64Value)
        let dir = root.appendingPathComponent("midi-\(key)", isDirectory: true)
        let prepared: (wavPath: String, file: MidiFileData)
        do {
            prepared = try await Task.detached { try MidiImporter.prepare(atPath: url.path, cacheDir: dir) }.value
        } catch {
            errorTitle = "MIDIを読み込めませんでした"
            errorMessage = "\(url.lastPathComponent): \((error as? MidiError)?.description ?? error.localizedDescription)"
            return []
        }
        let t = max(0, time ?? currentTime)
        var ids: [String] = []
        edit("MIDIの読み込み") { p in
            ids = MidiImporter.place(wavPath: prepared.wavPath, file: prepared.file, at: t, in: &p)
            UnusedMedia.register([prepared.wavPath], in: &p)
        }
        guard !ids.isEmpty else { return [] }
        selectedClipId = ids.last
        statusText = "MIDIを読み込みました(ノート \(prepared.file.notes.count) 個を音声化、マーカー \(MidiImporter.noteMarkers(for: prepared.file, at: 0).count) 件)"
        return ids
    }

    // MARK: - 連番画像(#6)

    func chooseAndImportImageSequence() {
        guard !isLocked else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = ClipEditing.imageExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.title = "連番画像を読み込む(コマのファイルか、フォルダを選ぶ)"
        let run: (NSApplication.ModalResponse) -> Void = { [weak self] resp in
            guard resp == .OK else { return }
            let urls = panel.urls
            Task { @MainActor in
                guard let self else { return }
                // フォルダが選ばれたら、その中の連番を使う
                var sequences: [ImageSequence] = []
                var files: [URL] = []
                for u in urls {
                    if (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                        sequences += ImageSequenceDetector.detectInFolder(u)
                    } else {
                        files.append(u)
                    }
                }
                if let seq = ImageSequenceDetector.singleSequence(urls: files) { sequences.append(seq) }
                else if !files.isEmpty { self.statusText = "選ばれたファイルからは連番が見つかりませんでした"; return }
                guard !sequences.isEmpty else { self.statusText = "連番画像が見つかりませんでした"; return }
                guard let fps = await self.askSequenceFPS(sequences: sequences) else { return }
                var cursor: Double? = nil
                for seq in sequences {
                    let ids = await self.importImageSequence(seq, fps: fps, at: cursor)
                    if let clip = ids.first.flatMap({ id in self.project.allClips.first { $0.id == id } }) {
                        cursor = clip.start + clip.duration
                    }
                }
            }
        }
        if let w = window { panel.beginSheetModal(for: w, completionHandler: run) } else { panel.begin(completionHandler: run) }
    }

    /// フレームレートを選ぶシート(12 / 24 / 30 / 60、既定 24)。キャンセルは nil。
    private func askSequenceFPS(sequences: [ImageSequence]) async -> Double? {
        let alert = NSAlert()
        alert.messageText = "連番画像を読み込む"
        let frames = sequences.reduce(0) { $0 + $1.frameCount }
        alert.informativeText = "\(sequences.count) 件の連番(合計 \(frames) コマ)を 1 件ずつアニメーション素材にします。フレームレートを選んでください。"
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 160, height: 26))
        popup.addItems(withTitles: ["12 fps", "24 fps", "30 fps", "60 fps"])
        popup.selectItem(at: 1)
        alert.accessoryView = popup
        alert.addButton(withTitle: "読み込む")
        alert.addButton(withTitle: "キャンセル")
        let resp: NSApplication.ModalResponse
        if let w = window {
            resp = await withCheckedContinuation { c in alert.beginSheetModal(for: w) { c.resume(returning: $0) } }
        } else {
            resp = alert.runModal()
        }
        guard resp == .alertFirstButtonReturn else { return nil }
        return [12, 24, 30, 60][popup.indexOfSelectedItem]
    }

    /// シートなしで取り込む(テスト・自動化用)。連番を APNG にまとめて、再生する画像クリップを置く。
    @discardableResult
    func importImageSequence(_ sequence: ImageSequence, fps: Double, at time: Double? = nil, cacheRoot: URL? = nil) async -> [String] {
        guard !isLocked else { return [] }
        guard let root = cacheRoot ?? Self.inputCacheRoot else { statusText = "連番画像を置く場所を作れませんでした"; return [] }
        let dir = root.appendingPathComponent("seq-\(ImageSequenceImporter.cacheKey(sequence: sequence, fps: fps))", isDirectory: true)
        let apng: String
        do {
            apng = try await Task.detached { try ImageSequenceImporter.prepare(sequence: sequence, fps: fps, cacheDir: dir) }.value
        } catch {
            errorTitle = "連番画像を読み込めませんでした"
            errorMessage = (error as? ImageSequenceError)?.description ?? error.localizedDescription
            return []
        }
        let t = max(0, time ?? currentTime)
        var ids: [String] = []
        edit("連番画像の読み込み") { p in
            ids = ImageSequenceImporter.place(apngPath: apng, sequence: sequence, fps: fps, at: t, in: &p)
            UnusedMedia.register([apng], in: &p)
        }
        guard !ids.isEmpty else { return [] }
        selectedClipId = ids.last
        var s = "連番画像を読み込みました(\(sequence.frameCount) コマ、\(Int(ImageSequence.validFPS(fps))) fps)"
        if !sequence.missingNumbers.isEmpty { s += "。抜けている番号: \(sequence.missingNumbers.map(String.init).joined(separator: ", "))" }
        statusText = s
        return ids
    }

    /// フォルダ 1 つを取り込む(ドロップ・素材の追加でフォルダが渡されたとき)。見つかった連番を
    /// 既定 24fps で順に置く。連番が無ければ空。
    @discardableResult
    func importSequenceFolder(_ folder: URL, at time: Double? = nil, cacheRoot: URL? = nil) async -> [String] {
        let sequences = ImageSequenceDetector.detectInFolder(folder)
        var all: [String] = []
        var cursor = time
        for seq in sequences {
            let ids = await importImageSequence(seq, fps: ImageSequence.defaultFPS, at: cursor, cacheRoot: cacheRoot)
            all += ids
            if let clip = ids.first.flatMap({ id in project.allClips.first { $0.id == id } }) {
                cursor = clip.start + clip.duration
            }
        }
        return all
    }
}

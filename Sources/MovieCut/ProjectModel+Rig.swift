import AppKit
import UniformTypeIdentifiers
import MovieCutCore

/// パーツ式立ち絵(`CharacterRig`)の編集と取り込み。編集は 1 回 = Undo 1 回。変わらない編集は履歴に載せない
/// (`setCharacterProperty` → `edit` が前後の `Project` を比べる)。
extension ProjectModel {
    // MARK: インスペクタからの編集

    /// リグを書き換える(純粋関数 `RigEditing` の結果を入れる)。リグが無いキャラは何もしない。
    func editRig(charId: String, name: String, _ change: @escaping (CharacterRig) -> CharacterRig) {
        guard let ch = character(charId), let rig = ch.rig else { return }
        let new = change(rig)
        guard new != rig else { return }
        setCharacterProperty({ $0.rig = new }, name: name, charId: charId)
    }

    func rigSelect(charId: String, slot: String, index: Int) {
        editRig(charId: charId, name: "立ち絵パーツの切り替え(\(slot))") { RigEditing.select($0, slot: slot, index: index) }
    }

    func rigAssignBlink(charId: String) {
        editRig(charId: charId, name: "まばたきの目を設定") { RigEditing.assignBlink($0) }
    }

    func rigClearBlink(charId: String) {
        editRig(charId: charId, name: "まばたきの目を外す") { RigEditing.clearBlink($0) }
    }

    /// role: "closed" "open" "a" "i" "u" "e" "o"
    func rigAssignMouth(charId: String, role: String, use: Bool = true) {
        let label = Self.rigMouthLabel(role)
        editRig(charId: charId, name: use ? "口「\(label)」を設定" : "口「\(label)」を外す") { RigEditing.assignMouth($0, role: role, use: use) }
    }

    static func rigMouthLabel(_ role: String) -> String {
        ["closed": "閉じ", "open": "開き", "a": "あ", "i": "い", "u": "う", "e": "え", "o": "お"][role] ?? role
    }

    /// 今の選択を表情として追加(名前は「表情N」)。追加した名前を返す。
    @discardableResult
    func rigAddExpression(charId: String, name: String? = nil) -> String? {
        guard let rig = character(charId)?.rig else { return nil }
        let taken = Set((rig.expressions ?? [:]).keys)
        var key = name?.trimmingCharacters(in: .whitespaces) ?? ""
        if key.isEmpty { var n = taken.count + 1; key = "表情\(n)"; while taken.contains(key) { n += 1; key = "表情\(n)" } }
        let new = RigEditing.captureExpression(rig, name: key)
        guard new != rig else { return nil }
        editRig(charId: charId, name: "表情の追加") { RigEditing.captureExpression($0, name: key) }
        return key
    }

    /// 今の選択で、既にある表情を上書きする。
    func rigRecaptureExpression(charId: String, name: String) {
        guard character(charId)?.rig?.expressions?[name] != nil else { return }
        editRig(charId: charId, name: "表情の更新") { RigEditing.captureExpression($0, name: name) }
    }

    func rigRenameExpression(charId: String, from old: String, to new: String) {
        editRig(charId: charId, name: "表情の名前の変更") { RigEditing.renameExpression($0, from: old, to: new) }
    }

    func rigDeleteExpression(charId: String, name: String) {
        editRig(charId: charId, name: "表情の削除") { RigEditing.deleteExpression($0, name: name) }
    }

    func rigApplyExpression(charId: String, name: String) {
        editRig(charId: charId, name: "表情を選ぶ") { RigEditing.applyExpression($0, name: name) }
    }

    // MARK: 取り込み(ファイル ▸ 立ち絵パーツのフォルダを読み込む… / PSDから立ち絵を作る…)

    func chooseAndImportRigFolder() {
        guard !isLocked else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "立ち絵パーツのフォルダを選ぶ"
        panel.message = "眉・目・口・髪・体などの透過 PNG(同じ大きさ)が入ったフォルダ。下の階層も見ます"
        let run: (NSApplication.ModalResponse) -> Void = { [weak self] resp in
            guard resp == .OK, let url = panel.url else { return }
            Task { @MainActor in _ = await self?.importRigFolder(url: url) }
        }
        if let w = window { panel.beginSheetModal(for: w, completionHandler: run) } else { panel.begin(completionHandler: run) }
    }

    func chooseAndImportRigPSD() {
        guard !isLocked else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if let t = UTType(filenameExtension: "psd") { panel.allowedContentTypes = [t] }
        panel.title = "立ち絵にする PSD を選ぶ"
        let run: (NSApplication.ModalResponse) -> Void = { [weak self] resp in
            guard resp == .OK, let url = panel.url else { return }
            Task { @MainActor in _ = await self?.importRigPSD(url: url) }
        }
        if let w = window { panel.beginSheetModal(for: w, completionHandler: run) } else { panel.begin(completionHandler: run) }
    }

    /// フォルダのパーツをスロットに分けて、新しいキャラ(パーツ式立ち絵つき)を足す。Undo 1 回。足したキャラの id を返す。
    @discardableResult
    func importRigFolder(url: URL) async -> String? {
        guard !isLocked else { return nil }
        statusText = "立ち絵パーツを読み込んでいます…"
        let report = await Task.detached(priority: .userInitiated) { RigFolderImporter.scan(folder: url) }.value
        guard let report else {
            statusText = "立ち絵パーツの画像(PNG)が見つかりませんでした"
            errorTitle = "立ち絵パーツを読み込めませんでした"
            errorMessage = "「\(url.lastPathComponent)」に眉・目・口・髪・体などの PNG が見つかりません。"
            return nil
        }
        var notes = report.notes
        if report.unclassified > 0 { notes.append("振り分けられなかった画像 \(report.unclassified) 枚") }
        return addRigCharacter(rig: report.rig, name: url.lastPathComponent, detail: notes, undoName: "立ち絵パーツの読み込み")
    }

    /// PSD のレイヤーをスロットに分け(キャンバス全面の PNG を PSDCache に書く)、新しいキャラを足す。
    @discardableResult
    func importRigPSD(url: URL, cacheRoot: URL? = nil) async -> String? {
        guard !isLocked else { return nil }
        guard let root = cacheRoot ?? Self.psdCacheRoot else { statusText = "PSDの画像を置く場所を作れませんでした"; return nil }
        statusText = "PSDから立ち絵を作っています…"
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let key = PSDImporter.cacheKey(path: url.path, modified: attrs?[.modificationDate] as? Date, size: (attrs?[.size] as? NSNumber)?.int64Value)
        let dir = root.appendingPathComponent("rig-" + key, isDirectory: true)
        do {
            let result = try await Task.detached(priority: .userInitiated) { () throws -> RigPSDImporter.Result in
                let doc = try PSDParser.parse(Data(contentsOf: url, options: .mappedIfSafe))
                return try RigPSDImporter.build(doc, cacheDir: dir)
            }.value
            return addRigCharacter(rig: result.rig, name: url.deletingPathExtension().lastPathComponent, detail: result.notes, undoName: "PSDから立ち絵を作る")
        } catch {
            errorTitle = "PSDから立ち絵を作れませんでした"
            errorMessage = "\(url.lastPathComponent): \((error as? PSDError)?.description ?? error.localizedDescription)"
            return nil
        }
    }

    private func addRigCharacter(rig: CharacterRig, name: String, detail: [String], undoName: String) -> String? {
        var c = Character()
        c.name = name
        c.engine = "voicevox"
        c.speaker = 3; c.speed = 1; c.pitch = 0; c.intonation = 1
        c.color = "#4f8cff"
        c.x = 0.5; c.flip = false
        c.rig = rig
        guard edit(undoName, { $0.characters.append(c) }) else { return nil }
        selectCharacter(c.id)
        statusText = "立ち絵「\(name)」を追加しました(" + rig.slots.map { "\($0.name) \($0.parts.count)" }.joined(separator: "・") + ")。" + detail.joined(separator: "。")
        return c.id
    }
}

import AppKit
import MovieCutCore

/// 自動保存と復元(画面まわり)。ロジックは Core の `AutosaveRecovery`。
/// 写しは「~/Library/Application Support/MovieCut/Recovery」に置く。利用者のファイルは書き換えない。

/// 復元フォルダ(無ければ作る)。
enum RecoveryFolder {
    static var url: URL? {
        guard let base = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else { return nil }
        let dir = base.appendingPathComponent("MovieCut", isDirectory: true).appendingPathComponent(AutosaveRecovery.folderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 残っている写し(壊れたものは捨てる)。
    static func list(in dir: URL) -> [(url: URL, entry: AutosaveRecovery.Entry)] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { AutosaveRecovery.isRecoveryFileName($0.lastPathComponent) }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url), let e = try? AutosaveRecovery.decode(data) else {
                    try? FileManager.default.removeItem(at: url)
                    return nil
                }
                return (url, e)
            }
            .sorted { $0.entry.savedAt < $1.entry.savedAt }
    }
}

/// 「復元」で開く新しい書類に、復元する中身を渡す箱。`ProjectDocument.init()` が先頭から 1 つずつ受け取る。
@MainActor
enum RecoveryInbox {
    private(set) static var pending: [Project] = []
    static func set(_ list: [Project]) { pending = list }
    static func take() -> Project? { pending.isEmpty ? nil : pending.removeFirst() }
}

/// 起動時の確認: 「復元」「捨てる」「あとで」。
@MainActor
enum RecoveryPrompt {
    static func offerIfNeeded(directory: URL? = RecoveryFolder.url) {
        guard let dir = directory else { return }
        let items = RecoveryFolder.list(in: dir)
        guard !items.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "前回の未保存の編集が残っています"
        alert.informativeText = items.map { AutosaveRecovery.title($0.entry) }.joined(separator: "\n")
            + "\n\n「復元」は新しい書類として開きます。元のファイルは書き換えません。"
        alert.addButton(withTitle: "復元")
        alert.addButton(withTitle: "捨てる")
        alert.addButton(withTitle: "あとで")
        let r = alert.runModal()
        switch r {
        case .alertFirstButtonReturn:
            let projects = items.compactMap { try? Project.decode(from: $0.entry.project) }
            items.forEach { try? FileManager.default.removeItem(at: $0.url) }
            RecoveryInbox.set(projects)
            for _ in projects { NSDocumentController.shared.newDocument(nil) }
        case .alertSecondButtonReturn:
            items.forEach { try? FileManager.default.removeItem(at: $0.url) }
        default:
            break
        }
    }
}

extension ProjectModel {
    /// 書類を開いたら 1 度だけ呼ぶ: 一定間隔で写しを書く。テストや静かな検証では動かさない。
    func startAutosave(restored: Bool = false) {
        guard !DebugHooks.isQuiet, recoveryTimer == nil else { return }
        if restored {
            // 復元した中身は、すぐ写しに残す(次の周期を待たない)
            restoredFromRecovery = true
            autosaveTick()
        }
        recoveryTimer = Timer.scheduledTimer(withTimeInterval: AutosaveRecovery.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.autosaveTick() }
        }
    }

    /// 書類を閉じるとき: タイマーを止め、写しを消す(閉じた = 捨てた、か、保存済み)。
    func closeRecovery() {
        recoveryTimer?.invalidate()
        recoveryTimer = nil
        removeRecoveryFile()
    }

    private var edited: Bool {
        restoredFromRecovery || (window.flatMap { NSDocumentController.shared.document(for: $0) }?.isDocumentEdited ?? false)
    }

    func autosaveTick() {
        guard let dir = RecoveryFolder.url else { return }
        autosaveTick(directory: dir, edited: edited)
    }

    /// 編集済みで版が変わっていれば写しを書く。保存済みなら写しを消す。
    func autosaveTick(directory: URL, edited: Bool) {
        if AutosaveRecovery.shouldRemove(edited: edited) { removeRecoveryFile(in: directory); return }
        guard AutosaveRecovery.shouldWrite(edited: edited, revision: projectRevision, lastWritten: recoveryWrittenRevision),
              let data = try? project.encoded() else { return }
        let entry = AutosaveRecovery.Entry(name: documentName, originalPath: fileURL?.path, savedAt: Date(), project: data)
        guard let out = try? AutosaveRecovery.encode(entry) else { return }
        do {
            try out.write(to: directory.appendingPathComponent(AutosaveRecovery.fileName(sessionID: recoverySessionID)), options: .atomic)
            recoveryWrittenRevision = projectRevision
        } catch {
            // 書けなくても編集は続けられる。次の周期で再度試す
        }
    }

    func removeRecoveryFile() {
        if let dir = RecoveryFolder.url { removeRecoveryFile(in: dir) }
    }

    private func removeRecoveryFile(in dir: URL) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(AutosaveRecovery.fileName(sessionID: recoverySessionID)))
        recoveryWrittenRevision = nil
    }
}

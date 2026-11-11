import AppKit
import MovieCutCore

/// 自動保存と復元(画面まわり)。ロジックは Core の `AutosaveRecovery`。
/// 写しは「~/Library/Application Support/MovieCut/Recovery」に置く。利用者のファイルは書き換えない。

/// 復元フォルダ(無ければ作る)。
enum RecoveryFolder {
    static var url: URL? {
        let dir = DataLocations.current.recovery
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 残っている写し(壊れたもの・巨大なもの・リンクは出さない)。
    static func list(in dir: URL) -> [(url: URL, entry: AutosaveRecovery.Entry)] { AutosaveRecovery.list(in: dir) }
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

    /// 自動保存が「変わったか」を見る版(編集と台本のどちらでも変わる)。
    var autosaveRevision: Int { projectRevision &+ (scriptRevision << 32) }

    func autosaveTick() {
        guard let dir = RecoveryFolder.url else { return }
        autosaveTick(directory: dir, edited: edited)
    }

    /// 編集済みで版が変わっていれば写しを書く。保存済みなら写しを消す。
    /// 主スレッドでは値型のプロジェクトを写し取るだけ。符号化と書き込みは model ごとの直列キューで行い(2 つが重ならない。
    /// 前の書き込みが終わっていなければ今回は見送り、次の周期でそのときの最新を書く = 最後に書いたものが残る)、
    /// 結果は主スレッドへ戻して数える。`synchronous` はテスト用(その場で書いて結果まで反映する)。
    func autosaveTick(directory: URL, edited: Bool, synchronous: Bool = false) {
        if AutosaveRecovery.shouldRemove(edited: edited) { removeRecoveryFile(in: directory); return }
        let revision = autosaveRevision
        guard AutosaveRecovery.shouldWrite(edited: edited, revision: revision, lastWritten: recoveryWrittenRevision),
              !recoveryWriteInFlight else { return }
        // 主スレッドでの仕事はここまで(プロジェクトは値型なので、写しはその後の編集の影響を受けない)
        let snapshot = savedProject
        let name = documentName, path = fileURL?.path, sessionID = recoverySessionID
        let epoch = recoveryEpoch
        let work: @Sendable () -> Bool = {
            guard let data = try? snapshot.encoded() else { return false }
            let entry = AutosaveRecovery.Entry(name: name, originalPath: path, savedAt: Date(), project: data)
            return AutosaveRecovery.write(entry, sessionID: sessionID, in: directory)
        }
        if synchronous {
            applyAutosaveResult(work(), revision: revision, epoch: epoch)
            return
        }
        recoveryWriteInFlight = true
        recoveryQueue.async { [weak self] in
            let ok = work()
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.applyAutosaveResult(ok, revision: revision, epoch: epoch) } }
        }
    }

    /// 書き込みの結果を主スレッドで反映する。書けた版を覚え、失敗は数えて、続けて失敗したときだけ 1 度知らせる(成功で消す)。
    func applyAutosaveResult(_ ok: Bool, revision: Int, epoch: Int) {
        recoveryWriteInFlight = false
        guard epoch == recoveryEpoch else { return }   // 書いている間に写しを消した(保存・閉じた)ので、結果は捨てる
        if ok { recoveryWrittenRevision = revision }
        switch recoveryFailures.record(success: ok) {
        case .showWarning: statusText = AutosaveRecovery.FailureTracker.message
        case .clearWarning: if statusText == AutosaveRecovery.FailureTracker.message { statusText = "" }
        case .none: break
        }
    }

    func removeRecoveryFile() {
        if let dir = RecoveryFolder.url { removeRecoveryFile(in: dir) }
    }

    private func removeRecoveryFile(in dir: URL) {
        // 書き込み中のものがあれば、それが済んでから消す(同じ直列キューの後ろ。短く待つだけ。閉じてすぐ終了しても写しが残らない)。結果は epoch で捨てる
        recoveryEpoch &+= 1
        recoveryWrittenRevision = nil
        if let url = AutosaveRecovery.safeURL(sessionID: recoverySessionID, in: dir) {
            recoveryQueue.sync { try? FileManager.default.removeItem(at: url) }
        }
    }
}

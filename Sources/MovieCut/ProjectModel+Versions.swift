import AppKit
import MovieCutCore

/// 世代バックアップ(画面まわり)。ロジックは Core の `ProjectVersions`。
/// 保存のたびに、保存した中身の写しを「~/Library/Application Support/MovieCut/Versions/<プロジェクトごと>」へ残す(利用者のファイルは書き換えない)。
/// ファイル ▸ 過去の版から復元… は、選んだ世代を「無題の新しい書類」として開く(上書きではなく、写しを開く)。
enum ProjectVersionRecorder {
    /// 保存の書き込みのあとに呼ぶ。保存先が決まっていない(無題)ときは何もしない。重い入出力は別のキューで行い、保存を待たせない。
    static func record(data: Data, projectURL: URL?, locations: DataLocations = .current, defaults: UserDefaults? = nil,
                       minInterval: TimeInterval = ProjectVersions.defaultMinInterval, synchronous: Bool = false) {
        guard let url = projectURL else { return }
        let keep = ProjectVersions.keep(from: defaults ?? locations.defaults)
        let work = {
            _ = try? ProjectVersions.record(data: data, projectURL: url, locations: locations, keep: keep, minInterval: minInterval)
        }
        if synchronous { work() } else { DispatchQueue.global(qos: .utility).async(execute: work) }
    }
}

@MainActor
extension ProjectModel {
    /// 新しい版の Movie Cut で作られたファイルを開いたとき、書類ごとに 1 度だけ知らせる。閉じたら `then`(次の案内)へ。
    func warnNewerFormatOnOpen(then: @escaping () -> Void) {
        guard newerFormatOriginal != nil, !warnedNewerFormat, let window else { then(); return }
        warnedNewerFormat = true
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = ProjectFormat.newerWarning
        alert.informativeText = ProjectFormat.newerWarningDetail
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window) { _ in then() }
    }

    /// 保存した書類か(世代があり得るか)。
    var hasSavedFile: Bool { fileURL != nil }

    /// 今のプロジェクトの世代(新しい順)。
    func versionEntries(locations: DataLocations = .current) -> [ProjectVersions.Entry] {
        guard let url = fileURL else { return [] }
        return ProjectVersions.list(for: url, in: locations)
    }

    /// 世代を、無題の新しい書類として開く準備(中身を渡す)。世代のファイルも、元のプロジェクトも変えない。
    /// 開けなければ throw。実際に書類を開く処理は `openVersionAsNewDocument`。
    @discardableResult
    static func prepareRestore(_ entry: ProjectVersions.Entry) throws -> Project {
        let p = try ProjectVersions.load(entry)
        TemplateInbox.set(p)
        return p
    }

    /// 世代を無題の新しい書類として開く。
    func openVersionAsNewDocument(_ entry: ProjectVersions.Entry) {
        do {
            try Self.prepareRestore(entry)
            NSDocumentController.shared.newDocument(nil)
            statusText = "過去の版のコピーを新しい書類として開きました（元のファイルはそのままです）"
        } catch {
            _ = TemplateInbox.take()
            errorTitle = "過去の版を開けませんでした"
            errorMessage = error.localizedDescription
        }
    }

    /// ファイル ▸ 過去の版から復元…: 世代の一覧(日付と大きさ)から選んで、コピーを新しい書類として開く。
    func showVersionRestore() {
        guard let url = fileURL else {
            errorTitle = "過去の版はまだありません"
            errorMessage = "保存したプロジェクトだけが、保存のたびに世代を残します。先に保存してください。"
            return
        }
        let entries = versionEntries()
        guard !entries.isEmpty else {
            errorTitle = "過去の版はまだありません"
            errorMessage = "「\(url.lastPathComponent)」の世代は、これから保存するたびに残ります。"
            return
        }
        let alert = NSAlert()
        alert.messageText = "過去の版から復元"
        alert.informativeText = "選んだ版のコピーを、新しい無題の書類として開きます。今のプロジェクトのファイルは変わりません。"
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 26), pullsDown: false)
        popup.addItems(withTitles: entries.map { ProjectVersions.title($0) })
        popup.setAccessibilityIdentifier("version-restore-list")
        let keepPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 140, height: 26), pullsDown: false)
        let keepChoices = [5, 10, 20, 50]
        let current = ProjectVersions.keep(from: DataLocations.current.defaults)
        let choices = keepChoices.contains(current) ? keepChoices : (keepChoices + [current]).sorted()
        keepPopup.addItems(withTitles: choices.map { "\($0) 世代" })
        keepPopup.selectItem(at: choices.firstIndex(of: current) ?? 1)
        let label = NSTextField(labelWithString: "残す世代の数")
        let row = NSStackView(views: [label, keepPopup])
        row.orientation = .horizontal; row.spacing = 8
        let stack = NSStackView(views: [popup, row])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 320, height: 62)
        alert.accessoryView = stack
        alert.addButton(withTitle: "コピーを開く")
        alert.addButton(withTitle: "キャンセル")
        let resp = alert.runModal()
        // 世代の数は、開かなくても選んだ値を残す
        DataLocations.current.defaults.set(choices[max(0, keepPopup.indexOfSelectedItem)], forKey: ProjectVersions.keepDefaultsKey)
        guard resp == .alertFirstButtonReturn, popup.indexOfSelectedItem >= 0, popup.indexOfSelectedItem < entries.count else { return }
        openVersionAsNewDocument(entries[popup.indexOfSelectedItem])
    }
}

import AppKit
import UniformTypeIdentifiers
import MovieCutCore

/// ヘルプ ▸ システムレポートを書き出す…。
/// 環境と設定の要約・直近のクラッシュレポートを zip にまとめ、保存先は利用者が選ぶ。
/// プロジェクトファイルは、書類を開いているときにチェックを入れた場合だけ同梱する(既定は入れない)。
/// 書き出しが終わったら Finder で場所を示す。サーバへの自動送信はしない。
enum SystemReportExporter {
    @MainActor
    static func run(model: ProjectModel?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = defaultFileName()
        panel.canCreateDirectories = true
        panel.title = L10n.t("システムレポートを書き出す")
        panel.message = L10n.t("アプリの版数・OS・機種・直近のクラッシュレポート・設定の要約を zip にまとめます。プロジェクトの中身は含めません。")

        var includeBox: NSButton?
        if model != nil {
            let box = NSButton(checkboxWithTitle: L10n.t("現在のプロジェクトファイルも含める"), target: nil, action: nil)
            box.state = .off
            box.setAccessibilityIdentifier("system-report-include-project")
            let note = NSTextField(labelWithString: L10n.t("プロジェクトファイルはそのままの形で zip に入ります。渡したくない場合は入れないでください。"))
            note.font = .systemFont(ofSize: 11)
            note.textColor = .secondaryLabelColor
            let column = NSStackView(views: [box, note])
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = 4
            column.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
            panel.accessoryView = column
            includeBox = box
        }

        let completion: (NSApplication.ModalResponse) -> Void = { resp in
            guard resp == .OK, let picked = panel.url else { return }
            let url = picked.pathExtension.lowercased() == "zip" ? picked : picked.appendingPathExtension("zip")
            let includeProject = includeBox?.state == .on
            Task { @MainActor in
                do {
                    let projectURL = includeProject ? try projectSnapshotFile(model: model) : nil
                    defer {
                        if let projectURL {
                            try? FileManager.default.removeItem(at: projectURL.deletingLastPathComponent())
                        }
                    }
                    let env = environment()
                    let options = SystemReportOptions(projectFileURL: projectURL, settings: settingsSummary(model: model))
                    try await Task.detached(priority: .userInitiated) {
                        try SystemReportBuilder.generate(environment: env, options: options, destination: url)
                    }.value
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } catch {
                    presentError(error)
                }
            }
        }
        FilePanelPresenter.shared.present(panel, window: model?.window ?? NSApp.keyWindow, completion: completion)
    }

    /// 既定のファイル名(MovieCut-SystemReport-20261125-0156.zip)。
    static func defaultFileName(date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmm"
        return "MovieCut-SystemReport-\(f.string(from: date)).zip"
    }

    /// 今の環境情報。版数は Info.plist 由来(AppInfo と同じ出どころ)。
    static func environment() -> SystemReportEnvironment {
        let info = Bundle.main.infoDictionary
        return SystemReportEnvironment.current(
            appName: AppInfo.name,
            appVersion: AppInfo.version(info: info),
            appBuild: (info?["CFBundleVersion"] as? String) ?? "-",
            bundleIdentifier: Bundle.main.bundleIdentifier ?? AppEdition.current.bundleIdentifier,
            edition: AppEdition.current.rawValue)
    }

    /// 設定の要約(個人情報を含まない項目だけ。API キーやパスは入れない)。
    @MainActor
    static func settingsSummary(model: ProjectModel?) -> [SystemReportSetting] {
        var out: [SystemReportSetting] = [
            SystemReportSetting(key: "プレビュー画質", value: PreviewTierStore.current.title),
            SystemReportSetting(key: "プレビューの背景", value: PreviewBackgroundStore.current.title),
            SystemReportSetting(key: "プレビュー用プロキシ", value: ProxySettings.enabled() ? "オン" : "オフ"),
            SystemReportSetting(key: "VOICEVOX", value: FileManager.default.fileExists(atPath: VoicevoxEngine.defaultBinary) ? "インストール済み" : "なし"),
            SystemReportSetting(key: "AquesTalkPlayer", value: AquesTalkSynthesizer(cache: .standard).playerInstalled ? "インストール済み" : "なし"),
        ]
        if let model {
            let p = model.project
            out.append(SystemReportSetting(key: "開いているプロジェクト",
                                           value: "\(p.width)×\(p.height) / \(FrameRate.label(p.fps)) fps"))
        }
        return out
    }

    /// 同梱用に、今のプロジェクトを一時ファイルへ書き出す(保存済みかどうかによらず今の中身)。
    /// 戻り値の一時ファイルは呼び出し側が後片付けする。
    @MainActor
    static func projectSnapshotFile(model: ProjectModel?) throws -> URL? {
        guard let model else { return nil }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MovieCutSystemReportProject-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(model.documentName + ".ymproj")
        try model.project.encoded().write(to: url, options: .atomic)
        return url
    }

    @MainActor
    private static func presentError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.t("システムレポートを作れませんでした")
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}

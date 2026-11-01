import AppKit
import MovieCutCore

/// 素材の欠落: 書き出し前の確認と、場所の再指定(ロジックは Core の `MissingMedia`)。
extension ProjectModel {
    /// 欠けている素材があれば、書き出しを止める文言を出して true。無ければ false。
    @discardableResult
    func reportMissingMediaForExport() -> Bool {
        let missing = MissingMedia.find(in: project)
        guard !missing.isEmpty else { return false }
        errorTitle = "書き出せません(素材が見つかりません)"
        errorMessage = MissingMedia.blockMessage(missing)
        statusText = "欠けている素材が \(missing.count) 件あります。ファイル ▸ 素材の場所を再指定… で直せます"
        return true
    }

    /// ファイル ▸ 素材の場所を再指定…: フォルダを選び、その中から同じファイル名の素材を探して差し替える。Undo は 1 回。
    func chooseAndRelinkMedia() {
        guard !isLocked, !MissingMedia.find(in: project).isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "素材を探すフォルダを選ぶ(中のフォルダも探します)"
        let run: (NSApplication.ModalResponse) -> Void = { [weak self] resp in
            guard resp == .OK, let url = panel.url, let self else { return }
            self.relinkMedia(in: url)
        }
        if let w = window { panel.beginSheetModal(for: w, completionHandler: run) } else { panel.begin(completionHandler: run) }
    }

    /// フォルダの中からファイル名で探して差し替える。差し替えた数を返す(0 なら何も変えない)。
    @discardableResult
    func relinkMedia(in folder: URL) -> Int {
        guard !isLocked else { return 0 }
        var index: [String: String] = [:]
        if let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for case let u as URL in e where index[u.lastPathComponent] == nil { index[u.lastPathComponent] = u.path }
        }
        let r = MissingMedia.relink(project, index: index)
        guard r.relinked > 0 else {
            statusText = "フォルダ内に一致する素材が見つかりませんでした(欠けている素材 \(r.stillMissing) 件)"
            return 0
        }
        edit("素材の場所の再指定") { $0 = r.project }
        statusText = "素材 \(r.relinked) 件の場所を直しました。残り \(r.stillMissing) 件"
        return r.relinked
    }
}

import AppKit
import MovieCutCore

/// 素材の欠落: 書き出し前の確認、開いたときの案内、場所の再指定、パッケージ保存(ロジックは Core の `MissingMedia` / `MediaPackage`)。
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

    /// 書類を開いたとき(書類ごとに 1 回): 欠けた素材があれば案内を出す。
    /// 目印(相対パス)で直るものは先に直す(Undo は 1 回)。直らないものが残ったら、
    /// 「フォルダから探す」「パッケージとして保存…」「あとで」を選ばせる。
    func offerMissingMediaOnOpen() {
        guard !offeredMissingMediaOnOpen, let window else { return }
        offeredMissingMediaOnOpen = true
        var missing = MissingMedia.find(in: project)
        guard !missing.isEmpty else { return }
        let projectDir = fileURL?.deletingLastPathComponent().path
        let hinted = MissingMedia.relink(project, candidates: [:], projectDir: projectDir)
        if hinted.relinked > 0, edit("素材の場所の復元", { $0 = hinted.project }) {
            missing = MissingMedia.find(in: project)
        }
        guard !missing.isEmpty else { statusText = "目印から素材の場所を直しました"; return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "欠けている素材が \(missing.count) 件あります"
        alert.informativeText = MissingMedia.blockMessage(missing, limit: 5)
        alert.addButton(withTitle: "フォルダから探す")
        alert.addButton(withTitle: "パッケージとして保存…")
        alert.addButton(withTitle: "あとで")
        alert.beginSheetModal(for: window) { [weak self] resp in
            guard let self else { return }
            switch resp {
            case .alertFirstButtonReturn: self.chooseAndRelinkMedia()
            case .alertSecondButtonReturn: self.saveAsPackage()
            default: break
            }
        }
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

    /// フォルダの中を再帰的に探し、ファイル名(目印があればサイズも)で差し替える。差し替えた数を返す(0 なら何も変えない)。
    @discardableResult
    func relinkMedia(in folder: URL) -> Int {
        guard !isLocked else { return 0 }
        let index = MissingMedia.index(root: folder)
        let dir = fileURL?.deletingLastPathComponent().path
        let r = MissingMedia.relink(project, candidates: index, projectDir: dir)
        guard r.relinked > 0 else {
            statusText = "フォルダ内に一致する素材が見つかりませんでした(欠けている素材 \(r.stillMissing) 件)"
            return 0
        }
        edit("素材の場所の再指定") { $0 = r.project }
        statusText = "素材 \(r.relinked) 件の場所を直しました。残り \(r.stillMissing) 件"
        return r.relinked
    }

    /// ファイル ▸ パッケージとして保存…: 親フォルダを選び、その中に「<書類名> パッケージ」を作って
    /// プロジェクトと使っている素材(media/)を入れる。今の書類は変えない。
    func saveAsPackage() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "パッケージを作るフォルダを選ぶ"
        panel.prompt = "ここに作る"
        let name = documentName
        let run: (NSApplication.ModalResponse) -> Void = { [weak self] resp in
            guard resp == .OK, let parent = panel.url, let self else { return }
            let fm = FileManager.default
            var folder = parent.appendingPathComponent("\(name) パッケージ", isDirectory: true)
            var n = 2
            while fm.fileExists(atPath: folder.path) {
                folder = parent.appendingPathComponent("\(name) パッケージ \(n)", isDirectory: true)
                n += 1
            }
            let plan = MediaPackage.plan(self.project, size: { p in
                (try? fm.attributesOfItem(atPath: p)[.size] as? NSNumber)?.int64Value
            })
            do {
                try MediaPackage.write(plan, to: folder, projectName: name)
                self.statusText = "パッケージを作りました: \(folder.lastPathComponent)(素材 \(plan.copies.count) 件)"
                if !plan.skipped.isEmpty { self.statusText += "。見つからず入れなかった素材 \(plan.skipped.count) 件" }
            } catch {
                self.errorTitle = "パッケージを作れませんでした"
                self.errorMessage = error.localizedDescription
            }
        }
        if let w = window { panel.beginSheetModal(for: w, completionHandler: run) } else { panel.begin(completionHandler: run) }
    }
}

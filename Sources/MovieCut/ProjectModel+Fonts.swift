import AppKit
import UniformTypeIdentifiers
import MovieCutCore

/// フォントの追加(メニューとドロップ)。ロジックは Core の `FontLibrary`。書類は変えない(Undo には載らない)。
extension ProjectModel {
    /// ファイル ▸ フォントを追加…: フォントを選んで取り込む。
    func chooseAndAddFonts() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = FontLibrary.fontExtensions.sorted().compactMap { UTType(filenameExtension: $0) }
        panel.message = L10n.t("追加するフォント(.ttf / .otf / .ttc)を選んでください")
        panel.prompt = L10n.t("追加")
        let run: (NSApplication.ModalResponse) -> Void = { [weak self] resp in
            guard resp == .OK, let self else { return }
            self.addFonts(urls: panel.urls)
        }
        FilePanelPresenter.shared.present(panel, window: window, completion: run)
    }

    /// フォントのファイルを `Application Support/MovieCut/Fonts` へ取り込み、登録し直して一覧を更新する。
    /// 取り込めたファミリー名を返す。読めないものは案内に並べる。
    @discardableResult
    func addFonts(urls: [URL]) -> [String] {
        let dir = FontLibrary.defaultDirectory()
        var families: [String] = []
        var failed: [String] = []
        var copied = 0
        for u in urls where FontLibrary.isFontFile(u) {
            do {
                let a = try FontLibrary.add(u, to: dir)
                if !a.alreadyPresent { copied += 1 }
                for n in a.familyNames where !families.contains(n) { families.append(n) }
            } catch {
                failed.append(u.lastPathComponent)
            }
        }
        FontLibrary.registerAll(in: dir)
        FontChoices.userFamilies = FontLibrary.families(in: dir)
        if !failed.isEmpty {
            errorTitle = "フォントを追加できませんでした"
            errorMessage = String(format: L10n.t("読めないファイル: %@"), failed.joined(separator: "、"))
        }
        if families.isEmpty {
            statusText = failed.isEmpty ? "追加するフォントがありません" : "フォントを追加できませんでした"
        } else {
            statusText = String(format: L10n.t("フォントを %d 件追加しました(%@)"), copied, families.joined(separator: "、"))
        }
        return families
    }
}

import AppKit
import MovieCutCore

/// プロジェクトのテンプレート(画面まわり)。ロジックは Core の `ProjectTemplate` / `TemplateStore`。
/// 保存先は「~/Library/Application Support/MovieCut/Templates」。利用者のプロジェクトは書き換えない。

/// メニューに出すテンプレートの名前の一覧(フォルダを読むのは最初の 1 回だけ。保存のあとに作り直す)。
@MainActor
enum ProjectTemplateLibrary {
    private static var cached: [String]?
    static var names: [String] {
        if let cached { return cached }
        let list = TemplateStore.standard()?.names() ?? []
        cached = list
        return list
    }
    static func invalidate() { cached = nil }
}

/// 「テンプレートから新規作成」で開く無題の書類に渡す中身の箱。`ProjectDocument.init()` が受け取る。
@MainActor
enum TemplateInbox {
    private static var pending: Project?
    static func set(_ p: Project) { pending = p }
    static func take() -> Project? {
        defer { pending = nil }
        return pending
    }
}

@MainActor
enum ProjectTemplateActions {
    /// ファイル ▸ テンプレートから新規作成 ▸ 名前: 中身を入れた無題の書類を開く。
    static func newDocument(fromTemplate name: String) {
        guard let store = TemplateStore.standard() else { return }
        do {
            let p = try store.load(name: name)
            TemplateInbox.set(p)
            NSDocumentController.shared.newDocument(nil)
        } catch {
            let alert = NSAlert()
            alert.messageText = "テンプレート「\(name)」を開けませんでした"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            ProjectTemplateLibrary.invalidate()
            ActiveDocument.shared.refresh()
        }
    }
}

extension ProjectModel {
    /// ファイル ▸ テンプレートとして保存…: 名前を聞いて、クリップを外した中身を保存する。同じ名前があれば「名前 2」にする。
    func saveAsTemplate() {
        let alert = NSAlert()
        alert.messageText = "テンプレートとして保存"
        alert.informativeText = "クリップは含めません。キャラクター・レイヤー・設定・マーカーを保存します。"
        let field = NSTextField(string: "新しいテンプレート")
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "キャンセル")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let name = ProjectTemplate.sanitizedName(field.stringValue) else {
            statusText = "テンプレートの名前が空なので保存しませんでした"
            return
        }
        do {
            guard let store = TemplateStore.standard() else { throw TemplateStore.StoreError.invalidName }
            let saved = try store.save(project, as: name)
            ProjectTemplateLibrary.invalidate()
            ActiveDocument.shared.refresh()
            statusText = "テンプレート「\(saved)」を保存しました"
        } catch {
            let err = NSAlert()
            err.messageText = "テンプレートを保存できませんでした"
            err.informativeText = error.localizedDescription
            err.runModal()
        }
    }
}

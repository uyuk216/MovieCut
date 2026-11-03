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
    /// ファイル ▸ テンプレートとして保存…: 名前と、含める項目(設定・キャラクター・レイヤー構成・マーカー・選んでいるクリップ)を聞いて保存する。
    /// 同じ名前があれば「名前 2」にする。
    func saveAsTemplate() {
        let alert = NSAlert()
        alert.messageText = "テンプレートとして保存"
        alert.informativeText = "含める項目を選びます。選ばなかった項目は新規プロジェクトの初期値になります。"
        let field = NSTextField(string: "新しいテンプレート")
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        var boxes: [(ProjectTemplate.Parts, NSButton)] = []
        let titles: [(ProjectTemplate.Parts, String)] = [
            (.settings, "設定(解像度・fps・背景・書き出し)"), (.characters, "キャラクター"),
            (.layers, "レイヤーの構成"), (.markers, "マーカー")]
        let stack = NSStackView(views: [field])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 6
        for (part, title) in titles {
            let b = NSButton(checkboxWithTitle: title, target: nil, action: nil)
            b.state = .on
            stack.addArrangedSubview(b)
            boxes.append((part, b))
        }
        let selectedCount = selectedClipIDs.count
        var clipBox: NSButton?
        if selectedCount > 0 {
            let b = NSButton(checkboxWithTitle: "選んでいるクリップ(\(selectedCount) 個)を含める", target: nil, action: nil)
            b.state = .off
            stack.addArrangedSubview(b)
            clipBox = b
        }
        stack.frame = NSRect(x: 0, y: 0, width: 320, height: CGFloat(30 + 22 * (titles.count + (selectedCount > 0 ? 1 : 0))))
        alert.accessoryView = stack
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "キャンセル")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var parts: ProjectTemplate.Parts = []
        for (part, b) in boxes where b.state == .on { parts.insert(part) }
        let clipIds: Set<String> = clipBox?.state == .on ? selectedClipIDs : []
        saveTemplate(named: field.stringValue, parts: parts, clipIds: clipIds)
    }

    /// 名前と項目を決めたあとの保存(ダイアログを使わない部分。テストから呼べる)。
    @discardableResult
    func saveTemplate(named raw: String, parts: ProjectTemplate.Parts, clipIds: Set<String>, store: TemplateStore? = nil) -> String? {
        guard let name = ProjectTemplate.sanitizedName(raw) else {
            statusText = "テンプレートの名前が空なので保存しませんでした"
            return nil
        }
        do {
            guard let store = store ?? TemplateStore.standard() else { throw TemplateStore.StoreError.invalidName }
            let saved = try store.save(project, as: name, parts: parts, clipIds: clipIds)
            ProjectTemplateLibrary.invalidate()
            ActiveDocument.shared.refresh()
            statusText = "テンプレート「\(saved)」を保存しました"
            return saved
        } catch {
            let err = NSAlert()
            err.messageText = "テンプレートを保存できませんでした"
            err.informativeText = error.localizedDescription
            err.runModal()
            return nil
        }
    }
}

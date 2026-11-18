import AppKit
import MovieCutCore

/// アイテムテンプレート(#8)の画面まわり。ロジックは Core の `ItemTemplate` / `ItemTemplateStore`。
/// 保存先はプロジェクトテンプレートと同じ Templates フォルダの `item-templates.json`(アプリ全体で共有)。

/// メニューに出すアイテムテンプレート(組み込み + 保存したもの)。フォルダを読むのは最初の 1 回だけ。
@MainActor
enum ItemTemplateLibraryCache {
    private static var cachedUser: [ItemTemplate]?
    static var userTemplates: [ItemTemplate] {
        if let cachedUser { return cachedUser }
        let list = ItemTemplateStore.standard()?.load() ?? []
        cachedUser = list
        return list
    }
    /// メニューに出す名前(組み込み + 保存したもの・保存した順)。
    static var names: [String] { ItemTemplateLibrary.all(user: userTemplates).map(\.name) }
    static func find(name: String) -> ItemTemplate? {
        ItemTemplateLibrary.find(name: name, user: userTemplates)
    }
    static func invalidate() { cachedUser = nil }
}

extension ProjectModel {
    /// クリップ ▸ 選択クリップをアイテムテンプレートとして保存…: 名前を聞いて保存する。
    func saveSelectedAsItemTemplate() {
        guard let clip = selectedClip else { return }
        let alert = NSAlert()
        alert.messageText = "アイテムテンプレートとして保存"
        alert.informativeText = "選択中のクリップの設定一式(見た目・振る舞い)を保存します。素材やセリフは、既存クリップへの適用では上書きしません。"
        let field = NSTextField(string: "\(clip.type.rawValue) テンプレート")
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "キャンセル")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        saveItemTemplate(named: field.stringValue, from: clip)
    }

    /// 名前を決めたあとの保存(ダイアログを使わない部分。テストから呼べる)。
    @discardableResult
    func saveItemTemplate(named raw: String, from clip: Clip, store: ItemTemplateStore? = nil) -> String? {
        do {
            guard let store = store ?? ItemTemplateStore.standard() else { return nil }
            guard let saved = try store.save(clip: clip, as: raw) else {
                statusText = "テンプレートの名前が空か、上限に達したので保存しませんでした"
                return nil
            }
            ItemTemplateLibraryCache.invalidate()
            ActiveDocument.shared.refresh()
            statusText = "アイテムテンプレート「\(saved.name)」を保存しました"
            return saved.name
        } catch {
            let err = NSAlert()
            err.messageText = "テンプレートを保存できませんでした"
            err.informativeText = error.localizedDescription
            err.runModal()
            return nil
        }
    }

    /// クリップ ▸ アイテムテンプレートを適用 ▸ 名前: 選んでいるクリップ(同じ種類のもの)へ設定を当てる。1 回の Undo。
    @discardableResult
    func applyItemTemplate(named name: String) -> Bool {
        guard !isLocked, let template = ItemTemplateLibraryCache.find(name: name) else { return false }
        let ids = selectedClipIDs
        guard !ids.isEmpty else { statusText = "クリップを選んでください"; return false }
        var applied = 0
        let ok = edit("アイテムテンプレートの適用") { p in
            for ti in p.tracks.indices {
                for ci in p.tracks[ti].clips.indices where ids.contains(p.tracks[ti].clips[ci].id) {
                    if template.apply(to: &p.tracks[ti].clips[ci]) { applied += 1 }
                }
            }
        }
        if ok {
            statusText = "テンプレート「\(name)」を \(applied) 個のクリップに適用しました"
        } else {
            statusText = "種類が違うため、テンプレート「\(name)」を適用できるクリップがありませんでした"
        }
        return ok
    }

    /// クリップ ▸ テンプレートからクリップを作成 ▸ 名前: テンプレートの写しを再生ヘッドの位置に置いて選ぶ。1 回の Undo。
    @discardableResult
    func createClipFromItemTemplate(named name: String) -> String? {
        guard !isLocked, let template = ItemTemplateLibraryCache.find(name: name) else { return nil }
        var clip = template.makeClip()
        clip.start = currentTime
        guard edit("テンプレートからクリップを作成", { ClipEditing.appendToTopLayer(clip, in: &$0, useTarget: true) }) else { return nil }
        selectedClipId = clip.id
        statusText = "テンプレート「\(name)」からクリップを作成しました"
        return clip.id
    }
}

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
    /// 「差し替え可能項目を付ける」がオンなら、文字・色・画像(素材)をスロットとして一緒に保存する。
    func saveSelectedAsItemTemplate() {
        guard let clip = selectedClip else { return }
        let alert = NSAlert()
        alert.messageText = "アイテムテンプレートとして保存"
        alert.informativeText = "選択中のクリップの設定一式(見た目・振る舞い)を保存します。素材やセリフは、既存クリップへの適用では上書きしません。"
        let field = NSTextField(string: "\(clip.type.rawValue) テンプレート")
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        let slotBox = NSButton(checkboxWithTitle: L10n.t("差し替え可能項目を付ける(文字・色・画像)"), target: nil, action: nil)
        slotBox.state = .on
        let stack = NSStackView(views: [field, slotBox])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 300, height: 56)
        alert.accessoryView = stack
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: L10n.t("キャンセル"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let slots = slotBox.state == .on ? ItemTemplate.suggestedSlots(for: clip) : []
        saveItemTemplate(named: field.stringValue, from: clip, slots: slots)
    }

    /// 名前を決めたあとの保存(ダイアログを使わない部分。テストから呼べる)。
    @discardableResult
    func saveItemTemplate(named raw: String, from clip: Clip, slots: [TemplateSlot] = [], store: ItemTemplateStore? = nil) -> String? {
        do {
            guard let store = store ?? ItemTemplateStore.standard() else { return nil }
            // Core の store.save(clip:as:) はスロットを受けないので、capture(slots:) → add → save の順で保存する。
            var list = store.load()
            guard let t = ItemTemplate.capture(name: raw, from: clip, slots: slots),
                  ItemTemplateLibrary.add(&list, t) != nil, let saved = list.last else {
                statusText = "テンプレートの名前が空か、上限に達したので保存しませんでした"
                return nil
            }
            try store.save(list)
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

    /// 差し替え項目の値入力ダイアログ。スロットごとに 1 行(初期値は既定値)。キャンセルは nil。
    /// 戻り値は スロット id → 入力文字列(空欄は「保存時の値のまま」として Core が読み飛ばす)。
    private func askSlotValues(for template: ItemTemplate, confirmTitle: String) -> [String: String]? {
        let alert = NSAlert()
        alert.messageText = L10n.t("差し替える値を入力")
        alert.informativeText = L10n.t("空欄の項目は、テンプレートに保存した値のままになります。色は #RRGGBB の形で入力します。")
        var fields: [(id: String, field: NSTextField)] = []
        var rows: [NSView] = []
        for slot in template.slots {
            let label = NSTextField(labelWithString: slot.label)
            label.frame = NSRect(x: 0, y: 0, width: 100, height: 22)
            let field = NSTextField(string: slot.defaultValue ?? "")
            field.frame = NSRect(x: 0, y: 0, width: 220, height: 22)
            let row = NSStackView(views: [label, field])
            row.orientation = .horizontal
            row.spacing = 8
            rows.append(row)
            fields.append((slot.id, field))
        }
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.frame = NSRect(x: 0, y: 0, width: 340, height: CGFloat(rows.count) * 28)
        alert.accessoryView = stack
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: L10n.t("キャンセル"))
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        var values: [String: String] = [:]
        for f in fields { values[f.id] = f.field.stringValue }
        return values
    }

    /// 無効で断った値があるときの状態欄への付け足し。
    private func rejectionNote(_ count: Int) -> String {
        count > 0 ? "(値が不正な \(count) 項目は反映していません)" : ""
    }

    /// クリップ ▸ アイテムテンプレートを適用 ▸ 名前: 選んでいるクリップ(同じ種類のもの)へ設定を当てる。1 回の Undo。
    /// 差し替え項目があるテンプレートだけ、値入力ダイアログを出す。
    @discardableResult
    func applyItemTemplate(named name: String) -> Bool {
        guard !isLocked, let template = ItemTemplateLibraryCache.find(name: name) else { return false }
        guard !selectedClipIDs.isEmpty else { statusText = "クリップを選んでください"; return false }
        var values: [String: String] = [:]
        if !template.slots.isEmpty {
            guard let v = askSlotValues(for: template, confirmTitle: L10n.t("適用")) else { return false }
            values = v
        }
        return applyItemTemplate(named: name, values: values)
    }

    /// ダイアログを使わない適用(テストから呼べる)。`values` は スロット id → 値。空なら従来どおりの適用。
    @discardableResult
    func applyItemTemplate(named name: String, values: [String: String]) -> Bool {
        guard let template = ItemTemplateLibraryCache.find(name: name) else { return false }
        return applyItemTemplate(template, values: values)
    }

    /// テンプレート本体を直接渡す適用(組み込み・保存済みを問わない)。
    @discardableResult
    func applyItemTemplate(_ template: ItemTemplate, values: [String: String]) -> Bool {
        guard !isLocked else { return false }
        let name = template.name
        let ids = selectedClipIDs
        guard !ids.isEmpty else { statusText = "クリップを選んでください"; return false }
        var applied = 0
        var rejected = 0
        let ok = edit("アイテムテンプレートの適用") { p in
            for ti in p.tracks.indices {
                for ci in p.tracks[ti].clips.indices where ids.contains(p.tracks[ti].clips[ci].id) {
                    let r = template.apply(values: values, to: &p.tracks[ti].clips[ci])
                    if r.changed { applied += 1 }
                    rejected = max(rejected, r.rejections.count)
                }
            }
        }
        if ok {
            statusText = "テンプレート「\(name)」を \(applied) 個のクリップに適用しました" + rejectionNote(rejected)
        } else {
            statusText = "種類が違うため、テンプレート「\(name)」を適用できるクリップがありませんでした"
        }
        return ok
    }

    /// クリップ ▸ テンプレートからクリップを作成 ▸ 名前: テンプレートの写しを再生ヘッドの位置に置いて選ぶ。1 回の Undo。
    /// 差し替え項目があるテンプレートだけ、値入力ダイアログを出す。
    @discardableResult
    func createClipFromItemTemplate(named name: String) -> String? {
        guard !isLocked, let template = ItemTemplateLibraryCache.find(name: name) else { return nil }
        var values: [String: String] = [:]
        if !template.slots.isEmpty {
            guard let v = askSlotValues(for: template, confirmTitle: L10n.t("作成")) else { return nil }
            values = v
        }
        return createClipFromItemTemplate(template, values: values)
    }

    /// ダイアログを使わない作成(テストから呼べる)。`values` は スロット id → 値。空なら従来どおりの作成。
    @discardableResult
    func createClipFromItemTemplate(named name: String, values: [String: String]) -> String? {
        guard let template = ItemTemplateLibraryCache.find(name: name) else { return nil }
        return createClipFromItemTemplate(template, values: values)
    }

    /// テンプレート本体を直接渡す作成(組み込み・保存済みを問わない)。
    @discardableResult
    func createClipFromItemTemplate(_ template: ItemTemplate, values: [String: String]) -> String? {
        guard !isLocked else { return nil }
        let made = template.instantiate(values: values)
        var clip = made.clip
        clip.start = currentTime
        guard edit("テンプレートからクリップを作成", { ClipEditing.appendToTopLayer(clip, in: &$0, useTarget: true) }) else { return nil }
        selectedClipId = clip.id
        statusText = "テンプレート「\(template.name)」からクリップを作成しました" + rejectionNote(made.rejections.count)
        return clip.id
    }
}

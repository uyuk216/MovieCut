import AppKit
import MovieCutCore

/// 開いている書類(ProjectModel)の一覧。別プロジェクトへの複製で、行き先の候補にする。弱い参照だけ持つ。
@MainActor
enum OpenProjects {
    private final class Ref { weak var model: ProjectModel?; init(_ m: ProjectModel) { model = m } }
    private static var refs: [Ref] = []

    static func register(_ m: ProjectModel) {
        refs.removeAll { $0.model == nil }
        if !refs.contains(where: { $0.model === m }) { refs.append(Ref(m)) }
    }
    static func unregister(_ m: ProjectModel) { refs.removeAll { $0.model == nil || $0.model === m } }
    /// 自分以外で、ウインドウを持つ(開かれている)書類。
    static func others(excluding m: ProjectModel) -> [ProjectModel] {
        refs.compactMap(\.model).filter { $0 !== m && $0.window != nil }
    }
}

/// 選んだクリップを、元の配置(レイヤーと時刻)を残して別のプロジェクトへ複製する(候補 37)。ロジックは MovieCutCore の `ClipTransfer`。
/// 元のプロジェクトは変えない。行き先が開いている書類なら、その書類の 1 回の Undo。新しい書類なら、未保存の無題の書類として開く。
extension ProjectModel {
    private var transferIds: Set<String> {
        var ids = selectedClipIDs
        if let id = selectedClipId { ids.insert(id) }
        return ids
    }

    /// 選択だけの新しいプロジェクトを作って、無題の書類として開く。作ったクリップ数を返す(0 = 何もしなかった)。
    @discardableResult
    func transferSelectionToNewDocument() -> Int {
        guard !isLocked, let pk = ClipTransfer.extract(from: project, clipIds: transferIds) else {
            statusText = "複製するクリップを選んでください"
            return 0
        }
        TemplateInbox.set(pk.project)
        NSDocumentController.shared.newDocument(nil)
        statusText = "\(pk.copied) 個のクリップを新しいプロジェクトに複製しました"
        return pk.copied
    }

    /// 選択を、開いている別の書類へ複製する(行き先の 1 回の Undo。行き先の選択は複製したクリップになる)。入れた数を返す。
    @discardableResult
    func transferSelection(to dest: ProjectModel) -> Int {
        guard !isLocked, dest !== self, !dest.isLocked, let pk = ClipTransfer.extract(from: project, clipIds: transferIds) else {
            statusText = "複製できませんでした"
            return 0
        }
        let n = dest.receiveTransfer(pk.project)
        statusText = n > 0 ? "\(n) 個のクリップを「\(dest.documentName)」に複製しました" : "「\(dest.documentName)」には入れられませんでした(ロックされたレイヤーなど)"
        return n
    }

    /// 行き先として受け取る。時刻もレイヤーも元のまま。
    func receiveTransfer(_ source: Project) -> Int {
        guard !isLocked, let r = ClipTransfer.insert(from: source, into: project) else {
            statusText = "複製されたクリップを入れられませんでした"
            return 0
        }
        flushCoalesced()
        guard edit("別のプロジェクトから複製", enforcesLock: false, { $0 = r.project }) else { return 0 }
        setSelection(ClipSelection(ids: Set(r.newIds), primary: r.newIds.first))
        var note = "\(r.newIds.count) 個のクリップを複製しました"
        if r.skipped > 0 { note += "(ロックされたレイヤーの \(r.skipped) 個は入れていません)" }
        if r.addedCharacters > 0 { note += "。キャラクターを \(r.addedCharacters) 人足しました" }
        statusText = note
        return r.newIds.count
    }

    /// クリップ ▸ 選択クリップを別プロジェクトへ複製…: 行き先(新しいプロジェクト / 開いている書類)を聞く。
    func chooseTransferDestination() {
        guard !isLocked, !transferIds.isEmpty else { return }
        let others = OpenProjects.others(excluding: self)
        let alert = NSAlert()
        alert.messageText = "選択クリップを別プロジェクトへ複製"
        alert.informativeText = "レイヤーと時刻はそのまま写します。このプロジェクトは変わりません。"
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 26))
        popup.addItem(withTitle: "新しいプロジェクト")
        others.forEach { popup.addItem(withTitle: "「\($0.documentName)」に追加") }
        alert.accessoryView = popup
        alert.addButton(withTitle: "複製")
        alert.addButton(withTitle: "キャンセル")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let i = popup.indexOfSelectedItem
        if i <= 0 { transferSelectionToNewDocument() }
        else if others.indices.contains(i - 1) { transferSelection(to: others[i - 1]) }
    }
}

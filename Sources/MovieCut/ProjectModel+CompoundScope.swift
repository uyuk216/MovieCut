import Foundation
import MovieCutCore

/// 複合クリップの中を編集する(メニュー ▸ クリップ ▸ 複合クリップの中を編集 / 複合クリップから出る、タイムラインのダブルクリック、パンくず)。
/// 計算は MovieCutCore の `CompoundScope`。入る・出るは「画面の切り替え」なので Undo には載せない。中での編集は通常の `edit` を通り、Undo の列は共通。
extension ProjectModel {
    /// いま複合クリップの中にいるか。
    var isInsideCompound: Bool { !compoundPath.isEmpty }

    /// パンくずの名前の列(先頭は「プロジェクト」)。
    var compoundBreadcrumb: [String] { CompoundScope.breadcrumb(rootProject, path: compoundPath) }

    /// 選んでいる複合クリップの中に入る(`clipId` を渡せばそのクリップ)。複合クリップでない・中身が無い・書き出し中などは false。
    @discardableResult
    func enterCompound(_ clipId: String? = nil) -> Bool {
        guard !isLocked, let id = clipId ?? selectedClipId, let c = clip(id), CompoundEditing.supports(c) else { return false }
        guard c.tracks != nil else { statusText = "この複合クリップには中身がありません"; return false }
        flushCoalesced()
        playback.pause()
        let root = rootProject
        let path = compoundPath + [id]
        guard let v = CompoundScope.view(of: root, path: path) else { return false }
        scopeRoot = root
        compoundPath = path
        selectedClipId = nil
        selectedLayerIndex = nil
        project = v
        playback.projectDidChange()
        playback.seek(to: 0)
        return true
    }

    /// 1 つ外へ出る。一番上にいるときは何もしない。
    @discardableResult
    func exitCompound() -> Bool {
        guard !compoundPath.isEmpty else { return false }
        return exitCompound(toDepth: compoundPath.count - 1)
    }

    /// 深さ `toDepth`(0 = 書類の一番上)まで出る(パンくずのクリック)。いまより深い・同じなら何もしない。
    @discardableResult
    func exitCompound(toDepth depth: Int) -> Bool {
        guard depth >= 0, depth < compoundPath.count else { return false }
        flushCoalesced()
        playback.pause()
        let leftId = compoundPath.last
        let root = rootProject
        let path = Array(compoundPath.prefix(depth))
        scopeRoot = path.isEmpty ? nil : root
        compoundPath = path
        selectedLayerIndex = nil
        project = CompoundScope.view(of: root, path: path) ?? root
        playback.projectDidChange()
        playback.seek(to: 0)
        if let leftId, project.allClips.contains(where: { $0.id == leftId }) { selectOnly(leftId) } else { selectedClipId = nil }
        return true
    }

    /// 一番上まで出る(書き出しの前など、書類全体が必要なとき)。
    func exitAllCompoundScopes() {
        _ = exitCompound(toDepth: 0)
    }
}

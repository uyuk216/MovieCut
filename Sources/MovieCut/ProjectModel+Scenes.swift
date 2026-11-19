import Foundation
import MovieCutCore

/// シーン／ネスト(W3-01)。計算は MovieCutCore の `SceneEditing` / `SceneScope`。
/// ここは Undo(1 操作 = 1 回)・選択・状態表示と、「シーンを開いて編集」の画面切り替えだけ。
/// 開く・出るは画面の切り替えなので Undo には載せない(複合クリップと同じ)。中での編集は通常の `edit` を通り、
/// 根への戻しは `ProjectModel.rootProject` / `replace` / `applyRoot` がシーン分も面倒を見る。
extension ProjectModel {
    /// いまシーンの中を編集しているか。
    var isInsideScene: Bool { editingSceneId != nil }

    /// パンくずの名前の列(先頭は「プロジェクト」)。
    var sceneBreadcrumb: [String] { SceneScope.breadcrumb(rootProject, sceneId: editingSceneId) }

    /// 開いているシーンの名前(無ければ nil)。
    var editingSceneName: String? {
        editingSceneId.flatMap { rootProject.scene(withId: $0)?.name }
    }

    // MARK: 一覧(作成・名前変更・複製・削除)

    /// シーン一覧のシートを開く。
    func openSceneList() {
        guard !isLocked else { return }
        showSceneListSheet = true
    }

    /// 空のシーンを作る。作ったシーンの id を返す(1 回の Undo)。
    @discardableResult
    func createScene(name: String) -> String? {
        guard !isLocked else { return nil }
        var made: String?
        let ok = edit("シーンを作成", enforcesLock: false) { p in
            if let r = SceneEditing.create(in: p, name: name) { p = r.project; made = r.sceneId }
        }
        if ok { statusText = "シーン「\(name)」を作成しました" }
        return ok ? made : nil
    }

    /// シーンの名前を変える(1 回の Undo)。
    @discardableResult
    func renameScene(_ sceneId: String, to name: String) -> Bool {
        guard !isLocked else { return false }
        return edit("シーンの名前を変更", enforcesLock: false) { p in
            if let r = SceneEditing.rename(in: p, sceneId: sceneId, to: name) { p = r }
        }
    }

    /// シーンを複製する(1 回の Undo)。複製先の id を返す。
    @discardableResult
    func duplicateScene(_ sceneId: String) -> String? {
        guard !isLocked else { return nil }
        var made: String?
        let ok = edit("シーンを複製", enforcesLock: false) { p in
            if let r = SceneEditing.duplicate(in: p, sceneId: sceneId) { p = r.project; made = r.sceneId }
        }
        return ok ? made : nil
    }

    /// シーンを削除する(1 回の Undo)。削除ポリシー: 参照されているシーンは削除できない
    /// (参照クリップが黙って壊れるのを防ぐ。先にシーンクリップを消すのが手順)。
    @discardableResult
    func deleteScene(_ sceneId: String) -> Bool {
        guard !isLocked else { return false }
        if SceneEditing.referenceCount(in: rootProject, sceneId: sceneId) > 0 {
            statusText = "参照されているシーンは削除できません。先にシーンクリップを削除してください"
            return false
        }
        // 開いているシーン自身を消すときは、先に出てから消す(見え方のまま消すと根への戻し先が無くなるため)
        if editingSceneId == sceneId { exitSceneScope() }
        return edit("シーンを削除", enforcesLock: false) { p in
            if let r = SceneEditing.delete(in: p, sceneId: sceneId) { p = r }
        }
    }

    // MARK: 配置

    /// シーンクリップを、いま見えているタイムラインの選択レイヤー(無ければ先頭)・再生ヘッドの位置に置く(1 回の Undo)。
    /// シーンの中を編集中なら、そのシーンの中に置く(循環になる配置は `SceneEditing` が拒否する)。
    @discardableResult
    func placeSceneClip(_ sceneId: String) -> Bool {
        guard !isLocked else { return false }
        let host: SceneEditing.Host = editingSceneId.map { .scene($0) } ?? .main
        let trackIndex = selectedLayerIndex ?? 0
        let at = currentTime
        var placedId: String?
        let ok = edit("シーンを配置") { p in
            if let r = SceneEditing.place(in: p, sceneId: sceneId, host: host, trackIndex: trackIndex, at: at) { p = r.project; placedId = r.clipId }
        }
        guard ok, let placedId else {
            statusText = "シーンを配置できません(空のシーン、ロックされたレイヤー、循環する配置のいずれか)"
            return false
        }
        selectOnly(placedId)
        return true
    }

    // MARK: 選択から作成(R2-3)

    /// 選択から作るときの既定の名前(「シーン 1」「シーン 2」…のうち、まだ使われていない最初のもの)。
    func defaultSceneName() -> String {
        let names = Set(project.scenes.map(\.name))
        var i = 1
        while names.contains("シーン \(i)") { i += 1 }
        return "シーン \(i)"
    }

    /// 選んでいるクリップ(1 つ以上・複数トラック可)を新しいシーン定義にまとめ、元の位置にシーンクリップを置く。
    /// 計算は `SceneEditing.createFromSelection`。全体で 1 回の Undo で、作ったシーンクリップを選ぶ。
    /// シーンの中を編集中なら、そのシーンの中の選択が対象で、シーンクリップもその中へ置かれる
    /// (循環になる作成は Core が拒否する)。名前を渡さなければ `defaultSceneName()`。
    @discardableResult
    func createSceneFromSelection(name: String? = nil) -> (sceneId: String, clipId: String)? {
        guard !isLocked else { return nil }
        let ids = LayerEditing.editableIds(selectedClipIDs, in: project)
        guard !ids.isEmpty else { statusText = "シーンにするクリップを選んでください"; return nil }
        let sceneName = name ?? defaultSceneName()
        var made: (sceneId: String, clipId: String)?
        let ok = edit("選択からシーンを作成") { p in
            if let r = SceneEditing.createFromSelection(in: p, name: sceneName, clipIds: Array(ids), hostSceneId: editingSceneId) {
                p = r.project
                made = (sceneId: r.sceneId, clipId: r.clipId)
            }
        }
        guard ok, let made else {
            statusText = "シーンを作成できません(深すぎる入れ子、循環する参照のいずれか)"
            return nil
        }
        selectOnly(made.clipId)
        statusText = "選択からシーン「\(sceneName)」を作成しました"
        return made
    }

    /// 選んでいるクリップがシーンクリップか(メニューの有効・無効)。
    var selectedSceneClipId: String? {
        guard let c = selectedClip, c.type == .scene else { return nil }
        return c.sceneId
    }

    // MARK: 開く・出る

    /// シーンを開いて中を編集する。複合クリップの中にいるときは入らない(スコープは 1 段だけ)。
    @discardableResult
    func enterScene(_ sceneId: String) -> Bool {
        guard !isLocked, compoundPath.isEmpty, editingSceneId == nil else { return false }
        let root = rootProject
        guard let v = SceneScope.view(of: root, sceneId: sceneId) else { return false }
        flushCoalesced()
        playback.pause()
        sceneScopeRoot = root
        editingSceneId = sceneId
        selectedClipId = nil
        selectedLayerIndex = nil
        project = v
        playback.projectDidChange()
        playback.seek(to: 0)
        return true
    }

    /// 選んでいるシーンクリップのシーンを開く。
    @discardableResult
    func enterSelectedScene() -> Bool {
        guard let sid = selectedSceneClipId else { return false }
        return enterScene(sid)
    }

    /// シーンから出て、書類の一番上に戻る。中での編集はすでに根へ戻っているので、見え方を戻すだけ。
    @discardableResult
    func exitSceneScope() -> Bool {
        guard let sid = editingSceneId else { return false }
        flushCoalesced()
        playback.pause()
        let root = rootProject
        sceneScopeRoot = nil
        editingSceneId = nil
        selectedLayerIndex = nil
        project = root
        playback.projectDidChange()
        playback.seek(to: 0)
        if let ref = root.tracks.flatMap({ $0.clips }).first(where: { $0.type == .scene && $0.sceneId == sid }) {
            selectOnly(ref.id)
        } else {
            selectedClipId = nil
        }
        return true
    }
}

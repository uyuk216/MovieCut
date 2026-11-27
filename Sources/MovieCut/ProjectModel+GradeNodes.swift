import AppKit
import UniformTypeIdentifiers
import MovieCutCore

/// ノード式グレーディングの編集(クリップの `gradeNodes`)。値の変更は `GradeNodeEditing`(純粋関数)に任せ、Undo はクリップ単位で積む。
extension ProjectModel {
    @discardableResult
    func addGradeNode(_ kind: EffectKind, clipId: String? = nil) -> String? {
        guard !isLocked, let c = gradeTargetClip(clipId) else { return nil }
        let node = GradeNode(kind)
        var probe = c
        guard GradeNodeEditing.add(&probe, node) else { return nil }
        setClipProperty({ _ = GradeNodeEditing.add(&$0, node) }, name: String(format: L10n.t("ノードの追加: %@"), L10n.t(kind.label)), clipId: c.id)
        return node.id
    }

    func removeGradeNode(id: String, clipId: String? = nil) {
        guard !isLocked else { return }
        setClipProperty({ _ = GradeNodeEditing.remove(&$0, id: id) }, name: "ノードの削除", clipId: clipId)
    }

    func moveGradeNode(id: String, by delta: Int, clipId: String? = nil) {
        guard !isLocked else { return }
        setClipProperty({ _ = GradeNodeEditing.move(&$0, id: id, by: delta) }, name: "ノードの順番の変更", clipId: clipId)
    }

    func setGradeNodeEnabled(_ on: Bool, id: String, clipId: String? = nil) {
        guard !isLocked else { return }
        setClipProperty({ _ = GradeNodeEditing.setEnabled(&$0, id: id, on) }, name: on ? "ノードを有効にする" : "ノードを無効にする", clipId: clipId)
    }

    /// スライダー操作中の値(ドラッグ全体で 1 回の Undo)。
    func liveGradeNodeOpacity(_ v: Double, id: String, clipId: String? = nil) {
        liveClipProperty({ _ = GradeNodeEditing.setOpacity(&$0, id: id, v) }, name: "ノードの不透明度の変更", clipId: clipId)
    }

    func liveGradeNodeParam(_ key: String, _ v: Double, id: String, clipId: String? = nil) {
        liveClipProperty({ _ = GradeNodeEditing.setParam(&$0, id: id, key: key, v) }, name: "ノードの調整", clipId: clipId)
    }

    /// ノードの LUT: .cube を選ぶ(開くパネル)。読めると確かめてから書く。
    func chooseGradeNodeLUT(id: String, clipId: String? = nil) {
        guard gradeTargetClip(clipId) != nil else { return }
        let target = clipId ?? selectedClipId
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "cube")].compactMap { $0 }
        panel.allowsOtherFileTypes = true
        panel.title = L10n.t("LUT（.cube）を読み込む")
        let run: (NSApplication.ModalResponse) -> Void = { [weak self] resp in
            guard resp == .OK, let url = panel.url, let self else { return }
            Task { @MainActor in
                do { _ = try CubeLUT.load(from: url) } catch {
                    self.statusText = "LUT を読み込めません: \(url.lastPathComponent)（.cube の形式が正しくありません）"
                    return
                }
                self.setClipProperty({ _ = GradeNodeEditing.setLUTPath(&$0, id: id, url.path) }, name: String(format: L10n.t("LUT の読み込み: %@"), url.lastPathComponent), clipId: target)
            }
        }
        FilePanelPresenter.shared.present(panel, window: window, completion: run)
    }
}

extension ProjectModel {
    fileprivate func gradeTargetClip(_ clipId: String?) -> Clip? {
        guard !isLocked, let id = clipId ?? selectedClipId, let c = clip(id) else { return nil }
        return c
    }
}

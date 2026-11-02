import Foundation
import AppKit
import UniformTypeIdentifiers
import MovieCutCore

/// エフェクト(インスペクタ・メニューが呼ぶ)。計算は MovieCutCore の EffectEditing に任せ、ここは Undo・選択・状態表示だけ。
/// 引数の値は、キーフレームの仕組み("fx.<番号>.<引数>")と同じ `setKeyed` / `coalescedKeyed` / `liveKeyed` で編集する。
extension ProjectModel {
    private func targetClip(_ clipId: String?) -> Clip? {
        guard !isLocked, let id = clipId ?? selectedClipId, let c = clip(id) else { return nil }
        return c
    }

    // MARK: 追加・削除・並べ替え

    @discardableResult
    func addEffect(_ kind: EffectKind, clipId: String? = nil) -> Bool {
        guard let c = targetClip(clipId) else { return false }
        var probe = c
        guard EffectEditing.add(&probe, kind) else { return false }
        setClipProperty({ _ = EffectEditing.add(&$0, kind) }, name: "エフェクトの追加: \(kind.label)", clipId: c.id)
        return true
    }

    /// メニュー「クリップ ▸ エフェクト ▸ ○○」。
    @discardableResult
    func addEffectSelected(_ kind: EffectKind) -> Bool { addEffect(kind) }

    @discardableResult
    func removeEffect(at index: Int, clipId: String? = nil) -> Bool {
        guard let c = targetClip(clipId) else { return false }
        var probe = c
        guard EffectEditing.remove(&probe, at: index) else { return false }
        let label = c.effects[index].known?.label ?? "エフェクト"
        setClipProperty({ _ = EffectEditing.remove(&$0, at: index) }, name: "エフェクトの削除: \(label)", clipId: c.id)
        return true
    }

    @discardableResult
    func moveEffect(at index: Int, by delta: Int, clipId: String? = nil) -> Bool {
        guard let c = targetClip(clipId) else { return false }
        var probe = c
        guard EffectEditing.move(&probe, at: index, by: delta) else { return false }
        setClipProperty({ _ = EffectEditing.move(&$0, at: index, by: delta) }, name: "エフェクトの順番の変更", clipId: c.id)
        return true
    }

    @discardableResult
    func setEffectEnabled(_ on: Bool, at index: Int, clipId: String? = nil) -> Bool {
        guard let c = targetClip(clipId) else { return false }
        var probe = c
        guard EffectEditing.setEnabled(&probe, at: index, on) else { return false }
        setClipProperty({ _ = EffectEditing.setEnabled(&$0, at: index, on) }, name: on ? "エフェクトを有効にする" : "エフェクトを無効にする", clipId: c.id)
        return true
    }

    /// 影・縁取りの色(色ピッカーの連続編集なので、まとめて 1 回の Undo)。
    func coalescedEffectColor(_ hex: String, at index: Int, clipId: String? = nil) {
        guard !isLocked else { return }
        coalescedClipProperty({ _ = EffectEditing.setColor(&$0, at: index, hex) }, name: "エフェクトの色の変更", clipId: clipId)
    }

    @discardableResult
    func resetEffect(at index: Int, clipId: String? = nil) -> Bool {
        guard let c = targetClip(clipId) else { return false }
        var probe = c
        guard EffectEditing.reset(&probe, at: index) else { return false }
        setClipProperty({ _ = EffectEditing.reset(&$0, at: index) }, name: "エフェクトを初期値に戻す", clipId: c.id)
        return true
    }

    // MARK: メニュー

    @discardableResult
    func clearEffectsSelected() -> Bool {
        guard let c = targetClip(nil), !c.effects.isEmpty else { return false }
        setClipProperty({ _ = EffectEditing.clear(&$0) }, name: "エフェクトをすべて外す", clipId: c.id)
        return true
    }

    @discardableResult
    func copyEffectsSelected() -> Bool {
        guard let c = selectedClip, !c.effects.isEmpty else { return false }
        effectClipboard = c.effects
        statusText = "エフェクトをコピーしました（\(c.effects.count) 個）"
        return true
    }

    @discardableResult
    func pasteEffectsSelected() -> Bool {
        guard !effectClipboard.isEmpty, let c = targetClip(nil) else { return false }
        var probe = c
        guard EffectEditing.append(&probe, effectClipboard) else { return false }
        let list = effectClipboard
        setClipProperty({ _ = EffectEditing.append(&$0, list) }, name: "エフェクトの貼り付け", clipId: c.id)
        return true
    }

    // MARK: LUT

    /// クリップ ▸ LUT を読み込む…(開くパネル → LUT を足す/差し替える)。
    func chooseAndLoadLUT(clipId: String? = nil) {
        guard targetClip(clipId) != nil else { return }
        let target = clipId ?? selectedClipId
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "cube")].compactMap { $0 }
        panel.allowsOtherFileTypes = true
        panel.title = "LUT（.cube）を読み込む"
        let run: (NSApplication.ModalResponse) -> Void = { [weak self] resp in
            guard resp == .OK, let url = panel.url, let self else { return }
            Task { @MainActor in self.loadLUT(from: url, clipId: target) }
        }
        if let w = window { panel.beginSheetModal(for: w, completionHandler: run) } else { panel.begin(completionHandler: run) }
    }

    /// .cube を読めると確かめてから、クリップの LUT のファイルにする(Undo は 1 回。同じファイルなら何もしない)。
    @discardableResult
    func loadLUT(from url: URL, clipId: String? = nil) -> Bool {
        guard let c = targetClip(clipId) else { return false }
        do { _ = try CubeLUT.load(from: url) } catch {
            statusText = "LUT を読み込めません: \(url.lastPathComponent)（.cube の形式が正しくありません）"
            return false
        }
        var probe = c
        guard EffectEditing.setLUTPath(&probe, url.path) else { return false }
        setClipProperty({ _ = EffectEditing.setLUTPath(&$0, url.path) }, name: "LUT の読み込み: \(url.lastPathComponent)", clipId: c.id)
        return true
    }

    @discardableResult
    func applyEffectPreset(_ preset: EffectPreset) -> Bool {
        guard let c = targetClip(nil) else { return false }
        var probe = c
        guard preset.apply(to: &probe) else { return false }
        setClipProperty({ _ = preset.apply(to: &$0) }, name: preset.undoName, clipId: c.id)
        return true
    }

    // MARK: 自動ホワイトバランス

    static let autoWhiteBalanceUndoName = "自動ホワイトバランス"

    /// クリップ ▸ 自動ホワイトバランス。選んでいる画像・動画のクリップの、再生位置のコマ(エフェクトを外した絵)の平均色が
    /// 灰色になるよう、ホワイトバランスのエフェクトを足す(あれば値を直す)。測るのは背景で行い、結果を 1 回の Undo で当てる。
    /// 測っている間に編集された(クリップが消えた・ロック・書き出し中)ときは何もしない。
    func autoWhiteBalanceSelected() {
        guard let c = targetClip(nil), c.type == .image || c.type == .video,
              let mp = AutoWhiteBalance.measurementProject(for: c, in: project) else { return }
        let assets = self.assets, id = c.id
        let end = max(c.start, c.start + c.duration - 1.0 / max(1, project.fps))
        let t = min(max(currentTime, c.start), end)
        statusText = "自動ホワイトバランス: 色を測っています…"
        Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> AutoWhiteBalance.Result? in
                guard let img = Renderer(project: mp, assets: assets).renderImage(t: t) else { return nil }
                return AutoWhiteBalance.estimate(from: img)
            }.value
            guard let self, !self.isLocked, let now = self.clip(id) else { return }
            guard let result else { self.statusText = "自動ホワイトバランス: このコマの色を読めませんでした"; return }
            var probe = now
            guard AutoWhiteBalance.apply(result, to: &probe) else {
                self.statusText = "自動ホワイトバランス: すでにほぼ灰色なので、変えませんでした"
                return
            }
            self.setClipProperty({ _ = AutoWhiteBalance.apply(result, to: &$0) }, name: Self.autoWhiteBalanceUndoName, clipId: id)
            self.statusText = String(format: "自動ホワイトバランス: 色温度 %+.2f・ティント %+.2f を設定しました", result.temperature, result.tint)
        }
    }
}

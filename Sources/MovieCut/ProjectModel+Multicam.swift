import Foundation
import MovieCutCore

/// クリップ ▸ リップルトリム / マルチカメラ のモデル側。計算は Core の `ClipRippleTrim` / `Multicam`。どれも 1 回の Undo、変わらなければ何も登録しない。
extension ProjectModel {
    // MARK: リップルトリム

    func rippleBlockedReason(edge: ClipRippleTrim.Edge) -> String? {
        guard selectedClipIDs.count <= 1 else { return "クリップを 1 つ選んでください" }
        return ClipRippleTrim.blockedReason(in: project, clipId: selectedClipId, edge: edge, playhead: currentTime, allLayers: rippleTrimAllLayers)
    }

    func canRipple(edge: ClipRippleTrim.Edge) -> Bool { !isLocked && rippleBlockedReason(edge: edge) == nil }

    static let rippleUndoName = "リップルトリム"

    /// 選んでいるクリップの頭 / 尻を再生位置までトリムし、後ろを詰める。
    @discardableResult
    func rippleTrimSelectedToPlayhead(edge: ClipRippleTrim.Edge) -> Bool {
        guard !isLocked, selectedClipIDs.count <= 1, let id = selectedClipId else { return false }
        guard let p = ClipRippleTrim.trimToPlayhead(in: project, clipId: id, edge: edge, playhead: currentTime, allLayers: rippleTrimAllLayers) else {
            if ClipRippleTrim.touchesLocked(id, in: project, allLayers: rippleTrimAllLayers) { statusText = Self.lockedNotice }
            return false
        }
        return edit(Self.rippleUndoName) { $0 = p }
    }

    // MARK: マルチカメラ

    /// 再生位置で使うマルチカメラのグループ(基準の角度が再生位置を含むもの)。
    var activeMulticam: MulticamGroup? { Multicam.activeGroup(in: project, at: currentTime) }

    var canMulticamCreate: Bool { !isLocked && Multicam.candidates(in: project, ids: selectedClipIDs) != nil }

    func openMulticamCreateSheet() {
        guard canMulticamCreate else { return }
        multicamCreateIds = selectedClipIDs
        showMulticamCreateSheet = true
    }

    func openMulticamSwitchSheet() {
        guard !isLocked, !project.multicams.isEmpty else { return }
        showMulticamSwitchSheet = true
    }

    /// 音で基準(先頭の角度)との同期のずれ(クリップの頭からの秒)を測る。音が合わなかった角度は値なし。読むのは別のタスク(画面を止めない)。
    func measureMulticamLags(ids: Set<String>) async -> [String: Double?] {
        guard let cands = Multicam.candidates(in: project, ids: ids), let ref = cands.first else { return [:] }
        return await Task.detached(priority: .userInitiated) { () -> [String: Double?] in
            guard let pr = SilenceDetector.analyze(clip: ref) else { return Dictionary(uniqueKeysWithValues: cands.dropFirst().map { ($0.id, nil) }) }
            let renv = AudioSyncEditing.envelope(from: pr)
            var out: [String: Double?] = [:]
            for c in cands.dropFirst() {
                let lag: Double? = SilenceDetector.analyze(clip: c).flatMap { Multicam.localLag(reference: renv, angle: AudioSyncEditing.envelope(from: $0)) }
                out[c.id] = .some(lag)
            }
            return out
        }.value
    }

    static let multicamCreateUndoName = "マルチカメラを作る"

    /// グループを作る(結果のレイヤーを足し、基準以外の元クリップを無音にする)。1 回の Undo。
    @discardableResult
    func createMulticam(ids: Set<String>, localLags: [String: Double]) -> Bool {
        guard !isLocked else { return false }
        switch Multicam.makeGroup(in: project, ids: ids, localLags: localLags) {
        case .created(let p, _):
            let ok = edit(Self.multicamCreateUndoName) { $0 = p }
            if ok { statusText = "マルチカメラを作りました。「マルチカメラ切替…」でアングルを切り替えます" }
            return ok
        case .locked: statusText = Self.lockedNotice
        case .invalid: statusText = Multicam.selectionHint
        }
        return false
    }

    /// 再生位置から角度 `angle`(0 始まり)に切り替える。`groupId` が nil なら再生位置のグループ。1 回の Undo。変わらなければ何も登録しない。
    @discardableResult
    func multicamCut(angle: Int, groupId: String? = nil) -> Bool {
        guard !isLocked else { return false }
        let t = currentTime
        // マルチカムクリップを選んでいる、または(グループが無くて)再生位置にマルチカムクリップがあるときは、クリップのほうを切り替える
        if groupId == nil, selectedMulticamClip != nil || (Multicam.activeGroup(in: project, at: t) == nil && multicamClipTarget != nil) {
            return multicamClipCut(angle: angle, atPlayhead: true)
        }
        guard let g = groupId.flatMap({ id in project.multicams.first { $0.id == id } }) ?? Multicam.activeGroup(in: project, at: t) else {
            statusText = "再生位置にマルチカメラのグループがありません"
            return false
        }
        switch Multicam.cut(in: project, groupId: g.id, angle: angle, at: t) {
        case .cut(let p):
            let ok = edit(String(format: L10n.t("アングル%dに切り替え"), angle + 1)) { $0 = p }
            if ok { statusText = String(format: L10n.t("%.2f 秒から %@ に切り替えました"), t, g.angles[angle].name) }
            return ok
        case .unchanged: statusText = "すでにその角度です"
        case .locked: statusText = Self.lockedNotice
        case .outsideRange: statusText = "再生位置が基準のカメラの範囲の外です"
        case .noFootage: statusText = "そのカメラの映像が、この区間にありません(同期のずれを確認してください)"
        case .invalid: statusText = "切り替えられません"
        }
        return false
    }

    // MARK: マルチカムクリップ(タイムライン上の 1 クリップ。計算は Core の `Multicam` の `placeClip` / `setActiveAngle` / `setAudioAngle`)

    /// 選んでいる 1 つのクリップがマルチカムクリップならそれ。
    var selectedMulticamClip: Clip? {
        guard selectedClipIDs.count <= 1, let c = selectedClip, c.multicam != nil else { return nil }
        return c
    }

    /// 1〜9 キーなどの切り替え対象: 再生位置が選択中のマルチカムクリップの中ならそれ、そうでなければ再生位置に重なるマルチカムクリップ(上のレイヤー優先)、
    /// それも無ければ選択中のマルチカムクリップ(停止中にクリップ全体を変える)。
    var multicamClipTarget: Clip? {
        let t = currentTime
        if let s = selectedMulticamClip, t >= s.start, t < s.start + s.duration { return s }
        return Multicam.clip(at: t, in: project) ?? selectedMulticamClip
    }

    /// メニュー・キーの対象にできるアングル数(グループがあればグループ、なければマルチカムクリップ)。
    var multicamCutAngleCount: Int {
        if selectedMulticamClip == nil, let g = activeMulticam { return g.angles.count }
        return multicamClipTarget.map { Multicam.angleCount($0) } ?? 0
    }

    static let multicamClipCreateUndoName = "マルチカムクリップを作る"

    /// 選んだ映像クリップを 1 つのマルチカムクリップにして置く(基準のクリップの位置に。ほかの元クリップは外れてアングルになる)。1 回の Undo。
    @discardableResult
    func createMulticamClip(ids: Set<String>, localLags: [String: Double]) -> Bool {
        guard !isLocked else { return false }
        switch Multicam.placeClip(in: project, ids: ids, localLags: localLags) {
        case .placed(let p, let id):
            let ok = edit(Self.multicamClipCreateUndoName) { $0 = p }
            if ok {
                selectedClipId = id
                statusText = "マルチカムクリップを置きました。インスペクタの「マルチカム」か 1〜9 キーでアングルを切り替えます"
            }
            return ok
        case .locked: statusText = Self.lockedNotice
        case .invalid: statusText = Multicam.selectionHint
        }
        return false
    }

    /// マルチカムクリップの有効アングルを切り替える。`atPlayhead` が true なら再生位置で分割して右側だけ(再生位置がクリップの外・端ならクリップ全体)。
    /// 対象は選択中のマルチカムクリップ、なければ再生位置のもの。1 回の Undo。変わらなければ何も登録しない。
    @discardableResult
    func multicamClipCut(angle: Int, atPlayhead: Bool) -> Bool {
        guard !isLocked, let c = multicamClipTarget else { return false }
        switch Multicam.setActiveAngle(in: project, clipId: c.id, angle: angle, at: atPlayhead ? currentTime : nil) {
        case .cut(let p):
            let name = c.multicam?.angles.indices.contains(angle) == true ? c.multicam!.angles[angle].name : "\(angle + 1)"
            let ok = edit(String(format: L10n.t("アングル%dに切り替え"), angle + 1)) { $0 = p }
            if ok { statusText = String(format: L10n.t("%@ に切り替えました"), name) }
            return ok
        case .unchanged: statusText = "すでにその角度です"
        case .locked: statusText = Self.lockedNotice
        case .noFootage: statusText = "そのカメラの映像が、この区間にありません(同期のずれを確認してください)"
        case .invalid: statusText = "切り替えられません"
        }
        return false
    }

    /// 選択中のマルチカムクリップの音声アングルを変える(映像は変えない)。1 回の Undo。
    @discardableResult
    func setMulticamAudioAngle(_ angle: Int) -> Bool {
        guard !isLocked, let p = Multicam.setAudioAngle(in: project, ids: selectedClipIDs, angle: angle) else { return false }
        return edit("音声アングルを変更") { $0 = p }
    }
}

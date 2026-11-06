import Foundation
import MovieCutCore

/// 立ち絵素材(`Project.tachies`)・立ち絵クリップ・ボイスの字幕の文の編集。
/// どれも「1 回 = Undo 1 回」で、何も変わらない編集は履歴に載せない(`edit` が前後の `Project` を比べる)。
/// 画面(インスペクタ・素材の一覧・プレビューのドラッグ)からはこれらを呼ぶ。ロックされたレイヤーのクリップに触れる編集は断る。
extension ProjectModel {
    func tachie(_ id: String?) -> Tachie? { project.tachie(id) }

    /// 立ち絵素材を足す。足したら id を返す(同じ id があるときは nil)。
    @discardableResult
    func addTachie(_ t: Tachie, undoName: String = "立ち絵素材の追加") -> String? {
        guard !isLocked, !project.tachies.contains(where: { $0.id == t.id }) else { return nil }
        guard edit(undoName, { $0 = TachieEditing.add($0, tachie: t) }) else { return nil }
        return t.id
    }

    func renameTachie(id: String, to name: String) {
        guard !isLocked else { return }
        edit("立ち絵素材の名前の変更") { $0 = TachieEditing.rename($0, id: id, to: name) }
    }

    /// 素材を消す(使っている立ち絵クリップも一緒に消える)。
    func removeTachie(id: String) {
        guard !isLocked else { return }
        edit("立ち絵素材の削除") { $0 = TachieEditing.remove($0, id: id) }
    }

    /// パーツの位置の補正(基準キャンバスの画素単位。ゼロで外す)。
    func setTachiePartOffset(tachieId: String, path: String, offset: PartOffset) {
        guard !isLocked else { return }
        edit("立ち絵パーツの位置") { $0 = TachieEditing.setPartOffset($0, tachieId: tachieId, path: path, offset: offset) }
    }

    /// 大きさが違うパーツの位置を自動で合わせる(手で決めた補正は残す)。
    func autoAlignTachieParts(tachieId: String, base: (w: Int, h: Int)) {
        guard !isLocked else { return }
        edit("立ち絵パーツの位置合わせ") { $0 = TachieEditing.autoAlignParts($0, tachieId: tachieId, base: base) }
    }

    /// 立ち絵クリップを足して選ぶ(トラックターゲットのレイヤーが空いていればそこ、無ければいちばん上のレイヤー。重なるなら新しいレイヤー)。素材が無い・長さが 0 以下なら nil。
    @discardableResult
    func addTachieClip(tachieId: String, start: Double? = nil, duration: Double = 5, drive: MouthDrive = .all, followsProjectEnd: Bool = false) -> String? {
        guard !isLocked, let c = TachieEditing.makeClip(project, tachieId: tachieId, start: start ?? currentTime, duration: duration, drive: drive, followsProjectEnd: followsProjectEnd) else { return nil }
        guard edit("立ち絵クリップの追加", { ClipEditing.appendToTopLayer(c, in: &$0, useTarget: true) }) else { return nil }
        selectedClipId = c.id
        return c.id
    }

    /// 立ち絵クリップの「口を動かす声」(すべての声 / キャラの声 / 声クリップ / 動かさない)。
    func setTachieMouthDrive(clipId: String, drive: MouthDrive) {
        guard !isLocked else { return }
        edit("口を動かす声の変更") { $0 = TachieEditing.setMouthDrive($0, clipId: clipId, drive: drive) }
    }

    /// 立ち絵クリップの再生位置の声の表情を決める(nil = 通常に戻す)。展開した行の表情の切り替えの追加・削除。Undo 1 回。
    func setTachieExpressionAtPlayhead(clipId: String, tag: String?) {
        guard !isLocked else { return }
        let t = currentTime
        if edit(tag == nil ? "表情の切り替えを外す" : "表情の切り替えを足す", { $0 = TachieEditing.setExpression($0, clipId: clipId, at: t, tag: tag) }) {
            statusText = tag == nil ? "再生位置の声の表情を通常に戻しました" : "再生位置の声の表情を「\(tag ?? "")」にしました"
        } else if TachieEditing.driverVoice(project, clip: project.allClips.first { $0.id == clipId } ?? Clip(), at: t) == nil {
            statusText = "再生位置に、この立ち絵が連動する声がありません"
        }
    }

    /// 立ち絵クリップの素材を差し替える。
    func setClipTachie(clipId: String, tachieId: String) {
        guard !isLocked else { return }
        edit("立ち絵クリップの素材の変更") { $0 = TachieEditing.setClipTachie($0, clipId: clipId, tachieId: tachieId) }
    }

    /// ボイスの字幕の文。nil = 読み上げる文と同じ、空文字 = 字幕なし。
    func setVoiceSubtitleText(clipId: String, text: String?) {
        guard !isLocked else { return }
        edit("字幕の文の変更") { $0 = TachieEditing.setSubtitleText($0, clipId: clipId, text: text) }
    }
}

extension ProjectModel {
    /// 話している間に上下へ揺れる(素材の設定)。
    func setTachieBounce(tachieId: String, _ on: Bool) {
        guard !isLocked else { return }
        edit("バウンスの切り替え") { $0 = TachieEditing.update($0, id: tachieId) { $0.bounce = on ? true : nil } }
    }

    /// 立ち絵クリップを、連動する声の範囲に合わせる(Undo 1 回)。声が無い・他のクリップと重なる・もう合っているときは何もしない。
    func fitTachieClipToVoice(clipId: String? = nil) {
        guard !isLocked, let id = clipId ?? selectedClipId else { return }
        let before = project
        guard edit("立ち絵クリップを声の長さに合わせる", { $0 = TachieEditing.fitToVoice($0, clipId: id) }) else {
            if let c = clip(id), c.type == .tachie {
                statusText = TachieEditing.voiceSpan(before, clip: c) == nil ? "連動する声がありません" : "声の長さに合わせられません(他のクリップと重なる、またはもう合っています)"
            }
            return
        }
        statusText = "立ち絵クリップを声の長さに合わせました"
    }

    /// 選んでいるクリップが立ち絵クリップか(メニューの有効条件)。
    var selectedIsTachie: Bool { selectedClip?.type == .tachie }

    /// 声の長さに合わせられるか(立ち絵クリップを選んでいて、連動する声がある)。
    var canFitTachieToVoice: Bool {
        guard let c = selectedClip, c.type == .tachie else { return false }
        return TachieEditing.voiceSpan(project, clip: c) != nil
    }
}

extension ProjectModel {
    /// クリップ ▸ 立ち絵を追加…(シートを開く)。
    func openAddTachie() {
        guard !isLocked else { return }
        showTachieSheet = true
    }

    /// シートで選んだ素材を再生位置に置き、シートを閉じる。
    /// `followsEnd` のとき、クリップはプロジェクトの終わりまで(無ければ 5 秒)で、あとから声を足しても終わりに合わせ続ける。
    func placeTachie(_ id: String, followsEnd: Bool = false) {
        let end = project.endTime
        let d = followsEnd && end > currentTime + 0.05 ? end - currentTime : 5
        if addTachieClip(tachieId: id, duration: d, followsProjectEnd: followsEnd) != nil { showTachieSheet = false }
    }

    /// 立ち絵クリップの「プロジェクトの長さに合わせる」を切り替える(オンにすると、その場で終わりを合わせる)。Undo 1 回。
    func setTachieFollowsProjectEnd(clipId: String, _ on: Bool) {
        guard !isLocked else { return }
        edit(on ? "立ち絵クリップをプロジェクトの長さに合わせる" : "プロジェクトの長さに合わせるをやめる") { p in
            for ti in p.tracks.indices {
                guard let ci = p.tracks[ti].clips.firstIndex(where: { $0.id == clipId }), p.tracks[ti].clips[ci].type == .tachie else { continue }
                p.tracks[ti].clips[ci].followsProjectEnd = on ? true : nil
            }
        }
    }
}

extension ProjectModel {
    /// タイムラインで立ち絵クリップの中身(表情の切り替わり)を開閉する。表示だけの状態で、保存も Undo もしない。
    func toggleTachieExpanded(_ clipId: String) {
        if expandedTachieClipIds.contains(clipId) { expandedTachieClipIds.remove(clipId) } else { expandedTachieClipIds.insert(clipId) }
    }
}

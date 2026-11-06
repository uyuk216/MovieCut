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

    /// 立ち絵クリップを足して選ぶ(いちばん上のレイヤー。重なるなら新しいレイヤー)。素材が無い・長さが 0 以下なら nil。
    @discardableResult
    func addTachieClip(tachieId: String, start: Double? = nil, duration: Double = 5, drive: MouthDrive = .all) -> String? {
        guard !isLocked, let c = TachieEditing.makeClip(project, tachieId: tachieId, start: start ?? currentTime, duration: duration, drive: drive) else { return nil }
        guard edit("立ち絵クリップの追加", { ClipEditing.appendToTopLayer(c, in: &$0) }) else { return nil }
        selectedClipId = c.id
        return c.id
    }

    /// 立ち絵クリップの「口を動かす声」(すべての声 / キャラの声 / 声クリップ / 動かさない)。
    func setTachieMouthDrive(clipId: String, drive: MouthDrive) {
        guard !isLocked else { return }
        edit("口を動かす声の変更") { $0 = TachieEditing.setMouthDrive($0, clipId: clipId, drive: drive) }
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

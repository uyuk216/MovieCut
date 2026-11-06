import Foundation
import MovieCutCore

/// 立ち絵パーツの先読み。タイムラインに立ち絵クリップ(パーツ式)があるとき、書類を開いたとき・立ち絵を足したり変えたとき・再生の前に、
/// 口・まばたき・表情の主な状態のパーツを背景のキューで読んで合成しておく(初回に 25〜40ms かかっていた分を、見えるときまでに終える)。
/// 同じ内容(素材・高さ)は 1 回だけ。編集のたびに予約するが、指紋が変わらなければ何もしない。
extension ProjectModel {
    /// 先読みの内容の指紋(立ち絵クリップが使うパーツ式の素材・揃え方・位置の補正・描く高さ)。何も無ければ nil。
    static func prewarmSignature(_ p: Project) -> Int? {
        var h = Hasher()
        var any = false
        let H = Double(p.height)
        for tr in p.tracks where !tr.isHidden {
            for c in tr.clips where c.type == .tachie {
                guard let id = c.tachieId, let rig = p.tachie(id)?.rig, rig.hasParts else { continue }
                any = true
                h.combine(id); h.combine(rig.slots.map { [$0.name] + $0.parts }); h.combine(rig.slots.map(\.active))
                h.combine(rig.alignmentOrDefault); h.combine((rig.partOffsets ?? [:]).map { "\($0.key)\($0.value.dx),\($0.value.dy)" }.sorted())
                h.combine(Int((H * 0.6 * (c.scale ?? 1)).rounded()))
            }
        }
        return any ? h.finalize() : nil
    }

    /// 主スレッドで 1 回にまとめて予約する(編集が続いても、予約は 1 回)。
    func schedulePrewarm() {
        guard !prewarmScheduled else { return }
        prewarmScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.prewarmScheduled = false
            self.prewarmTachies()
        }
    }

    /// 先読みを始める(背景のキュー)。指紋が前回と同じ・立ち絵が無いときは何もしない。
    func prewarmTachies() {
        let sig = Self.prewarmSignature(project)
        guard sig != prewarmSignature else { return }
        prewarmSignature = sig
        guard sig != nil else { return }
        let p = project
        let a = assets
        DispatchQueue.global(qos: .utility).async { _ = a.prewarmTachies(project: p) }
    }
}

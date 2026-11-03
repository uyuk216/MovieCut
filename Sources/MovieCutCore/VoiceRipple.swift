import Foundation

/// 合成音声を作り直して尺が変わったとき、同じレイヤーの後ろのクリップを変わった分だけずらして、すき間・重なりを作らない(候補 31)。
/// 純粋な計算。ずらすのは「尺が変わったボイスクリップの終わり(作り直す前)以降に始まる、同じレイヤーのクリップ」。
/// 変わったクリップが複数あるときは、前にあるものの変化量の合計だけ後ろをずらす(時刻順の累積)。
/// ロックされたレイヤー・ロックされたクリップはずらさない。0 秒より前には動かさない。他のレイヤーには触らない。
public enum VoiceRipple {
    public struct Result: Equatable {
        public var project: Project
        /// ずらしたクリップの数(尺が変わったクリップ自身は含めない)。
        public var shifted: Int
        /// ロックのために、ずらせなかったクリップの数。
        public var skippedLocked: Int
    }

    /// 尺の変化を、新しいプロジェクトの `updated`(尺が変わった後)に反映して後ろをずらす。
    /// - Parameters:
    ///   - old: 作り直す前のプロジェクト(元の頭・尺を調べる)。
    ///   - new: 作り直したクリップの尺が反映されたプロジェクト。
    ///   - changedIds: 作り直したボイスクリップの id。
    public static func apply(old: Project, new: Project, changedIds: Set<String>) -> Result {
        var p = new
        var shifted = 0, skipped = 0
        for oldTrack in old.tracks {
            guard let ni = p.tracks.firstIndex(where: { $0.id == oldTrack.id }) else { continue }
            // このレイヤーで尺が変わったクリップ(元の終わりと変化量)
            var deltas: [(oldEnd: Double, delta: Double)] = []
            for c in oldTrack.clips where changedIds.contains(c.id) {
                guard let n = p.tracks[ni].clips.first(where: { $0.id == c.id }) else { continue }
                let d = n.duration - c.duration
                if abs(d) > 1e-6 { deltas.append((c.start + c.duration, d)) }
            }
            guard !deltas.isEmpty else { continue }
            for c in oldTrack.clips {
                // 元の頭が、変わったクリップの元の終わり以降なら、その変化量を足す(前にあるものの累積)
                let shift = deltas.filter { $0.oldEnd <= c.start + ClipEditing.timeEpsilon }
                    .reduce(0) { $0 + $1.delta }
                guard abs(shift) > 1e-9, let ci = p.tracks[ni].clips.firstIndex(where: { $0.id == c.id }) else { continue }
                if oldTrack.isLocked || c.isClipLocked { skipped += 1; continue }
                let target = max(0, c.start + shift)
                guard abs(target - p.tracks[ni].clips[ci].start) > 1e-9 else { continue }
                p.tracks[ni].clips[ci].start = target
                if !changedIds.contains(c.id) { shifted += 1 }
            }
        }
        return Result(project: p, shifted: shifted, skippedLocked: skipped)
    }
}

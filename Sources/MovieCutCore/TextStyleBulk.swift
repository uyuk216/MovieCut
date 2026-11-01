import Foundation

/// 文字スタイルの一括適用(純粋な計算)。保存したスタイル(`TextLook`)を、文字クリップにまとめて当てる。
/// 対象は文字クリップだけ(セリフ・画像などは変えない)。ロックされたレイヤーは変えない(数だけ `lockedSkipped` に入れる)。
/// `scope` が nil なら全部、あれば選んだ id の文字クリップだけ。変わらないクリップは `changedIds` に入れない。
public enum TextStyleBulk {
    public struct Result {
        public var project: Project
        public var changedIds: [String]
        public var lockedSkipped: Int
    }

    public static func apply(_ look: TextLook, to project: Project, scope: Set<String>? = nil) -> Result {
        var p = project
        var ids: [String] = []
        var locked = 0
        for ti in project.tracks.indices {
            for ci in project.tracks[ti].clips.indices {
                let c = project.tracks[ti].clips[ci]
                guard c.type == .text, scope?.contains(c.id) ?? true else { continue }
                if project.tracks[ti].isLocked { locked += 1; continue }
                var n = c
                guard look.apply(to: &n) else { continue }
                p.tracks[ti].clips[ci] = n
                ids.append(c.id)
            }
        }
        return Result(project: p, changedIds: ids, lockedSkipped: locked)
    }
}

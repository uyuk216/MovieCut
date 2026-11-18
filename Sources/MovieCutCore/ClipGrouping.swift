import Foundation

// MARK: - クリップのグループ化(土台)
//
// 複数のクリップに同じグループ ID(`Clip.group`)を持たせ、「まとめて扱う」ための純粋な計算。
// YMM4 のグループ制御相当。画面の操作(選択の拡張・ドラッグ追随・メニュー)はアプリ側
// (`ProjectModel+Grouping`)が持ち、ここはファイル形式に依存しない計算だけを持つ。
// - グループは ID の文字列で表す(名前は持たない。表示名が要るようになったら別に足す)。
// - 複合クリップ(ネスト)とは別物: グループはレイヤーをまたいでゆるく束ねるだけ。中身を
//   1 枚の絵として合成したいときは、グループのメンバーを複合クリップへ変換する
//   (YMM4 の「画像を合成」は複合化が MovieCut の相当機能。二重の合成機構は作らない)。
// - 有効/無効は `Clip.disabled`(クリップ単体の無効化)をグループ全員分まとめて切り替える。

public enum ClipGrouping {
    /// プロジェクト内にあるグループ ID(出てくる順・重複なし)。
    public static func groupIds(in project: Project) -> [String] {
        var out: [String] = []
        for c in project.allClips { if let g = c.group, !out.contains(g) { out.append(g) } }
        return out
    }

    /// そのグループのクリップ(レイヤー順)。
    public static func members(of group: String, in project: Project) -> [Clip] {
        project.allClips.filter { $0.group == group }
    }

    /// 選択したクリップの集合に、同じグループのクリップを全部足す(グループのどれか 1 つを選んだら全員を選ぶ、の土台)。
    public static func expand(_ ids: Set<String>, in project: Project) -> Set<String> {
        let groups = Set(project.allClips.filter { ids.contains($0.id) }.compactMap { $0.group })
        guard !groups.isEmpty else { return ids }
        var out = ids
        for c in project.allClips where c.group.map({ groups.contains($0) }) ?? false { out.insert(c.id) }
        return out
    }

    /// まだ使われていない新しいグループ ID("group1", "group2", …のうち一番小さい空き)。
    public static func nextId(in project: Project) -> String {
        let used = Set(groupIds(in: project))
        var n = 1
        while used.contains("group\(n)") { n += 1 }
        return "group\(n)"
    }

    /// グループの付け外し。group が nil なら解除。対象が無ければ何もしない。
    public static func assign(_ group: String?, to ids: Set<String>, in project: inout Project) {
        for ti in project.tracks.indices {
            for ci in project.tracks[ti].clips.indices where ids.contains(project.tracks[ti].clips[ci].id) {
                project.tracks[ti].clips[ci].group = group
            }
        }
    }

    /// グループ全員を同じだけ時刻方向へずらす。頭が 0 より前へ出ないように丸める。ずらした量を返す。
    @discardableResult
    public static func shift(group: String, by dt: Double, in project: inout Project) -> Double {
        let ms = members(of: group, in: project)
        guard !ms.isEmpty else { return 0 }
        let applied = max(dt, -(ms.map { $0.start }.min() ?? 0))
        guard applied != 0 else { return 0 }
        let ids = Set(ms.map { $0.id })
        for ti in project.tracks.indices {
            for ci in project.tracks[ti].clips.indices where ids.contains(project.tracks[ti].clips[ci].id) {
                project.tracks[ti].clips[ci].start += applied
            }
        }
        return applied
    }
    // MARK: 有効 / 無効(グループ全員まとめて)

    /// そのグループの全員が無効化されているか(メンバーが居なければ false)。
    public static func allDisabled(_ group: String, in project: Project) -> Bool {
        let ms = members(of: group, in: project)
        return !ms.isEmpty && ms.allSatisfy { $0.isDisabled }
    }

    /// グループ全員の無効化を揃えて切り替える。変わった数を返す。対象が無ければ何もしない。
    @discardableResult
    public static func setDisabled(_ group: String, on: Bool, in project: inout Project) -> Int {
        let ids = Set(members(of: group, in: project).map { $0.id })
        guard !ids.isEmpty else { return 0 }
        var changed = 0
        for ti in project.tracks.indices {
            for ci in project.tracks[ti].clips.indices where ids.contains(project.tracks[ti].clips[ci].id) {
                if project.tracks[ti].clips[ci].isDisabled != on {
                    project.tracks[ti].clips[ci].disabled = on ? true : nil
                    project.tracks[ti].clips[ci].extra["disabled"] = nil
                    changed += 1
                }
            }
        }
        return changed
    }

    /// 任意のクリップ集合の無効化を揃えて切り替える(グループのメンバー集合にも使う)。変わった数を返す。
    @discardableResult
    public static func setDisabled(ids: Set<String>, on: Bool, in project: inout Project) -> Int {
        var changed = 0
        for ti in project.tracks.indices {
            for ci in project.tracks[ti].clips.indices where ids.contains(project.tracks[ti].clips[ci].id) {
                if project.tracks[ti].clips[ci].isDisabled != on {
                    project.tracks[ti].clips[ci].disabled = on ? true : nil
                    project.tracks[ti].clips[ci].extra["disabled"] = nil
                    changed += 1
                }
            }
        }
        return changed
    }

    // MARK: 複製・貼り付けのグループ引き継ぎ

    /// 貼り付け・複数複製で新しく生まれたクリップ(newIds)のグループを、貼り付け先に元からある
    /// グループと混ざらないように振り直す。コピー同士は同じ新しいグループに残るので、
    /// グループごと複製すれば複製側もまとめて動かせる。元からあるグループと重ならない ID はそのまま。
    /// 振り直したグループの対応(旧 ID → 新 ID)を返す。
    @discardableResult
    public static func isolateCopiedGroups(newIds: Set<String>, in project: inout Project) -> [String: String] {
        let existing = Set(project.allClips.filter { !newIds.contains($0.id) }.compactMap { $0.group })
        let copied = Set(project.allClips.filter { newIds.contains($0.id) }.compactMap { $0.group })
        let colliding = copied.intersection(existing)
        guard !colliding.isEmpty else { return [:] }
        var map: [String: String] = [:]
        for g in colliding.sorted() {
            let fresh = nextId(in: project)
            map[g] = fresh
            for ti in project.tracks.indices {
                for ci in project.tracks[ti].clips.indices
                where newIds.contains(project.tracks[ti].clips[ci].id) && project.tracks[ti].clips[ci].group == g {
                    project.tracks[ti].clips[ci].group = fresh
                }
            }
        }
        return map
    }
}

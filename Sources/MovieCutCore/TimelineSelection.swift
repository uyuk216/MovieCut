import Foundation

/// A6: 複数選択の純粋な計算(クリックの修飾キー・ラバーバンド・全選択)。
/// 選択は「集合 + 主(primary)」。主はプロパティ欄が見るクリップで、従来の単一選択 `selectedClipId` に当たる。
public struct ClipSelection: Equatable, Sendable {
    public var ids: Set<String>
    public var primary: String?

    public init(ids: Set<String> = [], primary: String? = nil) {
        self.ids = ids
        self.primary = primary
    }

    public static let empty = ClipSelection()
    public static func only(_ id: String) -> ClipSelection { ClipSelection(ids: [id], primary: id) }
    public var count: Int { ids.count }
}

public enum SelectionModifier: Sendable { case none, shift, command }

public enum TimelineSelection {
    /// クリップ(`id`)または何もない所(nil)を押したときの新しい選択。
    /// - 修飾なし: そのクリップだけ(何もない所なら空)。
    /// - ⌘: そのクリップを入れる / 外す(トグル)。何もない所では変えない。
    /// - ⇧: 主のクリップと同じレイヤーなら、間のクリップをまとめて足す。別のレイヤーならそのクリップだけ足す。何もない所では変えない。
    public static func click(_ s: ClipSelection, on id: String?, modifier: SelectionModifier, in project: Project) -> ClipSelection {
        guard let id else { return modifier == .none ? .empty : s }
        switch modifier {
        case .none:
            return .only(id)
        case .command:
            if s.ids.contains(id) {
                var ids = s.ids
                ids.remove(id)
                let primary = s.primary == id ? fallbackPrimary(ids, in: project) : s.primary
                return ClipSelection(ids: ids, primary: primary)
            }
            var ids = s.ids
            ids.insert(id)
            return ClipSelection(ids: ids, primary: id)
        case .shift:
            var ids = s.ids
            ids.insert(id)
            if let p = s.primary, let a = ClipEditing.locate(p, in: project), let b = ClipEditing.locate(id, in: project), a.track == b.track {
                // 配列の並びは移動などで時間順とずれることがある。範囲は開始時刻で決める
                let clips = project.tracks[a.track].clips
                let t0 = min(clips[a.index].start, clips[b.index].start), t1 = max(clips[a.index].start, clips[b.index].start)
                for c in clips where c.start >= t0 && c.start <= t1 { ids.insert(c.id) }
            }
            return ClipSelection(ids: ids, primary: id)
        }
    }

    /// 残った選択の中で主にするクリップ(開始の一番早いもの)。無ければ nil。
    public static func fallbackPrimary(_ ids: Set<String>, in project: Project) -> String? {
        ClipEditing.clipsByStart(project).first { ids.contains($0.id) }?.id
    }

    /// すべてのクリップ(主は開始の一番早いもの)。
    public static func selectAll(in project: Project) -> ClipSelection {
        let all = Set(project.allClips.map(\.id))
        return ClipSelection(ids: all, primary: fallbackPrimary(all, in: project))
    }

    /// 時間の範囲と行の範囲に(少しでも)かかるクリップ。長方形の当たり判定(ビューが座標を時間と行に直して呼ぶ)。
    public static func clips(in project: Project, timeRange: ClosedRange<Double>, rows: ClosedRange<Int>) -> [String] {
        var out: [String] = []
        for ti in rows where project.tracks.indices.contains(ti) {
            for c in project.tracks[ti].clips {
                let end = c.start + c.duration
                // 長さ 0 のクリップは、範囲の中にあれば当たり
                let hit = c.duration > 0 ? (c.start <= timeRange.upperBound && end >= timeRange.lowerBound) : timeRange.contains(c.start)
                if hit { out.append(c.id) }
            }
        }
        return out
    }

    /// ラバーバンドの結果。`additive`(⇧/⌘)なら、押す前の選択に足す。
    public static func rubberBand(base: ClipSelection, hits: [String], additive: Bool, in project: Project) -> ClipSelection {
        var ids = additive ? base.ids : []
        for h in hits { ids.insert(h) }
        guard !ids.isEmpty else { return .empty }
        // 主: 足す前の主が残っていればそれ、無ければ当たった中で開始の一番早いもの
        if additive, let p = base.primary, ids.contains(p) { return ClipSelection(ids: ids, primary: p) }
        return ClipSelection(ids: ids, primary: fallbackPrimary(ids, in: project))
    }

    /// プロジェクトに無くなったクリップを選択から外す。
    public static func pruned(_ s: ClipSelection, in project: Project) -> ClipSelection {
        let alive = Set(project.allClips.map(\.id))
        let ids = s.ids.intersection(alive)
        if ids == s.ids { return s }
        let primary = s.primary.flatMap { ids.contains($0) ? $0 : nil } ?? fallbackPrimary(ids, in: project)
        return ClipSelection(ids: ids, primary: primary)
    }
}

// MARK: - 複数クリップの編集

extension ClipEditing {
    /// 選択したクリップをまとめて消す。1 つも消せなければ nil。
    public static func delete(in project: Project, clipIds: Set<String>) -> Project? {
        var p = project
        var removed = false
        for ti in p.tracks.indices {
            let before = p.tracks[ti].clips.count
            p.tracks[ti].clips.removeAll { clipIds.contains($0.id) }
            if p.tracks[ti].clips.count != before { removed = true }
        }
        return removed ? p : nil
    }

    /// すき間を詰めてまとめて消す: 後ろのクリップから順に 1 つずつ詰める(先に消した分で、手前のクリップの場所は変わらない)。
    /// 同じレイヤーの連続した複数のクリップを消すと、その合計の長さだけ後ろが詰まる。
    public static func rippleDelete(in project: Project, clipIds: Set<String>) -> Project? {
        var p = project
        let ordered = clipsByStart(project).filter { clipIds.contains($0.id) }.reversed()
        var any = false
        for c in ordered {
            if let r = rippleDelete(in: p, clipId: c.id) { p = r; any = true }
        }
        return any ? p : nil
    }

    /// 複数クリップのドラッグ移動。主のクリップを `move` と同じ規則(吸着つき)で動かし、その結果の動き量(秒・レイヤー数)を
    /// 全員に同じだけ当てる(相対位置は保たれる)。頭が 0 未満になるクリップがあれば、全体の動きをそこで止める。
    /// レイヤーは端で止まる。行き先がロックされたレイヤーのクリップは、元のレイヤーのまま時刻だけ動く。
    /// ロックされたレイヤーのクリップは動かさない。重なり(同じレイヤーの時間の重なり)は禁止しない = 単独のドラッグと同じ(後ろの配列順が手前に描かれる)。
    public static func moveMany(in project: Project, clipIds: Set<String>, primaryId: String, deltaT: Double, targetTrackIndex: Int?,
                                playhead: Double, pps: Double, snapEnabled: Bool) -> Result {
        let ids = LayerEditing.editableIds(clipIds, in: project)
        guard ids.contains(primaryId), let ploc = locate(primaryId, in: project) else { return Result(project: project, guides: []) }
        // 主の動き量(吸着つき)。同時に動くクリップは吸着の候補から外す(自分の仲間に吸い付かない)
        var base = project
        for ti in base.tracks.indices {
            // 仲間の頭と終わりを吸着の候補に含めないよう、いったん取り除いた写しで計算する
            base.tracks[ti].clips.removeAll { ids.contains($0.id) && $0.id != primaryId }
        }
        let single = move(in: base, clipId: primaryId, deltaT: deltaT, targetTrackIndex: nil, playhead: playhead, pps: pps, snapEnabled: snapEnabled)
        let primary = project.tracks[ploc.track].clips[ploc.index]
        let newStart = single.project.allClips.first { $0.id == primaryId }?.start ?? primary.start
        var dt = newStart - primary.start
        let minStart = ids.compactMap { id in project.allClips.first { $0.id == id }?.start }.min() ?? 0
        dt = max(dt, -minStart)
        // レイヤーの移動量
        var dTrack = 0
        if let to = targetTrackIndex, project.tracks.indices.contains(to) { dTrack = to - ploc.track }
        var p = project
        // 動かすクリップを取り出す(配列の順は保つ)
        var moving: [(clip: Clip, track: Int)] = []
        for ti in p.tracks.indices {
            for c in p.tracks[ti].clips where ids.contains(c.id) { moving.append((c, ti)) }
            p.tracks[ti].clips.removeAll { ids.contains($0.id) }
        }
        for var m in moving {
            m.clip.start = max(0, m.clip.start + dt)
            var to = m.track
            let want = min(max(0, m.track + dTrack), p.tracks.count - 1)
            if want != m.track, !p.tracks[want].isLocked { to = want }
            p.tracks[to].clips.append(m.clip)
        }
        let guides = dt == 0 ? [] : single.guides
        return Result(project: p, guides: guides)
    }

    /// 複数クリップの複製: 選択の全体の終わりの時刻に、同じレイヤー・同じ相対位置で置く(貼り付けと同じ規則)。新しい id を返す。
    public static func duplicate(in project: Project, clipIds: Set<String>) -> (project: Project, newIds: [String])? {
        // 読むだけなので、ロックされたレイヤーのクリップも複製元にできる
        guard let clip = ClipClipboard.make(from: project, clipIds: clipIds) else { return nil }
        let end = clip.items.map { $0.clip.start + $0.clip.duration }.max() ?? 0
        guard let r = paste(clip, in: project, at: end, targetTrack: nil) else { return nil }
        return (r.project, r.newIds)
    }

    // MARK: 貼り付け

    public struct PasteResult: Equatable {
        public var project: Project
        public var newIds: [String]
        /// ロックされたレイヤーに当たって貼らなかった数。
        public var skipped: Int
    }

    /// 貼り付け: 内容の一番早い頭を `time` に合わせ、相対位置を保つ。
    /// レイヤー: `targetTrack` があれば、内容の一番上のレイヤーをそこへ置き、相対的な段差を保つ(足りなければ末尾にレイヤーを足す)。
    /// nil なら元のレイヤー(番号が無ければ足す)。行き先がロックされたレイヤーのクリップは貼らない(skipped に数える)。
    /// 新しい id。1 つも貼れなければ nil。
    public static func paste(_ clip: ClipClipboard, in project: Project, at time: Double, targetTrack: Int?) -> PasteResult? {
        guard !clip.items.isEmpty else { return nil }
        let minStart = clip.items.map { $0.clip.start }.min() ?? 0
        let minTrack = clip.items.map { $0.track }.min() ?? 0
        let dt = max(0, time) - minStart
        var p = project
        // 参照先の定義が行き先に無ければ足す(同じ id があれば行き先の定義を優先)
        for s in clip.scenes where !p.scenes.contains(where: { $0.id == s.id }) { p.scenes.append(s) }
        for t in clip.tachies where !p.tachies.contains(where: { $0.id == t.id }) { p.tachies.append(t) }
        for ch in clip.characters where !p.characters.contains(where: { $0.id == ch.id }) { p.characters.append(ch) }
        var ids: [String] = []
        var skipped = 0
        for item in clip.items {
            // 外から来た JSON のレイヤー番号は信用しない: 差が溢れたり、巨大な番号でレイヤーを際限なく作ったりしないよう丸める
            let (diff, overflow) = item.track.subtractingReportingOverflow(minTrack)
            let rel = overflow ? ClipClipboard.maxPasteTrack : min(max(diff, 0), ClipClipboard.maxPasteTrack)
            var want = targetTrack.map { min(max($0, 0), ClipClipboard.maxPasteTrack) + rel } ?? min(max(item.track, 0), ClipClipboard.maxPasteTrack)
            want = max(0, want)
            while p.tracks.count <= want { p.tracks.append(Track(name: "レイヤー\(p.tracks.count + 1)")) }
            if p.tracks[want].isLocked { skipped += 1; continue }
            let c0 = CompoundEditing.freshIds(item.clip)   // 複合の中の子にも新しい id
            var c = c0
            c.start = max(0, c.start + dt)
            // 同じレイヤーのクリップと重なるなら、次の空きレイヤー(ロック除く)へ。無ければ末尾に足す
            func overlaps(_ ti: Int) -> Bool {
                p.tracks[ti].clips.contains { !($0.start >= c.start + c.duration || $0.start + $0.duration <= c.start) }
            }
            if overlaps(want) {
                var w = want + 1
                while true {
                    if w >= p.tracks.count { p.tracks.append(Track(name: "レイヤー\(p.tracks.count + 1)")); break }
                    if !p.tracks[w].isLocked && !overlaps(w) { break }
                    w += 1
                }
                want = w
            }
            p.tracks[want].clips.append(c)
            ids.append(c.id)
        }
        // 1 つも貼れなかったときは、足したレイヤーも含めて何も変えない
        guard !ids.isEmpty else { return nil }
        // グループ: 貼ったコピーが貼り付け先の既存グループと混ざらないよう、重なる ID は新しいグループへ振り直す
        ClipGrouping.isolateCopiedGroups(newIds: Set(ids), in: &p)
        return PasteResult(project: p, newIds: ids, skipped: skipped)
    }
}

// MARK: - クリップボード

/// コピーしたクリップの入れ物(アプリ内と、一般のペーストボードに JSON で書く)。
public struct ClipClipboard: Equatable {
    public struct Item: Codable, Equatable {
        /// コピー元のレイヤー番号
        public var track: Int
        public var clip: Clip
    }
    public var version = 1
    public var items: [Item]
    /// クリップが参照するシーンの定義(参照だけ写すと、貼り付け先で何も表示されなくなる)
    public var scenes: [SceneDefinition] = []
    /// クリップが使う立ち絵の定義
    public var tachies: [Tachie] = []
    /// ボイスクリップが使うキャラクターの定義
    public var characters: [Character] = []

    /// 貼り付けで扱うレイヤー番号の上限(外から来た JSON の巨大な番号でレイヤーを際限なく作らない)
    public static let maxPasteTrack = 1024

    /// 選択したクリップから作る(レイヤー番号順、開始順)。無ければ nil。
    public static func make(from project: Project, clipIds: Set<String>) -> ClipClipboard? {
        var items: [Item] = []
        for (ti, tr) in project.tracks.enumerated() {
            for c in tr.clips where clipIds.contains(c.id) { items.append(Item(track: ti, clip: c)) }
        }
        items.sort { a, b in a.track != b.track ? a.track < b.track : a.clip.start < b.clip.start }
        guard !items.isEmpty else { return nil }
        var cb = ClipClipboard(items: items)
        // 参照先の定義も一緒に持つ(シーン・立ち絵・キャラクター)
        let clips = items.map(\.clip)
        var holder = Track(name: "")
        holder.clips = clips
        cb.scenes = ClipTransfer.sceneDefinitions(referencedFrom: [holder], in: project)
        var tachieIds = ClipTransfer.usedTachieIds(clips)
        for s in cb.scenes { tachieIds.formUnion(ClipTransfer.usedTachieIds(s.tracks.flatMap(\.clips))) }
        cb.tachies = project.tachies.filter { tachieIds.contains($0.id) }
        let charIds = ClipTransfer.usedCharacterIds(clips)
        cb.characters = project.characters.filter { charIds.contains($0.id) }
        return cb
    }

    public func encoded() -> Data? { try? JSONEncoder().encode(self) }


    public static func decode(_ data: Data) -> ClipClipboard? {
        guard let c = try? JSONDecoder().decode(ClipClipboard.self, from: data), c.version == 1, !c.items.isEmpty,
              c.items.allSatisfy({ (0...maxPasteTrack).contains($0.track) }) else { return nil }
        return c
    }
}

extension ClipClipboard: Codable {
    private enum CodingKeys: String, CodingKey { case version, items, scenes, tachies, characters }

    public init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        version = try box.decode(Int.self, forKey: .version)
        items = try box.decode([Item].self, forKey: .items)
        // 定義の同梱(scenes / tachies / characters)は後から足した項目。無い書き方(旧形式)でも読めるようにする
        scenes = try box.decodeIfPresent([SceneDefinition].self, forKey: .scenes) ?? []
        tachies = try box.decodeIfPresent([Tachie].self, forKey: .tachies) ?? []
        characters = try box.decodeIfPresent([Character].self, forKey: .characters) ?? []
    }
}

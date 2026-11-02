import Foundation

/// A6: レイヤー(ファイルの `tracks`)の名前・ロック・ソロ・高さ。UI にも Undo にも依存しない純粋な計算。
/// どれも「変わらないとき」は nil を返す(= 何も登録しない)。ファイルには既定でないときだけ書く。
public enum LayerHeight: String, CaseIterable, Sendable {
    case small, normal, large

    /// 行の高さ(pt)。標準は従来の 40。
    public var points: Double {
        switch self {
        case .small: return 36
        case .normal: return 40
        case .large: return 64
        }
    }

    public var title: String {
        switch self {
        case .small: return "小"
        case .normal: return "標準"
        case .large: return "大"
        }
    }

    /// ファイルに書く値(標準は書かない)。
    var stored: String? { self == .normal ? nil : rawValue }

    /// 知らない値・未設定は標準。
    public static func of(_ track: Track) -> LayerHeight {
        track.height.flatMap(LayerHeight.init(rawValue:)) ?? .normal
    }
}

public extension Project {
    /// どれかのレイヤーがソロか。
    var hasSolo: Bool { tracks.contains { $0.isSolo } }

    /// このレイヤーの音が鳴るか: 消音でなく、ソロがあるときはソロのレイヤーだけ。
    func isAudible(_ track: Track) -> Bool {
        !track.isMuted && (!hasSolo || track.isSolo)
    }
}

public enum LayerEditing {
    /// 名前を変える。前後の空白は落とす。空・同じ名前・範囲外は nil。
    public static func rename(in project: Project, index: Int, to name: String) -> Project? {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard project.tracks.indices.contains(index), !n.isEmpty, n != project.tracks[index].name else { return nil }
        var p = project
        p.tracks[index].name = n
        return p
    }

    public static func setLocked(in project: Project, index: Int, _ on: Bool) -> Project? {
        guard project.tracks.indices.contains(index), project.tracks[index].isLocked != on else { return nil }
        var p = project
        p.tracks[index].locked = on ? true : nil
        p.tracks[index].extra["locked"] = nil
        return p
    }

    public static func setSolo(in project: Project, index: Int, _ on: Bool) -> Project? {
        guard project.tracks.indices.contains(index), project.tracks[index].isSolo != on else { return nil }
        var p = project
        p.tracks[index].solo = on ? true : nil
        p.tracks[index].extra["solo"] = nil
        return p
    }

    public static func setHeight(in project: Project, index: Int, _ h: LayerHeight) -> Project? {
        guard project.tracks.indices.contains(index), LayerHeight.of(project.tracks[index]) != h else { return nil }
        var p = project
        p.tracks[index].height = h.stored
        p.tracks[index].extra["height"] = nil
        return p
    }

    /// 各行の高さ(pt)。
    public static func rowHeights(_ project: Project) -> [Double] {
        project.tracks.map { LayerHeight.of($0).points }
    }

    /// 編集(`new`)が、`old` でロックされていたレイヤーのクリップに触れているか。
    /// ロックの切り替えや名前・高さ・ソロ・隠す・消音はクリップに触れないので対象外。
    public static func violatesLock(old: Project, new: Project) -> Bool {
        for tr in old.tracks where tr.isLocked {
            guard let n = new.tracks.first(where: { $0.id == tr.id }) else { return true }
            if n.clips != tr.clips { return true }
        }
        return false
    }

    /// 編集してよいクリップだけに絞る(ロックされたレイヤーのクリップを除く)。
    public static func editableIds(_ ids: Set<String>, in project: Project) -> Set<String> {
        var out = Set<String>()
        for tr in project.tracks where !tr.isLocked {
            for c in tr.clips where ids.contains(c.id) { out.insert(c.id) }
        }
        return out
    }

    /// そのクリップがロックされたレイヤーにあるか。
    public static func isLockedClip(_ id: String, in project: Project) -> Bool {
        project.tracks.contains { $0.isLocked && $0.clips.contains { $0.id == id } }
    }

    // MARK: 削除

    /// レイヤーを消せない理由(日本語)。消せるなら nil。最後の 1 つは消せない(タイムラインが空になるため)。
    public static func deleteBlockedReason(in project: Project, index: Int) -> String? {
        guard project.tracks.indices.contains(index) else { return "削除するレイヤーがありません" }
        if project.tracks.count <= 1 { return "最後のレイヤーは削除できません" }
        return nil
    }

    /// レイヤーを(中のクリップごと)消す。範囲外・最後の 1 つは nil。ほかのレイヤーの順番と中身は変えない。
    /// ロックの確認は呼ぶ側(アプリ)で行う。この関数はロックされたレイヤーでも消す。
    public static func delete(in project: Project, index: Int) -> Project? {
        guard deleteBlockedReason(in: project, index: index) == nil else { return nil }
        var p = project
        p.tracks.remove(at: index)
        return p
    }

    /// 確認ダイアログ用: そのレイヤーのクリップ数(複合の中は数えない)と、ロックか。
    public static func deletionImpact(in project: Project, index: Int) -> (name: String, clipCount: Int, locked: Bool)? {
        guard project.tracks.indices.contains(index) else { return nil }
        let t = project.tracks[index]
        return (t.name, t.clips.count, t.isLocked)
    }
}

import Foundation

// 画面のドッキング(パネルの配置)。UI を持たない純粋なモデル。
// 4 つのパネル(キャラクター・プロパティ・タイムライン・プレビュー)を、分割の木 + タブのグループで並べる。
// 不変条件: どのパネルも「木のどこか / 別ウインドウ(floating) / 閉じている(closed)」のちょうど 1 か所にあり、空のグループは無く、
// 分割の比率は 0.1〜0.9。壊れた JSON は初期配置に戻る。ドキュメントには保存しない(アプリ全体の設定)。

public enum DockPanel: String, Codable, CaseIterable, Hashable {
    // 宣言順 = 「1つのタブにまとめる」ときのタブの並び
    case characters, preview, inspector, timeline

    public var title: String {
        switch self {
        case .characters: return "キャラクター"
        case .preview: return "プレビュー"
        case .inspector: return "プロパティ"
        case .timeline: return "タイムライン"
        }
    }
}

/// horizontal = 左右に並べる、vertical = 上下に並べる。
public enum DockAxis: String, Codable { case horizontal, vertical }
public enum DockEdge: String, Codable, CaseIterable { case left, right, top, bottom }

/// 組み込みの配置(表示 ▸ レイアウト)。
public enum DockPreset: String, CaseIterable, Hashable {
    case initial, singleTab, allSeparate, previewLarge

    public var title: String {
        switch self {
        case .initial: return "初期配置に戻す"
        case .singleTab: return "1つのタブにまとめる"
        case .allSeparate: return "すべて分離"
        case .previewLarge: return "プレビューを大きく"
        }
    }
}

public struct DockGroup: Equatable, Codable {
    public var panels: [DockPanel]
    public var active: DockPanel
    public init(panels: [DockPanel], active: DockPanel? = nil) {
        self.panels = panels
        self.active = active.flatMap { panels.contains($0) ? $0 : nil } ?? panels.first ?? .preview
    }
}

public indirect enum DockNode: Equatable, Codable {
    case group(DockGroup)
    /// fraction = first が占める割合(0.1〜0.9)
    case split(axis: DockAxis, fraction: Double, first: DockNode, second: DockNode)

    static let maxDepth = 16

    // MARK: Codable({"kind":"group",...} / {"kind":"split",...})

    private enum CodingKeys: String, CodingKey { case kind, panels, active, axis, fraction, first, second }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "group":
            let panels = try c.decode([DockPanel].self, forKey: .panels)
            self = .group(DockGroup(panels: panels, active: try c.decodeIfPresent(DockPanel.self, forKey: .active)))
        case "split":
            self = .split(axis: try c.decode(DockAxis.self, forKey: .axis), fraction: try c.decode(Double.self, forKey: .fraction),
                          first: try c.decode(DockNode.self, forKey: .first), second: try c.decode(DockNode.self, forKey: .second))
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "unknown kind")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .group(let g):
            try c.encode("group", forKey: .kind); try c.encode(g.panels, forKey: .panels); try c.encode(g.active, forKey: .active)
        case .split(let axis, let f, let a, let b):
            try c.encode("split", forKey: .kind); try c.encode(axis, forKey: .axis); try c.encode(f, forKey: .fraction)
            try c.encode(a, forKey: .first); try c.encode(b, forKey: .second)
        }
    }

    // MARK: 問い合わせ

    /// 木の中のパネル(左/上から順)。
    public var panels: [DockPanel] {
        switch self {
        case .group(let g): return g.panels
        case .split(_, _, let a, let b): return a.panels + b.panels
        }
    }

    /// そのパネルを含むグループ。
    public func group(containing panel: DockPanel) -> DockGroup? {
        switch self {
        case .group(let g): return g.panels.contains(panel) ? g : nil
        case .split(_, _, let a, let b): return a.group(containing: panel) ?? b.group(containing: panel)
        }
    }

    var depth: Int {
        switch self {
        case .group: return 1
        case .split(_, _, let a, let b): return 1 + max(a.depth, b.depth)
        }
    }

    // MARK: 変更(純粋: 新しい木を返す)

    /// パネルを取り除く。空になったグループと、子が 1 つになった分割はたたむ。全部なくなれば nil。
    func removing(_ panel: DockPanel) -> DockNode? {
        switch self {
        case .group(var g):
            guard let i = g.panels.firstIndex(of: panel) else { return self }
            g.panels.remove(at: i)
            if g.panels.isEmpty { return nil }
            if g.active == panel { g.active = g.panels[min(i, g.panels.count - 1)] }
            return .group(g)
        case .split(let axis, let f, let a, let b):
            let na = a.removing(panel), nb = b.removing(panel)
            switch (na, nb) {
            case (nil, nil): return nil
            case (let x?, nil): return x
            case (nil, let y?): return y
            case (let x?, let y?): return .split(axis: axis, fraction: f, first: x, second: y)
            }
        }
    }

    /// `panel` を含むグループを変換する。
    func mapGroup(containing panel: DockPanel, _ transform: (DockGroup) -> DockNode) -> DockNode {
        switch self {
        case .group(let g): return g.panels.contains(panel) ? transform(g) : self
        case .split(let axis, let f, let a, let b):
            return .split(axis: axis, fraction: f, first: a.mapGroup(containing: panel, transform), second: b.mapGroup(containing: panel, transform))
        }
    }

    /// `anchors` のパネルを全部含む、いちばん小さい部分木を変換する。
    func wrapping(anchors: Set<DockPanel>, _ transform: (DockNode) -> DockNode) -> DockNode {
        if case .split(let axis, let f, let a, let b) = self {
            if anchors.isSubset(of: Set(a.panels)) { return .split(axis: axis, fraction: f, first: a.wrapping(anchors: anchors, transform), second: b) }
            if anchors.isSubset(of: Set(b.panels)) { return .split(axis: axis, fraction: f, first: a, second: b.wrapping(anchors: anchors, transform)) }
        }
        return transform(self)
    }

    /// 経路(false = first / true = second)の分割の比率を変える。
    func settingFraction(at path: [Bool], to value: Double) -> DockNode {
        guard case .split(let axis, let f, let a, let b) = self else { return self }
        guard let step = path.first else {
            return .split(axis: axis, fraction: DockLayout.clamp(value), first: a, second: b)
        }
        let rest = Array(path.dropFirst())
        return step ? .split(axis: axis, fraction: f, first: a, second: b.settingFraction(at: rest, to: value))
                    : .split(axis: axis, fraction: f, first: a.settingFraction(at: rest, to: value), second: b)
    }

    /// 比率を範囲内に直し、グループの active を直す。
    func sanitized() -> DockNode {
        switch self {
        case .group(let g): return .group(DockGroup(panels: g.panels, active: g.active))
        case .split(let axis, let f, let a, let b):
            return .split(axis: axis, fraction: DockLayout.clamp(f), first: a.sanitized(), second: b.sanitized())
        }
    }

    var isWellFormed: Bool {
        switch self {
        case .group(let g): return !g.panels.isEmpty && g.panels.contains(g.active)
        case .split(_, let f, let a, let b): return f.isFinite && f >= DockLayout.minFraction - 1e-9 && f <= DockLayout.maxFraction + 1e-9 && a.isWellFormed && b.isWellFormed
        }
    }
}

public struct DockLayout: Equatable, Codable {
    public static let minFraction = 0.1, maxFraction = 0.9

    /// ドッキングしているパネルの木(1 つもなければ nil)。
    public var root: DockNode?
    /// 別ウインドウに出しているパネル。
    public var floating: [DockPanel]
    /// 閉じているパネル(表示 ▸ パネルで開き直せる)。
    public var closed: [DockPanel]

    public init(root: DockNode?, floating: [DockPanel] = [], closed: [DockPanel] = []) {
        self.root = root; self.floating = floating; self.closed = closed
    }

    static func clamp(_ f: Double) -> Double {
        f.isFinite ? min(max(f, minFraction), maxFraction) : 0.5
    }

    private enum CodingKeys: String, CodingKey { case root, floating, closed }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        root = try c.decodeIfPresent(DockNode.self, forKey: .root)
        floating = try c.decodeIfPresent([DockPanel].self, forKey: .floating) ?? []
        closed = try c.decodeIfPresent([DockPanel].self, forKey: .closed) ?? []
    }

    // MARK: 初期配置とプリセット

    private static func leaf(_ p: DockPanel) -> DockNode { .group(DockGroup(panels: [p])) }

    /// 初期配置 = これまでの画面そのもの: 上段に キャラクター | プレビュー | プロパティ、下段にタイムライン。
    public static let `default` = DockLayout(root:
        .split(axis: .vertical, fraction: 0.7,
               first: .split(axis: .horizontal, fraction: 0.22,
                             first: leaf(.characters),
                             second: .split(axis: .horizontal, fraction: 0.74, first: leaf(.preview), second: leaf(.inspector))),
               second: leaf(.timeline)))

    public static func preset(_ p: DockPreset) -> DockLayout {
        switch p {
        case .initial: return .default
        case .singleTab:
            return DockLayout(root: .group(DockGroup(panels: DockPanel.allCases, active: .preview)))
        case .allSeparate:
            // 2×2: 上段 キャラクター | プレビュー、下段 タイムライン | プロパティ
            return DockLayout(root:
                .split(axis: .vertical, fraction: 0.55,
                       first: .split(axis: .horizontal, fraction: 0.3, first: leaf(.characters), second: leaf(.preview)),
                       second: .split(axis: .horizontal, fraction: 0.7, first: leaf(.timeline), second: leaf(.inspector))))
        case .previewLarge:
            // プレビューを大きく、キャラクターとプロパティは右の 1 グループ(タブ)に小さく、タイムラインは下に細く
            return DockLayout(root:
                .split(axis: .vertical, fraction: 0.8,
                       first: .split(axis: .horizontal, fraction: 0.78, first: leaf(.preview),
                                     second: .group(DockGroup(panels: [.characters, .inspector], active: .inspector))),
                       second: leaf(.timeline)))
        }
    }

    public mutating func apply(_ p: DockPreset) { self = Self.preset(p) }

    // MARK: 問い合わせ

    public enum Location: Equatable { case docked, floating, closed }

    public var docked: [DockPanel] { root?.panels ?? [] }

    public func location(of panel: DockPanel) -> Location {
        if floating.contains(panel) { return .floating }
        if closed.contains(panel) { return .closed }
        return .docked
    }

    /// 画面に出ている(ドッキング or 別ウインドウ)。
    public func isVisible(_ panel: DockPanel) -> Bool { location(of: panel) != .closed }

    public func group(containing panel: DockPanel) -> DockGroup? { root?.group(containing: panel) }

    /// 不変条件を満たすか(全パネルがちょうど 1 か所、空グループなし、比率が範囲内、深さの上限内)。
    public var isValid: Bool {
        let all = docked + floating + closed
        guard all.count == DockPanel.allCases.count, Set(all).count == all.count, Set(all) == Set(DockPanel.allCases) else { return false }
        if let r = root { return r.isWellFormed && r.depth <= DockNode.maxDepth }
        return true
    }

    /// 比率を範囲内に、active を所属内に直したもの。
    public func sanitized() -> DockLayout {
        DockLayout(root: root?.sanitized(), floating: floating, closed: closed)
    }

    // MARK: 操作

    /// パネルをどこにあっても取り除く(木・別ウインドウ・閉じている)。
    private mutating func take(_ panel: DockPanel) {
        root = root?.removing(panel)
        floating.removeAll { $0 == panel }
        closed.removeAll { $0 == panel }
    }

    /// タブを選ぶ。
    @discardableResult
    public mutating func setActive(_ panel: DockPanel) -> Bool {
        guard let r = root, r.group(containing: panel) != nil else { return false }
        root = r.mapGroup(containing: panel) { g in var n = g; n.active = panel; return .group(n) }
        return true
    }

    /// `target` のいるグループへタブとして入れる(別ウインドウ・閉じているものも可)。`index` が無ければ末尾。同じグループなら並べ替え。
    @discardableResult
    public mutating func moveToTab(_ panel: DockPanel, ofGroupContaining target: DockPanel, at index: Int? = nil) -> Bool {
        guard panel != target, let r = root, r.group(containing: target) != nil else { return false }
        if let g = r.group(containing: panel), g.panels.contains(target) {
            // 同じグループ内の並べ替え
            var list = g.panels
            let from = list.firstIndex(of: panel)!
            list.remove(at: from)
            let to = min(max(index.map { $0 > from ? $0 - 1 : $0 } ?? list.count, 0), list.count)
            list.insert(panel, at: to)
            guard list != g.panels else { return false }
            root = r.mapGroup(containing: target) { _ in .group(DockGroup(panels: list, active: panel)) }
            return true
        }
        take(panel)
        root = root?.mapGroup(containing: target) { g in
            var n = g
            let at = min(max(index ?? n.panels.count, 0), n.panels.count)
            n.panels.insert(panel, at: at)
            n.active = panel
            return .group(n)
        }
        return true
    }

    /// `target` のいるグループの端に、新しいグループとして入れる(分割を作る)。`fraction` = 新しい側が占める割合。
    @discardableResult
    public mutating func moveToEdge(_ panel: DockPanel, _ edge: DockEdge, ofGroupContaining target: DockPanel, fraction: Double = 0.5) -> Bool {
        guard let r = root, let tg = r.group(containing: target) else { return false }
        // 自分のグループの端へ(自分が残らないなら何も変わらない)
        var anchor = target
        if panel == target {
            guard let other = tg.panels.first(where: { $0 != panel }) else { return false }
            anchor = other
        }
        take(panel)
        guard let base = root, base.group(containing: anchor) != nil else { return false }
        let newLeaf = Self.leaf(panel)
        let f = Self.clamp(fraction)
        root = base.mapGroup(containing: anchor) { g in
            let old = DockNode.group(g)
            switch edge {
            case .left: return .split(axis: .horizontal, fraction: f, first: newLeaf, second: old)
            case .right: return .split(axis: .horizontal, fraction: Self.clamp(1 - f), first: old, second: newLeaf)
            case .top: return .split(axis: .vertical, fraction: f, first: newLeaf, second: old)
            case .bottom: return .split(axis: .vertical, fraction: Self.clamp(1 - f), first: old, second: newLeaf)
            }
        }
        return true
    }

    /// 別ウインドウに出す。
    @discardableResult
    public mutating func detach(_ panel: DockPanel) -> Bool {
        guard location(of: panel) == .docked else { return false }
        take(panel)
        floating.append(panel)
        return true
    }

    /// 閉じる(別ウインドウのものも閉じられる)。
    @discardableResult
    public mutating func close(_ panel: DockPanel) -> Bool {
        guard location(of: panel) != .closed else { return false }
        take(panel)
        closed.append(panel)
        return true
    }

    /// 元の場所へ戻す(別ウインドウ・閉じているものを、初期配置での隣のパネルの横に置く)。ドッキング中なら何もしない。
    @discardableResult
    public mutating func attach(_ panel: DockPanel) -> Bool {
        guard location(of: panel) != .docked else { return false }
        take(panel)
        guard root != nil else { root = Self.leaf(panel); return true }
        // 初期配置での隣(その部分木の外側に置く): (隣のパネルたち, 自分を置く端, 自分の割合)
        let anchors: [DockPanel], edge: DockEdge, fraction: Double
        switch panel {
        case .characters: (anchors, edge, fraction) = ([.preview, .inspector], .left, 0.22)
        case .inspector: (anchors, edge, fraction) = ([.preview], .right, 0.26)
        case .timeline: (anchors, edge, fraction) = ([.characters, .preview, .inspector], .bottom, 0.3)
        case .preview: (anchors, edge, fraction) = ([.inspector], .left, 0.74)
        }
        // ドッキング中の隣だけで数える。1 つもいなければ全体の端に置く
        var near = Set(anchors.filter { root?.group(containing: $0) != nil })
        if near.isEmpty { near = Set(docked) }
        let leaf = Self.leaf(panel), f = Self.clamp(fraction)
        root = root?.wrapping(anchors: near) { old in
            switch edge {
            case .left: return .split(axis: .horizontal, fraction: f, first: leaf, second: old)
            case .right: return .split(axis: .horizontal, fraction: Self.clamp(1 - f), first: old, second: leaf)
            case .top: return .split(axis: .vertical, fraction: f, first: leaf, second: old)
            case .bottom: return .split(axis: .vertical, fraction: Self.clamp(1 - f), first: old, second: leaf)
            }
        }
        return true
    }

    /// 表示 ▸ パネル: 出ていれば閉じ、閉じていれば開く。
    public mutating func toggle(_ panel: DockPanel) {
        if isVisible(panel) { close(panel) } else { attach(panel) }
    }

    /// 別ウインドウのものを全部ドッキングへ戻す(起動時)。
    public mutating func reattachAllFloating() {
        for p in floating { attach(p) }
    }

    /// 分割の比率(経路は false = first / true = second)。
    @discardableResult
    public mutating func setFraction(at path: [Bool], to value: Double) -> Bool {
        guard let r = root else { return false }
        let n = r.settingFraction(at: path, to: value)
        guard n != r else { return false }
        root = n
        return true
    }

    // MARK: 保存(JSON)

    public func encoded() -> Data? {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return try? e.encode(self)
    }

    /// 壊れた・足りない・矛盾した JSON は初期配置。比率だけ範囲外なら直して使う。
    public static func decoded(from data: Data?) -> DockLayout {
        guard let data, let l = try? JSONDecoder().decode(DockLayout.self, from: data) else { return .default }
        let s = l.sanitized()
        return s.isValid ? s : .default
    }

    /// 起動時の配置: 保存した配置の、別ウインドウに出ていたものを初期の位置へ戻したもの。
    public static func forLaunch(from data: Data?) -> DockLayout {
        var l = decoded(from: data)
        l.reattachAllFloating()
        return l
    }
}

// MARK: - ドラッグ&ドロップの判定と分割の寸法

/// タブをドロップした位置の意味: タブバー・中央 = タブとして合流、四辺 = その側に分割。
public enum DockDropZone: Equatable {
    case tab
    case edge(DockEdge)

    /// 座標は左上原点。`tabBarHeight` より上はタブバー。内容の外周 `edgeRatio` の帯は、いちばん近い辺。
    public static func zone(x: Double, y: Double, width: Double, height: Double, tabBarHeight: Double = 26, edgeRatio: Double = 0.25) -> DockDropZone {
        guard width > 0, height > tabBarHeight, y >= tabBarHeight else { return .tab }
        let cx = min(max(x / width, 0), 1)
        let cy = min(max((y - tabBarHeight) / (height - tabBarHeight), 0), 1)
        let dists: [(Double, DockEdge)] = [(cx, .left), (1 - cx, .right), (cy, .top), (1 - cy, .bottom)]
        let best = dists.min { $0.0 < $1.0 }!
        return best.0 < edgeRatio ? .edge(best.1) : .tab
    }
}

public enum DockMetrics {
    public static let dividerThickness = 6.0
    public static let minPanelSize = 120.0

    /// 分割の first の大きさ(仕切りを除いた長さ `total` に対する比率)。どちらも `minPanelSize` を割らない(狭すぎれば半々)。
    public static func firstSize(total: Double, fraction: Double) -> Double {
        let avail = max(total - dividerThickness, 0)
        guard avail >= minPanelSize * 2 else { return avail / 2 }
        return min(max(avail * DockLayout.clamp(fraction), minPanelSize), avail - minPanelSize)
    }

    /// ドラッグで first を `size` にしたときの比率。
    public static func fraction(forFirstSize size: Double, total: Double) -> Double {
        let avail = max(total - dividerThickness, 1)
        return DockLayout.clamp(size / avail)
    }
}

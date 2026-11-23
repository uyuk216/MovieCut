import Foundation

// MARK: - シーン／ネスト(W3-01、YMM4 監査 #7)
//
// シーンは「プロジェクトの中にある、名前付きの独立タイムライン」。定義は `Project.scenes` に置き、
// タイムラインからは `type == .scene` のクリップが `sceneId` で参照する。同じシーンを何箇所にも置けて、
// 定義を直せば参照先すべてに反映される(再利用)。
//
// 複合クリップ(`CompoundEditing`)との違い:
// - 複合クリップは中身(`Clip.tracks`)をクリップ自身が「値として」抱える。所有者はそのクリップ 1 つだけで、
//   コピーすれば中身も複製される。選択したクリップをその場で 1 本にまとめるための仕組み。
// - シーンは中身をプロジェクト級の定義として持ち、クリップは id で「参照」するだけ。複数箇所から参照でき、
//   名前を付けて一覧で管理し、シーン単体を開いて編集する。素材ライブラリに近い位置づけ。
// 土台の流用: 時刻の窓切り(`CompoundEditing.window`)、音声の平坦化(`CompoundEditing.audibleClips` の flatten)、
// 描画の入れ子 Renderer(背景・立ち絵を描かない子 Renderer、祖先スタックで循環防止)、深さ上限(8)は複合と共有する。
// シーン固有の差分は「参照グラフの循環検出」と「削除ポリシー(参照中は削除不可)」だけをここに足す。
//
// 尺の扱い: シーンクリップの `duration` が表示尺、`offset` がシーン内時刻の窓の頭(複合クリップと同じ)。
// シーン内時刻 = クリップの頭からの時刻 + offset で描き・混ぜ、窓の外(シーン尺を超えた分)は切り取る。
// シーンの尺そのものは中身のクリップの終わりの最大(空なら 0)。配置時の duration はその時点のシーン尺で、
// 後からシーンが伸びても既存クリップの duration は自動では変わらない(複合クリップと同じ)。

/// シーンの定義: 名前 + 独立タイムライン(レイヤーとクリップの集合)。
public struct SceneDefinition: Codable, Equatable, Identifiable {
    public var id: String = newId()
    public var name: String = ""
    public var tracks: [Track] = []
    /// 知らないキー(保持して書き戻す)
    public var extra: [String: JSONValue] = [:]

    static let knownKeys: Set<String> = ["id", "name", "tracks"]

    public init() {}
    public init(id: String, name: String, tracks: [Track]) { self.id = id; self.name = name; self.tracks = tracks }

    public init(from decoder: Decoder) throws {
        let l = Lenient(c: try decoder.container(keyedBy: AnyKey.self), known: Self.knownKeys)
        id = l.string("id") ?? id
        name = l.string("name") ?? name
        tracks = l.value("tracks") ?? []
        extra = l.extra()
        if tracks.isEmpty, let raw: JSONValue = l.value("tracks"), raw != .array([]) { extra["tracks"] = raw }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        for (k, v) in extra { try c.encode(v, forKey: AnyKey(k)) }
        try c.encode(id, forKey: AnyKey("id"))
        try c.encode(name, forKey: AnyKey("name"))
        try c.encode(tracks, forKey: AnyKey("tracks"))
    }

    /// シーンの尺(中身のクリップの終わりの最大。空なら 0)。
    public var duration: Double { SceneEditing.duration(of: self) }
    public var allClips: [Clip] { tracks.flatMap { $0.clips } }
}

public extension Project {
    /// id からシーンを引く。無ければ nil。
    func scene(withId id: String) -> SceneDefinition? { scenes.first { $0.id == id } }
    /// シーンを使っているか(定義が 1 つでもあるか)。
    var hasScenes: Bool { !scenes.isEmpty }
}

public enum SceneEditing {
    /// 入れ子の深さの上限(複合クリップと共有の予算。シーン参照・複合の合計段数)。
    /// これより深い配置は拒否し、読み込みでも深すぎる中身は描かない・混ぜない。
    public static let maxDepth = CompoundEditing.maxDepth

    // MARK: 尺・参照の走査

    /// シーンの尺(中身のクリップの終わりの最大。空・不正値なら 0)。
    public static func duration(of scene: SceneDefinition) -> Double {
        scene.tracks.flatMap { $0.clips }.map { $0.start + $0.duration }.filter { $0.isFinite }.max() ?? 0
    }

    /// レイヤー列の中から、シーン参照を(複合クリップの中まで)集める。
    public static func referencedSceneIds(in tracks: [Track]) -> Set<String> {
        var out: Set<String> = []
        func walk(_ clips: [Clip]) {
            for c in clips {
                if c.type == .scene, let sid = c.sceneId { out.insert(sid) }
                if c.type == .compound, let kids = c.tracks { walk(kids.flatMap { $0.clips }) }
            }
        }
        walk(tracks.flatMap { $0.clips })
        return out
    }

    /// プロジェクト全体(メイン + 全シーン)で参照されているシーン id。
    public static func allReferencedSceneIds(in p: Project) -> Set<String> {
        var out = referencedSceneIds(in: p.tracks)
        for s in p.scenes { out.formUnion(referencedSceneIds(in: s.tracks)) }
        return out
    }

    /// そのシーンを参照しているクリップの数(メイン + 全シーン、複合の中を含む)。
    public static func referenceCount(in p: Project, sceneId: String) -> Int {
        func count(_ clips: [Clip]) -> Int {
            clips.reduce(0) { acc, c in
                var n = acc
                if c.type == .scene, c.sceneId == sceneId { n += 1 }
                if c.type == .compound, let kids = c.tracks { n += count(kids.flatMap { $0.clips }) }
                return n
            }
        }
        return count(p.tracks.flatMap { $0.clips }) + p.scenes.reduce(0) { $0 + count($1.tracks.flatMap { $0.clips }) }
    }

    // MARK: 循環の検出・配置の検証

    /// シーン参照グラフで、`from` から辿って `target` に届くか(自分自身を含む)。
    /// シーン A の中身が B を参照する関係を辺 A → B として辿る。定義の無い id は行き止まり。
    public static func reaches(in p: Project, from: String, target: String) -> Bool {
        var seen: Set<String> = []
        var stack = [from]
        while let cur = stack.popLast() {
            if cur == target { return true }
            guard seen.insert(cur).inserted, let s = p.scene(withId: cur) else { continue }
            stack.append(contentsOf: referencedSceneIds(in: s.tracks))
        }
        return false
    }

    /// プロジェクト内のどこかに循環参照があるか(読み込み後の健全性チェック・テスト用)。
    public static func hasCycle(in p: Project) -> Bool {
        p.scenes.contains { directlyOrIndirectlySelfReferences(in: p, sceneId: $0.id) }
    }

    /// そのシーンが(複合クリップ経由も含めて)自分自身を参照しているか。
    private static func directlyOrIndirectlySelfReferences(in p: Project, sceneId: String) -> Bool {
        guard let s = p.scene(withId: sceneId) else { return false }
        // 自分への直接参照、または参照先のどれかから自分へ戻ってくる経路がある
        return referencedSceneIds(in: s.tracks).contains { reaches(in: p, from: $0, target: sceneId) }
    }

    /// シーン参照の入れ子の深さ(そのシーンを展開したときの最長段数。参照なしなら 0、循環なら .max)。
    public static func nestingDepth(in p: Project, sceneId: String) -> Int {
        func depth(_ id: String, _ seen: Set<String>) -> Int {
            guard !seen.contains(id) else { return .max }
            guard let s = p.scene(withId: id) else { return 0 }
            let refs = referencedSceneIds(in: s.tracks)
            guard !refs.isEmpty else { return 0 }
            let inner = refs.map { depth($0, seen.union([id])) }.max() ?? 0
            return inner == .max ? .max : 1 + inner
        }
        return depth(sceneId, [])
    }

    /// シーンクリップの配置可否。`hostSceneId` は配置先がシーンの中のとき、そのシーンの id(メインなら nil)。
    /// 拒否するのは: 参照先が無い / 配置で循環ができる / 入れ子が深さ上限を超える、の 3 つ。
    public static func canPlace(in p: Project, sceneId: String, hostSceneId: String?) -> Bool {
        guard p.scene(withId: sceneId) != nil else { return false }
        // 深さは、シーン参照の段数ではなく、複合クリップも含めた展開の段数(expansionCost)で数える。
        // 参照だけ数えると途中の複合の段数が抜け、描画・音声の平坦化が上限で末端を落とす構造を許してしまう。
        let content = contentDepth(in: p, sceneId: sceneId)
        guard content != .max else { return false }
        let clipDepth = 1 + content   // このシーンを指すクリップ自体の段数
        if let host = hostSceneId {
            // 辺 host → sceneId を足して循環になるのは、sceneId から host へ辿れるとき(自分自身を含む)
            if reaches(in: p, from: sceneId, target: host) { return false }
            // 配置先の中身として置く: 置いた後の配置先の中身の段数が、配置先自身の 1 段を残して上限に収まること
            let hostContent = contentDepth(in: p, sceneId: host)
            guard hostContent != .max else { return false }
            return max(hostContent, clipDepth) < maxDepth
        }
        return clipDepth <= maxDepth
    }

    /// シーンの中身の展開の段数(中身のクリップの expansionCost の最大。空なら 0、循環なら .max)。
    private static func contentDepth(in p: Project, sceneId: String) -> Int {
        guard let s = p.scene(withId: sceneId) else { return 0 }
        return s.tracks.flatMap { $0.clips }.map { expansionCost(of: $0, in: p, seen: ["scene:\(sceneId)"]) }.max() ?? 0
    }

    // MARK: 一覧の編集(作成・名前変更・複製・削除)

    /// シーンを作る(既定のレイヤー 5 本を持つ空のタイムライン)。名前が空なら nil。
    public static func create(in p: Project, name: String) -> (project: Project, sceneId: String)? {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return nil }
        var out = p
        let s = SceneDefinition(id: newId(), name: n, tracks: Track.defaultLayers())
        out.scenes.append(s)
        return (out, s.id)
    }

    /// 名前を変える。空・同じ・見つからないなら nil。
    public static func rename(in p: Project, sceneId: String, to name: String) -> Project? {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, let i = p.scenes.firstIndex(where: { $0.id == sceneId }), p.scenes[i].name != n else { return nil }
        var out = p
        out.scenes[i].name = n
        return out
    }

    /// 複製する: 定義に新しい id を振り、中身のクリップ(複合の中まで)にも新しい id を振る。
    /// 中身のシーン参照は元の参照先のまま(複製先も同じシーンを参照する)。見つからないなら nil。
    public static func duplicate(in p: Project, sceneId: String) -> (project: Project, sceneId: String)? {
        guard let src = p.scene(withId: sceneId) else { return nil }
        var copy = src
        copy.id = newId()
        copy.name = src.name + " のコピー"
        copy.tracks = src.tracks.map { t in
            var u = t
            u.clips = t.clips.map { CompoundEditing.freshIds($0) }
            return u
        }
        var out = p
        out.scenes.append(copy)
        return (out, copy.id)
    }

    /// 削除ポリシー: **参照されているシーンは削除できない**(参照クリップが黙って壊れるのを防ぐ)。
    /// メイン・他のシーン・複合クリップの中のどこか 1 箇所でも参照があれば nil。参照側を先に消すのが手順。
    public static func delete(in p: Project, sceneId: String) -> Project? {
        guard p.scene(withId: sceneId) != nil else { return nil }
        guard referenceCount(in: p, sceneId: sceneId) == 0 else { return nil }
        var out = p
        out.scenes.removeAll { $0.id == sceneId }
        return out
    }

    // MARK: 配置

    /// 配置先: メインのタイムラインか、あるシーンの中か。
    public enum Host: Equatable {
        case main
        case scene(String)
    }

    /// シーンクリップを置く。尺はその時点のシーン尺(空のシーンは置けない)。
    /// 配置先のレイヤーがロックされている・範囲外・循環や深さで置けないときは nil。
    /// 返すクリップの `duration` はシーン尺そのもの、`offset` は 0(シーンの頭から)。
    public static func place(in p: Project, sceneId: String, host: Host, trackIndex: Int, at time: Double) -> (project: Project, clipId: String)? {
        let hostSceneId: String? = { if case .scene(let id) = host { return id }; return nil }()
        guard canPlace(in: p, sceneId: sceneId, hostSceneId: hostSceneId) else { return nil }
        guard let scene = p.scene(withId: sceneId) else { return nil }
        let dur = duration(of: scene)
        guard dur > 0 else { return nil }
        var out = p
        var clip = Clip()
        clip.type = .scene
        clip.sceneId = sceneId
        clip.start = max(0, time)
        clip.duration = dur
        clip.offset = 0
        switch host {
        case .main:
            guard out.tracks.indices.contains(trackIndex), !out.tracks[trackIndex].isLocked else { return nil }
            CompoundEditing.insertByStart(clip, into: &out.tracks[trackIndex].clips)
        case .scene(let hostId):
            guard let hi = out.scenes.firstIndex(where: { $0.id == hostId }),
                  out.scenes[hi].tracks.indices.contains(trackIndex),
                  !out.scenes[hi].tracks[trackIndex].isLocked else { return nil }
            CompoundEditing.insertByStart(clip, into: &out.scenes[hi].tracks[trackIndex].clips)
        }
        return (out, clip.id)
    }
}

// MARK: - シーンの中を編集する(「開く」)
//
// 複合クリップの `CompoundScope` と同じ流儀: 根(root = 書類全体)に対し、見え方(view)は
// 根の `tracks` を開いているシーンの中身に差し替えたプロジェクト。編集は view に対して行い、
// `embed` で根に戻す。シーンの定義一覧・他の設定は view のものを採るので、一覧の編集と両立する。

public enum SceneScope {
    /// 開いているシーンの中身のレイヤー。見つからなければ nil。
    public static func innerTracks(of root: Project, sceneId: String) -> [Track]? {
        root.scene(withId: sceneId)?.tracks
    }

    /// 見え方: 根の `tracks` をシーンの中身へ差し替えたプロジェクト(シーン一覧などの他の設定は根のまま)。
    public static func view(of root: Project, sceneId: String) -> Project? {
        guard let inner = innerTracks(of: root, sceneId: sceneId) else { return nil }
        var v = root
        v.tracks = inner
        return v
    }

    /// 見え方を根へ戻す: view の `tracks` をシーンの中身にし、それ以外は view のものを採る。
    /// シーンが根・view のどちらかに無ければ nil。
    public static func embed(view: Project, into root: Project, sceneId: String) -> Project? {
        guard root.scene(withId: sceneId) != nil, let vi = view.scenes.firstIndex(where: { $0.id == sceneId }) else { return nil }
        var out = view
        out.tracks = root.tracks
        out.scenes[vi].tracks = view.tracks
        return out
    }

    /// パンくず用の表示名: 「プロジェクト」の後ろにシーン名を並べる。
    public static func breadcrumb(_ root: Project, sceneId: String?, rootTitle: String = "プロジェクト") -> [String] {
        guard let sceneId, let s = root.scene(withId: sceneId) else { return [rootTitle] }
        return [rootTitle, s.name.isEmpty ? "シーン" : s.name]
    }
}

// MARK: - 選択からシーンを作成(R2-3)

public extension SceneEditing {
    /// 選んだクリップを新しいシーン定義にまとめ、元の位置にそのシーンを参照するシーンクリップを置く。
    /// 複合クリップの `CompoundEditing.group` と同じ流儀: 中身は元のレイヤーごとに、同じ id・名前・状態の
    /// レイヤーへ、選んだクリップだけを入れる(時刻は先頭からの秒、1e-9 秒の格子で丸める)。
    /// シーンクリップは選んだクリップのうち最も前の元のレイヤーに、開始時刻順で入る。
    ///
    /// 複合との違いは 2 点:
    /// - 中身はクリップ自身ではなくプロジェクト級の定義(`Project.scenes`)に置くので、同じシーンを他の場所にも配置して再利用できる。
    /// - **1 つだけの選択でも作れる**(1 本のクリップを名前付きの再利用可能なシーンに昇格させる用途があるため。
    ///   複合は「まとめる」操作なので 2 つ未満を拒否するが、こちらは「定義化」が目的なので 1 つでも意味がある)。
    ///
    /// 対応する選択範囲は既存の選択モデル(`ClipSelection`)そのまま: 複数トラック・複数クリップの任意の集合
    /// (⌘クリックのばらばらの選択も、ラバーバンドの矩形選択も同じ経路)。同一レイヤーの一部だけの選択も可。
    ///
    /// 拒否するのは: 名前が空 / 選択が空・見つからない id を含む / ロックされたレイヤー・クリップを含む /
    /// 中身(複合クリップ)に循環がある / 入れ子が深さ上限を超える / 配置先のシーン(`hostSceneId`)への参照を含み
    /// 循環になる、のいずれか。作成後の描画・音声は作成前と一致する(シーンの描画・平坦化は複合と同じ窓・
    /// 同じ走査順で中身を辿り、中身のレイヤーの状態(消音・ソロ・非表示)もそのまま写すため)。
    static func createFromSelection(in p: Project, name: String, clipIds: [String], hostSceneId: String? = nil) -> (project: Project, sceneId: String, clipId: String)? {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return nil }
        let wanted = Set(clipIds)
        guard !wanted.isEmpty else { return nil }
        var found: [(ti: Int, ci: Int)] = []
        for (ti, tr) in p.tracks.enumerated() {
            for (ci, c) in tr.clips.enumerated() where wanted.contains(c.id) { found.append((ti, ci)) }
        }
        guard found.count == wanted.count else { return nil }
        guard !found.contains(where: { p.tracks[$0.ti].isLocked || p.tracks[$0.ti].clips[$0.ci].isClipLocked }) else { return nil }
        let picked = found.map { p.tracks[$0.ti].clips[$0.ci] }
        guard picked.allSatisfy({ !CompoundEditing.hasCycle($0) }) else { return nil }
        // 深さ: 新しいシーンクリップの 1 段 + 中身の展開の深さが上限以内か(循環する参照は .max になって、ここで拒否される)
        let innerDepth = picked.map { expansionCost(of: $0, in: p, seen: []) }.max() ?? 0
        guard innerDepth != .max, 1 + innerDepth <= maxDepth else { return nil }
        // 配置先がシーンの中のとき: 中身がそのシーンを(直接・間接に)参照していると、配置で循環ができるので拒否する
        if let host = hostSceneId {
            for sid in referencedSceneIds(inClips: picked) where sid == host || reaches(in: p, from: sid, target: host) { return nil }
        }

        let m = picked.map(\.start).min() ?? 0
        let end = picked.map { $0.start + $0.duration }.max() ?? m

        // 中身: 元のレイヤーごとに、同じ id・名前・状態のレイヤーへ、選んだクリップだけを入れる(時刻は頭からの秒)
        var out = p
        var kids: [Track] = []
        for ti in Set(found.map(\.ti)).sorted() {
            var kt = p.tracks[ti]
            kt.clips = p.tracks[ti].clips.filter { wanted.contains($0.id) }.map { c in
                var k = c
                k.start = CompoundEditing.grid(c.start - m)
                return k
            }
            // シーンの置き先レイヤー自身の音量・パンは、外側でもそのまま掛かり続ける。
            // 内側の写しにも残すと二重に掛かるため、置き先分だけ写し側を標準に戻す(複合化と同じ)。
            if ti == (found.map(\.ti).min() ?? 0) { kt.volume = nil; kt.pan = nil }
            kids.append(kt)
            out.tracks[ti].clips.removeAll { wanted.contains($0.id) }
        }
        let scene = SceneDefinition(id: newId(), name: n, tracks: kids)
        out.scenes.append(scene)
        var clip = Clip()
        clip.type = .scene
        clip.sceneId = scene.id
        clip.start = m
        clip.duration = CompoundEditing.grid(end - m)
        clip.offset = 0
        let home = found.map(\.ti).min() ?? 0
        CompoundEditing.insertByStart(clip, into: &out.tracks[home].clips)
        // 念のための健全性確認: 循環ができていたら作らなかったことにする
        guard !hasCycle(in: out) else { return nil }
        return (out, scene.id, clip.id)
    }

    /// クリップ列の中から、シーン参照を(複合クリップの中まで)集める(`referencedSceneIds(in:)` のクリップ列版)。
    private static func referencedSceneIds(inClips clips: [Clip]) -> Set<String> {
        var out: Set<String> = []
        func walk(_ cs: [Clip]) {
            for c in cs {
                if c.type == .scene, let sid = c.sceneId { out.insert(sid) }
                if c.type == .compound, let kids = c.tracks { walk(kids.flatMap { $0.clips }) }
            }
        }
        walk(clips)
        return out
    }

    /// クリップを展開したときの入れ子の深さ(描画・音声の平坦化が積む段数と同じ数え方:
    /// シーン参照・複合はそれぞれ 1 段、中身の最長で決まる。通常クリップは 0)。
    /// 循環する参照に届いたら `.max`。参照先の無いシーンクリップは何も出ないので 0。
    private static func expansionCost(of c: Clip, in p: Project, seen: Set<String>) -> Int {
        switch c.type {
        case .scene:
            guard let sid = c.sceneId, let sc = p.scene(withId: sid) else { return 0 }
            let key = "scene:\(sid)"
            guard !seen.contains(key) else { return .max }
            let inner = sc.tracks.flatMap { $0.clips }.map { expansionCost(of: $0, in: p, seen: seen.union([key])) }.max() ?? 0
            return inner == .max ? .max : 1 + inner
        case .compound:
            guard !seen.contains(c.id) else { return .max }
            let inner = (c.tracks ?? []).flatMap { $0.clips }.map { expansionCost(of: $0, in: p, seen: seen.union([c.id])) }.max() ?? 0
            return inner == .max ? .max : 1 + inner
        default:
            return 0
        }
    }
}

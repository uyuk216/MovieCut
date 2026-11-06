import Foundation
import CoreGraphics
import ImageIO

// パーツ式立ち絵(B-7 の続き): 体・髪・眉・目・口などを「スロット」に分け、同じ大きさの透過 PNG を重ねて 1 枚の立ち絵にする。
// 目(まばたき)・口(あいうえお)・表情はスロットの添字で切り替える。描画はプレビューも書き出しも同じ道(`RigFrameCache`)。
// 画面を持たない純粋ロジック + 合成。

// MARK: - モデル

/// 1 つのスロット(例: 眉)。`parts` は同じ大きさの画像のパス、`active` は今出しているもの(-1 = 何も出さない)。
public struct RigSlot: Codable, Equatable {
    public var name: String
    public var parts: [String]
    public var active: Int
    /// 体より後ろ(ほかの全スロットより下)に重ねる。例: 後ろ髪。false は書かない(nil = 前に重ねる従来の順)。
    public var behindBody: Bool?
    public var extra: [String: JSONValue] = [:]

    static let knownKeys: Set<String> = ["name", "parts", "active", "behindBody"]

    public init(name: String, parts: [String] = [], active: Int = 0) {
        self.name = name; self.parts = parts; self.active = active
    }

    public init(from decoder: Decoder) throws {
        let l = Lenient(c: try decoder.container(keyedBy: AnyKey.self), known: Self.knownKeys)
        name = l.string("name") ?? ""
        parts = l.value("parts") ?? []
        active = l.int("active") ?? 0
        extra = l.extra()
        if let raw: JSONValue = l.value("behindBody") {
            if l.bool("behindBody") == true { behindBody = true } else if l.bool("behindBody") == nil { extra["behindBody"] = raw }   // false は既定と同じ、読めない形は書き戻す
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        for (k, v) in extra { try c.encode(v, forKey: AnyKey(k)) }
        try c.encode(name, forKey: AnyKey("name"))
        try c.encode(parts, forKey: AnyKey("parts"))
        try c.encode(active, forKey: AnyKey("active"))
        if behindBody == true { try c.encode(true, forKey: AnyKey("behindBody")) }
    }

    public var isBehind: Bool { behindBody == true }

    /// 添字が使えるか(-1 = 出さない も含む)。
    public func isValid(_ index: Int) -> Bool { index >= -1 && index < parts.count }
    /// 今出しているパーツのパス(無ければ nil)。
    public var activePath: String? { parts.indices.contains(active) ? parts[active] : nil }
}

/// 口の状態(リップシンクの結果)。
public enum RigMouth: Equatable {
    /// 触らない(スロットの選択のまま)
    case unchanged
    case closed
    case open
    /// 母音 "a" "i" "u" "e" "o"
    case vowel(String)
}

/// パーツ画像の位置の補正(基準キャンバスの画素単位。右・下が正)。大きさが違うパーツ(例: 体より縦に長い髪)を、
/// 既定の置き方(下と左右の中央に揃える)からどれだけずらすか。ファイルでは `[dx, dy]` の 2 つ組。
public struct PartOffset: Codable, Equatable, Hashable {
    public var dx: Double
    public var dy: Double
    public init(dx: Double = 0, dy: Double = 0) { self.dx = dx; self.dy = dy }
    public var isZero: Bool { dx == 0 && dy == 0 }

    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        let a = try c.decode(Double.self), b = try c.decode(Double.self)
        guard a.isFinite, b.isFinite else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "offset") }
        dx = a; dy = b
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(dx); try c.encode(dy)
    }
}

/// 大きさが違うパーツ(例: 体より縦に長い髪)を、基準キャンバスの縦のどこに揃えて置くか。左右は常に中央。
/// 既定(ファイルに書かない)は下揃え。フォルダ取り込みは、パーツの大きさが違うとき中央揃えにする(実データの調査: DESIGN.md「立ち絵パーツの位置」)。
public enum PartAlignment: String, Codable, Equatable, CaseIterable, Sendable {
    case top, center, bottom
    public var label: String { switch self { case .top: return "上揃え"; case .center: return "中央揃え"; case .bottom: return "下揃え" } }
    /// パーツの高さ `h` を基準の高さ `base` に置くときの上端の位置(下に向かって正)。
    public func topY(base: Double, h: Double) -> Double {
        switch self { case .top: return 0; case .center: return (base - h) / 2; case .bottom: return base - h }
    }
}

public struct CharacterRig: Codable, Equatable {
    public static let eyeSlot = "目"
    public static let mouthSlot = "口"
    public static let standardOrder = ["体", "髪", "尻尾", "腕", "顔ベース", "頬", "眉", "目", "口", "エフェクト"]

    public var slots: [RigSlot]
    /// 目スロットの「まばたき(閉じた目)」の添字
    public var blink: Int?
    /// 口スロットの「閉じ」「開き」の添字
    public var mouthClosed: Int?
    public var mouthOpen: Int?
    /// 口スロットの あ・い・う・え・お(キー "a" "i" "u" "e" "o")の添字
    public var vowels: [String: Int]?
    /// 表情名 → (スロット名 → 添字)。セリフの先頭の [表情名] で切り替える。
    public var expressions: [String: [String: Int]]?
    /// パーツ画像のパス → 位置の補正。大きさの違うパーツのずれを直す。無い・ゼロは書かない。
    public var partOffsets: [String: PartOffset]?
    /// 大きさが違うパーツの縦の揃え方。nil = 下揃え(従来)。下揃えは書かない。
    public var alignment: PartAlignment?
    public var extra: [String: JSONValue] = [:]

    static let knownKeys: Set<String> = ["slots", "blink", "mouthClosed", "mouthOpen", "vowels", "expressions", "partOffsets", "alignment"]

    public var alignmentOrDefault: PartAlignment { alignment ?? .bottom }

    public init(slots: [RigSlot] = []) { self.slots = slots }

    public init(from decoder: Decoder) throws {
        let l = Lenient(c: try decoder.container(keyedBy: AnyKey.self), known: Self.knownKeys)
        slots = l.value("slots") ?? []
        extra = l.extra()   // 読めない形の既知キーは、下で extra に足す(先に集めないと上書きされる)
        blink = l.int("blink")
        mouthClosed = l.int("mouthClosed")
        mouthOpen = l.int("mouthOpen")
        vowels = l.value("vowels").flatMap { (d: [String: Int]) in d.isEmpty ? nil : d }
        expressions = l.value("expressions").flatMap { (d: [String: [String: Int]]) in d.isEmpty ? nil : d }
        if let raw: JSONValue = l.value("partOffsets") {
            if let d: [String: PartOffset] = l.value("partOffsets") {
                let nz = d.filter { !$0.value.isZero }
                partOffsets = nz.isEmpty ? nil : nz
            } else { extra["partOffsets"] = raw }   // 読めない形は捨てずに書き戻す
        }
        if let raw: JSONValue = l.value("alignment") {
            if let a: PartAlignment = l.value("alignment") { alignment = a == .bottom ? nil : a }
            else { extra["alignment"] = raw }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        for (k, v) in extra { try c.encode(v, forKey: AnyKey(k)) }
        try c.encode(slots, forKey: AnyKey("slots"))
        if let a = alignment, a != .bottom { try c.encode(a, forKey: AnyKey("alignment")) }
        try c.encodeIfPresent(blink, forKey: AnyKey("blink"))
        try c.encodeIfPresent(mouthClosed, forKey: AnyKey("mouthClosed"))
        try c.encodeIfPresent(mouthOpen, forKey: AnyKey("mouthOpen"))
        if let v = vowels, !v.isEmpty { try c.encode(v, forKey: AnyKey("vowels")) }
        if let e = expressions, !e.isEmpty { try c.encode(e, forKey: AnyKey("expressions")) }
        if let o = partOffsets?.filter({ !$0.value.isZero }), !o.isEmpty { try c.encode(o, forKey: AnyKey("partOffsets")) }
    }

    /// 描けるパーツが 1 つでもあるか。
    public var hasParts: Bool { slots.contains { !$0.parts.isEmpty } }

    public func slotIndex(_ name: String) -> Int? { slots.firstIndex { $0.name == name } }
    public func slot(_ name: String) -> RigSlot? { slotIndex(name).map { slots[$0] } }

    /// 画像のパスをすべて(未使用素材の判定などに使う)。
    public var allPaths: [String] { slots.flatMap(\.parts) }

    // MARK: 状態 → 各スロットの添字

    /// 表情・口・まばたきを重ねたときの、スロットごとの添字(`slots` と同じ並び)。
    /// 順序: スロットの選択 → 表情 → 口(話していなければ「閉じ」) → まばたき(目)。使えない添字は無視して、前の値のまま。
    public func resolvedActive(expression: String? = nil, mouth: RigMouth = .unchanged, blinking: Bool = false) -> [Int] {
        var act = slots.map(\.active)
        func set(_ name: String, _ idx: Int?) {
            guard let idx, let i = slotIndex(name), slots[i].isValid(idx) else { return }
            act[i] = idx
        }
        if let e = expression, let picks = expressions?[e] {
            for (name, idx) in picks { set(name, idx) }
        }
        switch mouth {
        case .unchanged: break
        case .closed: set(Self.mouthSlot, mouthClosed)
        case .open: set(Self.mouthSlot, mouthOpen)
        case .vowel(let k): set(Self.mouthSlot, vowels?[k] ?? mouthOpen)
        }
        if blinking { set(Self.eyeSlot, blink) }
        return act
    }

    /// `paths` の各パーツの位置の補正(無ければゼロ)。
    public func offsets(for paths: [String]) -> [PartOffset] { paths.map { partOffsets?[$0] ?? PartOffset() } }

    /// 重ねるパーツのパス(下から順)。
    /// 「体の後ろ」にしたスロットが先(一番下)、残りはスロットの並び順。
    public func paths(active: [Int]) -> [String] {
        var back: [String] = [], front: [String] = []
        for (i, s) in slots.enumerated() {
            let a = active.indices.contains(i) ? active[i] : s.active
            if s.parts.indices.contains(a), !s.parts[a].isEmpty {
                if s.isBehind { back.append(s.parts[a]) } else { front.append(s.parts[a]) }
            }
        }
        return back + front
    }

    // MARK: 編集(値を返すだけ。変わらなければ同じ値になる)

    /// 現在の選択を、名前つきの表情として取り込む(全スロットの添字)。
    public func capturedPicks() -> [String: Int] {
        var d: [String: Int] = [:]
        for s in slots { d[s.name] = s.active }
        return d
    }
}

// MARK: - 大きさ・並べ替え

public enum RigNaming {
    /// 数字を数として比べる並べ替え("(2)" < "(10)")。
    public static func naturalLess(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: [.numeric, .caseInsensitive, .widthInsensitive], range: nil, locale: Locale(identifier: "ja_JP")) == .orderedAscending
    }

    /// ファイル名(拡張子なし)から末尾の " (N)" や数字を除いた接頭辞。
    public static func prefix(of fileName: String) -> String {
        var s = (fileName as NSString).deletingPathExtension
        if let r = s.range(of: #"\s*[\(（]\s*[0-9０-９]+\s*[\)）][^\)）]*$"#, options: .regularExpression) { s.removeSubrange(r) }
        else if let r = s.range(of: #"[0-9０-９]+$"#, options: .regularExpression) { s.removeSubrange(r) }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// 名前に含まれる語から、標準のスロット名を決める(無ければ nil)。上にあるものを優先。
    /// 「体」は他の語がないときだけ。
    static let keywords: [(String, [String])] = [
        ("眉", ["眉", "まゆ", "brow"]),
        ("目", ["目", "瞳", "eye"]),
        ("口", ["口", "mouth"]),
        ("頬", ["頬", "ほほ", "cheek", "blush"]),
        ("髪", ["髪", "hair"]),
        ("尻尾", ["尻尾", "しっぽ", "シッポ", "tail"]),
        ("腕", ["腕", "手", "arm", "hand"]),
        ("エフェクト", ["エフェクト", "effect"]),
        ("体", ["体", "身体", "body", "霊夢正面", "ver"]),
    ]

    public static func slotName(for text: String) -> String? {
        let t = text.lowercased()
        for (slot, words) in keywords where words.contains(where: { t.contains($0) }) { return slot }
        return nil
    }

    /// ファイル名が「後ろ・奥」のパーツを指すか(後ろ髪など)。
    public static func isBackPart(_ fileName: String) -> Bool {
        let t = fileName.lowercased()
        return ["後ろ", "後髪", "うしろ", "奥", "back"].contains { t.contains($0) } && !t.contains("背面")
    }

    /// 標準の並びでの順位(標準にないスロットは最後、名前順)。
    public static func order(_ name: String) -> Int { CharacterRig.standardOrder.firstIndex(of: name) ?? CharacterRig.standardOrder.count }
}

// MARK: - フォルダ・ファイルの取り込み(振り分け)

public enum RigFolderImporter {
    public struct Report: Equatable {
        public var rig: CharacterRig
        /// 画像の大きさ(全スロット共通)
        public var width: Int
        public var height: Int
        /// 大きさが違って使わなかった画像
        public var skippedSize: [String]
        /// どのスロットにも振り分けられなかった画像の数
        public var unclassified: Int
        public var notes: [String]
    }

    static let imageExts: Set<String> = ["png", "webp"]

    /// 画像の大きさ(読み込まずに知る)。
    public static func imageSize(_ path: String) -> (w: Int, h: Int)? {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (w, h)
    }

    /// フォルダ(下の階層も)の画像を、ファイル名・フォルダ名の語でスロットに分ける。
    /// 同じ大きさの画像だけを使う(眉・目・口が最も多い大きさに揃える)。ヒューリスティックなので、あとでインスペクタで直せる。
    public static func scan(folder: URL, maxDepth: Int = 2, sizeOf: (String) -> (w: Int, h: Int)? = imageSize) -> Report? {
        let fm = FileManager.default
        var files: [(path: String, parent: String)] = []
        func walk(_ dir: URL, depth: Int) {
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return }
            for u in items {
                let isDir = (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDir { if depth < maxDepth { walk(u, depth: depth + 1) } }
                else if imageExts.contains(u.pathExtension.lowercased()) { files.append((u.path, dir.lastPathComponent)) }
            }
        }
        walk(folder, depth: 0)
        return group(files: files, sizeOf: sizeOf)
    }

    /// 大きさのグループ 1 つ(= 別の立ち絵素材 1 つ)。
    public struct SizeGroup: Equatable {
        public var name: String
        public var width: Int
        public var height: Int
        /// このグループの画像の数(使う・使わないを問わず、大きさがこのグループに属するもの)
        public var imageCount: Int
        public var report: Report
    }

    /// フォルダの画像を、キャンバスの大きさでグループに分け、グループごとに別のリグを作る(顔A系 2344×2500 と 体 3000×3000 は別の立ち絵素材)。
    /// グループの並びは、眉・目・口が多い順(最初が `scan` と同じ基準の大きさ)。パーツを作れないグループは含めない。
    public static func scanGroups(folder: URL, maxDepth: Int = 2, sizeOf: (String) -> (w: Int, h: Int)? = imageSize) -> [SizeGroup] {
        let fm = FileManager.default
        var files: [(path: String, parent: String)] = []
        func walk(_ dir: URL, depth: Int) {
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return }
            for u in items {
                let isDir = (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDir { if depth < maxDepth { walk(u, depth: depth + 1) } }
                else if imageExts.contains(u.pathExtension.lowercased()) { files.append((u.path, dir.lastPathComponent)) }
            }
        }
        walk(folder, depth: 0)
        return groups(files: files, rootName: folder.lastPathComponent, sizeOf: sizeOf)
    }

    /// 同じ幅で高さが基準の 1/6 以内の画像は同じグループ(体より縦に長い髪は体と同じグループ)。テスト用に分けてある。
    static func groups(files: [(path: String, parent: String)], rootName: String, sizeOf: (String) -> (w: Int, h: Int)?) -> [SizeGroup] {
        struct F { var file: (path: String, parent: String); var size: (w: Int, h: Int); var isFace: Bool }
        var all: [F] = []
        for f in files {
            guard let sz = sizeOf(f.path), sz.w > 0, sz.h > 0 else { continue }
            let base = ((f.path as NSString).lastPathComponent as NSString).deletingPathExtension
            if base.contains("加工用") { continue }
            let slot: String? = (base.contains("顔") && base.contains("体")) ? nil : RigNaming.slotName(for: base) ?? (RigNaming.prefix(of: base) == base ? nil : RigNaming.slotName(for: f.parent))
            all.append(F(file: f, size: sz, isFace: slot == "眉" || slot == "目" || slot == "口"))
        }
        // 大きさごとの数 → 種になる順(顔のパーツが多い、次に枚数が多い、次に面積が大きい)
        var bySize: [String: [F]] = [:]
        for f in all { bySize["\(f.size.w)x\(f.size.h)", default: []].append(f) }
        let order = bySize.values.sorted { a, b in
            let fa = a.filter(\.isFace).count, fb = b.filter(\.isFace).count
            if fa != fb { return fa > fb }
            if a.count != b.count { return a.count > b.count }
            return a[0].size.w * a[0].size.h > b[0].size.w * b[0].size.h
        }
        var taken: Set<String> = []
        var out: [SizeGroup] = []
        var clusters: [(base: (w: Int, h: Int), members: [F])] = []
        for seedList in order {
            let key = "\(seedList[0].size.w)x\(seedList[0].size.h)"
            if taken.contains(key) { continue }
            let base = seedList[0].size
            var members: [F] = []
            for (k, list) in bySize where !taken.contains(k) {
                let sz = list[0].size
                if sz.w == base.w && abs(sz.h - base.h) * 6 <= base.h { members += list; taken.insert(k) }
            }
            clusters.append((base, members))
        }
        for cl in clusters {
            guard let rep = group(files: cl.members.map(\.file), sizeOf: sizeOf) else { continue }
            let parents = Set(cl.members.map(\.file.parent))
            out.append(SizeGroup(name: "", width: rep.width, height: rep.height, imageCount: cl.members.count, report: rep))
            // 名前: 1 グループだけならフォルダ名のまま。複数なら「フォルダ名 縦横」(全部が 1 つのサブフォルダにあるならその名前)
            if parents.count == 1, let p = parents.first, p != rootName { out[out.count - 1].name = "\(p) \(rep.width)×\(rep.height)" }
            else { out[out.count - 1].name = "\(rootName) \(rep.width)×\(rep.height)" }
        }
        if out.count == 1 { out[0].name = rootName }
        return out
    }

    /// 与えられた (パス, 親フォルダ名) の並びを振り分ける。テスト用に分けてある。
    static func group(files: [(path: String, parent: String)], sizeOf: (String) -> (w: Int, h: Int)?) -> Report? {
        struct Item { var path: String; var slot: String?; var prefix: String; var size: (w: Int, h: Int) }
        var items: [Item] = []
        for f in files {
            guard let sz = sizeOf(f.path), sz.w > 0, sz.h > 0 else { continue }
            let base = ((f.path as NSString).lastPathComponent as NSString).deletingPathExtension
            if base.contains("加工用") { continue }
            // 「顔A体A」のような完成した立ち絵は体として扱わない(顔のパーツと重ねると二重になる)。
            let slot: String?
            if base.contains("顔") && base.contains("体") { slot = nil }
            else { slot = RigNaming.slotName(for: base) ?? (RigNaming.prefix(of: base) == base ? nil : RigNaming.slotName(for: f.parent)) }
            items.append(Item(path: f.path, slot: slot, prefix: RigNaming.prefix(of: base), size: sz))
        }
        // 基準の大きさ: 眉・目・口の画像が最も多い大きさ(無ければ全体で最も多い大きさ)
        func dominant(_ list: [Item]) -> (w: Int, h: Int)? {
            var count: [String: (n: Int, sz: (w: Int, h: Int))] = [:]
            for it in list { let k = "\(it.size.w)x\(it.size.h)"; count[k] = ((count[k]?.n ?? 0) + 1, it.size) }
            return count.values.max { a, b in a.n != b.n ? a.n < b.n : a.sz.w * a.sz.h < b.sz.w * b.sz.h }?.sz
        }
        let faceItems = items.filter { $0.slot == "眉" || $0.slot == "目" || $0.slot == "口" }
        guard let base = dominant(faceItems.isEmpty ? items : faceItems) else { return nil }
        var skipped: [String] = []
        var bySlot: [String: [String]] = [:]
        var unclassified = 0
        for it in items {
            if it.size.w != base.w || abs(it.size.h - base.h) * 6 > base.h { skipped.append((it.path as NSString).lastPathComponent); continue }
            if let s = it.slot { bySlot[s, default: []].append(it.path) }
            else { unclassified += 1 }
        }
        // 振り分けられなかったもの: 同じ接頭辞が 2 枚以上あれば、その接頭辞を名前にした自由なスロット
        var free: [String: [String]] = [:]
        for it in items where it.slot == nil && it.size.w == base.w && abs(it.size.h - base.h) * 6 <= base.h && !it.prefix.isEmpty {
            free[it.prefix, default: []].append(it.path)
        }
        for (k, v) in free where v.count >= 2 { bySlot[k] = v; unclassified -= v.count }
        guard !bySlot.isEmpty else { return nil }
        var slots: [RigSlot] = []
        for name in bySlot.keys.sorted(by: { (RigNaming.order($0), $0) < (RigNaming.order($1), $1) }) {
            var parts = bySlot[name] ?? []
            parts.sort { RigNaming.naturalLess(($0 as NSString).lastPathComponent, ($1 as NSString).lastPathComponent) }
            // 頬・髪(体に最初から髪がある)・エフェクトは初期では出さない
            let off = name == "頬" || name == "髪" || name == "エフェクト"
            slots.append(RigSlot(name: name, parts: parts, active: off ? -1 : 0))
        }
        var rig = CharacterRig(slots: slots)
        // 大きさが違うパーツ(体 3000×3000 に対して髪 3000×3200 など)は中央揃え。PSD(体の上下の余白がほぼ同じ)と同じ置き方になる
        let allSizes = items.filter { $0.size.w == base.w && abs($0.size.h - base.h) * 6 <= base.h }
        if allSizes.contains(where: { $0.size.w != base.w || $0.size.h != base.h }) { rig.alignment = .center }
        // 「後ろ髪」「奥の髪」のようなパーツだけのスロットは、体の後ろに置く
        for i in rig.slots.indices where rig.slots[i].name == "髪" && !rig.slots[i].parts.isEmpty
            && rig.slots[i].parts.allSatisfy({ RigNaming.isBackPart(($0 as NSString).lastPathComponent) }) { rig.slots[i].behindBody = true }
        var notes: [String] = []
        if !skipped.isEmpty { notes.append("大きさが違う画像 \(skipped.count) 枚は使っていません(基準 \(base.w)×\(base.h))") }
        RigHeuristics.guessRoles(&rig)
        // 大きさが違うパーツ(体より縦に長い髪など)の位置を、不透明な部分が基準キャンバスに収まるよう補正する
        rig = RigAlignment.applySuggestions(rig, base: base, canvas: sizeOf)
        return Report(rig: rig, width: base.w, height: base.h, skippedSize: skipped, unclassified: max(0, unclassified), notes: notes)
    }
}

// MARK: - 閉じた目・口の推測

public enum RigHeuristics {
    /// 不透明な画素の外接枠の位置・大きさ・面積(縮小した画像の画素。上が原点)と、縮小した画像の大きさ。何も描かれていなければ nil の枠(幅 0)。
    struct Scan { var minX: Int, minY: Int, w: Int, h: Int, area: Int, imageW: Int, imageH: Int }

    static func scan(_ path: String, maxPixel: Int) -> Scan? {
        guard let img = RigImageLoader.thumbnail(path, maxPixel: maxPixel) else { return nil }
        let w = img.width, h = img.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ok = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        var minX = w, maxX = -1, minY = h, maxY = -1, area = 0
        for y in 0..<h {
            for x in 0..<w where px[(y * w + x) * 4 + 3] > 24 {
                area += 1
                if x < minX { minX = x }; if x > maxX { maxX = x }
                if y < minY { minY = y }; if y > maxY { maxY = y }
            }
        }
        guard maxX >= 0 else { return Scan(minX: 0, minY: 0, w: 0, h: 0, area: 0, imageW: w, imageH: h) }
        return Scan(minX: minX, minY: minY, w: maxX - minX + 1, h: maxY - minY + 1, area: area, imageW: w, imageH: h)
    }

    /// 不透明な画素の外接枠(正規化前の画素)。小さく読んで数えるので速い。
    public static func opaqueBox(_ path: String, maxPixel: Int = 192) -> (w: Int, h: Int, area: Int)? {
        scan(path, maxPixel: maxPixel).map { ($0.w, $0.h, $0.area) }
    }

    /// 不透明な画素の外接枠を、画像全体に対する割合(0〜1、上が原点)で返す。何も描かれていなければ nil。
    public static func opaqueFraction(_ path: String, maxPixel: Int = 384) -> CGRect? {
        guard let s = scan(path, maxPixel: maxPixel), s.w > 0 else { return nil }
        return CGRect(x: Double(s.minX) / Double(s.imageW), y: Double(s.minY) / Double(s.imageH),
                      width: Double(s.w) / Double(s.imageW), height: Double(s.h) / Double(s.imageH))
    }

    /// 閉じた目・閉じた口・開いた口を推測する(自信が無いときは何も設定しない)。
    /// - まばたき: 目スロットのうち、両目ぶんの幅がある(幅が中央値の 6 割以上)画像で、不透明な面積が最も小さいもの
    ///   (開いた目より閉じた目の方が面積が小さい)。候補が 2 つ以上あり、最小が中央値の 9 割未満のときだけ。
    /// - 口: 閉じ = 描かれている画像で面積が最小、開き・「あ」= 面積が最大(最大が最小の 1.5 倍を超えるときだけ)。
    public static func guessRoles(_ rig: inout CharacterRig, box: (String) -> (w: Int, h: Int, area: Int)? = { opaqueBox($0) }) {
        if let i = rig.slotIndex(CharacterRig.eyeSlot), rig.slots[i].parts.count >= 2 {
            let boxes = rig.slots[i].parts.map { box($0) }
            let areas = boxes.compactMap { $0 }.filter { $0.area > 0 }.map { Double($0.area) }.sorted()
            let medArea = areas.isEmpty ? 0 : areas[areas.count / 2]
            let ws = boxes.compactMap { $0 }.filter { $0.w > 0 }.map { Double($0.w) }.sorted()
            let medW = ws.isEmpty ? 0 : ws[ws.count / 2]
            // ほぼ空(面積が中央値の 1 割ほど未満)の画像と、片目だけの細い画像は候補にしない
            let wide = boxes.indices.filter { (boxes[$0]?.h ?? 0) > 0 && Double(boxes[$0]?.area ?? 0) >= medArea * 0.12 && Double(boxes[$0]?.w ?? 0) >= medW * 0.6 }
            if wide.count >= 2, let minIdx = wide.min(by: { boxes[$0]!.area < boxes[$1]!.area }) {
                let wideAreas = wide.map { Double(boxes[$0]!.area) }.sorted()
                let median = wideAreas[wideAreas.count / 2]
                if median > 0, Double(boxes[minIdx]!.area) < median * 0.9 { rig.blink = minIdx }
            }
        }
        if let i = rig.slotIndex(CharacterRig.mouthSlot), rig.slots[i].parts.count >= 2 {
            let areas = rig.slots[i].parts.map { Double(box($0)?.area ?? 0) }
            if let lo = areas.indices.filter({ areas[$0] > 0 }).min(by: { areas[$0] < areas[$1] }),
               let hi = areas.indices.max(by: { areas[$0] < areas[$1] }), areas[hi] > areas[lo] * 1.5 {
                rig.mouthClosed = lo
                rig.mouthOpen = hi
                // 「あ」= 最も大きく開いた口。あいうえおの他の母音は、割り当てるまで「開き」で代用される
                var v = rig.vowels ?? [:]
                if v["a"] == nil { v["a"] = hi }
                rig.vowels = v
            }
        }
    }
}

// MARK: - 大きさが違うパーツの位置合わせ

public enum RigAlignment {
    /// 基準より大きさが違うパーツの位置の補正を推測する。
    /// 既定の置き方(リグの揃え方。下揃えと左右の中央が従来)でパーツの不透明な部分が基準キャンバスからはみ出すとき、はみ出さない最小の移動量を返す
    /// (大きさが同じパーツ・はみ出さないパーツは含めない)。不透明な部分は縮小画像で測るので、誤差は数画素〜十数画素。
    /// - Parameters:
    ///   - canvas: パーツの元の大きさ(画素)
    ///   - opaque: 不透明な部分の外接枠(パーツの大きさに対する割合、上が原点)。描かれていなければ nil
    public static func suggestOffsets(for rig: CharacterRig, base: (w: Int, h: Int),
                                      canvas: (String) -> (w: Int, h: Int)? = RigFolderImporter.imageSize,
                                      opaque: (String) -> CGRect? = { RigHeuristics.opaqueFraction($0) }) -> [String: PartOffset] {
        var out: [String: PartOffset] = [:]
        for path in rig.allPaths where !path.isEmpty && out[path] == nil {
            guard let size = canvas(path), size.w != base.w || size.h != base.h, let f = opaque(path) else { continue }
            // 既定の置き方での左上(基準キャンバスの画素)
            let x0 = (Double(base.w) - Double(size.w)) / 2, y0 = rig.alignmentOrDefault.topY(base: Double(base.h), h: Double(size.h))
            let left = x0 + f.minX * Double(size.w), right = x0 + f.maxX * Double(size.w)
            let top = y0 + f.minY * Double(size.h), bottom = y0 + f.maxY * Double(size.h)
            func shift(_ lo: Double, _ hi: Double, _ limit: Double) -> Double {
                if hi - lo > limit { return 0 }   // キャンバスより大きく描かれているときは動かさない
                if lo < 0 { return -lo }
                if hi > limit { return limit - hi }
                return 0
            }
            let off = PartOffset(dx: shift(left, right, Double(base.w)).rounded(), dy: shift(top, bottom, Double(base.h)).rounded())
            if !off.isZero { out[path] = off }
        }
        return out
    }

    /// リグにパーツの位置の補正を推測して入れる(既に手で決めた補正は残す)。変わらなければ入力と同じ値。
    public static func applySuggestions(_ rig: CharacterRig, base: (w: Int, h: Int),
                                        canvas: (String) -> (w: Int, h: Int)? = RigFolderImporter.imageSize,
                                        opaque: (String) -> CGRect? = { RigHeuristics.opaqueFraction($0) }) -> CharacterRig {
        let s = suggestOffsets(for: rig, base: base, canvas: canvas, opaque: opaque)
        guard !s.isEmpty else { return rig }
        var r = rig
        var o = r.partOffsets ?? [:]
        for (k, v) in s where o[k] == nil { o[k] = v }
        r.partOffsets = o
        return r == rig ? rig : r
    }
}

// MARK: - 編集の純粋関数(アプリのモデルから呼ぶ。変わらなければ入力と同じ値を返す)

public enum RigEditing {
    /// スロットの選択を変える。使えない添字・同じ値のときは変えない。
    public static func select(_ rig: CharacterRig, slot: String, index: Int) -> CharacterRig {
        guard let i = rig.slotIndex(slot), rig.slots[i].isValid(index), rig.slots[i].active != index else { return rig }
        var r = rig; r.slots[i].active = index; return r
    }

    /// 大きさが違うパーツの縦の揃え方を変える。同じ値のときは変えない(下揃えは「未設定」に戻す)。
    public static func setAlignment(_ rig: CharacterRig, _ a: PartAlignment) -> CharacterRig {
        let new: PartAlignment? = a == .bottom ? nil : a
        guard rig.alignment != new else { return rig }
        var r = rig; r.alignment = new; return r
    }

    /// スロットを体の後ろ(一番下)に置くか。無いスロット・同じ値のときは変えない。
    public static func setSlotBehind(_ rig: CharacterRig, slot: String, behind: Bool) -> CharacterRig {
        guard let i = rig.slotIndex(slot), rig.slots[i].isBehind != behind else { return rig }
        var r = rig; r.slots[i].behindBody = behind ? true : nil; return r
    }

    /// 「これをまばたき」: 目スロットの今の選択を閉じた目にする。選択なし(-1)・同じ値のときは変えない。
    public static func assignBlink(_ rig: CharacterRig) -> CharacterRig {
        guard let s = rig.slot(CharacterRig.eyeSlot), s.active >= 0, rig.blink != s.active else { return rig }
        var r = rig; r.blink = s.active; return r
    }

    public static func clearBlink(_ rig: CharacterRig) -> CharacterRig {
        guard rig.blink != nil else { return rig }
        var r = rig; r.blink = nil; return r
    }

    /// 口の割り当て: "closed" "open" "a" "i" "u" "e" "o" に、口スロットの今の選択を割り当てる(nil = 外す)。
    public static func assignMouth(_ rig: CharacterRig, role: String, use: Bool = true) -> CharacterRig {
        var r = rig
        guard let s = rig.slot(CharacterRig.mouthSlot) else { return rig }
        let idx: Int? = use ? (s.active >= 0 ? s.active : nil) : nil
        if use && idx == nil { return rig }
        switch role {
        case "closed": r.mouthClosed = idx
        case "open": r.mouthOpen = idx
        case "a", "i", "u", "e", "o":
            var v = r.vowels ?? [:]
            if let idx { v[role] = idx } else { v.removeValue(forKey: role) }
            r.vowels = v.isEmpty ? nil : v
        default: return rig
        }
        return r == rig ? rig : r
    }

    /// 表情を今の選択で追加(同名は上書き)。名前が使えない(空・[ ])ときは変えない。
    public static func captureExpression(_ rig: CharacterRig, name: String) -> CharacterRig {
        let key = name.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !key.contains("["), !key.contains("]") else { return rig }
        var r = rig
        var d = r.expressions ?? [:]
        d[key] = rig.capturedPicks()
        r.expressions = d
        return r == rig ? rig : r
    }

    public static func renameExpression(_ rig: CharacterRig, from old: String, to new: String) -> CharacterRig {
        let key = new.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !key.contains("["), !key.contains("]"), key != old,
              let picks = rig.expressions?[old], rig.expressions?[key] == nil else { return rig }
        var r = rig
        var d = r.expressions ?? [:]
        d.removeValue(forKey: old); d[key] = picks
        r.expressions = d
        return r
    }

    public static func deleteExpression(_ rig: CharacterRig, name: String) -> CharacterRig {
        guard rig.expressions?[name] != nil else { return rig }
        var r = rig
        var d = r.expressions ?? [:]
        d.removeValue(forKey: name)
        r.expressions = d.isEmpty ? nil : d
        return r
    }

    /// 表情を選んで、その表情の選択を各スロットの「今の選択」にする(使えない添字は無視)。
    public static func applyExpression(_ rig: CharacterRig, name: String) -> CharacterRig {
        guard let picks = rig.expressions?[name] else { return rig }
        var r = rig
        for (slot, idx) in picks { if let i = r.slotIndex(slot), r.slots[i].isValid(idx) { r.slots[i].active = idx } }
        return r == rig ? rig : r
    }
}

// MARK: - 先読み(初回のパーツ使用の 25〜40ms のカクつきをなくす)

public enum RigPrewarm {
    /// 再生中に出てくる状態の組み合わせ(スロットごとの添字)。同じ組み合わせは 1 つにまとめる。
    /// 優先順: 今の選択(口は閉じ)→ 口の開き・あいうえお → まばたき(口と組み合わせ)→ 表情(閉じ・開き)。
    public static func combinations(of rig: CharacterRig, limit: Int = 24) -> [[Int]] {
        var mouths: [RigMouth] = [.closed]
        if rig.mouthOpen != nil { mouths.append(.open) }
        for k in ["a", "i", "u", "e", "o"] where rig.vowels?[k] != nil { mouths.append(.vowel(k)) }
        var out: [[Int]] = []
        var seen: Set<[Int]> = []
        func add(_ a: [Int]) { if out.count < limit, seen.insert(a).inserted { out.append(a) } }
        for m in mouths { add(rig.resolvedActive(mouth: m)) }
        if rig.blink != nil { for m in mouths { add(rig.resolvedActive(mouth: m, blinking: true)) } }
        for e in (rig.expressions ?? [:]).keys.sorted() {
            for m in [RigMouth.closed, .open] { add(rig.resolvedActive(expression: e, mouth: m)) }
        }
        return out
    }
}

public extension RigFrameCache {
    /// リグの主な状態(上の組み合わせ)のパーツを読み、高さ `height` の立ち絵を合成してキャッシュに入れる。背景のキューから呼ぶ(同期処理)。
    /// 描画側が `frame(paths:height:offsets:alignment:)` を同じ引数で呼ぶので、初回に読み込み・合成を待たなくなる。作った枚数を返す。
    @discardableResult
    func prewarm(rig: CharacterRig, height: Int, limit: Int = 24) -> Int {
        guard rig.hasParts, height > 0 else { return 0 }
        var n = 0
        for act in RigPrewarm.combinations(of: rig, limit: limit) {
            let paths = rig.paths(active: act)
            let before = composeCount
            if frame(paths: paths, height: height, offsets: rig.offsets(for: paths), alignment: rig.alignmentOrDefault) != nil, composeCount > before { n += 1 }
        }
        return n
    }
}

// MARK: - 画像の読み込みと合成のキャッシュ

public enum RigImageLoader {
    /// 長辺が maxPixel 以下になるよう縮めて読む(大きな PNG を原寸で保持しない)。
    public static func thumbnail(_ path: String, maxPixel: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixel),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }
}

/// パーツの画像と、合成した立ち絵のキャッシュ。合成は「重ねるパーツの並び + 高さ」ごとに 1 枚。スレッドセーフ。
public final class RigFrameCache {
    private let lock = NSLock()
    private var parts: [String: CGImage] = [:]
    private var partOrder: [String] = []
    private var frames: [String: CGImage] = [:]
    private var frameOrder: [String] = []
    private var sizes: [String: (w: Int, h: Int)] = [:]
    private var missing: Set<String> = []
    public var partLimit = 64
    public var frameLimit = 32
    /// テスト・計測用: 合成を実際に行った回数 / パーツを読んだ回数
    public private(set) var composeCount = 0
    public private(set) var loadCount = 0

    public init() {}

    public var cachedFrameCount: Int { lock.lock(); defer { lock.unlock() }; return frames.count }

    public func removeAll() {
        lock.lock(); defer { lock.unlock() }
        parts = [:]; partOrder = []; frames = [:]; frameOrder = []; sizes = [:]; missing = []
    }

    /// 高さ `height` の立ち絵(重ねるパス = 下から順)。パーツが 1 枚も読めなければ nil。
    /// 画像の大きさは最初に読めたパーツのもの。他のパーツは同じ大きさに合わせて描く。
    /// `offsets` は `paths` と同じ並びの位置の補正(基準キャンバスの画素単位、右・下が正)。空(または全部ゼロ)なら従来の置き方。
    public func frame(paths: [String], height: Int, offsets: [PartOffset] = [], alignment: PartAlignment = .bottom) -> CGImage? {
        guard !paths.isEmpty, height > 0 else { return nil }
        let offs = offsets.count == paths.count && offsets.contains(where: { !$0.isZero }) ? offsets : []
        var key = paths.joined(separator: "\u{1f}") + "\u{1e}\(height)"
        if !offs.isEmpty { key += "\u{1e}" + offs.map { "\($0.dx),\($0.dy)" }.joined(separator: ";") }
        if alignment != .bottom { key += "\u{1e}" + alignment.rawValue }
        lock.lock()
        if let f = frames[key] { touch(&frameOrder, key); lock.unlock(); return f }
        lock.unlock()

        guard let first = paths.compactMap({ nativeSize($0) }).first else { return nil }
        let scale = min(1.0, Double(height) / Double(first.h))
        let cw = max(1, Int((Double(first.w) * scale).rounded())), ch = max(1, Int((Double(first.h) * scale).rounded()))
        guard let ctx = CGContext(data: nil, width: cw, height: ch, bitsPerComponent: 8, bytesPerRow: cw * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        var drew = false
        for (pi, p) in paths.enumerated() {
            // 読む大きさは、そのパーツを描く大きさ(基準より大きいパーツを縮めすぎて、描くときに引き伸ばさない)
            let pm = nativeSize(p).map { Int((Double(max($0.w, $0.h)) * scale).rounded(.up)) } ?? max(cw, ch)
            guard let img = part(p, maxPixel: max(cw, ch, pm)) else { continue }
            // 大きさが違うパーツ(同じ幅で高さだけ違う など)は拡大縮小せず、左右は中央・縦は `alignment`(既定は下)に揃えて置く
            var rect = CGRect(x: 0, y: 0, width: cw, height: ch)
            if let ns = nativeSize(p), ns.w != first.w || ns.h != first.h {
                let pw = Double(ns.w) * scale, ph = Double(ns.h) * scale
                // CGContext は下が原点: 上端の位置 topY から、下端の y = ch - topY - ph
                rect = CGRect(x: (Double(cw) - pw) / 2, y: Double(ch) - alignment.topY(base: Double(ch), h: ph) - ph, width: pw, height: ph)
            }
            if !offs.isEmpty {
                // 補正は基準キャンバスの画素単位。縮小して使うので scale を掛ける(CGContext は下が原点なので y は逆向き)
                rect = rect.offsetBy(dx: offs[pi].dx * scale, dy: -offs[pi].dy * scale)
            }
            ctx.draw(img, in: rect)
            drew = true
        }
        guard drew, let out = ctx.makeImage() else { return nil }
        lock.lock()
        composeCount += 1
        frames[key] = out; touch(&frameOrder, key)
        while frameOrder.count > frameLimit { frames.removeValue(forKey: frameOrder.removeFirst()) }
        lock.unlock()
        return out
    }

    private func touch(_ order: inout [String], _ key: String) {
        if let i = order.firstIndex(of: key) { order.remove(at: i) }
        order.append(key)
    }

    func nativeSize(_ path: String) -> (w: Int, h: Int)? {
        lock.lock()
        if let s = sizes[path] { lock.unlock(); return s }
        if missing.contains(path) { lock.unlock(); return nil }
        lock.unlock()
        let s = RigFolderImporter.imageSize(path)
        lock.lock(); defer { lock.unlock() }
        if let s { sizes[path] = s } else { missing.insert(path) }
        return s
    }

    private func part(_ path: String, maxPixel: Int) -> CGImage? {
        let key = "\(path)\u{1e}\(maxPixel)"
        lock.lock()
        if let p = parts[key] { touch(&partOrder, key); lock.unlock(); return p }
        if missing.contains(path) { lock.unlock(); return nil }
        lock.unlock()
        let img = RigImageLoader.thumbnail(path, maxPixel: maxPixel)
        lock.lock(); defer { lock.unlock() }
        guard let img else { missing.insert(path); return nil }
        loadCount += 1
        parts[key] = img; touch(&partOrder, key)
        while partOrder.count > partLimit { parts.removeValue(forKey: partOrder.removeFirst()) }
        return img
    }
}

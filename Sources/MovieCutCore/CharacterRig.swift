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
    public var extra: [String: JSONValue] = [:]

    static let knownKeys: Set<String> = ["name", "parts", "active"]

    public init(name: String, parts: [String] = [], active: Int = 0) {
        self.name = name; self.parts = parts; self.active = active
    }

    public init(from decoder: Decoder) throws {
        let l = Lenient(c: try decoder.container(keyedBy: AnyKey.self), known: Self.knownKeys)
        name = l.string("name") ?? ""
        parts = l.value("parts") ?? []
        active = l.int("active") ?? 0
        extra = l.extra()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        for (k, v) in extra { try c.encode(v, forKey: AnyKey(k)) }
        try c.encode(name, forKey: AnyKey("name"))
        try c.encode(parts, forKey: AnyKey("parts"))
        try c.encode(active, forKey: AnyKey("active"))
    }

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
    public var extra: [String: JSONValue] = [:]

    static let knownKeys: Set<String> = ["slots", "blink", "mouthClosed", "mouthOpen", "vowels", "expressions"]

    public init(slots: [RigSlot] = []) { self.slots = slots }

    public init(from decoder: Decoder) throws {
        let l = Lenient(c: try decoder.container(keyedBy: AnyKey.self), known: Self.knownKeys)
        slots = l.value("slots") ?? []
        blink = l.int("blink")
        mouthClosed = l.int("mouthClosed")
        mouthOpen = l.int("mouthOpen")
        vowels = l.value("vowels").flatMap { (d: [String: Int]) in d.isEmpty ? nil : d }
        expressions = l.value("expressions").flatMap { (d: [String: [String: Int]]) in d.isEmpty ? nil : d }
        extra = l.extra()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        for (k, v) in extra { try c.encode(v, forKey: AnyKey(k)) }
        try c.encode(slots, forKey: AnyKey("slots"))
        try c.encodeIfPresent(blink, forKey: AnyKey("blink"))
        try c.encodeIfPresent(mouthClosed, forKey: AnyKey("mouthClosed"))
        try c.encodeIfPresent(mouthOpen, forKey: AnyKey("mouthOpen"))
        if let v = vowels, !v.isEmpty { try c.encode(v, forKey: AnyKey("vowels")) }
        if let e = expressions, !e.isEmpty { try c.encode(e, forKey: AnyKey("expressions")) }
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

    /// 重ねるパーツのパス(下から順)。
    public func paths(active: [Int]) -> [String] {
        var out: [String] = []
        for (i, s) in slots.enumerated() {
            let a = active.indices.contains(i) ? active[i] : s.active
            if s.parts.indices.contains(a), !s.parts[a].isEmpty { out.append(s.parts[a]) }
        }
        return out
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
        var notes: [String] = []
        if !skipped.isEmpty { notes.append("大きさが違う画像 \(skipped.count) 枚は使っていません(基準 \(base.w)×\(base.h))") }
        RigHeuristics.guessRoles(&rig)
        return Report(rig: rig, width: base.w, height: base.h, skippedSize: skipped, unclassified: max(0, unclassified), notes: notes)
    }
}

// MARK: - 閉じた目・口の推測

public enum RigHeuristics {
    /// 不透明な画素の外接枠(正規化前の画素)。小さく読んで数えるので速い。
    public static func opaqueBox(_ path: String, maxPixel: Int = 192) -> (w: Int, h: Int, area: Int)? {
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
        guard maxX >= 0 else { return (0, 0, 0) }
        return (maxX - minX + 1, maxY - minY + 1, area)
    }

    /// 閉じた目(外接枠の高さが小さいもの)、閉じた口(面積が小さいもの)、開いた口(面積が大きいもの)を推測する。
    /// 自信が無い(差が小さい)ときは何も設定しない。
    public static func guessRoles(_ rig: inout CharacterRig, box: (String) -> (w: Int, h: Int, area: Int)? = { opaqueBox($0) }) {
        if let i = rig.slotIndex(CharacterRig.eyeSlot), rig.slots[i].parts.count >= 2 {
            // 何も描かれていない画像(高さ 0)は除く。残りの中で外接枠が極端に低いものを閉じた目とみなす
            let boxes = rig.slots[i].parts.map { box($0) }
            let areas = boxes.compactMap { $0 }.filter { $0.area > 0 }.map { Double($0.area) }.sorted()
            let medArea = areas.isEmpty ? 0 : areas[areas.count / 2]
            // ほぼ空(面積が中央値の 1 割ほど未満)の画像は目ではないので除く
            let ws = boxes.compactMap { $0 }.filter { $0.w > 0 }.map { Double($0.w) }.sorted()
            let medW = ws.isEmpty ? 0 : ws[ws.count / 2]
            // 両目ぶんの幅がある(中央値の 6 割以上)ことも条件にする
            let drawn = boxes.indices.filter { (boxes[$0]?.h ?? 0) > 0 && Double(boxes[$0]?.area ?? 0) >= medArea * 0.12 && Double(boxes[$0]?.w ?? 0) >= medW * 0.6 }
            let heights = drawn.map { Double(boxes[$0]!.h) }.sorted()
            if let minIdx = drawn.min(by: { boxes[$0]!.h < boxes[$1]!.h }), heights.count >= 2 {
                let median = heights[heights.count / 2]
                if median > 0, Double(boxes[minIdx]!.h) < median * 0.6 { rig.blink = minIdx }
            }
        }
        if let i = rig.slotIndex(CharacterRig.mouthSlot), rig.slots[i].parts.count >= 2 {
            let areas = rig.slots[i].parts.map { Double(box($0)?.area ?? 0) }
            if let lo = areas.indices.filter({ areas[$0] > 0 }).min(by: { areas[$0] < areas[$1] }),
               let hi = areas.indices.max(by: { areas[$0] < areas[$1] }), areas[hi] > areas[lo] * 1.5 {
                rig.mouthClosed = lo
                rig.mouthOpen = hi
            }
        }
    }
}

// MARK: - 編集の純粋関数(アプリのモデルから呼ぶ。変わらなければ入力と同じ値を返す)

public enum RigEditing {
    /// スロットの選択を変える。使えない添字・同じ値のときは変えない。
    public static func select(_ rig: CharacterRig, slot: String, index: Int) -> CharacterRig {
        guard let i = rig.slotIndex(slot), rig.slots[i].isValid(index), rig.slots[i].active != index else { return rig }
        var r = rig; r.slots[i].active = index; return r
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
    public func frame(paths: [String], height: Int) -> CGImage? {
        guard !paths.isEmpty, height > 0 else { return nil }
        let key = paths.joined(separator: "\u{1f}") + "\u{1e}\(height)"
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
        for p in paths {
            guard let img = part(p, maxPixel: max(cw, ch)) else { continue }
            // 大きさが違うパーツ(同じ幅で高さだけ違う など)は拡大縮小せず、下と左右の中央に揃えて置く(同じ立ち絵の別キャンバスは足元が揃っていることが多い)
            var rect = CGRect(x: 0, y: 0, width: cw, height: ch)
            if let ns = nativeSize(p), ns.w != first.w || ns.h != first.h {
                let pw = Double(ns.w) * scale, ph = Double(ns.h) * scale
                rect = CGRect(x: (Double(cw) - pw) / 2, y: 0, width: pw, height: ph)
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

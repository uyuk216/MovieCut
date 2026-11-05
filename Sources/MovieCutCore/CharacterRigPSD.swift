import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// PSD → パーツ式立ち絵。レイヤーのグループ名・レイヤー名の語(眉・目・口・頬・髪・体 など)でスロットに振り分け、
// 候補(1 枚のレイヤー、または見えるレイヤーをまとめたもの)ごとに「キャンバス全面の PNG」を書き出す。
// 最初に見えているものを初期の選択にする。ヒューリスティックなので、あとでインスペクタで直せる。

public enum RigPSDImporter {
    public struct Result {
        public var rig: CharacterRig
        public var width: Int
        public var height: Int
        public var notes: [String]
    }

    indirect enum Node {
        case leaf(Int)                                   // doc.layers の添字
        case group(name: String, visible: Bool, children: [Node])  // 子は下から上の順(ファイル順)
    }

    /// ファイル順(下から上)の記録から木を作る。グループは「終わりの印 … 開始の記録」で挟まれている。
    static func tree(_ doc: PSDDocument) -> [Node] {
        var stack: [[Node]] = [[]]
        for (i, l) in doc.layers.enumerated() {
            switch l.group {
            case .divider:
                stack.append([])
            case .openFolder, .closedFolder:
                let kids = stack.count > 1 ? stack.removeLast() : []
                stack[stack.count - 1].append(.group(name: l.name, visible: l.visible, children: kids))
            case .none:
                stack[stack.count - 1].append(.leaf(i))
            }
        }
        while stack.count > 1 { let k = stack.removeLast(); stack[stack.count - 1].append(contentsOf: k) }
        return stack[0]
    }

    static func leaves(_ n: Node) -> [Int] {
        switch n {
        case .leaf(let i): return [i]
        case .group(_, _, let kids): return kids.flatMap(leaves)
        }
    }

    static func names(_ n: Node, _ doc: PSDDocument) -> [String] {
        switch n {
        case .leaf(let i): return [doc.layers[i].name]
        case .group(let name, _, let kids): return [name] + kids.flatMap { names($0, doc) }
        }
    }

    /// 自分の名前、無ければ中のレイヤー名が指すスロット(1 種類だけのとき)で決める。
    static func classify(_ n: Node, _ doc: PSDDocument) -> String? {
        let own: String
        switch n {
        case .leaf(let i): own = doc.layers[i].name
        case .group(let name, _, _): own = name
        }
        if let s = RigNaming.slotName(for: own) { return s }
        var votes: [String: Int] = [:]
        for nm in names(n, doc) { if let s = RigNaming.slotName(for: nm) { votes[s, default: 0] += 1 } }
        // 中のレイヤー名が 1 種類のスロットだけを指すときに限る(眉・目・口を包むグループは決められない → 中を個別に見る)
        return votes.count == 1 ? votes.keys.first : nil
    }

    static let ignoredNames = ["用紙", "背景", "background", "paper", "下書き", "ガイド"]

    /// 1 つの候補 = 重ねるレイヤー(ファイル順)と、最初から見えているか。
    struct Candidate { var layers: [Int]; var visible: Bool; var label: String }

    /// スロットのグループの中身を候補に分ける。子のグループは、見えている中身が 1 枚以下なら「入れ替え用の候補の入れ物」として開き、
    /// 2 枚以上見えているなら 1 つの合成パーツとして扱う。
    static func candidates(of kids: [Node], doc: PSDDocument, groupVisible: Bool) -> [Candidate] {
        var out: [Candidate] = []
        for k in kids.reversed() {   // パネルの上から順
            switch k {
            case .leaf(let i):
                let l = doc.layers[i]
                if l.width * l.height <= 0 { continue }
                out.append(Candidate(layers: [i], visible: l.visible && groupVisible, label: l.name))
            case .group(let name, let vis, let sub):
                let ls = sub.flatMap(leaves).filter { doc.layers[$0].width * doc.layers[$0].height > 0 }
                if ls.isEmpty { continue }
                let visibleLeaves = ls.filter { doc.layers[$0].visible }
                if visibleLeaves.count >= 2 {
                    out.append(Candidate(layers: visibleLeaves, visible: vis && groupVisible, label: name))
                } else {
                    out += candidates(of: sub, doc: doc, groupVisible: vis && groupVisible)
                }
            }
        }
        return out
    }

    /// グループ(または葉)のキャンバス上の外接枠(位置の推測用)。
    static func bounds(_ n: Node, _ doc: PSDDocument) -> (top: Int, bottom: Int)? {
        let ls = leaves(n).map { doc.layers[$0] }.filter { $0.width * $0.height > 0 }
        guard let t = ls.map(\.top).min(), let b = ls.map(\.bottom).max() else { return nil }
        return (t, b)
    }

    // MARK: 本体

    public static func build(_ doc: PSDDocument, cacheDir: URL) throws -> Result {
        let fm = FileManager.default
        try fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        var notes: [String] = []
        let root = tree(doc)

        // スロット名 → 候補(パネルの上から順)
        var slotCands: [String: [Candidate]] = [:]
        var pending: [(node: Node, name: String)] = []   // 振り分けられなかった小さなグループ(位置で推測する)
        var freeCount = 0

        func take(_ nodes: [Node], depth: Int) {
            for n in nodes.reversed() {
                switch n {
                case .leaf(let i):
                    let l = doc.layers[i]
                    if l.width * l.height <= 0 { continue }
                    if ignoredNames.contains(where: { l.name.lowercased().contains($0) }) { continue }
                    let slot = RigNaming.slotName(for: l.name) ?? "体"
                    slotCands[slot, default: []].append(Candidate(layers: [i], visible: l.visible, label: l.name))
                case .group(let name, let vis, let kids):
                    if ignoredNames.contains(where: { name.lowercased().contains($0) }) { continue }
                    if let slot = classify(n, doc) {
                        slotCands[slot, default: []] += candidates(of: kids, doc: doc, groupVisible: vis)
                    } else if kids.contains(where: { if case .group = $0 { return true } else { return false } }), depth < 4 {
                        take(kids, depth: depth + 1)    // 入れ物のグループ: 中を個別に見る
                    } else {
                        pending.append((n, name))
                    }
                }
            }
        }
        take(root, depth: 0)

        // 名前で振り分けられなかったグループ: 目より上なら眉、下で口が無ければ口、それ以外は名前そのままのスロット
        let eyeBox = slotCands["目"].flatMap { c -> (top: Int, bottom: Int)? in
            let ls = c.flatMap(\.layers).map { doc.layers[$0] }
            guard let t = ls.map(\.top).min(), let b = ls.map(\.bottom).max() else { return nil }
            return (t, b)
        }
        for (n, name) in pending {
            guard let bb = bounds(n, doc), case .group(_, let vis, let kids) = n else { continue }
            let cands = candidates(of: kids, doc: doc, groupVisible: vis)
            if cands.isEmpty { continue }
            var slot: String
            if let eb = eyeBox, bb.bottom <= (eb.top + eb.bottom) / 2, slotCands["眉"] == nil { slot = "眉" }
            else if let eb = eyeBox, bb.top >= eb.bottom - 10, slotCands["口"] == nil { slot = "口" }
            else { freeCount += 1; slot = name }
            slotCands[slot, default: []] += cands
            if slot != name { notes.append("グループ「\(name)」を位置から「\(slot)」とみなしました") }
        }
        _ = freeCount

        guard !slotCands.isEmpty || doc.composite != nil else { throw PSDError.corrupt("立ち絵にできるレイヤーがありません") }

        // 画像を書く
        var slots: [RigSlot] = []
        var made = 0
        let names = slotCands.keys.sorted { (RigNaming.order($0), $0) < (RigNaming.order($1), $1) }
        for name in names {
            let cands = slotCands[name] ?? []
            var parts: [String] = []
            var active = -1
            for (k, c) in cands.enumerated() {
                let url = cacheDir.appendingPathComponent("\(safeName(name))-\(k + 1).png")
                if !fm.fileExists(atPath: url.path) || ((try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0) == 0 {
                    guard let img = renderCandidate(c, doc), writePNG(img, to: url) else { continue }
                    made += 1
                }
                parts.append(url.path)
                if active < 0, c.visible { active = parts.count - 1 }
            }
            if parts.isEmpty { continue }
            // 何も見えていないスロット: 体・眉・目・口は先頭を出す。それ以外は出さない
            if active < 0, ["体", "眉", "目", "口", "髪"].contains(name) { active = 0 }
            slots.append(RigSlot(name: name, parts: parts, active: active))
        }
        if slots.isEmpty, let comp = doc.composite, let img = PSDImporter.cgImage(comp) {
            let url = cacheDir.appendingPathComponent("merged.png")
            if writePNG(img, to: url) { slots = [RigSlot(name: "体", parts: [url.path], active: 0)] }
            notes.append("レイヤーを読めなかったため、統合画像 1 枚だけにしました")
        }
        guard !slots.isEmpty else { throw PSDError.corrupt("立ち絵の画像を書き出せませんでした") }
        var rig = CharacterRig(slots: slots)
        RigHeuristics.guessRoles(&rig)
        notes.insert("スロット: " + slots.map { "\($0.name)(\($0.parts.count))" }.joined(separator: " "), at: 0)
        _ = made
        return Result(rig: rig, width: doc.width, height: doc.height, notes: notes)
    }

    static func safeName(_ s: String) -> String {
        String(s.map { $0.isLetter || $0.isNumber ? $0 : "_" })
    }

    /// 候補のレイヤーをキャンバスの大きさに重ねた 1 枚(不透明度を反映)。
    static func renderCandidate(_ c: Candidate, _ doc: PSDDocument) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: doc.width, height: doc.height, bitsPerComponent: 8, bytesPerRow: doc.width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        for i in c.layers.sorted() {
            let l = doc.layers[i]
            guard !l.raster.isEmpty, let img = PSDImporter.cgImage(l.raster) else { continue }
            ctx.setAlpha(CGFloat(l.opacity) / 255)
            ctx.draw(img, in: CGRect(x: l.left, y: doc.height - l.top - l.height, width: l.width, height: l.height))
        }
        return ctx.makeImage()
    }

    static func writePNG(_ img: CGImage, to url: URL) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, img, nil)
        return CGImageDestinationFinalize(dest)
    }
}

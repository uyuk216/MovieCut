import Foundation
import CoreFoundation

// あいうえお口パク(B-7)の純粋ロジック。セリフの読み(ひらがな)を拍(モーラ)ごとの口の形にし、
// 音声の音量エンベロープに沿って 1/60 秒のコマへ割り当てる。画面も素材も持たず、同じ入力には必ず同じ結果を返す
// (プレビューと書き出しで同じ見た目になる)。

/// 口の形。`closed` は閉じた口(ん・っ・間・無音)。
public enum Viseme: String, CaseIterable, Codable {
    case closed, a, i, u, e, o

    /// 母音のキー(`Character.imgVowels` のキー)。閉じた口は nil。
    public var vowelKey: String? { self == .closed ? nil : rawValue }
}

public enum LipSync {
    public static let envelopeRate = 60.0

    // MARK: 読み → 口の形

    /// ひらがなの行ごとの母音(あ段〜お段の順)。
    private static let rows: [(String, [Viseme])] = [
        ("あいうえお", [.a, .i, .u, .e, .o]),
        ("かきくけこ", [.a, .i, .u, .e, .o]), ("がぎぐげご", [.a, .i, .u, .e, .o]),
        ("さしすせそ", [.a, .i, .u, .e, .o]), ("ざじずぜぞ", [.a, .i, .u, .e, .o]),
        ("たちつてと", [.a, .i, .u, .e, .o]), ("だぢづでど", [.a, .i, .u, .e, .o]),
        ("なにぬねの", [.a, .i, .u, .e, .o]),
        ("はひふへほ", [.a, .i, .u, .e, .o]), ("ばびぶべぼ", [.a, .i, .u, .e, .o]), ("ぱぴぷぺぽ", [.a, .i, .u, .e, .o]),
        ("まみむめも", [.a, .i, .u, .e, .o]),
        ("らりるれろ", [.a, .i, .u, .e, .o]),
        ("ゔ", [.u]), ("わ", [.a]), ("を", [.o]), ("ゐ", [.i]), ("ゑ", [.e]),
        ("や", [.a]), ("ゆ", [.u]), ("よ", [.o]),
    ]
    private static let vowelOfKana: [Swift.Character: Viseme] = {
        var d: [Swift.Character: Viseme] = [:]
        for (chars, vs) in rows { for (c, v) in zip(chars, vs) { d[c] = v } }
        return d
    }()
    /// 小さい文字(直前の拍に付く拗音は母音を置き換える)。
    private static let smallYouon: [Swift.Character: Viseme] = ["ゃ": .a, "ゅ": .u, "ょ": .o]
    private static let smallVowel: [Swift.Character: Viseme] = ["ぁ": .a, "ぃ": .i, "ぅ": .u, "ぇ": .e, "ぉ": .o]

    /// 文章を口の形の並び(1 拍 = 1 要素)にする。タグ `[名前]` は除く。
    /// ん・っ は閉じた口、ー は直前の母音の繰り返し(直前が閉じなら閉じ)、句読点・空白は短い間(閉じた口)。
    public static func moras(of text: String) -> [Viseme] {
        moras(ofHiragana: hiragana(of: ExpressionTag.body(text)))
    }

    public static func moras(ofHiragana s: String) -> [Viseme] {
        var out: [Viseme] = []
        var prev: Swift.Character? = nil
        let pureVowels = Set("あいうえお")
        for ch in s {
            defer { prev = ch }
            // 小さい文字は、直前が子音つきの仮名(き・ふ・て など)ならその拍の母音を置き換える。単独や あ行の直後なら 1 拍
            let small = smallYouon[ch] ?? smallVowel[ch]
            if let v = small {
                if let p = prev, vowelOfKana[p] != nil, !pureVowels.contains(p), !out.isEmpty { out[out.count - 1] = v }
                else { out.append(v) }
            }
            else if let v = vowelOfKana[ch] { out.append(v) }
            else if ch == "ん" || ch == "っ" { out.append(.closed) }
            else if ch == "ー" { out.append(out.last ?? .closed) }
            else if "、。,.，．　 \n!?！？…・".contains(ch) { if out.last != .closed { out.append(.closed) } }
            // それ以外(記号・読めない文字)は拍に数えない
        }
        // 先頭と末尾の間は不要(声は拍の位置で配るため、無音は音量で閉じる)
        while out.first == .closed { out.removeFirst() }
        while out.last == .closed { out.removeLast() }
        return out
    }

    /// 文章のひらがなの読み。漢字は形態素ごとにローマ字の読み(CFStringTokenizer)を通してひらがなへ。
    public static func hiragana(of text: String) -> String {
        let ns = text as NSString
        let tok = CFStringTokenizerCreate(nil, text as CFString, CFRangeMake(0, ns.length), kCFStringTokenizerUnitWordBoundary, Locale(identifier: "ja_JP") as CFLocale)
        var out = ""
        var last = 0
        func kana(_ s: String) -> String { s.applyingTransform(.hiraganaToKatakana, reverse: true) ?? s }
        while CFStringTokenizerAdvanceToNextToken(tok) != [] {
            let r = CFStringTokenizerGetCurrentTokenRange(tok)
            if r.location > last { out += kana(ns.substring(with: NSRange(location: last, length: r.location - last))) }
            let word = ns.substring(with: NSRange(location: r.location, length: r.length))
            if word.unicodeScalars.contains(where: { isKanji($0) }),
               let latin = CFStringTokenizerCopyCurrentTokenAttribute(tok, kCFStringTokenizerAttributeLatinTranscription) as? String,
               let h = latin.applyingTransform(.latinToHiragana, reverse: false) {
                out += h
            } else {
                out += kana(word)
            }
            last = r.location + r.length
        }
        if last < ns.length { out += kana(ns.substring(from: last)) }
        return out
    }

    private static func isKanji(_ u: Unicode.Scalar) -> Bool {
        (0x4E00...0x9FFF).contains(u.value) || (0x3400...0x4DBF).contains(u.value) || u.value == 0x3005
    }

    // MARK: 拍 × 音量 → コマごとの口の形

    /// 1/60 秒ごとの口の形。`range` はエンベロープの添字(クリップが使う範囲)。範囲の外・無音は閉じた口。
    /// 声が出ている(`MouthGate` で開いている)コマだけに、拍を音量の積算に比例して順に配る
    /// (音が大きい所ほど拍が速く進み、無音には拍を置かない)。拍が無ければ nil(従来の開閉に戻す)。
    public static func frames(moras: [Viseme], envelope: [Float], range: Range<Int>? = nil) -> [Viseme]? {
        guard !moras.isEmpty, !envelope.isEmpty else { return nil }
        let lo = max(0, range?.lowerBound ?? 0), hi = min(envelope.count, range?.upperBound ?? envelope.count)
        guard lo < hi else { return nil }
        let open = MouthGate.states(Array(envelope[lo..<hi]))
        var total = 0.0
        for (k, o) in open.enumerated() where o { total += Double(envelope[lo + k]) }
        var out = [Viseme](repeating: .closed, count: envelope.count)
        guard total > 0 else { return out }
        let n = Double(moras.count)
        var acc = 0.0
        for (k, o) in open.enumerated() where o {
            let e = Double(envelope[lo + k])
            let mid = acc + e / 2          // コマの中央までに積算した音量
            acc += e
            let idx = min(moras.count - 1, Int(mid / total * n))
            out[lo + k] = moras[idx]
        }
        return out
    }
}

import Foundation

// MARK: - 文字制御タグ(YMM4 互換の装飾タグ)
//
// テキスト文字列の中に埋め込む装飾タグを解釈する。仕様は YMM4 公式の
// 「文字制御タグを使用し、テキストの装飾や表示タイミングを制御する」に合わせる。
// - タグは保存形式ではない。本文テキスト内の記法としてだけ扱い、ファイル形式は変えない。
// - タグが無い文は `hasTags == false` で、呼び出し側は従来の描画経路をそのまま使う(描画結果は不変)。
// - 構文として不正なタグは、そのまま文字として表示する(落とさない)。
// - `<r>` `<w>` `<c>`(表示タイミング)は構文が合えば消費するが、効果は付けない
//   (MovieCut の文字アニメーションはクリップ単位の設定のため)。
// - 装飾種別(影/縁取りの種類、0-6 の数字)は解釈だけして描画では使わない
//   (MovieCut の装飾モデルに無い)。

/// 1 文字ぶんの実効スタイル(タグで変えた項目だけが非 nil / 非既定になる)。
public struct MarkupRunStyle: Equatable, Sendable {
    /// 文字色("#rrggbb")。
    public var color: String?
    /// 文字色の不透明度(8 桁指定のときだけ 1 未満になる)。
    public var colorAlpha: Double = 1
    /// 装飾色(縁の色)。
    public var outlineColor: String?
    public var outlineAlpha: Double = 1
    /// フォントサイズ(px、絶対値)。
    public var size: Double?
    public var fontName: String?
    public var bold: Bool?
    public var italic: Bool?
    public var underline: Bool = false
    public var strikethrough: Bool = false
    /// 字間(px)。`<ls>` で変えたときだけ非 nil。
    public var letterSpacing: Double?
    /// 座標オフセット(px、`<p>`/`<pp>` の累積値)。Y は下が正。
    public var offsetX: Double = 0
    public var offsetY: Double = 0
    /// 回転(度)。
    public var rotation: Double = 0

    public init() {}
    /// すべて既定(タグの影響なし)。
    public var isDefault: Bool {
        color == nil && outlineColor == nil && size == nil && fontName == nil && bold == nil && italic == nil
            && !underline && !strikethrough && letterSpacing == nil && offsetX == 0 && offsetY == 0 && rotation == 0
    }
}

/// スタイルの掛かる範囲。`range` はプレーンテキストの Character 位置(改行を含む通し番号、改行文字自体は含まない)。
public struct MarkupRun: Equatable, Sendable {
    public var range: Range<Int>
    public var style: MarkupRunStyle
    public init(range: Range<Int>, style: MarkupRunStyle) { self.range = range; self.style = style }
}

/// `<rb>` で指定されたルビ。範囲はプレーンテキストの Character 位置。
public struct MarkupRuby: Equatable, Sendable {
    public var start: Int
    public var end: Int
    public var reading: String
    /// 読みの大きさ(親文字に対する割合)。既定 0.5。
    public var sizeRatio: Double = RubyText.sizeRatio
    /// 読みの位置ずらし(px)。dy は下が正(YMM4 の例 `,,0,-5` = 5px 上)。
    public var dx: Double = 0
    public var dy: Double = 0
    public var fontName: String?
    public var bold: Bool?
    public var italic: Bool?
    public var color: String?
    public var outlineColor: String?

    public init(start: Int, end: Int, reading: String, sizeRatio: Double = RubyText.sizeRatio,
                dx: Double = 0, dy: Double = 0, fontName: String? = nil, bold: Bool? = nil, italic: Bool? = nil,
                color: String? = nil, outlineColor: String? = nil) {
        self.start = start; self.end = end; self.reading = reading; self.sizeRatio = sizeRatio
        self.dx = dx; self.dy = dy; self.fontName = fontName; self.bold = bold; self.italic = italic
        self.color = color; self.outlineColor = outlineColor
    }
}

/// パース結果。
public struct MarkupParsed: Equatable, Sendable {
    /// タグを取り除いた(ルビの親文字は含む)表示用の文。
    public var plain: String
    /// 既定でないスタイルの範囲(連続する同スタイルはまとめてある)。
    public var runs: [MarkupRun]
    public var rubies: [MarkupRuby]
    /// 有効なタグ(エスケープ含む)が 1 つでもあったか。false のとき plain は入力と同一。
    public var hasTags: Bool

    public init(plain: String, runs: [MarkupRun], rubies: [MarkupRuby], hasTags: Bool) {
        self.plain = plain; self.runs = runs; self.rubies = rubies; self.hasTags = hasTags
    }

    /// Character 位置ごとの実効スタイル(改行位置は既定)。描画側の便利関数。
    public func stylesByChar() -> [MarkupRunStyle] {
        var out = [MarkupRunStyle](repeating: MarkupRunStyle(), count: plain.count)
        for r in runs {
            for i in r.range where i >= 0 && i < out.count { out[i] = r.style }
        }
        return out
    }
}

public enum TextMarkup {
    /// タグを含んでいる可能性があるか(安い事前判定)。
    public static func mightContainTags(_ text: String) -> Bool { text.contains("<") }

    /// `text` を解釈する。`baseSize` は `<s>` の四則演算と `<pp>` の換算の基準、
    /// `baseLetterSpacing` は `<ls>` の基準(クリップの字間)。
    public static func parse(_ text: String, baseSize: Double, baseLetterSpacing: Double) -> MarkupParsed {
        var p = Parser(baseSize: baseSize, baseLetterSpacing: baseLetterSpacing)
        return p.run(text)
    }

    // MARK: - パーサ本体

    private struct Parser {
        let baseSize: Double
        let baseLetterSpacing: Double

        // 状態(タグは「書いた位置から後ろ」に効く)
        var fillSpec: (hex: String, alpha: Double)?
        var outlineSpec: (hex: String, alpha: Double)?
        var fSize: Double?
        var fName: String?
        var fBold: Bool?
        var fItalic: Bool?
        var fUnder = false
        var fStrike = false
        var lsValue: Double
        var lsSet = false
        var offX = 0.0
        var offY = 0.0
        var rot = 0.0

        // 出力
        var plainChars: [Swift.Character] = []
        var charStyles: [MarkupRunStyle?] = []   // 改行は nil
        var rubies: [MarkupRuby] = []
        var hasTags = false

        init(baseSize: Double, baseLetterSpacing: Double) {
            self.baseSize = baseSize
            self.baseLetterSpacing = baseLetterSpacing
            self.lsValue = baseLetterSpacing
        }

        var currentStyle: MarkupRunStyle {
            var s = MarkupRunStyle()
            s.color = fillSpec?.hex; s.colorAlpha = fillSpec?.alpha ?? 1
            s.outlineColor = outlineSpec?.hex; s.outlineAlpha = outlineSpec?.alpha ?? 1
            s.size = fSize; s.fontName = fName; s.bold = fBold; s.italic = fItalic
            s.underline = fUnder; s.strikethrough = fStrike
            s.letterSpacing = lsSet ? lsValue : nil
            s.offsetX = offX; s.offsetY = offY; s.rotation = rot
            return s
        }

        mutating func emit(_ ch: Swift.Character) {
            if ch == "\n" {
                plainChars.append(ch); charStyles.append(nil)
                offX = 0   // <p> の X は改行でリセット(YMM4 の仕様)
            } else {
                plainChars.append(ch); charStyles.append(currentStyle)
            }
        }

        mutating func run(_ text: String) -> MarkupParsed {
            let chars = Array(text)
            // 最後の '>' より後ろではタグは閉じない。そこから先の '<' は毎回、残り全体を探す二乗時間になっていた
            let lastClose = chars.lastIndex(of: ">")
            var i = 0
            while i < chars.count {
                let ch = chars[i]
                // エスケープ: \< は文字としての <
                if ch == "\\", i + 1 < chars.count, chars[i + 1] == "<" {
                    hasTags = true
                    emit("<")
                    i += 2
                    continue
                }
                if ch == "<", let lastClose, i < lastClose, let close = chars[(i + 1)...].firstIndex(of: ">") {
                    let content = String(chars[(i + 1)..<close])
                    if applyTag(content) {
                        hasTags = true
                        i = close + 1
                        continue
                    }
                    // 不正なタグはそのまま文字として出す
                    for k in i...close { emit(chars[k]) }
                    i = close + 1
                    continue
                }
                emit(ch)
                i += 1
            }
            // run にまとめる(改行を除く通し位置で、既定でない範囲だけ)
            var runs: [MarkupRun] = []
            var idx = 0
            while idx < plainChars.count {
                guard let st = charStyles[idx], !st.isDefault else { idx += 1; continue }
                var end = idx + 1
                while end < plainChars.count, charStyles[end] == st { end += 1 }
                runs.append(MarkupRun(range: idx..<end, style: st))
                idx = end
            }
            return MarkupParsed(plain: String(plainChars), runs: runs, rubies: rubies, hasTags: hasTags)
        }

        // MARK: タグの適用(成功したら true)

        mutating func applyTag(_ content: String) -> Bool {
            let trimmed = content.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return false }
            let lower = trimmed.lowercased()
            if trimmed.hasPrefix("#") { return applyColor(String(trimmed.dropFirst())) }
            if lower.hasPrefix("rb") { return applyRuby(String(trimmed.dropFirst(2))) }
            if lower.hasPrefix("rot") { return applyRotation(String(trimmed.dropFirst(3))) }
            if lower.hasPrefix("ls") { return applyLetterSpacing(String(trimmed.dropFirst(2))) }
            if lower.hasPrefix("pp") { return applyPosition(String(trimmed.dropFirst(2)), proportional: true) }
            if lower.hasPrefix("p") { return applyPosition(String(trimmed.dropFirst(1)), proportional: false) }
            if lower.hasPrefix("s") { return applyFont(String(trimmed.dropFirst(1))) }
            if lower.hasPrefix("@") { return applyFontName(String(trimmed.dropFirst(1))) }
            if lower.hasPrefix("r") { return checkTiming(String(trimmed.dropFirst(1)), allowStar: false) }
            if lower.hasPrefix("w") { return checkTiming(String(trimmed.dropFirst(1)), allowStar: true) }
            if lower.hasPrefix("c") { return checkTiming(String(trimmed.dropFirst(1)), allowStar: false) }
            return false
        }

        /// 色 `<#...>`: 空 = リセット。カンマで (文字色, 装飾色)。
        mutating func applyColor(_ body: String) -> Bool {
            let b = body.trimmingCharacters(in: .whitespaces)
            if b.isEmpty { fillSpec = nil; outlineSpec = nil; return true }
            let parts = b.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 1 || parts.count == 2, let first = colorSpec(parts[0]) else { return false }
            // 検証が全部通ってから状態へ書く(後半だけ不正なタグで、前半の色だけ残らないように)
            var second: (hex: String, alpha: Double)? = nil
            if parts.count == 2 {
                guard let s2 = colorSpec(parts[1]) else { return false }
                second = s2
            }
            fillSpec = first
            if let second { outlineSpec = second }
            return true
        }

        /// フォント `<s...>`: 空 = 全リセット。パラメータは (サイズ, フォント名, BISU)、空は変更なし。
        mutating func applyFont(_ body: String) -> Bool {
            if body.trimmingCharacters(in: .whitespaces).isEmpty {
                fSize = nil; fName = nil; fBold = nil; fItalic = nil; fUnder = false; fStrike = false
                return true
            }
            let parts = body.split(separator: ",", omittingEmptySubsequences: false).map { String($0) }
            guard parts.count <= 3 else { return false }
            // 検証が全部通ってから状態へ書く(途中の項目だけ不正なタグで、前の項目だけ残らないように)
            var newSize = fSize, newName = fName
            var newFlags: (b: Bool, i: Bool, s: Bool, u: Bool)? = nil
            let sizePart = parts[0].trimmingCharacters(in: .whitespaces)
            if !sizePart.isEmpty {
                guard let v = numberOrArithmetic(sizePart, base: fSize ?? baseSize) else { return false }
                newSize = v
            }
            if parts.count >= 2 {
                let name = parts[1].trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { newName = name }
            }
            if parts.count >= 3 {
                let bisu = parts[2].trimmingCharacters(in: .whitespaces)
                if !bisu.isEmpty {
                    guard let flags = parseBISU(bisu) else { return false }
                    newFlags = flags
                }
            }
            fSize = newSize; fName = newName
            if let flags = newFlags { fBold = flags.b; fItalic = flags.i; fStrike = flags.s; fUnder = flags.u }
            return true
        }

        /// フォント名・スタイル `<@...>`: 空 = フォント名と装飾のリセット(サイズは戻さない)。
        mutating func applyFontName(_ body: String) -> Bool {
            let b = body.trimmingCharacters(in: .whitespaces)
            if b.isEmpty { fName = nil; fBold = nil; fItalic = nil; fUnder = false; fStrike = false; return true }
            // 差分モード(名前なし): 先頭が + / -
            if b.hasPrefix("+") || b.hasPrefix("-") { return applyBISUDiff(b) }
            let parts = b.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count <= 2 else { return false }
            if parts.count == 2, !parts[1].isEmpty {
                if parts[1].hasPrefix("+") || parts[1].hasPrefix("-") {
                    // 差分モードは名前の有無に依らない。検証(適用込み)が通ったときだけ名前も書く
                    let saved = fName
                    if !parts[0].isEmpty { fName = parts[0] }
                    if applyBISUDiff(parts[1]) { return true }
                    fName = saved
                    return false
                }
                guard let flags = parseBISU(parts[1]) else { return false }
                if !parts[0].isEmpty { fName = parts[0] }
                fBold = flags.b; fItalic = flags.i; fStrike = flags.s; fUnder = flags.u
                return true
            }
            if !parts[0].isEmpty { fName = parts[0] }
            return true
        }

        /// 差分モードの装飾指定列: (+|-|+=|-=)(BISU0-6)+ の繰り返し。
        mutating func applyBISUDiff(_ s: String) -> Bool {
            var rest = Substring(s)
            var changes: [(on: Bool, ch: Swift.Character)] = []
            while !rest.isEmpty {
                let on: Bool
                if rest.hasPrefix("+=") { on = true; rest = rest.dropFirst(2) }
                else if rest.hasPrefix("-=") { on = false; rest = rest.dropFirst(2) }
                else if rest.hasPrefix("+") { on = true; rest = rest.dropFirst(1) }
                else if rest.hasPrefix("-") { on = false; rest = rest.dropFirst(1) }
                else { return false }
                var consumed = false
                while let ch = rest.first, "BISU0123456789".contains(ch.uppercased()) {
                    if "BISU".contains(ch.uppercased()) { changes.append((on, Swift.Character(ch.uppercased()))) }
                    rest = rest.dropFirst(); consumed = true
                }
                guard consumed else { return false }
            }
            for c in changes {
                switch String(c.ch) {
                case "B": fBold = c.on
                case "I": fItalic = c.on
                case "S": fStrike = c.on
                default: fUnder = c.on
                }
            }
            return true
        }

        /// ルビ `<rb親文字,ルビ[,サイズ%[,X,Y[,フォント[,BI[,文字色[,装飾色]]]]]]>`
        mutating func applyRuby(_ body: String) -> Bool {
            let parts = splitEscapedCommas(body).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 2, parts.count <= 9 else { return false }
            let base = parts[0], reading = parts[1]
            guard !base.isEmpty, !reading.isEmpty else { return false }
            var ruby = MarkupRuby(start: plainChars.count, end: plainChars.count + base.count, reading: reading)
            if parts.count >= 3, !parts[2].isEmpty {
                // サイズは既定 50% に対する四則演算、または % の数値そのもの
                guard let pct = numberOrArithmetic(parts[2], base: 50) else { return false }
                ruby.sizeRatio = min(max(pct / 100, 0.05), 3)
            }
            if parts.count >= 4, !parts[3].isEmpty {
                guard let v = Double(parts[3]), v.isFinite else { return false }
                ruby.dx = v
            }
            if parts.count >= 5, !parts[4].isEmpty {
                guard let v = Double(parts[4]), v.isFinite else { return false }
                ruby.dy = v
            }
            if parts.count >= 6, !parts[5].isEmpty { ruby.fontName = parts[5] }
            if parts.count >= 7, !parts[6].isEmpty {
                // ルビの装飾は B / I のみ対応(U / S は読み飛ばす。それ以外の文字は不正)
                for ch in parts[6].uppercased() {
                    switch ch {
                    case "B": ruby.bold = true
                    case "I": ruby.italic = true
                    case "U", "S": break
                    default: return false
                    }
                }
            }
            if parts.count >= 8, !parts[7].isEmpty {
                guard let c = colorSpec(parts[7]) else { return false }
                ruby.color = c.hex
            }
            if parts.count >= 9, !parts[8].isEmpty {
                guard let c = colorSpec(parts[8]) else { return false }
                ruby.outlineColor = c.hex
            }
            for ch in base { emit(ch) }
            rubies.append(ruby)
            return true
        }

        /// 回転 `<rot...>`: 空 = リセット。
        mutating func applyRotation(_ body: String) -> Bool {
            let b = body.trimmingCharacters(in: .whitespaces)
            if b.isEmpty { rot = 0; return true }
            guard let v = numberOrArithmetic(b, base: rot) else { return false }
            rot = v
            return true
        }

        /// 字間 `<ls...>`: 空 = クリップの字間へリセット。
        mutating func applyLetterSpacing(_ body: String) -> Bool {
            let b = body.trimmingCharacters(in: .whitespaces)
            if b.isEmpty { lsSet = false; lsValue = baseLetterSpacing; return true }
            guard let v = numberOrArithmetic(b, base: lsValue) else { return false }
            lsValue = v; lsSet = true
            return true
        }

        /// 座標 `<pX,Y>` / `<ppX,Y>`。符号なし = 絶対、符号あり = 相対、四則演算も可。
        mutating func applyPosition(_ body: String, proportional: Bool) -> Bool {
            let parts = body.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 1 || parts.count == 2 else { return false }
            let unit = proportional ? (fSize ?? baseSize) / 100 : 1
            var newX = offX, newY = offY
            if !parts[0].isEmpty {
                guard let v = positionComponent(parts[0], current: offX, unit: unit) else { return false }
                newX = v
            }
            if parts.count == 2, !parts[1].isEmpty {
                guard let v = positionComponent(parts[1], current: offY, unit: unit) else { return false }
                newY = v
            }
            offX = newX; offY = newY
            return true
        }

        /// 座標 1 成分(空でない前提)。解釈できなければ nil。
        func positionComponent(_ s: String, current: Double, unit: Double) -> Double? {
            func finite(_ v: Double?) -> Double? { v.flatMap { $0.isFinite ? $0 : nil } }
            for op in ["+=", "-=", "*=", "/="] where s.hasPrefix(op) {
                guard let v = Double(s.dropFirst(2)) else { return nil }
                switch op {
                case "+=": return finite(current + v * unit)
                case "-=": return finite(current - v * unit)
                case "*=": return finite(current * v)
                default: return v == 0 ? nil : finite(current / v)
                }
            }
            if s.hasPrefix("+") || s.hasPrefix("-") {
                guard let v = Double(s) else { return nil }
                return finite(current + v * unit)
            }
            guard let v = Double(s) else { return nil }
            return finite(v * unit)
        }

        /// タイミングタグ `<r>` `<w>` `<c>`(効果なし・消費のみ)。構文が合うかだけ見る。
        func checkTiming(_ body: String, allowStar: Bool) -> Bool {
            let b = body.trimmingCharacters(in: .whitespaces)
            if b.isEmpty { return true }
            var s = b
            if allowStar, s.hasPrefix("*") { s = String(s.dropFirst()) }
            if numberOrArithmetic(s, base: 0) != nil { return true }
            return Double(s) != nil
        }

        // MARK: 部品

        /// 数値そのもの(絶対)か、四則演算(+= -= *= /=、基準は base)か。解釈できなければ nil。
        func numberOrArithmetic(_ s: String, base: Double) -> Double? {
            // nan / inf の数値(リテラル・演算結果とも)は描画へ伝播させない
            func finite(_ v: Double?) -> Double? { v.flatMap { $0.isFinite ? $0 : nil } }
            for op in ["+=", "-=", "*=", "/="] where s.hasPrefix(op) {
                guard let v = Double(s.dropFirst(2)) else { return nil }
                switch op {
                case "+=": return finite(base + v)
                case "-=": return finite(base - v)
                case "*=": return finite(base * v)
                default: return v == 0 ? nil : finite(base / v)
                }
            }
            return finite(Double(s))
        }

        /// BISU + 装飾種別(0-6、読み捨て)の解釈。全置換の意味で返す。
        func parseBISU(_ s: String) -> (b: Bool, i: Bool, s: Bool, u: Bool)? {
            var f = (b: false, i: false, s: false, u: false)
            for ch in s.uppercased() {
                switch ch {
                case "B": f.b = true
                case "I": f.i = true
                case "S": f.s = true
                case "U": f.u = true
                case "0", "1", "2", "3", "4", "5", "6": break   // 装飾種別は MovieCut に無いので読み捨てる
                default: return nil
                }
            }
            return f
        }

        /// `\,` をエスケープとして扱うカンマ分割(ルビ用)。
        func splitEscapedCommas(_ s: String) -> [String] {
            var parts: [String] = []
            var cur = ""
            let chars = Array(s)
            var i = 0
            while i < chars.count {
                if chars[i] == "\\", i + 1 < chars.count {
                    cur.append(chars[i + 1]); i += 2; continue
                }
                if chars[i] == "," { parts.append(cur); cur = ""; i += 1; continue }
                cur.append(chars[i]); i += 1
            }
            parts.append(cur)
            return parts
        }

        /// 色の指定 1 つ(16 進の短縮形・色名) → (正規化した "#rrggbb", 不透明度)。
        func colorSpec(_ raw: String) -> (hex: String, alpha: Double)? {
            let s = raw.trimmingCharacters(in: .whitespaces)
            guard !s.isEmpty else { return nil }
            if s.allSatisfy({ $0.isHexDigit }) {
                let d = Array(s.lowercased())
                func pair(_ a: Swift.Character, _ b: Swift.Character) -> Int { Int(String([a, b]), radix: 16) ?? 0 }
                let r: Int, g: Int, b: Int
                var alpha = 1.0
                switch d.count {
                case 1: r = pair(d[0], d[0]); g = r; b = r
                case 2: r = pair(d[0], d[1]); g = r; b = r
                case 3: r = pair(d[0], d[0]); g = pair(d[1], d[1]); b = pair(d[2], d[2])
                case 4: r = pair(d[0], d[0]); g = pair(d[1], d[1]); b = pair(d[2], d[2]); alpha = Double(pair(d[3], d[3])) / 255
                case 6: r = pair(d[0], d[1]); g = pair(d[2], d[3]); b = pair(d[4], d[5])
                case 8: r = pair(d[0], d[1]); g = pair(d[2], d[3]); b = pair(d[4], d[5]); alpha = Double(pair(d[6], d[7])) / 255
                default: return nil
                }
                return (String(format: "#%02x%02x%02x", r, g, b), alpha)
            }
            if let hex = Self.cssColorNames[s.lowercased()] { return (hex, 1) }
            return nil
        }

        /// CSS の名前付き色(小文字名 → "#rrggbb")。
        static let cssColorNames: [String: String] = [
            "aliceblue": "#f0f8ff", "antiquewhite": "#faebd7", "aqua": "#00ffff", "aquamarine": "#7fffd4",
            "azure": "#f0ffff", "beige": "#f5f5dc", "bisque": "#ffe4c4", "black": "#000000",
            "blanchedalmond": "#ffebcd", "blue": "#0000ff", "blueviolet": "#8a2be2", "brown": "#a52a2a",
            "burlywood": "#deb887", "cadetblue": "#5f9ea0", "chartreuse": "#7fff00", "chocolate": "#d2691e",
            "coral": "#ff7f50", "cornflowerblue": "#6495ed", "cornsilk": "#fff8dc", "crimson": "#dc143c",
            "cyan": "#00ffff", "darkblue": "#00008b", "darkcyan": "#008b8b", "darkgoldenrod": "#b8860b",
            "darkgray": "#a9a9a9", "darkgreen": "#006400", "darkgrey": "#a9a9a9", "darkkhaki": "#bdb76b",
            "darkmagenta": "#8b008b", "darkolivegreen": "#556b2f", "darkorange": "#ff8c00", "darkorchid": "#9932cc",
            "darkred": "#8b0000", "darksalmon": "#e9967a", "darkseagreen": "#8fbc8f", "darkslateblue": "#483d8b",
            "darkslategray": "#2f4f4f", "darkslategrey": "#2f4f4f", "darkturquoise": "#00ced1", "darkviolet": "#9400d3",
            "deeppink": "#ff1493", "deepskyblue": "#00bfff", "dimgray": "#696969", "dimgrey": "#696969",
            "dodgerblue": "#1e90ff", "firebrick": "#b22222", "floralwhite": "#fffaf0", "forestgreen": "#228b22",
            "fuchsia": "#ff00ff", "gainsboro": "#dcdcdc", "ghostwhite": "#f8f8ff", "gold": "#ffd700",
            "goldenrod": "#daa520", "gray": "#808080", "green": "#008000", "greenyellow": "#adff2f",
            "grey": "#808080", "honeydew": "#f0fff0", "hotpink": "#ff69b4", "indianred": "#cd5c5c",
            "indigo": "#4b0082", "ivory": "#fffff0", "khaki": "#f0e68c", "lavender": "#e6e6fa",
            "lavenderblush": "#fff0f5", "lawngreen": "#7cfc00", "lemonchiffon": "#fffacd", "lightblue": "#add8e6",
            "lightcoral": "#f08080", "lightcyan": "#e0ffff", "lightgoldenrodyellow": "#fafad2", "lightgray": "#d3d3d3",
            "lightgreen": "#90ee90", "lightgrey": "#d3d3d3", "lightpink": "#ffb6c1", "lightsalmon": "#ffa07a",
            "lightseagreen": "#20b2aa", "lightskyblue": "#87cefa", "lightslategray": "#778899", "lightslategrey": "#778899",
            "lightsteelblue": "#b0c4de", "lightyellow": "#ffffe0", "lime": "#00ff00", "limegreen": "#32cd32",
            "linen": "#faf0e6", "magenta": "#ff00ff", "maroon": "#800000", "mediumaquamarine": "#66cdaa",
            "mediumblue": "#0000cd", "mediumorchid": "#ba55d3", "mediumpurple": "#9370db", "mediumseagreen": "#3cb371",
            "mediumslateblue": "#7b68ee", "mediumspringgreen": "#00fa9a", "mediumturquoise": "#48d1cc", "mediumvioletred": "#c71585",
            "midnightblue": "#191970", "mintcream": "#f5fffa", "mistyrose": "#ffe4e1", "moccasin": "#ffe4b5",
            "navajowhite": "#ffdead", "navy": "#000080", "oldlace": "#fdf5e6", "olive": "#808000",
            "olivedrab": "#6b8e23", "orange": "#ffa500", "orangered": "#ff4500", "orchid": "#da70d6",
            "palegoldenrod": "#eee8aa", "palegreen": "#98fb98", "paleturquoise": "#afeeee", "palevioletred": "#db7093",
            "papayawhip": "#ffefd5", "peachpuff": "#ffdab9", "peru": "#cd853f", "pink": "#ffc0cb",
            "plum": "#dda0dd", "powderblue": "#b0e0e6", "purple": "#800080", "rebeccapurple": "#663399",
            "red": "#ff0000", "rosybrown": "#bc8f8f", "royalblue": "#4169e1", "saddlebrown": "#8b4513",
            "salmon": "#fa8072", "sandybrown": "#f4a460", "seagreen": "#2e8b57", "seashell": "#fff5ee",
            "sienna": "#a0522d", "silver": "#c0c0c0", "skyblue": "#87ceeb", "slateblue": "#6a5acd",
            "slategray": "#708090", "slategrey": "#708090", "snow": "#fffafa", "springgreen": "#00ff7f",
            "steelblue": "#4682b4", "tan": "#d2b48c", "teal": "#008080", "thistle": "#d8bfd8",
            "tomato": "#ff6347", "turquoise": "#40e0d0", "violet": "#ee82ee", "wheat": "#f5deb3",
            "white": "#ffffff", "whitesmoke": "#f5f5f5", "yellow": "#ffff00", "yellowgreen": "#9acd32",
        ]
    }
}

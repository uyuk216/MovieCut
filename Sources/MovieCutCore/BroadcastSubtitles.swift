import Foundation

// MARK: - 放送・配信用字幕(SCC / EBU-STL)
//
// 内部表現(SubtitleFile のキュー列)から放送・配信用形式へ変換するエクスポータ。
// 仕様の出典と割り切りは docs/放送・配信用字幕形式.md にまとめた。
// どちらも「表せる文字」が限られる形式なので、変換できない文字は '?' に置き換え、
// 置き換え・分割などが起きたら warnings に日本語で残す(黙って落とさない)。

/// SCC(Scenarist Closed Caption)の書き出し設定。フレームレートは形式の性質上 29.97fps 固定。
public struct SCCOptions {
    /// ドロップフレームのタイムコードを使うか(true: 区切りは ';'、false: ':')。
    public var dropFrame: Bool = true
    public init(dropFrame: Bool = true) { self.dropFrame = dropFrame }
}

/// EBU-STL のフレームレート。形式上 25 / 30 の 2 種しか無い(DFC で宣言する)。
public enum EBUSTLFrameRate {
    case fps25, fps30
    public var nominal: Int { self == .fps25 ? 25 : 30 }
    public var diskFormatCode: String { self == .fps25 ? "STL25.01" : "STL30.01" }
}

/// EBU-STL の書き出し設定。
public struct EBUSTLOptions {
    public var frameRate: EBUSTLFrameRate = .fps25
    /// GSI の番組タイトル(OPT、32 バイトまで、ASCII 以外は '?' になる)。
    public var programmeTitle: String = ""
    /// GSI の言語コード(LC、EBU の 2 文字コード。09=英語、69=日本語)。
    public var languageCode: String = "09"
    /// GSI の作成日(CD、YYMMDD の 6 桁)。空なら今日の日付。
    public var creationDateCode: String = ""
    public init(frameRate: EBUSTLFrameRate = .fps25, programmeTitle: String = "", languageCode: String = "09", creationDateCode: String = "") {
        self.frameRate = frameRate
        self.programmeTitle = programmeTitle
        self.languageCode = languageCode
        self.creationDateCode = creationDateCode
    }
}

// MARK: - SCC

/// CEA-608(CC1)の pop-on 字幕を SCC テキストにする。
/// 制約: 32 桁 × 最大 4 行、文字は CEA-608 のレパートリーのみ、送信は 2 バイト/フレーム。
public enum SCCExporter {
    public static let framesPerSecond = 30000.0 / 1001.0 // 29.97
    public static let maxColumns = 32
    public static let maxRows = 4

    // MARK: パリティとワード

    /// 7 ビットの値に奇数パリティ(1 の数が奇数になるよう最上位ビット)を付ける。
    public static func withParity(_ raw: UInt8) -> UInt8 {
        let b = raw & 0x7F
        return b.nonzeroBitCount % 2 == 0 ? (b | 0x80) : b
    }

    static func word(_ b1: UInt8, _ b2: UInt8) -> UInt16 {
        UInt16(withParity(b1)) << 8 | UInt16(withParity(b2))
    }

    static func hex(_ w: UInt16) -> String { String(format: "%04x", w) }

    // 制御コード(CC1、パリティ適用前の生バイト対)
    static let enm: (UInt8, UInt8) = (0x14, 0x2E) // Erase Non-displayed Memory
    static let rcl: (UInt8, UInt8) = (0x14, 0x20) // Resume Caption Loading(pop-on 開始)
    static let edm: (UInt8, UInt8) = (0x14, 0x2C) // Erase Displayed Memory
    static let eoc: (UInt8, UInt8) = (0x14, 0x2F) // End Of Caption(表示へ切り替え)

    // MARK: PAC(行・桁の指定)

    /// 行 1...15 → (1 バイト目, 下位グループか)。CEA-608 の PAC 表そのまま
    /// (行 11 だけ 0x10、行 12 から 0x13/0x14 に移る不規則さを含む)。
    static let pacRows: [(UInt8, Bool)] = [
        (0x11, false), (0x11, true), (0x12, false), (0x12, true),
        (0x15, false), (0x15, true), (0x16, false), (0x16, true),
        (0x17, false), (0x17, true), (0x10, false), (0x13, false),
        (0x13, true), (0x14, false), (0x14, true),
    ]

    /// 行 row(1...15)、桁 indent(0,4,...,28)の PAC(白・下線なし)。生バイト対を返す。
    public static func pac(row: Int, indent: Int) -> (UInt8, UInt8) {
        let r = pacRows[min(max(row, 1), 15) - 1]
        let base: UInt8 = r.1 ? 0x70 : 0x50
        return (r.0, base + UInt8(min(max(indent, 0), 28) / 4 * 2))
    }

    /// Tab Over(1...3 桁)。生バイト対を返す。
    static func tabOver(_ n: Int) -> (UInt8, UInt8) {
        switch n {
        case 1: return (0x17, 0x21)
        case 2: return (0x17, 0x22)
        default: return (0x17, 0x23)
        }
    }

    // MARK: 文字の対応表(CEA-608)

    /// 基本文字のうち ASCII と位置がずれるもの(Unicode → 生バイト)。
    static let basicOverrides: [Swift.Character: UInt8] = [
        "á": 0x2A, "é": 0x5C, "í": 0x5E, "ó": 0x5F, "ú": 0x60,
        "ç": 0x7B, "÷": 0x7C, "Ñ": 0x7D, "ñ": 0x7E,
    ]
    /// 基本文字では出せない ASCII(拡張文字側にある)。
    static let notBasicASCII: Set<Swift.Character> = ["*", "\\", "^", "_", "`", "{", "|", "}", "~"]
    /// 特殊文字(0x11 + 下のバイト)。
    static let specialChars: [Swift.Character: UInt8] = [
        "®": 0x30, "°": 0x31, "½": 0x32, "¿": 0x33, "™": 0x34, "¢": 0x35, "£": 0x36,
        "♪": 0x37, "à": 0x38, "è": 0x3A, "â": 0x3B, "ê": 0x3C, "î": 0x3D, "ô": 0x3E, "û": 0x3F,
    ]
    /// 拡張文字(フォールバック文字 + 2 バイトコード)。デコーダが未対応でもフォールバックで読める。
    static let extendedChars: [Swift.Character: (fallback: Swift.Character, first: UInt8, second: UInt8)] = [
        "Á": ("A", 0x12, 0x20), "É": ("E", 0x12, 0x21), "Ó": ("O", 0x12, 0x22), "Ú": ("U", 0x12, 0x23),
        "Ü": ("U", 0x12, 0x24), "ü": ("u", 0x12, 0x25), "‘": ("'", 0x12, 0x26), "¡": ("!", 0x12, 0x27),
        "*": ("#", 0x12, 0x28), "’": ("'", 0x12, 0x29), "—": ("-", 0x12, 0x2A), "©": ("C", 0x12, 0x2B),
        "℠": ("s", 0x12, 0x2C), "•": (".", 0x12, 0x2D), "“": ("\"", 0x12, 0x2E), "”": ("\"", 0x12, 0x2F),
        "À": ("A", 0x12, 0x30), "Â": ("A", 0x12, 0x31), "Ç": ("C", 0x12, 0x32), "È": ("E", 0x12, 0x33),
        "Ê": ("E", 0x12, 0x34), "Ë": ("E", 0x12, 0x35), "ë": ("e", 0x12, 0x36), "Î": ("I", 0x12, 0x37),
        "Ï": ("I", 0x12, 0x38), "ï": ("i", 0x12, 0x39), "Ô": ("O", 0x12, 0x3A), "Ù": ("U", 0x12, 0x3B),
        "ù": ("u", 0x12, 0x3C), "Û": ("U", 0x12, 0x3D), "«": ("\"", 0x12, 0x3E), "»": ("\"", 0x12, 0x3F),
        "Ã": ("A", 0x13, 0x20), "ã": ("a", 0x13, 0x21), "Í": ("I", 0x13, 0x22), "Ì": ("I", 0x13, 0x23),
        "ì": ("i", 0x13, 0x24), "Ò": ("O", 0x13, 0x25), "ò": ("o", 0x13, 0x26), "Õ": ("O", 0x13, 0x27),
        "õ": ("o", 0x13, 0x28), "{": ("[", 0x13, 0x29), "}": ("]", 0x13, 0x2A), "\\": ("/", 0x13, 0x2B),
        "^": ("/", 0x13, 0x2C), "_": ("-", 0x13, 0x2D), "¦": ("-", 0x13, 0x2E), "~": ("-", 0x13, 0x2F),
        "Ä": ("A", 0x13, 0x30), "ä": ("a", 0x13, 0x31), "Ö": ("O", 0x13, 0x32), "ö": ("o", 0x13, 0x33),
        "ß": ("s", 0x13, 0x34), "¥": ("Y", 0x13, 0x35), "¤": ("C", 0x13, 0x36), "|": ("/", 0x13, 0x37),
        "Å": ("A", 0x13, 0x38), "å": ("a", 0x13, 0x39), "Ø": ("O", 0x13, 0x3A), "ø": ("o", 0x13, 0x3B),
        "┌": ("+", 0x13, 0x3C), "┐": ("+", 0x13, 0x3D), "└": ("+", 0x13, 0x3E), "┘": ("+", 0x13, 0x3F),
    ]

    /// 1 文字分の送信単位(表示は常に 1 桁ぶん)。
    enum Piece {
        case basic(UInt8)
        case special(UInt8)
        case extended(fallback: UInt8, first: UInt8, second: UInt8)
        var rawBytes: [UInt8] {
            switch self {
            case .basic(let b): return [b]
            case .special(let b): return [0x11, b]
            case .extended(let f, let a, let b): return [f, a, b]
            }
        }
    }

    /// 全角英数記号は半角へ、… は "..." へ寄せてから対応表を引く。
    static func normalize(_ ch: Swift.Character) -> [Swift.Character] {
        if ch == "…" { return [".", ".", "."] }
        if ch == "　" { return [" "] }
        let scalars = ch.unicodeScalars
        if scalars.count == 1, let v = scalars.first?.value, (0xFF01...0xFF5E).contains(v),
           let half = UnicodeScalar(v - 0xFEE0) {
            return [Swift.Character(half)]
        }
        return [ch]
    }

    static func piece(for ch: Swift.Character, replaced: inout Int) -> Piece {
        if let b = basicOverrides[ch] { return .basic(b) }
        if let b = specialChars[ch] { return .special(b) }
        if let e = extendedChars[ch], let f = e.fallback.asciiValue { return .extended(fallback: f, first: e.first, second: e.second) }
        if let a = ch.asciiValue, (0x20...0x7E).contains(a), !notBasicASCII.contains(ch) { return .basic(a) }
        replaced += 1
        return .basic(0x3F) // '?'
    }

    // MARK: 折り返し

    /// 1 行の文字列 → 32 桁以内の行の列(語の途中で割らない。ただし 1 語が 32 桁を超えたら割る)。
    static func wrapLine(_ line: String, replaced: inout Int) -> [[Piece]] {
        var words: [[Piece]] = []
        for w in line.split(separator: " ", omittingEmptySubsequences: true) {
            var pieces: [Piece] = []
            for ch in w { for n in normalize(ch) { pieces.append(piece(for: n, replaced: &replaced)) } }
            if !pieces.isEmpty { words.append(pieces) }
        }
        guard !words.isEmpty else { return [] }
        var lines: [[Piece]] = []
        var cur: [Piece] = []
        for w in words {
            var word = w
            while word.count > maxColumns { // 長い語は割る(先に今の行を出す)
                if !cur.isEmpty { lines.append(cur); cur = [] }
                lines.append(Array(word.prefix(maxColumns)))
                word = Array(word.dropFirst(maxColumns))
            }
            if cur.isEmpty { cur = word }
            else if cur.count + 1 + word.count <= maxColumns { cur.append(.basic(0x20)); cur += word }
            else { lines.append(cur); cur = word }
        }
        if !cur.isEmpty { lines.append(cur) }
        return lines
    }

    // MARK: 時刻

    /// 秒 → フレーム番号(29.97fps、四捨五入、負は 0)。
    public static func frameIndex(at t: Double) -> Int {
        guard t.isFinite, t > 0 else { return 0 }
        return Int((t * framesPerSecond + 0.5).rounded(.down))
    }

    /// フレーム番号 → SCC のタイムコード文字列。DF は ';'、NDF は ':' がフレームの区切り。
    public static func timecode(frame: Int, dropFrame: Bool) -> String {
        var n = max(0, frame)
        if dropFrame {
            // 1 分ごとに番号 00/01 を飛ばす(10 分ごとは飛ばさない)。名目 30fps の番号へ換算する。
            let tenMinutes = n / 17982
            let rem = n % 17982
            n += 18 * tenMinutes
            if rem >= 2 { n += 2 * ((rem - 2) / 1798) }
        }
        let h = n / 108000, m = (n / 1800) % 60, s = (n / 30) % 60, f = n % 30
        return String(format: "%02d:%02d:%02d%@%02d", h, m, s, dropFrame ? ";" : ":", f)
    }

    // MARK: 書き出し

    /// キュー列 → SCC テキスト。pop-on、CC1、下寄せ中央。送信が間に合わない字幕は表示を遅らせて警告する。
    public static func export(_ cues: [SubtitleCue], options: SCCOptions = SCCOptions()) -> (text: String, warnings: [String]) {
        var warnings: [String] = []
        var replaced = 0
        var splitCount = 0
        var delayedCount = 0

        // キュー → (表示フレーム, 終了フレーム, 行のまとまり) の列。4 行を超えるキューは時間を等分して分割する。
        struct Caption { var start: Double; var end: Double; var lines: [[Piece]] }
        var captions: [Caption] = []
        for c in cues {
            guard c.end > c.start else { continue }
            let body = c.text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            var lines: [[Piece]] = []
            for rawLine in body.components(separatedBy: "\n") {
                let t = rawLine.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { lines += wrapLine(t, replaced: &replaced) }
            }
            guard !lines.isEmpty else { continue }
            if lines.count <= maxRows {
                captions.append(Caption(start: c.start, end: c.end, lines: lines))
            } else {
                splitCount += 1
                let groups = stride(from: 0, to: lines.count, by: maxRows).map { Array(lines[$0..<min($0 + maxRows, lines.count)]) }
                let span = (c.end - c.start) / Double(groups.count)
                for (i, g) in groups.enumerated() {
                    captions.append(Caption(start: c.start + span * Double(i), end: c.start + span * Double(i + 1), lines: g))
                }
            }
        }
        captions.sort { $0.start < $1.start }

        // 送信スケジュール: pop-on は表示中でも裏バッファへ次を読み込めるので、
        // 読み込み同士が重ならないことだけを制約にする。表示が間に合わない字幕は遅らせて警告する。
        struct Scheduled { var words: [UInt16]; var loadStart: Int; var display: Int; var end: Int }
        var scheduled: [Scheduled] = []
        var channelFree = 0 // 次の読み込みを始められるフレーム
        for cap in captions {
            var words: [UInt16] = []
            func push(_ p: (UInt8, UInt8)) { words.append(word(p.0, p.1)); words.append(word(p.0, p.1)) }
            push(enm); push(rcl)
            let firstRow = 16 - cap.lines.count
            for (i, line) in cap.lines.enumerated() {
                let startCol = (maxColumns - line.count) / 2
                let indent = startCol / 4 * 4
                push(pac(row: firstRow + i, indent: indent))
                let rem = startCol - indent
                if rem > 0 { push(tabOver(rem)) }
                var bytes: [UInt8] = []
                for p in line { bytes += p.rawBytes }
                if bytes.count % 2 == 1 { bytes.append(0) } // 対にそろえる詰め物(表示されない)
                for j in stride(from: 0, to: bytes.count, by: 2) { words.append(word(bytes[j], bytes[j + 1])) }
            }
            push(eoc)
            let wantDisplay = frameIndex(at: cap.start)
            let loadStart = max(wantDisplay - (words.count - 1), channelFree, 0)
            let display = loadStart + words.count - 1
            if display > wantDisplay { delayedCount += 1 }
            channelFree = display + 1
            scheduled.append(Scheduled(words: words, loadStart: loadStart, display: display, end: frameIndex(at: cap.end)))
        }

        var out = "Scenarist_SCC V1.0\n\n"
        let edmHex = "\(hex(word(edm.0, edm.1))) \(hex(word(edm.0, edm.1)))"
        for (i, s) in scheduled.enumerated() {
            out += "\(timecode(frame: s.loadStart, dropFrame: options.dropFrame))\t\(s.words.map(hex).joined(separator: " "))\n\n"
            // 消去(EDM)は、次の読み込みとぶつからない隙間がある時だけ終了フレームに出す。
            // 次の字幕がすぐ続く場合は、その EOC(表示の入れ替え)で画面が切り替わるので EDM は不要。
            let nextLoad = i + 1 < scheduled.count ? scheduled[i + 1].loadStart : Int.max
            let endFrame = max(s.end, s.display + 1)
            if nextLoad >= endFrame + 2 {
                out += "\(timecode(frame: endFrame, dropFrame: options.dropFrame))\t\(edmHex)\n\n"
            }
        }

        if replaced > 0 { warnings.append("CEA-608 で表せない文字 \(replaced) 文字を ? に置き換えました(日本語などは SCC に載せられません)") }
        if splitCount > 0 { warnings.append("4 行を超える字幕 \(splitCount) 件を、時間で等分して複数に分割しました") }
        if delayedCount > 0 { warnings.append("送信(2 バイト/フレーム)が間に合わず、\(delayedCount) 件の表示を遅らせました") }
        return (out, warnings)
    }
}

// MARK: - EBU-STL

/// EBU-STL(EBU Tech 3264)のバイナリ書き出しと読み戻し。
/// 構成: GSI ブロック 1024 バイト + TTI ブロック 128 バイト × 件数(拡張ブロック含む)。
/// 文字は CCT 00 = ISO 6937(Latin)。アクセントは「ダイアクリティカル記号のバイト + 基底文字」の 2 バイトで表す。
public enum EBUSTLExporter {
    public static let maxColumns = 40
    static let textFieldSize = 112
    static let lineBreak: UInt8 = 0x8A
    static let padding: UInt8 = 0x8F

    // MARK: ISO 6937 の文字変換

    /// 結合文字(Unicode スカラ値) → ISO 6937 のダイアクリティカルバイト。
    static let diacriticBytes: [UInt32: UInt8] = [
        0x0300: 0xC1, 0x0301: 0xC2, 0x0302: 0xC3, 0x0303: 0xC4, 0x0304: 0xC5,
        0x0306: 0xC6, 0x0307: 0xC7, 0x0308: 0xC8, 0x030A: 0xCA, 0x0327: 0xCB,
        0x030B: 0xCD, 0x0328: 0xCE, 0x030C: 0xCF,
    ]
    static let diacriticMarks: [UInt8: UInt32] = Dictionary(uniqueKeysWithValues: diacriticBytes.map { ($0.value, $0.key) })
    /// 1 バイトで表せる補助集合(ISO 6937 補助集合の一部)。
    static let singleBytes: [Swift.Character: UInt8] = [
        "¡": 0xA1, "¢": 0xA2, "£": 0xA3, "±": 0xB1, "¿": 0xBF, "¹": 0xD1, "Æ": 0xE1, "æ": 0xF1,
    ]
    static let singleChars: [UInt8: Swift.Character] = Dictionary(uniqueKeysWithValues: singleBytes.map { ($0.value, $0.key) })

    /// 文字列 → ISO 6937 バイト列。表せない文字は '?' にし、数を replaced に数える。
    static func encodeText(_ s: String, replaced: inout Int) -> [UInt8] {
        var out: [UInt8] = []
        let scalars = Array(s.decomposedStringWithCanonicalMapping.unicodeScalars)
        var i = 0
        while i < scalars.count {
            let sc = scalars[i]
            // 基底文字 + 結合文字の組なら「記号バイト + 基底文字」
            if i + 1 < scalars.count, let dia = diacriticBytes[scalars[i + 1].value],
               sc.value >= 0x20, sc.value <= 0x7E {
                out.append(dia); out.append(UInt8(sc.value)); i += 2; continue
            }
            if sc.value >= 0x20, sc.value <= 0x7E { out.append(UInt8(sc.value)); i += 1; continue }
            let ch = Swift.Character(sc)
            if let b = singleBytes[ch] { out.append(b); i += 1; continue }
            if sc.properties.generalCategory == .nonspacingMark { i += 1; continue } // 落ちた結合文字は捨てる
            replaced += 1; out.append(0x3F); i += 1
        }
        return out
    }

    /// ISO 6937 バイト列 → 文字列(0x8A は改行、詰め物と制御コードは読み飛ばす)。
    static func decodeText(_ bytes: [UInt8]) -> String {
        var out = ""
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if b == lineBreak { out.append("\n"); i += 1; continue }
            if b == padding || b < 0x20 || (0x80...0x85).contains(b) { i += 1; continue }
            if let mark = diacriticMarks[b], i + 1 < bytes.count {
                let base = bytes[i + 1]
                if base >= 0x20, base <= 0x7E, let ms = UnicodeScalar(mark) {
                    var s = ""
                    s.unicodeScalars.append(UnicodeScalar(base)); s.unicodeScalars.append(ms)
                    out += s.precomposedStringWithCanonicalMapping
                    i += 2; continue
                }
            }
            if (0x20...0x7E).contains(b) { out.append(Swift.Character(UnicodeScalar(b))); i += 1; continue }
            if let ch = singleChars[b] { out.append(ch); i += 1; continue }
            i += 1
        }
        return out
    }

    // MARK: 折り返し

    /// 1 行を 40 文字以内に折る(数えるのは文字数。ISO 6937 の 2 バイト文字は表示 1 文字)。
    static func wrapLine(_ line: String) -> [String] {
        var lines: [String] = []
        var cur = ""
        for w in line.split(separator: " ", omittingEmptySubsequences: true) {
            let word = String(w)
            if cur.isEmpty { cur = word }
            else if cur.count + 1 + word.count <= maxColumns { cur += " " + word }
            else { lines.append(cur); cur = word }
            while cur.count > maxColumns { // 1 語が長い場合は割る
                lines.append(String(cur.prefix(maxColumns)))
                cur = String(cur.dropFirst(maxColumns))
            }
        }
        if !cur.isEmpty { lines.append(cur) }
        return lines
    }

    // MARK: GSI / TTI

    static func setField(_ gsi: inout [UInt8], _ offset: Int, _ length: Int, _ value: String) {
        let bytes = Array(value.utf8.prefix(length))
        for (i, b) in bytes.enumerated() { gsi[offset + i] = (0x20...0x7E).contains(b) ? b : 0x3F }
    }

    static func timecodeBytes(_ t: Double, fps: Int) -> [UInt8] {
        let total = (t.isFinite && t > 0) ? Int((t * Double(fps) + 0.5).rounded(.down)) : 0
        return [UInt8(total / (fps * 3600)), UInt8((total / (fps * 60)) % 60), UInt8((total / fps) % 60), UInt8(total % fps)]
    }

    static func seconds(fromTC b: ArraySlice<UInt8>, fps: Int) -> Double {
        let a = Array(b)
        guard a.count == 4 else { return 0 }
        return Double(((Int(a[0]) * 60 + Int(a[1])) * 60 + Int(a[2])) * fps + Int(a[3])) / Double(fps)
    }

    /// キュー列 → STL バイナリ。112 バイトを超える字幕は拡張ブロック(EBN)に分ける。
    public static func export(_ cues: [SubtitleCue], options: EBUSTLOptions = EBUSTLOptions()) -> (data: Data, warnings: [String]) {
        var warnings: [String] = []
        var replaced = 0
        let fps = options.frameRate.nominal

        struct Sub { var start: Double; var end: Double; var rows: Int; var textBytes: [UInt8] }
        var subs: [Sub] = []
        for c in cues {
            guard c.end > c.start else { continue }
            let body = c.text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            var lines: [String] = []
            for rawLine in body.components(separatedBy: "\n") {
                let t = rawLine.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { lines += wrapLine(t) }
            }
            guard !lines.isEmpty else { continue }
            var bytes: [UInt8] = []
            for (i, l) in lines.enumerated() {
                if i > 0 { bytes.append(lineBreak) }
                bytes += encodeText(l, replaced: &replaced)
            }
            subs.append(Sub(start: c.start, end: c.end, rows: lines.count, textBytes: bytes))
        }
        subs.sort { $0.start < $1.start }

        // TTI ブロック列(テキストは表示単位を割らないよう 112 バイト以下に分ける)
        var blocks: [[UInt8]] = []
        for (idx, s) in subs.enumerated() {
            var chunks: [[UInt8]] = []
            var cur: [UInt8] = []
            var j = 0
            while j < s.textBytes.count {
                let isDia = diacriticMarks[s.textBytes[j]] != nil
                let unit = isDia && j + 1 < s.textBytes.count ? 2 : 1
                if cur.count + unit > textFieldSize { chunks.append(cur); cur = [] }
                cur += s.textBytes[j..<(j + unit)]; j += unit
            }
            if !cur.isEmpty || chunks.isEmpty { chunks.append(cur) }
            for (k, chunk) in chunks.enumerated() {
                var tti = [UInt8](repeating: padding, count: 128)
                tti[0] = 0 // SGN
                tti[1] = UInt8(idx & 0xFF); tti[2] = UInt8((idx >> 8) & 0xFF) // SN(リトルエンディアン)
                tti[3] = k == chunks.count - 1 ? 0xFF : UInt8(k) // EBN(最後は FF)
                tti[4] = 0 // CS
                let tin = timecodeBytes(s.start, fps: fps), tout = timecodeBytes(s.end, fps: fps)
                for m in 0..<4 { tti[5 + m] = tin[m]; tti[9 + m] = tout[m] }
                tti[13] = UInt8(min(max(24 - s.rows, 1), 23)) // VP(23 行グリッドの下寄せ)
                tti[14] = 0x02 // JC(中央)
                tti[15] = 0 // CF
                for (m, b) in chunk.enumerated() { tti[16 + m] = b }
                blocks.append(tti)
            }
        }

        // GSI ブロック(1024 バイト、未使用は空白)
        var gsi = [UInt8](repeating: 0x20, count: 1024)
        setField(&gsi, 0, 3, "437") // CPN
        setField(&gsi, 3, 8, options.frameRate.diskFormatCode) // DFC
        setField(&gsi, 11, 1, "0") // DSC(オープン字幕)
        setField(&gsi, 12, 2, "00") // CCT(ISO 6937 Latin)
        let lc = options.languageCode.count == 2 ? options.languageCode : "09"
        setField(&gsi, 14, 2, lc) // LC
        setField(&gsi, 16, 32, options.programmeTitle) // OPT
        let dateCode = options.creationDateCode.count == 6 ? options.creationDateCode : Self.todayCode()
        setField(&gsi, 224, 6, dateCode) // CD
        setField(&gsi, 230, 6, dateCode) // RD
        setField(&gsi, 236, 2, "00") // RN
        setField(&gsi, 238, 5, String(format: "%05d", blocks.count)) // TNB
        setField(&gsi, 243, 5, String(format: "%05d", subs.count)) // TNS
        setField(&gsi, 248, 3, "001") // TNG
        setField(&gsi, 251, 2, String(format: "%02d", maxColumns)) // MNC
        setField(&gsi, 253, 2, "23") // MNR
        setField(&gsi, 255, 1, "1") // TCS(タイムコード使用)
        setField(&gsi, 256, 8, "00000000") // TCP
        if let first = subs.first { // TCF(最初の字幕の開始タイムコード、数字 8 桁)
            let tc = timecodeBytes(first.start, fps: fps)
            setField(&gsi, 264, 8, tc.map { String(format: "%02d", $0) }.joined())
        } else {
            setField(&gsi, 264, 8, "00000000")
        }
        setField(&gsi, 272, 1, "1") // TND
        setField(&gsi, 273, 1, "1") // DSN

        var data = Data(gsi)
        for b in blocks { data.append(contentsOf: b) }
        if replaced > 0 { warnings.append("ISO 6937(Latin)で表せない文字 \(replaced) 文字を ? に置き換えました(日本語などは EBU-STL に載せられません)") }
        return (data, warnings)
    }

    static func todayCode() -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyMMdd"
        return f.string(from: Date())
    }

    // MARK: 読み戻し(往復確認・取り込み用)

    /// STL バイナリ → キュー列。形式が違う・壊れている場合は nil。拡張ブロックは連結し、コメントブロック(CF=1)は飛ばす。
    public static func parse(_ data: Data) -> [SubtitleCue]? {
        let bytes = [UInt8](data)
        guard bytes.count >= 1024, (bytes.count - 1024) % 128 == 0 else { return nil }
        let dfc = String(bytes: bytes[3..<11].map { (0x20...0x7E).contains($0) ? $0 : 0x20 }, encoding: .ascii) ?? ""
        let fps: Int
        if dfc.contains("25") { fps = 25 } else if dfc.contains("30") { fps = 30 } else { return nil }

        var cues: [SubtitleCue] = []
        var pending: (start: Double, end: Double, text: [UInt8])? = nil
        func flush() {
            guard let p = pending else { return }
            let text = decodeText(p.text).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { cues.append(SubtitleCue(start: p.start, end: p.end, text: text)) }
            pending = nil
        }
        var i = 1024
        while i + 128 <= bytes.count {
            let tti = Array(bytes[i..<(i + 128)]) // 0 始まりの配列に直してから添字を使う
            i += 128
            if tti[15] == 1 { continue } // コメントブロック
            let ebn = tti[3]
            if pending == nil {
                pending = (seconds(fromTC: tti[5...8], fps: fps), seconds(fromTC: tti[9...12], fps: fps), Array(tti[16...127]))
            } else {
                pending!.text += Array(tti[16...127])
            }
            if ebn == 0xFF { flush() }
        }
        flush()
        return cues.sorted { $0.start < $1.start }
    }
}

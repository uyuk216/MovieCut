import Foundation

/// 文字起こしの単語時刻から、カラオケ字幕の `Highlight.times` を作る(画面にも Undo にも依存しない純粋な計算)。
///
/// 規則: 字幕の本文の「空白と改行を除いた文字列」が、窓の中の単語を順に連結した文字列と完全に一致するときだけ作る。
/// 一致したら、単語の中の文字は単語の [開始, 終了) を字数で等分して開始時刻を決める。
/// 単位(char = 1 文字、word = 空白までの並び)の開始秒は、その単位の最初の文字の時刻。空白は直前の文字と同時に塗る。
/// 一致しない・単語が無い・時刻が壊れているときは nil(既存の字数比例の塗り方に任せる)。
public enum KaraokeTiming {
    /// - Parameters:
    ///   - text: 字幕の本文(描画に使う文字列)。
    ///   - words: 単語単位の認識結果(窓と同じ時間軸の秒)。窓の外のものは使わない。
    ///   - windowStart: 字幕の開始(`words` と同じ時間軸の秒)。結果はここからの相対秒。
    ///   - duration: 字幕の長さ(秒)。結果は [0, duration] に収め、昇順にする。
    ///   - wordMode: true なら "word" の単位、false なら "char"。
    /// - Returns: 単位ごとの開始秒(`KaraokeMath` の単位の数と同じ長さ)。作れなければ nil。
    public static func times(text: String, words: [TranscriptSegment], windowStart: Double, duration: Double, wordMode: Bool) -> [Double]? {
        guard windowStart.isFinite, duration.isFinite, duration > 0 else { return nil }
        // 窓の中の単語(中点で判定)。空・非有限は捨てる。
        let inWindow = words
            .filter { w in
                let body = w.text.filter { !$0.isWhitespace }
                guard !body.isEmpty, w.start.isFinite, w.end.isFinite else { return false }
                let mid = (w.start + max(w.start, w.end)) / 2
                return mid >= windowStart - 1e-9 && mid <= windowStart + duration + 1e-9
            }
            .sorted { $0.start < $1.start }
        guard !inWindow.isEmpty else { return nil }

        // 単語ごとに文字の開始時刻(窓の頭から)を作る
        var glyphs: [Swift.Character] = []
        var glyphTimes: [Double] = []
        for w in inWindow {
            let chars = w.text.filter { !$0.isWhitespace }
            let s = w.start - windowStart, e = max(w.start, w.end) - windowStart
            let n = chars.count
            for (j, ch) in chars.enumerated() {
                glyphs.append(ch)
                glyphTimes.append(s + (e - s) * Double(j) / Double(n))
            }
        }

        // 本文(改行を除く)と突き合わせる。空白以外の文字が完全に一致しなければ作らない。
        let shown = Array(text.filter { $0 != "\n" })
        guard shown.filter({ !$0.isWhitespace }) == glyphs else { return nil }

        // 本文の文字ごとの開始時刻。空白は直前の文字と同時(先頭の空白は 0)。
        var perChar: [Double] = []
        var gi = 0
        var running = 0.0
        for ch in shown {
            if ch.isWhitespace {
                perChar.append(running)
            } else {
                running = max(running, min(max(glyphTimes[gi], 0), duration))
                perChar.append(running)
                gi += 1
            }
        }

        // 単位ごとの開始秒(単位の先頭の文字の時刻)
        let units = KaraokeMath.units(text, wordMode: wordMode)
        var out: [Double] = []
        var idx = 0
        for u in units {
            guard idx < perChar.count else { return nil }
            out.append(perChar[idx])
            idx += u.length
        }
        guard idx == perChar.count, out.allSatisfy({ $0.isFinite }) else { return nil }
        return out
    }
}

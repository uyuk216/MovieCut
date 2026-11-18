import Foundation

// VOICEVOX の /audio_query が持つモーラ(拍)の長さと母音から、実際の発音タイミングに沿った口の形を作る(B-7)。
// 純粋な変換だけを持つ(通信・ファイルの読み書きは呼び出し側)。同じ入力には必ず同じ結果を返す。

/// WAV 内の区間 [start, end)(秒)に出す口の形。
public struct TimedViseme: Equatable {
    public var vowel: Viseme
    public var start: Double
    public var end: Double
    public init(vowel: Viseme, start: Double, end: Double) {
        self.vowel = vowel
        self.start = start
        self.end = end
    }
}

public enum VoicevoxMora {
    /// サイドカーの形式の版。
    public static let sidecarVersion = 1
    /// サイドカー区間の終端の上限(秒)。これを超える区間は壊れているとみなす(フォールバックへ)。
    public static let maxSidecarTime: Double = 86_400
    /// サイドカー区間の最大件数。
    public static let maxSidecarSegments: Int = 100_000

    // MARK: /audio_query → 区間

    /// /audio_query の JSON から区間の並びを作る。読めない JSON・モーラ無しは空。
    public static func parse(_ data: Data) -> [TimedViseme] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return parse(obj)
    }

    /// 辞書版。accent_phrases を順に辿り、prePhonemeLength を先頭に、各モーラ長を speedScale で割って積む。
    /// pause_mora は閉じた口で、長さに pauseLengthScale を掛ける。postPhonemeLength は足さない(範囲外は閉じ扱い)。
    public static func parse(_ query: [String: Any]) -> [TimedViseme] {
        func num(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }
        let speed = (num(query["speedScale"]) ?? 1) > 0 ? (num(query["speedScale"]) ?? 1) : 1
        let pauseScale = num(query["pauseLengthScale"]) ?? 1
        var t = max(0, num(query["prePhonemeLength"]) ?? 0)
        var out: [TimedViseme] = []
        func push(_ v: Viseme, _ length: Double) {
            let len = max(0, length) / speed
            out.append(TimedViseme(vowel: v, start: t, end: t + len))
            t += len
        }
        for phrase in query["accent_phrases"] as? [[String: Any]] ?? [] {
            for mora in phrase["moras"] as? [[String: Any]] ?? [] {
                let length = (num(mora["consonant_length"]) ?? 0) + (num(mora["vowel_length"]) ?? 0)
                push(viseme(ofVowel: mora["vowel"] as? String), length)
            }
            if let pause = phrase["pause_mora"] as? [String: Any] {
                push(.closed, (num(pause["vowel_length"]) ?? 0) * pauseScale)
            }
        }
        return out
    }

    /// 母音の文字 → 口の形。a/i/u/e/o(大文字の無声化も同じ)。N(ん)・cl(っ)・その他は閉じた口。
    static func viseme(ofVowel s: String?) -> Viseme {
        switch s {
        case "a", "A": return .a
        case "i", "I": return .i
        case "u", "U": return .u
        case "e", "E": return .e
        case "o", "O": return .o
        default: return .closed
        }
    }

    // MARK: サイドカー(WAV のパス + ".visemes.json")

    /// WAV の隣のサイドカーの場所。
    public static func sidecarURL(forWav path: String) -> URL { URL(fileURLWithPath: path + ".visemes.json") }

    /// {"version":1,"segments":[{"v":"a","s":0.03,"e":0.18},...]}
    public static func encodeSidecar(_ segments: [TimedViseme]) -> Data? {
        let segs: [[String: Any]] = segments.map { ["v": $0.vowel.rawValue, "s": $0.start, "e": $0.end] }
        return try? JSONSerialization.data(withJSONObject: ["version": sidecarVersion, "segments": segs] as [String: Any], options: [.sortedKeys])
    }

    /// サイドカーを読む。壊れている・版が違う・区間が不正な場合は nil(従来のエンベロープ比例に戻す)。
    /// 区間の検証: 版は整数の 1 ちょうど(1.5 や true を 1 とみなさない)、開始 >= 0、終了 >= 開始、
    /// 終了 <= maxSidecarTime、区間は開始順に並び重ならないこと(接触は可)。1 つでも外れたら全体を nil にする。
    public static func decodeSidecar(_ data: Data) -> [TimedViseme]? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = obj["version"] as? NSNumber, !isBoolean(version),
              version.doubleValue == Double(sidecarVersion),
              let arr = obj["segments"] as? [[String: Any]],
              !arr.isEmpty, arr.count <= maxSidecarSegments else { return nil }
        var out: [TimedViseme] = []
        var prevEnd = 0.0
        for s in arr {
            guard let v = (s["v"] as? String).flatMap(Viseme.init(rawValue:)),
                  let an = s["s"] as? NSNumber, let bn = s["e"] as? NSNumber,
                  !isBoolean(an), !isBoolean(bn) else { return nil }
            let a = an.doubleValue, b = bn.doubleValue
            guard a.isFinite, b.isFinite, a >= prevEnd, b >= a, b <= maxSidecarTime else { return nil }
            out.append(TimedViseme(vowel: v, start: a, end: b))
            prevEnd = b
        }
        return out
    }

    /// JSON の true/false は NSNumber として届くため、数値と区別する。
    static func isBoolean(_ n: NSNumber) -> Bool { CFGetTypeID(n) == CFBooleanGetTypeID() }
}

extension LipSync {
    /// 1/60 秒ごとの口の形。コマの中央時刻が区間 [start, end) にある Viseme を入れ、区間の外は閉じた口。
    /// 区間端点は、先に浮動小数点のまま「全コマ分の秒数」へクランプしてから Int 化する
    /// (1e100 のような有限だが巨大な値でも Int 変換でトラップしない)。非有限の区間は読み飛ばす。
    public static func timedFrames(segments: [TimedViseme], frameCount: Int) -> [Viseme] {
        guard frameCount > 0 else { return [] }
        var out = [Viseme](repeating: .closed, count: frameCount)
        let limit = Double(frameCount) / envelopeRate
        for seg in segments {
            guard seg.start.isFinite, seg.end.isFinite else { continue }
            let s = min(max(seg.start, 0), limit)
            let e = min(max(seg.end, 0), limit)
            guard e > s else { continue }
            // 中央時刻 (k + 0.5) / rate が [s, e) に入る k の範囲(クランプ済みなので Int 化が安全)
            let lo = max(0, Int(ceil(s * envelopeRate - 0.5)))
            let hi = min(frameCount, Int(ceil(e * envelopeRate - 0.5)))
            guard lo < hi else { continue }
            for k in lo..<hi { out[k] = seg.vowel }
        }
        return out
    }
}

import Foundation

// キャラクター演出の純粋ロジック(B-7): 口の開閉・まばたき・セリフの表情タグ・話し中バウンス。
// 画面も素材も持たず、同じ入力には必ず同じ結果を返す(プレビューと書き出しで同じ見た目になるため)。

// MARK: - 口パク(ヒステリシス付きの開閉)

public enum MouthGate {
    /// この音量(RMS)を超えたら口を開く。
    public static let openLevel: Float = 0.03
    /// この音量を下回ったら口を閉じる。開く閾値より低くして、境目でのチラつきを防ぐ。
    public static let closeLevel: Float = 0.02

    /// 1/60 秒ごとのエンベロープから、各コマの口の開閉を先頭から順に決める。
    /// 状態を持つ(直前が開いていれば閉じ閾値を使う)ので、同じ配列なら必ず同じ結果になる。
    public static func states(_ env: [Float], open: Float = openLevel, close: Float = closeLevel) -> [Bool] {
        var isOpen = false
        return env.map { level in
            if isOpen { if level < close { isOpen = false } }
            else if level > open { isOpen = true }
            return isOpen
        }
    }
}

// MARK: - まばたき

public enum Blink {
    /// 目を閉じている時間(秒)。
    public static let duration = 0.15
    /// 瞬きの間隔の範囲(秒)。
    public static let intervalRange: ClosedRange<Double> = 3...5

    /// 時刻 t(秒)に目を閉じているか。seed(クリップ id など)から決まる擬似乱数で瞬きの時刻を作る。
    /// 最初の瞬きは開始から 3〜5 秒後。
    public static func isClosed(seed: String, t: Double) -> Bool {
        guard t >= 0 else { return false }
        for start in starts(seed: seed, until: t) where t >= start && t < start + duration {
            return true
        }
        return false
    }

    /// t 以前(t を含む)に始まる瞬きの開始時刻。決定的。
    public static func starts(seed: String, until t: Double) -> [Double] {
        var rng = SplitMix64(seed: fnv1a(seed))
        var out: [Double] = []
        var at = 0.0
        while true {
            at += intervalRange.lowerBound + (intervalRange.upperBound - intervalRange.lowerBound) * rng.nextUnit()
            if at > t { break }
            out.append(at)
        }
        return out
    }

    static func fnv1a(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return h
    }
}

/// 決定的な擬似乱数(SplitMix64)。0..<1 の値を返す。
struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func nextUnit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}

// MARK: - バウンス(話し中の上下の揺れ)

public enum Bounce {
    /// 音量がこの値のとき揺れが最大になる(RMS の目安)。
    public static let fullLevel: Float = 0.2
    /// 最大の上下の移動量(画面の高さに対する割合)。
    public static let maxOffset = 0.012
    /// 最大の拡大量(1 + この値)。
    public static let maxScale = 0.03

    /// 音量 level(RMS)から、画面高さに対する上方向の移動量(0 以上)。音量 0 で 0。
    public static func lift(level: Float) -> Double {
        let n = min(1, max(0, Double(level) / Double(fullLevel)))
        return maxOffset * n
    }

    /// 音量から拡大率(1 以上)。
    public static func scale(level: Float) -> Double {
        let n = min(1, max(0, Double(level) / Double(fullLevel)))
        return 1 + maxScale * n
    }
}

// MARK: - 表情タグ

public enum ExpressionTag {
    /// 先頭の `[名前]` を表情タグとして取り出す。返り値: タグ名(無ければ nil)と、タグを除いた本文。
    /// 例: "[笑顔]こんにちは" → ("笑顔", "こんにちは")。タグは先頭だけ。空の [] は本文に残す。
    public static func split(_ text: String) -> (tag: String?, body: String) {
        guard text.hasPrefix("[") else { return (nil, text) }
        guard let close = text.firstIndex(of: "]") else { return (nil, text) }
        let name = String(text[text.index(after: text.startIndex)..<close])
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.contains("[") { return (nil, text) }
        let body = String(text[text.index(after: close)...])
        return (trimmed, body)
    }

    /// 字幕・読み上げに使う本文(タグを除く)。
    public static func body(_ text: String) -> String { split(text).body }

    /// 表情名から画像を選ぶ。辞書に無い名前(未知のタグ)は nil = 通常の立ち絵のまま。
    public static func imagePath(for text: String, in expressions: [String: String]?) -> String? {
        guard let expressions, let tag = split(text).tag else { return nil }
        return expressions[tag]
    }
}

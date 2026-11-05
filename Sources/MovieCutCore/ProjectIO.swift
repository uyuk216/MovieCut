import Foundation

extension Project {
    /// プロジェクトの JSON を読む。大きさ・入れ子の深さ・個数に上限があり、読めた値は安全な範囲に収める(`sanitizeLoaded`)。
    public static func decode(from data: Data) throws -> Project {
        guard data.count <= InputLimits.maxProjectBytes else { throw InputLimits.Failure.tooLarge(what: "プロジェクトファイル", limit: InputLimits.maxProjectBytes) }
        guard InputLimits.jsonDepthWithinLimit(data) else { throw InputLimits.Failure.tooDeep }
        var p = try JSONDecoder().decode(Project.self, from: data)
        try p.sanitizeLoaded()
        return p
    }

    /// キーを並べ替え、整形して書き出す。"/" をエスケープしない(パスが読みやすい)。
    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return try e.encode(self)
    }

    public static func load(from url: URL) throws -> Project {
        try decode(from: InputLimits.readFile(url, limit: InputLimits.maxProjectBytes, what: "プロジェクトファイル"))
    }

    public func save(to url: URL) throws {
        try encoded().write(to: url, options: .atomic)
    }

    /// 解像度を変えたとき、文字やぼかしの大きさが見た目で変わらないように
    /// 面積比の平方根で fontSize / blur / strength を掛け直す(renderer.js scaleForResolution と同じ)。
    /// width / height 自体も更新する。位置や幅・高さは 0〜1 の割合なので変えない。
    public func scaledForResolution(newWidth: Int, newHeight: Int) -> Project {
        var p = self
        let k = (Double(newWidth) * Double(newHeight) / (Double(width) * Double(height))).squareRoot()
        p.width = newWidth
        p.height = newHeight
        guard k.isFinite, k > 0, abs(k - 1) >= 1e-6 else { return p }
        for ti in p.tracks.indices {
            for ci in p.tracks[ti].clips.indices {
                var c = p.tracks[ti].clips[ci]
                if (c.type == .text || c.type == .voice), let f = c.fontSize, f != 0 {
                    c.fontSize = max(8, (f * k).rounded())
                }
                if let b = c.blur, b > 0 { c.blur = (b * k).rounded() }
                if c.type == .blur, let s = c.strength, s > 0 { c.strength = (s * k).rounded() }
                // 動くぼかし(キー)の値も同じ比で直す
                for key in ["blur", "strength"] where c.keyframes[key] != nil {
                    c.keyframes[key] = c.keyframes[key]!.map { Keyframe(t: $0.t, v: ($0.v * k).rounded(), ease: $0.ease) }
                }
                p.tracks[ti].clips[ci] = c
            }
        }
        return p
    }
}

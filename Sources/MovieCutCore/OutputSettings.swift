import Foundation

// MARK: - 書き出し計画(サイズ・コーデックの決まり)

/// 書き出すときの実際のサイズとコーデック。アプリ(シート・メニュー・書き出し)とコマンドラインが同じ決まりを使う。
public struct OutputPlan: Equatable, Sendable {
    /// 入力できる幅・高さの範囲。
    public static let minSide = 64
    public static let maxSide = 8192
    /// H.264(ハードウェアエンコーダー)で書ける上限 = 4096×2304 相当(レベル 5.1 の 36864 マクロブロック)。
    public static let h264MaxSide = 4096
    public static let h264MaxArea = 4096 * 2304
    /// HEVC で書ける上限 = 8192×4320 相当の面積。
    public static let hevcMaxArea = 8192 * 4320

    /// 偶数に切り下げた書き出しサイズ。
    public var width: Int
    public var height: Int
    /// 指定されたコーデックと、実際に使うコーデック("h264" / "hevc")。
    public var requestedCodec: String
    public var codec: String
    /// 書き出せないときの理由(日本語)。nil なら書き出せる。
    public var error: String?

    /// 奇数を偶数に切り下げたか(元のサイズ)。
    public var evenRoundedFrom: (width: Int, height: Int)?
    public var usesFallbackCodec: Bool { requestedCodec != codec }

    public static func == (a: OutputPlan, b: OutputPlan) -> Bool {
        a.width == b.width && a.height == b.height && a.requestedCodec == b.requestedCodec && a.codec == b.codec && a.error == b.error
            && a.evenRoundedFrom?.width == b.evenRoundedFrom?.width && a.evenRoundedFrom?.height == b.evenRoundedFrom?.height
    }

    /// 重い組み合わせの目安 = 3840×2160×120 を超える(8K@60 以上・4K@240・5K@120 以上)。
    public static let heavyThreshold = 3840.0 * 2160.0 * 120.0
    public static let heavyNotice = "このサイズとフレームレートは書き出しにとても時間がかかります（またはお使いの Mac では書き出せないことがあります）"

    /// 書き出しが重すぎそうなら注意文(止めはしない)。
    public static func heavyWarning(width: Int, height: Int, fps: Double) -> String? {
        Double(width & ~1) * Double(height & ~1) * fps > heavyThreshold ? heavyNotice : nil
    }

    public static let fallbackNotice = "このサイズは H.264 で書き出せないので HEVC で書き出します"

    /// H.264 で書けるサイズか(偶数に直したあとのサイズで見る)。
    public static func h264Supports(width: Int, height: Int) -> Bool {
        let w = width & ~1, h = height & ~1
        return w <= h264MaxSide && h <= h264MaxSide && w * h <= h264MaxArea
    }

    /// HEVC で書けるサイズか。
    public static func hevcSupports(width: Int, height: Int) -> Bool {
        let w = width & ~1, h = height & ~1
        return w <= maxSide && h <= maxSide && w * h <= hevcMaxArea
    }

    public static func make(width: Int, height: Int, codec: String) -> OutputPlan {
        let w = width & ~1, h = height & ~1
        let requested = codec.lowercased() == "hevc" ? "hevc" : "h264"
        var plan = OutputPlan(width: w, height: h, requestedCodec: requested, codec: requested, error: nil, evenRoundedFrom: nil)
        if w != width || h != height { plan.evenRoundedFrom = (width, height) }
        if w < 2 || h < 2 {
            plan.error = "書き出しサイズが小さすぎます(\(width)×\(height))"
        } else if !hevcSupports(width: w, height: h) {
            plan.error = "書き出しサイズが大きすぎます(\(width)×\(height))。書き出せるのは 8192×4320 相当の面積までです"
        } else if requested == "h264", !h264Supports(width: w, height: h) {
            plan.codec = "hevc"
        }
        return plan
    }

    /// 偶数に直したことの説明("書き出しは 1080×606 になります")。直さないなら nil。
    public var evenNotice: String? {
        evenRoundedFrom == nil ? nil : "書き出しは \(width)×\(height) になります"
    }
}

// MARK: - 解像度の入力

/// 「解像度を入力」シートと動画設定シートが共有する入力の状態と検証。
public struct ResolutionInput: Equatable {
    public var widthText: String
    public var heightText: String
    public var lockAspect = false
    public var codec: String
    /// 重さの注意に使うフレームレート。
    public var fps: Double = 60
    /// 縦横比を固定するときの基準(幅 ÷ 高さ)。固定を入れた時点の値。
    private var lockedAspect: Double?

    public init(width: Int, height: Int, codec: String = "h264", fps: Double = 60) {
        widthText = String(width); heightText = String(height); self.codec = codec; self.fps = fps
    }

    public static let quickSizes: [(label: String, width: Int, height: Int)] = [
        ("1280×720", 1280, 720), ("1920×1080", 1920, 1080), ("2560×1440", 2560, 1440), ("3840×2160", 3840, 2160),
        ("1080×1920", 1080, 1920), ("1080×1080", 1080, 1080), ("4096×2160 (DCI 4K)", 4096, 2160), ("2048×1080", 2048, 1080),
    ]

    private static func parseInt(_ s: String) -> Int? {
        let t = s.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? s
        return Int(t.trimmingCharacters(in: .whitespaces))
    }

    public var width: Int? { Self.parseInt(widthText) }
    public var height: Int? { Self.parseInt(heightText) }

    /// 縦横比の固定を切り替える。入れた時点の縦横比を覚える。
    public mutating func setLock(_ on: Bool) {
        lockAspect = on
        if on, let w = width, let h = height, w > 0, h > 0 { lockedAspect = Double(w) / Double(h) } else if !on { lockedAspect = nil }
    }

    /// 幅を入力した。固定中は高さも合わせる。
    public mutating func setWidth(_ text: String) {
        widthText = text
        if lockAspect, let a = lockedAspect, let w = width, w > 0 { heightText = String(max(1, Int((Double(w) / a).rounded()))) }
    }

    /// 高さを入力した。固定中は幅も合わせる。
    public mutating func setHeight(_ text: String) {
        heightText = text
        if lockAspect, let a = lockedAspect, let h = height, h > 0 { widthText = String(max(1, Int((Double(h) * a).rounded()))) }
    }

    /// 縦横を入れ替える(固定中の縦横比も逆数にする)。
    public mutating func swap() {
        Swift.swap(&widthText, &heightText)
        if let a = lockedAspect, a > 0 { lockedAspect = 1 / a }
    }

    public mutating func set(width: Int, height: Int) {
        widthText = String(width); heightText = String(height)
        if lockAspect, width > 0, height > 0 { lockedAspect = Double(width) / Double(height) }
    }

    /// 入力の誤り(日本語)。nil なら適用できる。
    public static func validate(width: Int?, height: Int?) -> String? {
        guard let w = width, let h = height else { return "幅と高さは数字で入力してください" }
        let lo = OutputPlan.minSide, hi = OutputPlan.maxSide
        guard (lo...hi).contains(w), (lo...hi).contains(h) else { return "幅と高さは \(lo)〜\(hi) の整数で入力してください" }
        if !OutputPlan.hevcSupports(width: w, height: h) { return "このサイズは大きすぎて書き出せません(8192×4320 相当の面積まで)" }
        return nil
    }

    public var validation: String? { Self.validate(width: width, height: height) }
    public var isValid: Bool { validation == nil }

    /// 実際の書き出し計画(妥当なときだけ)。
    public var plan: OutputPlan? {
        guard isValid, let w = width, let h = height else { return nil }
        return OutputPlan.make(width: w, height: h, codec: codec)
    }

    /// 縦横比の表記("16:9")。約分して大きすぎる比は小数("1.78:1")。
    public static func aspectLabel(width: Int, height: Int) -> String {
        guard width > 0, height > 0 else { return "-" }
        func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
        let g = gcd(width, height)
        let a = width / g, b = height / g
        if a <= 32, b <= 32 { return "\(a):\(b)" }
        return String(format: "%.2f:1", Double(width) / Double(height))
    }

    /// 注意書きの並び(偶数に直す・コーデックの切り替え)。
    public var notices: [String] {
        guard let p = plan else { return [] }
        var out: [String] = []
        if let e = p.evenNotice { out.append(e) }
        if p.usesFallbackCodec { out.append(OutputPlan.fallbackNotice) }
        if let h = OutputPlan.heavyWarning(width: p.width, height: p.height, fps: fps) { out.append(h) }
        return out
    }

    /// 「縦横比 16:9 · 書き出しサイズ 1920×1080 · H.264」の 1 行。
    public var summary: String {
        guard let w = width, let h = height, w > 0, h > 0 else { return "-" }
        guard let p = plan else { return "縦横比 \(Self.aspectLabel(width: w, height: h))" }
        let name = { (c: String) in c == "hevc" ? "HEVC" : "H.264" }
        let codecText = p.usesFallbackCodec ? "\(name(p.requestedCodec)) → \(name(p.codec))" : name(p.codec)
        return "縦横比 \(Self.aspectLabel(width: w, height: h)) · 書き出しサイズ \(p.width)×\(p.height) · \(codecText)"
    }

    /// "1920x1080" / "1920×1080" / "1920 1080" を読む(コマンドライン・保存した履歴用)。
    public static func parseSize(_ s: String) -> (width: Int, height: Int)? {
        let t = (s.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? s).lowercased()
            .replacingOccurrences(of: "×", with: "x").replacingOccurrences(of: " ", with: "x")
        let parts = t.split(separator: "x").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return (parts[0], parts[1])
    }

    /// コマンドライン用: "WxH" を検証して返す。誤りは日本語のメッセージ。
    public static func parseAndValidate(_ s: String) -> Result<(width: Int, height: Int), InputError> {
        guard let sz = parseSize(s) else { return .failure(InputError(message: "--size は 幅x高さ で指定してください(例 1920x1080)")) }
        if let m = validate(width: sz.width, height: sz.height) { return .failure(InputError(message: m)) }
        return .success(sz)
    }
}

public struct InputError: Error, Equatable, LocalizedError {
    public var message: String
    public init(message: String) { self.message = message }
    public var errorDescription: String? { message }
}

// MARK: - フレームレートの入力

/// 「フレームレートを入力」シート・動画設定・コマンドラインが共有する、読み取りと検証。
public enum FrameRateInput {
    public static let rangeMessage = "フレームレートは 1〜240 の数字で入力してください(例 29.97、30000/1001)"

    /// 検証なしで数値だけ読む("29.97" "29,97" "30000/1001" "29.97fps" 全角も可)。
    public static func rawValue(_ text: String) -> Double? {
        var t = text.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text
        t = t.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        for suffix in ["fps", "コマ"] where t.hasSuffix(suffix) { t = String(t.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces) }
        t = t.replacingOccurrences(of: ",", with: ".")
        if t.contains("/") {
            let parts = t.split(separator: "/", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, let n = Double(parts[0]), let d = Double(parts[1]), d > 0, n.isFinite else { return nil }
            return n / d
        }
        guard !t.isEmpty, let v = Double(t), v.isFinite else { return nil }
        return v
    }

    /// 読み取って 1〜240 を確かめ、保存用の値(29.97 など)にして返す。
    public static func parse(_ text: String) -> Result<Double, InputError> {
        guard let v = rawValue(text) else { return .failure(InputError(message: rangeMessage)) }
        return validated(v)
    }

    public static func validated(_ v: Double) -> Result<Double, InputError> {
        guard v.isFinite, v >= FrameRate.minValue - 1e-9, v <= FrameRate.maxValue + 1e-9 else { return .failure(InputError(message: rangeMessage)) }
        return .success(FrameRate.canonical(v))
    }

    /// 「1フレーム = 33.367 ms · 毎秒 29.97 コマ」
    public static func describe(_ v: Double) -> String {
        let r = FrameRate.from(v)
        return "1フレーム = \(r.frameMilliseconds()) ms · 毎秒 \(FrameRate.label(v)) コマ"
    }
}

// MARK: - 最近使ったカスタム

/// 「最近使ったカスタム」(最大 3 件・新しい順・重複なし)。UserDefaults に文字列の配列で持つ(試験では別の UserDefaults を渡す)。
public struct RecentCustoms {
    public let key: String
    public let defaults: UserDefaults
    public let limit: Int

    public init(key: String, defaults: UserDefaults = DataLocations.current.defaults, limit: Int = 3) {
        self.key = key; self.defaults = defaults; self.limit = limit
    }

    public static func resolutions(_ defaults: UserDefaults = DataLocations.current.defaults) -> RecentCustoms { RecentCustoms(key: "recentCustomResolutions", defaults: defaults) }
    public static func frameRates(_ defaults: UserDefaults = DataLocations.current.defaults) -> RecentCustoms { RecentCustoms(key: "recentCustomFrameRates", defaults: defaults) }

    public var items: [String] { Array((defaults.stringArray(forKey: key) ?? []).prefix(limit)) }

    /// 先頭に入れる。すでにあれば先頭へ移し、上限を超えた古いものは捨てる。
    public func add(_ s: String) {
        var list = items.filter { $0 != s }
        list.insert(s, at: 0)
        defaults.set(Array(list.prefix(limit)), forKey: key)
    }

    public func clear() { defaults.removeObject(forKey: key) }

    // 型付きの出し入れ
    public var sizes: [(width: Int, height: Int)] { items.compactMap { ResolutionInput.parseSize($0) } }
    public func addSize(width: Int, height: Int) { add("\(width)x\(height)") }
    public var rates: [Double] { items.compactMap { Double($0) } }
    public func addRate(_ v: Double) { add(String(FrameRate.canonical(v))) }
}

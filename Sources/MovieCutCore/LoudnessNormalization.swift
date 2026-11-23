import Foundation
import AVFoundation

// MARK: - エラー

public enum LoudnessNormalizationError: LocalizedError {
    case unsupportedFormat(path: String)
    case cannotRead(path: String, underlying: Error?)
    case cannotWrite(url: URL, underlying: Error?)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let path):
            return "ラウドネス正規化に使えない音声形式です(48 kHz・ステレオ・Float32 のみ対応): \(path)"
        case .cannotRead(let path, let e):
            return "ラウドネス正規化のために音声を読み込めませんでした: \(path)" + (e.map { "(\($0.localizedDescription))" } ?? "")
        case .cannotWrite(let url, let e):
            return "ラウドネス正規化した音声を書き出せませんでした: \(url.lastPathComponent)" + (e.map { "(\($0.localizedDescription))" } ?? "")
        }
    }
}

// MARK: - 設定

/// 書き出し時のラウドネス正規化の設定(完成したミックス全体に 1 つのゲインをかける)。
/// クリップ単位の `AudioFx.Normalize` とは別物。既定は無効(従来どおりの書き出し)。
public struct LoudnessNormalizationSettings: Equatable, Sendable {
    /// 目標ラウドネス(LUFS)の有効範囲。
    public static let targetRange: ClosedRange<Double> = -36 ... -5
    /// トゥルーピーク上限(dBTP)の有効範囲。
    public static let ceilingRange: ClosedRange<Double> = -6 ... 0
    public static let defaultTargetLUFS = -14.0
    public static let defaultCeilingDbTP = -1.0

    public var enabled: Bool
    public var targetLUFS: Double
    public var truePeakCeilingDbTP: Double

    /// 範囲外(NaN を含む)は有効範囲へ丸める。NaN は既定値にする。
    public static func clampedTarget(_ v: Double) -> Double {
        v.isNaN ? defaultTargetLUFS : min(max(v, targetRange.lowerBound), targetRange.upperBound)
    }

    public static func clampedCeiling(_ v: Double) -> Double {
        v.isNaN ? defaultCeilingDbTP : min(max(v, ceilingRange.lowerBound), ceilingRange.upperBound)
    }

    public init(enabled: Bool = false, targetLUFS: Double = defaultTargetLUFS, truePeakCeilingDbTP: Double = defaultCeilingDbTP) {
        self.enabled = enabled
        self.targetLUFS = Self.clampedTarget(targetLUFS)
        self.truePeakCeilingDbTP = Self.clampedCeiling(truePeakCeilingDbTP)
    }

    /// 無効(従来の書き出し)。
    public static let disabled = LoudnessNormalizationSettings()
    /// YouTube の目安: −14 LUFS、ピーク上限 −1 dBTP。
    public static let youtube = LoudnessNormalizationSettings(enabled: true)

    /// 目標だけ変えた有効設定(ピーク上限は既定)。
    public static func enabled(targetLUFS: Double) -> LoudnessNormalizationSettings {
        LoudnessNormalizationSettings(enabled: true, targetLUFS: targetLUFS)
    }
}

// MARK: - 計画

/// 計測値と設定から決めた、かけるゲイン。
public struct LoudnessNormalizationPlan: Equatable, Sendable {
    /// 元の計測値。
    public var measured: LoudnessReport
    /// 目標に合わせるために要るゲイン(dB)。統合が −∞ のときは 0。
    public var requestedGainDb: Double
    /// 実際にかけるゲイン(dB)。無効・無音は 0。トゥルーピーク上限で抑えられることがある。
    public var appliedGainDb: Double
    /// 上限のために `requestedGainDb` より小さく(または負に)した。
    public var limitedByTruePeak: Bool
    /// 10^(applied/20)。
    public var linearGain: Double

    /// ゲインが 0 なら音声は変わらない(新しいファイルは作らない)。
    public var isNoOp: Bool { appliedGainDb == 0 }
}

public enum LoudnessNormalization {
    /// 純粋関数。無効なら適用 0。完全な無音(統合も真のピークも −∞)も適用 0。
    /// 統合が −∞ でもピークが有限なら(400 ms 未満で momentary 窓が埋まらないクリップ)、ピーク上限だけを適用する。
    /// ピーク上限は増幅のときだけでなく、目標へ下げるときも効く(`ceiling − truePeak` が下限)。
    public static func plan(report: LoudnessReport, settings: LoudnessNormalizationSettings) -> LoudnessNormalizationPlan {
        let target = LoudnessNormalizationSettings.clampedTarget(settings.targetLUFS)
        let ceiling = LoudnessNormalizationSettings.clampedCeiling(settings.truePeakCeilingDbTP)
        guard settings.enabled else {
            let requested = report.integrated.isFinite ? target - report.integrated : 0
            return LoudnessNormalizationPlan(measured: report, requestedGainDb: requested, appliedGainDb: 0, limitedByTruePeak: false, linearGain: 1)
        }
        guard report.integrated.isFinite else {
            // 目標へ合わせるゲインは定義できないので 0。ピークが測れていれば上限だけ効かせる。
            guard report.truePeakDb.isFinite else {
                return LoudnessNormalizationPlan(measured: report, requestedGainDb: 0, appliedGainDb: 0, limitedByTruePeak: false, linearGain: 1)
            }
            let gain = min(0, ceiling - report.truePeakDb)
            return LoudnessNormalizationPlan(measured: report, requestedGainDb: 0, appliedGainDb: gain,
                                             limitedByTruePeak: gain < 0, linearGain: pow(10, gain / 20))
        }
        let requested = target - report.integrated
        var gain = requested
        var limited = false
        if report.truePeakDb.isFinite, report.truePeakDb + gain > ceiling {
            gain = ceiling - report.truePeakDb
            limited = true
        }
        return LoudnessNormalizationPlan(measured: report, requestedGainDb: requested, appliedGainDb: gain,
                                         limitedByTruePeak: limited, linearGain: pow(10, gain / 20))
    }

    /// `input`(48 kHz ステレオ Float32 の CAF)の全サンプルに `linearGain` をかけて `output` へ書く。
    /// フレーム数は入力と完全に同じ。[-1, 1] にクランプする(ミキサーと同じ流儀)。16384 フレームずつ流す。
    public static func apply(linearGain: Double, input: URL, output: URL) throws {
        let inFile: AVAudioFile
        do { inFile = try AVAudioFile(forReading: input) }
        catch { throw LoudnessNormalizationError.cannotRead(path: input.path, underlying: error) }
        let fmt = inFile.processingFormat
        guard fmt.sampleRate == LoudnessMeter.sampleRate, fmt.channelCount == 2, fmt.commonFormat == .pcmFormatFloat32 else {
            throw LoudnessNormalizationError.unsupportedFormat(path: input.path)
        }

        try? FileManager.default.removeItem(at: output)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: LoudnessMeter.sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let chunk: AVAudioFrameCount = 16384
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunk) else {
            throw LoudnessNormalizationError.cannotRead(path: input.path, underlying: nil)
        }
        let gain = Float(linearGain)
        do {
            let out = try AVAudioFile(forWriting: output, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            while inFile.framePosition < inFile.length {
                let want = AVAudioFrameCount(min(Int64(chunk), inFile.length - inFile.framePosition))
                do { try inFile.read(into: buf, frameCount: want) }
                catch { throw LoudnessNormalizationError.cannotRead(path: input.path, underlying: error) }
                let n = Int(buf.frameLength)
                guard n > 0, let c = buf.floatChannelData else { break }
                for ch in 0..<2 {
                    let p = c[ch]
                    for i in 0..<n { p[i] = min(max(p[i] * gain, -1), 1) }
                }
                try out.write(from: buf)
            }
        } catch let e as LoudnessNormalizationError {
            try? FileManager.default.removeItem(at: output)
            throw e
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw LoudnessNormalizationError.cannotWrite(url: output, underlying: error)
        }
    }

    /// 便利関数の結果。
    public struct Result: Equatable, Sendable {
        public var plan: LoudnessNormalizationPlan
        /// 適用済みファイル。適用ゲインが 0 のときは nil(呼び出し側は元のファイルをそのまま使う)。
        public var outputURL: URL?
    }

    /// ミックスファイルを測る → 計画 → 適用ゲインが 0 でなければ `output` へ適用済みファイルを作る。
    /// 設定が無効なら計測もしない(計画は無音扱いの 0 ゲイン)。
    public static func normalize(input: URL, output: URL, settings: LoudnessNormalizationSettings) throws -> Result {
        guard settings.enabled else {
            let empty = LoudnessReport(integrated: -.infinity, shortTermMax: -.infinity, truePeakDb: -.infinity, samplePeakDb: -.infinity, duration: 0)
            return Result(plan: plan(report: empty, settings: settings), outputURL: nil)
        }
        let report: LoudnessReport
        do { report = try LoudnessAnalysis.measureFile(input) }
        catch let e as CocoaError where e.code == .fileReadUnsupportedScheme { throw LoudnessNormalizationError.unsupportedFormat(path: input.path) }
        catch { throw LoudnessNormalizationError.cannotRead(path: input.path, underlying: error) }
        let p = plan(report: report, settings: settings)
        guard !p.isNoOp else { return Result(plan: p, outputURL: nil) }
        try apply(linearGain: p.linearGain, input: input, output: output)
        return Result(plan: p, outputURL: output)
    }

    /// 書き出し時に stderr へ出す 1 行(計測値・目標・適用ゲイン・ピーク制限の有無)。
    public static func logLine(_ plan: LoudnessNormalizationPlan, settings: LoudnessNormalizationSettings) -> String {
        func f(_ v: Double) -> String { v.isFinite ? String(format: "%.1f", v) : "-∞" }
        let m = plan.measured
        if !m.integrated.isFinite && !m.truePeakDb.isFinite { return "ラウドネス正規化: 無音のため変更しません" }
        if !m.integrated.isFinite {
            return "ラウドネス正規化: 統合ラウドネスを測れない(400 ms 未満など)ため、トゥルーピーク上限 \(f(settings.truePeakCeilingDbTP)) dBTP のみ適用: "
                + "計測 \(f(m.truePeakDb)) dBTP → 適用ゲイン \(String(format: "%+.1f", plan.appliedGainDb)) dB"
        }
        return "ラウドネス正規化: 計測 \(f(m.integrated)) LUFS(トゥルーピーク \(f(m.truePeakDb)) dBTP) → 目標 \(f(settings.targetLUFS)) LUFS、"
            + "適用ゲイン \(String(format: "%+.1f", plan.appliedGainDb)) dB" + (plan.limitedByTruePeak ? "(トゥルーピーク上限 \(f(settings.truePeakCeilingDbTP)) dBTP で制限)" : "")
    }
}

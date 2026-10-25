import Foundation
import AVFoundation

/// 音声合成の結果(WAV ファイルと長さ)。
public struct VoiceResult {
    public var url: URL
    public var duration: Double
    public init(url: URL, duration: Double) { self.url = url; self.duration = duration }
}

/// セリフ → 音声ファイル。VOICEVOX / AquesTalk / say は後のマイルストーンでこれを実装する。
public protocol VoiceProvider: AnyObject {
    func synthesize(character: Character, text: String, in directory: URL) async throws -> VoiceResult
}

/// 検証用: 合成せず、キャラごとに高さの違う「ピー」(フェード付きのトーンバースト)を作る。
/// 呼び出し順に durations / frequencies を巡回して使う(既定は 1.7 秒 220 Hz → 1.6 秒 330 Hz)。
public final class ToneVoiceProvider: VoiceProvider {
    private let durations: [Double]
    private let frequencies: [Double]
    private let lock = NSLock()
    private var calls = 0

    public init(durations: [Double] = [1.7, 1.6], frequencies: [Double] = [220, 330]) {
        self.durations = durations.isEmpty ? [1.0] : durations
        self.frequencies = frequencies.isEmpty ? [220] : frequencies
    }

    public func synthesize(character: Character, text: String, in directory: URL) async throws -> VoiceResult {
        let n = lock.withLock { () -> Int in calls += 1; return calls - 1 }
        let dur = durations[n % durations.count], freq = frequencies[n % frequencies.count]
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("tone-\(n)-\(UUID().uuidString.prefix(6)).wav")
        try ToneVoiceProvider.writeTone(to: url, duration: dur, frequency: freq)
        return VoiceResult(url: url, duration: dur)
    }

    /// 24 kHz モノ 16bit の WAV(取り込み側のサンプルレート変換とモノ→ステレオも通るように、わざと 48k ステレオにしない)。
    public static func writeTone(to url: URL, duration: Double, frequency: Double, sampleRate: Double = 24000, amplitude: Float = 0.5) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let n = Int(duration * sampleRate)
        guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(n)),
              let ch = buf.floatChannelData else { throw CocoaError(.fileWriteUnknown) }
        buf.frameLength = AVAudioFrameCount(n)
        let fade = Int(0.03 * sampleRate)
        for i in 0..<n {
            let t = Double(i) / sampleRate
            // 基本波 + 2 倍音、4 Hz で強弱をつけて口パクの検出にも使える形にする
            let tone = sin(2 * .pi * frequency * t) + 0.3 * sin(4 * .pi * frequency * t)
            let syl = 0.65 + 0.35 * sin(2 * .pi * 4 * t)
            let env = min(1, Double(i) / Double(max(1, fade)), Double(n - 1 - i) / Double(max(1, fade)))
            ch[0][i] = Float(tone / 1.3 * syl * env) * amplitude
        }
        try file.write(from: buf)
    }
}

import Foundation
import AVFoundation

/// 合成した声の WAV に、音程を保ったまま速さをかける後処理(AquesTalk の「話す速さ」の反映用)。
///
/// AquesTalkPlayer のコマンドライン(-P / -T / -W)には速さの指定が無いため、内蔵 `AquesTalkSynthesizer` と
/// プラグイン `AquesTalkPluginSynthesizer` の両方が、生成した WAV をこの部品で伸縮してからキャッシュへ置く。
/// 実装は書き出し側の `AudioRemap` の速度変換と同じ流儀: AVAudioEngine のオフラインレンダリング +
/// `AVAudioUnitTimePitch`(`ShuttleAudio.makeRateUnit`)、出力は入力フレーム数 ÷ rate ちょうど、
/// ユニットの遅れぶんは頭を捨てる。出力は入力と同じサンプルレート・チャンネル数の 16bit PCM WAV。
///
/// 速さ 100(%)・未指定では呼び出し側がこの部品を通さない(無変換)。それが参照 WAV との
/// バイト一致(実プレイヤーの等価性テスト)を保つための互換条件。
public enum VoiceTimeStretch {
    /// この速さ(%)で伸縮が要るか。nil・100・不正値(0 以下)は無変換。
    public static func needsStretch(speed: Double?) -> Bool {
        guard let speed, speed > 0 else { return false }
        return speed != 100
    }

    /// `input` の WAV を `speedPercent` % の速さ(音程保持)にして `output` へ書く。尺は入力 ÷ (speedPercent / 100)。
    /// 書き込みは同じフォルダの一時ファイルを経由し、成功したときだけ `output` を差し替える
    /// (失敗時に壊れたファイルをキャッシュへ残さないため)。
    public static func apply(input: URL, speedPercent: Double, output: URL) throws {
        let rate = min(max(speedPercent / 100, 1.0 / 32.0), 32.0)   // AVAudioUnitTimePitch の rate の範囲に収める
        let file = try AVAudioFile(forReading: input)
        guard file.length > 0 else { throw VoiceError.message("速さを変える元の音声が空でした。") }
        // 変換は非インターリーブ Float32 で統一する(チャンネルごとのコピーを安全にするため)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: file.processingFormat.sampleRate, channels: file.processingFormat.channelCount, interleaved: false) else {
            throw VoiceError.message("速さの変換用フォーマットを作れませんでした。")
        }
        let outFrames = max(1, Int((Double(file.length) / rate).rounded()))
        let tmp = output.deletingLastPathComponent().appendingPathComponent("moviecut-stretch-\(UUID().uuidString).wav")
        do {
            try render(file: file, format: format, rate: rate, outFrames: outFrames, to: tmp)
            let fm = FileManager.default
            if fm.fileExists(atPath: output.path) { try fm.removeItem(at: output) }
            try fm.moveItem(at: tmp, to: output)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }

    private static func render(file: AVAudioFile, format fmt: AVAudioFormat, rate: Double, outFrames: Int, to outURL: URL) throws {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let unit = ShuttleAudio.makeRateUnit(rate: rate, keepPitch: true)
        engine.attach(player); engine.attach(unit)
        engine.connect(player, to: unit, format: fmt)
        engine.connect(unit, to: engine.mainMixerNode, format: fmt)
        let maxFrames: AVAudioFrameCount = 4096
        do { try engine.enableManualRenderingMode(.offline, format: fmt, maximumFrameCount: maxFrames) }
        catch { throw VoiceError.message("速さの変換を準備できませんでした: \(error.localizedDescription)") }
        engine.prepare()
        do { try engine.start() } catch { throw VoiceError.message("速さの変換を開始できませんでした: \(error.localizedDescription)") }
        defer { player.stop(); engine.stop() }
        let latencyFrames = Int((unit.latency * fmt.sampleRate).rounded())   // 先頭の遅れ(TimePitch の処理の遅れ)は捨てる
        player.scheduleFile(file, at: nil, completionHandler: nil)
        player.play()

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: fmt.sampleRate,
            AVNumberOfChannelsKey: Int(fmt.channelCount),
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let out = try AVAudioFile(forWriting: outURL, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buf = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: maxFrames) else {
            throw VoiceError.message("速さの変換用バッファを作れませんでした。")
        }
        var skip = latencyFrames
        var written = 0
        var stalls = 0
        var prevProgress = -latencyFrames
        while written < outFrames {
            let want = AVAudioFrameCount(min(Int(maxFrames), outFrames - written + skip))
            let st: AVAudioEngineManualRenderingStatus
            do { st = try engine.renderOffline(want, to: buf) } catch { throw VoiceError.message("速さの変換に失敗しました: \(error.localizedDescription)") }
            switch st {
            case .success:
                break
            case .insufficientDataFromInputNode, .cannotDoInCurrentContext:
                stalls += 1
                if stalls > 200 { throw VoiceError.message("速さの変換が進まなくなりました。") }
                Thread.sleep(forTimeInterval: 0.001)
                continue
            case .error:
                throw VoiceError.message("速さの変換に失敗しました。")
            @unknown default:
                throw VoiceError.message("速さの変換に失敗しました。")
            }
            guard let ch = buf.floatChannelData else { throw VoiceError.message("速さの変換でチャンネルを読めませんでした。") }
            var n = Int(buf.frameLength)
            var from = 0
            if skip > 0 { let d = min(skip, n); skip -= d; from = d; n -= d }
            n = min(n, outFrames - written)
            if n > 0 {
                guard let ob = AVAudioPCMBuffer(pcmFormat: out.processingFormat, frameCapacity: AVAudioFrameCount(n)),
                      let och = ob.floatChannelData else { throw VoiceError.message("速さの変換用バッファを作れませんでした。") }
                ob.frameLength = AVAudioFrameCount(n)
                for c in 0..<Int(fmt.channelCount) { och[c].update(from: ch[c] + from, count: n) }
                try out.write(from: ob)
                written += n
            }
            let progress = written - skip
            if progress == prevProgress {
                stalls += 1
                if stalls > 200 { throw VoiceError.message("速さの変換が進まなくなりました。") }
                Thread.sleep(forTimeInterval: 0.001)
            } else {
                stalls = 0
                prevProgress = progress
            }
        }
    }
}

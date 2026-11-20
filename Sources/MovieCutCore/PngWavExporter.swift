import Foundation
import AVFoundation
import CoreGraphics

// MARK: - 連番 PNG + WAV 書き出し(W3-25 / YMM4 監査 #70)
//
// YMM4 の「連番PNG+WAV出力」(FileWriter.PngWav)の MovieCut 版。
// 映像は既存の `Renderer`(プレビュー・書き出しと同じ描画経路)で 1 コマずつ描いて
// `frame_000001.png` のような連番 PNG にし、音声は既存のミックス経路
// (`AudioMixer`)で 1 本の WAV(48 kHz・ステレオ・16 ビット PCM)にする。
// 既存の連番画像書き出し(`ImageSequenceExporter`: PNG/JPEG のみ・最低 5 桁)とは別形式として
// 追加する(既存形式の挙動は変えない)。こちらは最低 6 桁・PNG 固定・WAV 同梱が仕様。
//
// - fps はプロジェクト設定(`Project.frameRate`)に従う。
// - 1 コマずつ描いて書くので、長尺でもメモリは 1 コマ分しか持たない。
// - 音声が無いプロジェクトでも、尺いっぱいの無音 WAV を書く(NLE 側で映像と同期が取れる)。
// - ラウドネス正規化は任意(既定は無効 = 従来のミックスそのまま)。有効時は WAV にだけ効く。
// - キャンセル・失敗のときは、その回に書いたファイルをすべて消す(中途半端な組を残さない)。
//   WAV は、その回に作ったもの(.part から置き換えたもの)だけを消す。WAV 工程に入る前に
//   止まったときは、同名の既存 WAV(前回の書き出し結果など)には触らない(PNG 側の
//   「書けたものだけ消す」流儀に揃える。既存 WAV の置き換えは、変換が成功してから行う)。

/// 連番 PNG + WAV の書き出し設定。
public struct PngWavOptions: Equatable, Sendable {
    /// 連番と WAV の基底名。PNG は `<base>_000001.png` …、WAV は `<base>.wav`。
    public var base: String
    /// 完成ミックスへのラウドネス正規化(既定は無効)。
    public var loudness: LoudnessNormalizationSettings

    public init(base: String = "frame", loudness: LoudnessNormalizationSettings = .disabled) {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        self.base = trimmed.isEmpty ? "frame" : trimmed
        self.loudness = loudness
    }

    public static let standard = PngWavOptions()
}

/// 連番 PNG + WAV の書き出し計画(シート表示とテスト用)。
public struct PngWavPlan: Equatable, Sendable {
    public var frameCount: Int
    /// 連番の桁数(最低 6。コマ数が 999999 を超えるなら足りるだけ)。
    public var digits: Int
    public var firstFileName: String
    public var lastFileName: String
    public var wavFileName: String
    public var width: Int
    public var height: Int
}

public enum PngWavExporter {
    public struct Result: Equatable, Sendable {
        public var directory: URL
        public var frameCount: Int
        public var files: [String]
        public var wavURL: URL
        /// WAV の長さ(秒)。
        public var wavDuration: Double
        /// 実際に音のあるクリップがあったか(false なら WAV は無音)。
        public var hasAudio: Bool
    }

    /// 連番の桁数(最低 6)。
    public static func digits(frameCount n: Int) -> Int { max(6, String(max(1, n)).count) }

    /// `frame_000001.png` 形式の名前(番号は 1 から)。
    public static func fileName(base: String, index: Int, digits: Int) -> String {
        let num = String(index)
        return base + "_" + String(repeating: "0", count: max(0, digits - num.count)) + num + ".png"
    }

    public static func plan(project: Project, range: ExportRange? = nil, options: PngWavOptions = .standard) -> PngWavPlan {
        let n = project.frameRate.frameCount(duration: range?.duration ?? project.endTime)
        let d = digits(frameCount: n)
        return PngWavPlan(frameCount: n, digits: d,
                          firstFileName: fileName(base: options.base, index: 1, digits: d),
                          lastFileName: fileName(base: options.base, index: max(1, n), digits: d),
                          wavFileName: options.base + ".wav",
                          width: project.width, height: project.height)
    }

    /// `directory` に連番 PNG と WAV を書く。進み具合は PNG が 0〜0.9、WAV が 0.9〜1。
    /// キャンセル・失敗のときは、その回に書いたファイルをすべて消して投げ直す。
    @discardableResult
    public static func export(project: Project, assets: RenderAssets = RenderAssets(), range: ExportRange? = nil,
                              options: PngWavOptions = .standard, to directory: URL,
                              pluginEffectProviders: [any VideoEffectProviding] = [],
                              vst3Provider: (any AudioEffectProviding)? = nil,
                              progress: ((Double) -> Void)? = nil) async throws -> Result {
        let p = plan(project: project, range: range, options: options)
        guard p.frameCount > 0 else { throw ExportError.emptyProject }
        guard project.width > 0, project.height > 0 else { throw ExportError.noOutputSize(width: project.width, height: project.height) }
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { throw ExportError.cannotCreateWriter(error) }
        let rate = project.frameRate
        let t0 = range?.start ?? 0
        let loudness = options.loudness

        let work = Task.detached(priority: .userInitiated) { () throws -> Result in
            var written: [String] = []
            let wavURL = directory.appendingPathComponent(p.wavFileName)
            // F-5: この回に WAV を作ったか(.part の置き換えまで進んだか)と、変換途中の .part の場所。
            // cleanup が既存 WAV を巻き込まないよう、作ったものだけを消すための記録。
            var wavCreated = false
            var wavPartURL: URL? = nil
            func cleanup() {
                for f in written { try? FileManager.default.removeItem(at: directory.appendingPathComponent(f)) }
                if let part = wavPartURL { try? FileManager.default.removeItem(at: part) }
                if wavCreated { try? FileManager.default.removeItem(at: wavURL) }
            }
            do {
                // 映像: 1 コマずつ描いて書く(長尺でも 1 コマ分しかメモリに置かない)
                if let vst3Provider { assets.setVST3Provider(vst3Provider) }
                let renderer = Renderer(project: project, assets: assets, pluginEffectProviders: pluginEffectProviders)
                assets.beginExportMode()
                var last = -1.0
                for i in 0..<p.frameCount {
                    if Task.isCancelled { throw CancellationError() }
                    let name = fileName(base: options.base, index: i + 1, digits: p.digits)
                    try autoreleasepool {
                        guard let img = renderer.renderImage(t: t0 + rate.time(ofFrame: i)) else { throw ExportError.pixelBufferFailed(-1) }
                        try StillExporter.writeImage(img, format: .png, to: directory.appendingPathComponent(name))
                    }
                    written.append(name)
                    let v = Double(i + 1) / Double(p.frameCount) * 0.9
                    if v - last >= 0.001 || i + 1 == p.frameCount { last = v; progress?(v) }
                }
                assets.endExportMode()
                if Task.isCancelled { throw CancellationError() }

                // 音声: 既存ミックス経路 → (任意でラウドネス正規化) → WAV 16 ビット
                let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("moviecut-pngwav-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: tmpDir) }
                let mixURL = tmpDir.appendingPathComponent("mix.caf")
                let mix: AudioMixer.MixResult
                do { mix = try AudioMixer.mixdownDetailed(project: project, to: mixURL, range: range, vst3Provider: vst3Provider) }
                catch { throw ExportError.audioMixFailed(error) }
                var audioURL = mixURL
                if mix.sourceCount > 0, loudness.enabled {
                    let normURL = tmpDir.appendingPathComponent("mix-norm.caf")
                    let res = try LoudnessNormalization.normalize(input: mixURL, output: normURL, settings: loudness)
                    FileHandle.standardError.write(Data((LoudnessNormalization.logLine(res.plan, settings: loudness) + "\n").utf8))
                    if let applied = res.outputURL { audioURL = applied }
                }
                if Task.isCancelled { throw CancellationError() }
                let partWav = directory.appendingPathComponent(".moviecut-\(UUID().uuidString).wav.part")
                wavPartURL = partWav
                do {
                    try WavFileWriter.convertToWav16(input: audioURL, output: partWav)
                    try? FileManager.default.removeItem(at: wavURL)
                    try FileManager.default.moveItem(at: partWav, to: wavURL)
                    // ここから先は wavURL が「この回の WAV」。失敗・キャンセル時の cleanup で消してよい。
                    wavCreated = true
                    wavPartURL = nil
                } catch {
                    try? FileManager.default.removeItem(at: partWav)
                    throw error
                }
                progress?(1.0)
                // WAV を作った直後にキャンセルされていたら、その回のファイル一式を残さない(cleanup 側で消える)。
                if Task.isCancelled { throw CancellationError() }
                let info = try WavFileWriter.info(of: wavURL)
                return Result(directory: directory, frameCount: written.count, files: written,
                              wavURL: wavURL, wavDuration: info.duration, hasAudio: mix.sourceCount > 0)
            } catch {
                assets.endExportMode()
                cleanup()
                throw error
            }
        }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }
}

// MARK: - WAV(16 ビット PCM)の読み書き

/// 48 kHz ステレオ Float32 の音声ファイル(ミックスの出力)を、48 kHz ステレオ 16 ビット PCM の
/// WAV に変換する。ヘッダは先に書けるよう、フレーム数は入力ファイルの長さから決める。
/// 変換は 16384 フレームずつ流す(長尺でもメモリに全部は置かない)。
public enum WavFileWriter {
    public struct Info: Equatable, Sendable {
        public var sampleRate: Int
        public var channels: Int
        public var frames: Int
        public var duration: Double { sampleRate > 0 ? Double(frames) / Double(sampleRate) : 0 }
    }

    /// WAV ファイルのヘッダ(先頭 44 バイト)を読む。WAV でなければ nil。
    public static func info(of url: URL) throws -> Info {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        let head = try fh.read(upToCount: 44) ?? Data()
        guard head.count >= 44,
              head[0..<4] == Data("RIFF".utf8), head[8..<12] == Data("WAVE".utf8),
              head[12..<16] == Data("fmt ".utf8), head[36..<40] == Data("data".utf8) else {
            throw ExportError.writerFailed(nil)
        }
        func u16(_ o: Int) -> Int { Int(head[o]) | Int(head[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { Int(head[o]) | Int(head[o + 1]) << 8 | Int(head[o + 2]) << 16 | Int(head[o + 3]) << 24 }
        let channels = u16(22), bits = u16(34), rate = u32(24), dataBytes = u32(40)
        guard channels > 0, bits == 16, rate > 0 else { throw ExportError.writerFailed(nil) }
        return Info(sampleRate: rate, channels: channels, frames: dataBytes / (channels * 2))
    }

    /// Float32 ステレオ(48 kHz)の `input` を 16 ビット PCM WAV にする。サンプルは [-1, 1] にクランプ。
    public static func convertToWav16(input: URL, output: URL) throws {
        let inFile: AVAudioFile
        do { inFile = try AVAudioFile(forReading: input) }
        catch { throw ExportError.audioReadFailed(error) }
        let fmt = inFile.processingFormat
        guard fmt.channelCount == 2, fmt.commonFormat == .pcmFormatFloat32 else { throw ExportError.audioReadFailed(nil) }
        let frames = Int(inFile.length)
        let sampleRate = Int(fmt.sampleRate)

        try? FileManager.default.removeItem(at: output)
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let fh = try FileHandle(forWritingTo: output)
        defer { try? fh.close() }
        // RIFF ヘッダ(44 バイト、16 ビット・ステレオ・リトルエンディアン)
        var head = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { head.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { head.append(contentsOf: $0) } }
        let dataBytes = frames * 4
        head.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + dataBytes))
        head.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(2)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 4)); u16(4); u16(16)
        head.append(contentsOf: Array("data".utf8)); u32(UInt32(dataBytes))
        try fh.write(contentsOf: head)

        let chunk: AVAudioFrameCount = 16384
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunk) else { throw ExportError.audioReadFailed(nil) }
        while inFile.framePosition < inFile.length {
            let want = min(chunk, AVAudioFrameCount(inFile.length - inFile.framePosition))
            try inFile.read(into: buf, frameCount: want)
            let n = Int(buf.frameLength)
            guard n > 0, let c = buf.floatChannelData else { break }
            var data = Data(capacity: n * 4)
            for i in 0..<n {
                for ch in 0..<2 {
                    let v = Int16((max(-1, min(1, c[ch][i])) * 32767).rounded())
                    var x = v.littleEndian
                    withUnsafeBytes(of: &x) { data.append(contentsOf: $0) }
                }
            }
            try fh.write(contentsOf: data)
        }
    }
}

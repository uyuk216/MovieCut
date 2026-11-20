import Foundation
import AVFoundation
import CoreVideo
import CoreGraphics

// MARK: - エラー

public enum ExportError: LocalizedError {
    case emptyProject
    case noOutputSize(width: Int, height: Int)
    case cannotCreateWriter(Error)
    case cannotAddInput(String)
    case cannotStartWriting(Error?)
    case pixelBufferFailed(Int32)
    case appendFailed(frame: Int, underlying: Error?)
    case audioMixFailed(Error)
    case audioReadFailed(Error?)
    case writerFailed(Error?)
    case noAudio
    case invalidSize(String)

    public var errorDescription: String? {
        func tail(_ e: Error?) -> String { e.map { "(\($0.localizedDescription))" } ?? "" }
        switch self {
        case .emptyProject: return "タイムラインが空です"
        case .noOutputSize(let w, let h): return "書き出しサイズが小さすぎます(\(w)×\(h))"
        case .cannotCreateWriter(let e): return "書き出しファイルを作れませんでした" + tail(e)
        case .cannotAddInput(let what): return "\(what)の書き出し設定を使えませんでした"
        case .cannotStartWriting(let e): return "書き出しを始められませんでした" + tail(e)
        case .pixelBufferFailed(let r): return "フレームのメモリを確保できませんでした(CVReturn \(r))"
        case .appendFailed(let f, let e): return "\(f) コマ目を書き込めませんでした" + tail(e)
        case .audioMixFailed(let e): return "音声のミックスに失敗しました: \(e.localizedDescription)"
        case .audioReadFailed(let e): return "ミックスした音声を読み込めませんでした" + tail(e)
        case .writerFailed(let e): return "書き出しに失敗しました" + tail(e)
        case .invalidSize(let m): return m
        case .noAudio: return "音声がありません(音声・ボイス・動画の音が 1 つも無いので、音声だけの書き出しはできません)"
        }
    }
}

// MARK: - 内部状態

/// 書き出し中の共有状態(キャンセル・失敗・進み具合)。複数のキューから触るので NSLock で守る。
private final class ExportControl: @unchecked Sendable {
    private let lock = NSLock()
    private var _cancelled = false
    private var _failure: Error?
    func cancel() { lock.lock(); _cancelled = true; lock.unlock() }
    func fail(_ e: Error) { lock.lock(); if _failure == nil { _failure = e }; lock.unlock() }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }
    var failure: Error? { lock.lock(); defer { lock.unlock() }; return _failure }
    var shouldStop: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled || _failure != nil }
}

private let exportSRGB = CGColorSpace(name: CGColorSpace.sRGB)!
private let exportBitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

// MARK: - 音声チャンネル(書き出しオプション)

/// 書き出す音声のチャンネル構成。既定はステレオ(従来どおり。出力は従来とバイト一致)。
/// 5.1 は保存パネル内の一時選択のみで、プロジェクトファイルには保存しない(ラウドネス・字幕埋め込みと同じ扱い)。
/// 仕様と判断の全文は docs/マルチチャンネル音声.md「5.1 書き出し」。
public enum ExportAudioChannels: String, CaseIterable, Equatable, Sendable {
    case stereo
    case surround51

    /// UI に出す名前(日本語。英訳は L10nTable)。
    public var label: String {
        switch self {
        case .stereo: return "ステレオ"
        case .surround51: return "5.1 サラウンド"
        }
    }
}

// MARK: - Exporter

/// プロジェクトを MP4(H.264 / HEVC + AAC)に書き出す。再生を待たず、フレームを順に描いて AVAssetWriter へ渡す。
public final class Exporter {
    public let project: Project
    public let assets: RenderAssets

    /// 書き出す区間(nil なら全体)。
    public let range: ExportRange?
    /// 映像の目標ビットレート(bps)。nil なら解像度から決める既定値(従来どおり)。
    public let videoBitrate: Int?
    /// 完成したミックスへのラウドネス正規化(既定は無効 = 従来どおり)。
    public let loudness: LoudnessNormalizationSettings
    /// 描画バックエンド(#77。既定は自動 = Metal 優先・従来経路へフォールバック)。
    public let renderBackend: RenderBackend
    /// プラグインエフェクトのプロバイダ(F-1 配線。既定は空 = 従来描画と完全一致)。
    public let pluginEffectProviders: [any VideoEffectProviding]
    /// VST3 音声プロバイダ(再生/書き出し配線。既定は nil = プロバイダ無しの従来ミックスと完全一致)。
    public let vst3Provider: (any AudioEffectProviding)?
    /// 字幕トラック(mov_text)の埋め込み(既定は無効 = 従来どおり字幕トラックなし)。
    public let subtitleEmbed: SubtitleEmbedSettings
    /// 音声のチャンネル構成(既定はステレオ = 従来どおり)。5.1 は mp4(AAC 6ch)のときだけ効き、ProRes(.mov)はステレオのまま。
    public let audioChannels: ExportAudioChannels

    public init(project: Project, assets: RenderAssets, range: ExportRange? = nil, videoBitrate: Int? = nil, loudness: LoudnessNormalizationSettings = .disabled, renderBackend: RenderBackend = .auto, pluginEffectProviders: [any VideoEffectProviding] = [], vst3Provider: (any AudioEffectProviding)? = nil, subtitleEmbed: SubtitleEmbedSettings = .disabled, audioChannels: ExportAudioChannels = .stereo) {
        self.project = project
        self.assets = assets
        self.range = range
        self.videoBitrate = videoBitrate
        self.loudness = loudness
        self.renderBackend = renderBackend
        self.pluginEffectProviders = pluginEffectProviders
        self.vst3Provider = vst3Provider
        self.subtitleEmbed = subtitleEmbed
        self.audioChannels = audioChannels
    }

    /// ProRes のコーデック文字列 → AVAssetWriter の映像コーデック。HQ / LT / Proxy も AVAssetWriter で直接書ける(実機確認済み 2026-11-19)。
    /// 4444 以外の ProRes は従来どおり 422 として書く(未知の文字列が来ても従来の挙動を変えないための保険)。
    public static func proResCodecType(for codec: String) -> AVVideoCodecType {
        switch codec.lowercased() {
        case OutputPlan.proRes4444: return .proRes4444
        case OutputPlan.proRes422HQ: return .proRes422HQ
        case OutputPlan.proRes422LT: return .proRes422LT
        case OutputPlan.proRes422Proxy: return .proRes422Proxy
        default: return .proRes422
        }
    }

    /// 正確な分数のフレームレート(29.97 → 30000/1001 など)。
    public var frameRate: FrameRate { project.frameRate }

    /// 書き出すコマ数 = ceil(長さ × fps)。浮動小数の誤差(3.7×60=222.00000000000003)で 1 コマ増えないよう少し引く。
    public var totalFrames: Int { frameRate.frameCount(duration: range?.duration ?? project.endTime) }

    /// 偶数に切り下げた出力サイズ(H.264 / HEVC は偶数が必要)。
    public var outputSize: (width: Int, height: Int) {
        (project.width & ~1, project.height & ~1)
    }

    /// 実際に書き出すサイズとコーデック(H.264 で書けない大きさなら HEVC に切り替える)。
    public var plan: OutputPlan { OutputPlan.make(width: project.width, height: project.height, codec: project.codec) }

    public func export(to url: URL, progress: ((Double) -> Void)? = nil) async throws {
        let control = ExportControl()
        try await withTaskCancellationHandler {
            try await run(to: url, progress: progress, control: control)
        } onCancel: {
            control.cancel()
        }
    }

    private func run(to url: URL, progress: ((Double) -> Void)?, control: ExportControl) async throws {
        let rate = frameRate
        let fpsValue = rate.value
        let N = totalFrames
        let t0 = range?.start ?? 0
        guard N > 0 else { throw ExportError.emptyProject }
        let plan = self.plan
        if let msg = plan.error { throw ExportError.invalidSize(msg) }
        let (ew, eh) = (plan.width, plan.height)
        if ew != project.width || eh != project.height {
            FileHandle.standardError.write(Data("書き出しサイズを偶数に切り下げました: \(project.width)x\(project.height) -> \(ew)x\(eh)\n".utf8))
        }
        if let w = OutputPlan.heavyWarning(width: ew, height: eh, fps: fpsValue) {
            FileHandle.standardError.write(Data((w + "\n").utf8))
        }
        if plan.usesFallbackCodec {
            FileHandle.standardError.write(Data((OutputPlan.fallbackNotice + "\n").utf8))
        }
        var rp = project
        rp.width = ew; rp.height = eh
        // 専用キューの中だけで使う(AVFoundation の部品は Sendable でないので、安全は呼び出し側の約束)
        if let vst3Provider { assets.setVST3Provider(vst3Provider) }
        nonisolated(unsafe) let renderer = Renderer(project: rp, assets: assets, backend: renderBackend, pluginEffectProviders: pluginEffectProviders)

        // 先に音声をミックスする(一時ファイル)
        let mixURL = FileManager.default.temporaryDirectory.appendingPathComponent("moviecut-mix-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: mixURL) }
        let proj = project
        // 5.1 は ProRes(.mov)では書かない(無圧縮 6ch の .mov は未検証のため、従来どおりステレオに倒す。docs 参照)
        let surround = audioChannels == .surround51 && !plan.isProRes
        if audioChannels == .surround51, plan.isProRes {
            FileHandle.standardError.write(Data("5.1 書き出しは ProRes(.mov)には未対応のため、音声はステレオで書き出します\n".utf8))
        }
        let mix: AudioMixer.MixResult
        do {
            nonisolated(unsafe) let vst3 = self.vst3Provider   // 専用キューの中だけで使う(プロバイダはスレッドをまたがない)
            mix = try await Task.detached { () throws -> AudioMixer.MixResult in
                if surround { return try AudioMixer.mixdownSurround51(project: proj, to: mixURL, range: self.range, vst3Provider: vst3) }
                return try AudioMixer.mixdownDetailed(project: proj, to: mixURL, range: self.range, vst3Provider: vst3)
            }.value
        } catch {
            if error is CancellationError { throw error }
            throw ExportError.audioMixFailed(error)
        }
        if control.cancelled || Task.isCancelled { throw CancellationError() }
        let hasAudio = mix.sourceCount > 0

        // ラウドネス正規化(有効で音声があるときだけ。計測 → 計画 → 必要なら適用済みの一時ファイルへ)
        var audioURL = mixURL
        let normURL = FileManager.default.temporaryDirectory.appendingPathComponent("moviecut-mix-norm-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: normURL) }
        if hasAudio, loudness.enabled, surround {
            // LoudnessNormalization は 2ch 前提なので、5.1 では適用しない(黙って無視せず記録する)
            FileHandle.standardError.write(Data("5.1 書き出しではラウドネス正規化は適用しません(ステレオのみ対応)\n".utf8))
        } else if hasAudio, loudness.enabled {
            let settings = loudness
            let res = try await Task.detached { try LoudnessNormalization.normalize(input: mixURL, output: normURL, settings: settings) }.value
            FileHandle.standardError.write(Data((LoudnessNormalization.logLine(res.plan, settings: settings) + "\n").utf8))
            if let applied = res.outputURL { audioURL = applied }
            if control.cancelled || Task.isCancelled { throw CancellationError() }
        }

        try? FileManager.default.removeItem(at: url)
        nonisolated(unsafe) let writer: AVAssetWriter
        let isProRes = plan.isProRes
        do { writer = try AVAssetWriter(outputURL: url, fileType: isProRes ? .mov : .mp4) }
        catch { throw ExportError.cannotCreateWriter(error) }
        if !isProRes { writer.shouldOptimizeForNetworkUse = true }

        // 字幕の埋め込み(選んだときだけ・MP4 のときだけ・載せる字幕があるときだけ。それ以外は従来どおり)
        let embedSamples: [SubtitleCue] = subtitleEmbed.enabled && !isProRes
            ? SubtitleEmbed.samples(from: SubtitleEmbed.cues(from: project, range: range), trackDuration: range?.duration ?? project.endTime)
            : []

        // 映像入力
        let isHEVC = plan.codec == "hevc"
        let base = Double(ew) * Double(eh) * fpsValue * 0.1
        let h264Rate = min(60_000_000, max(8_000_000, base))
        // 指定があれば、そのまま使う(HEVC の補正もしない)
        let averageRate = videoBitrate ?? Int(isHEVC ? h264Rate * 0.75 : h264Rate)
        var props: [String: Any] = [
            AVVideoAverageBitRateKey: averageRate,
            AVVideoExpectedSourceFrameRateKey: fpsValue,
            AVVideoMaxKeyFrameIntervalKey: max(1, Int((2 * fpsValue).rounded())),
        ]
        if !isHEVC { props[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
        // ProRes はビットレート・キーフレームの指定が無い(フレームごとに独立した圧縮)。4444 は背景が透明なら透明も残る
        let codecType: AVVideoCodecType = isProRes ? Self.proResCodecType(for: plan.codec) : (isHEVC ? .hevc : .h264)
        var vSettings: [String: Any] = [
            AVVideoCodecKey: codecType,
            AVVideoWidthKey: ew,
            AVVideoHeightKey: eh,
            AVVideoCompressionPropertiesKey: props,
            // sRGB の絵を BT.709 として記録する
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
        if isProRes { vSettings.removeValue(forKey: AVVideoCompressionPropertiesKey) }
        nonisolated(unsafe) let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: vSettings)
        vInput.expectsMediaDataInRealTime = false
        // トラックの時間の目盛りをコマの長さの整数倍にする(既定の 1/600 だと 29.97 などの時刻が丸められて、コマの間隔がそろわない)
        vInput.mediaTimeScale = CMTimeScale(rate.num * max(1, (600 + rate.num - 1) / rate.num))
        nonisolated(unsafe) let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: ew,
            kCVPixelBufferHeightKey as String: eh,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ])
        guard writer.canAdd(vInput) else { throw ExportError.cannotAddInput("映像") }
        writer.add(vInput)

        // 音声入力(ミックスした一時ファイルから)
        // 5.1: AAC 5.1 の並びへ入れ替えたサンプルに付ける形式記述(ステレオのときは nil)
        nonisolated(unsafe) let aacFormat: CMAudioFormatDescription? = surround ? Surround51AAC.makeFormatDescription() : nil
        if surround, aacFormat == nil { throw ExportError.cannotAddInput("音声") }
        var aInput: AVAssetWriterInput?
        var aReader: AVAssetReader?
        var aOutput: AVAssetReaderTrackOutput?
        if hasAudio {
            // ProRes(.mov)の音は、編集用の素材として無圧縮(24 ビット PCM)で入れる
            let aSettings: [String: Any] = surround ? Surround51AAC.writerSettings : isProRes ? [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 24,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ] : [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 256_000,
            ]
            let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: aSettings)
            ai.expectsMediaDataInRealTime = false
            guard writer.canAdd(ai) else { throw ExportError.cannotAddInput("音声") }
            writer.add(ai)
            let mixAsset = AVURLAsset(url: audioURL)
            guard let track = try await mixAsset.loadTracks(withMediaType: .audio).first,
                  let r = try? AVAssetReader(asset: mixAsset) else { throw ExportError.audioReadFailed(nil) }
            let o = AVAssetReaderTrackOutput(track: track, outputSettings: surround ? Surround51AAC.readerSettings : [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2,
            ])
            guard r.canAdd(o) else { throw ExportError.audioReadFailed(nil) }
            r.add(o)
            guard r.startReading() else { throw ExportError.audioReadFailed(r.error) }
            aInput = ai; aReader = r; aOutput = o
        }

        // 字幕入力(埋め込みを選んでいて、載せる字幕があるときだけ)
        var tInput: AVAssetWriterInput?
        var tFormat: CMFormatDescription?
        if !embedSamples.isEmpty {
            guard let fmt = SubtitleEmbed.makeFormatDescription(width: ew, height: eh) else { throw ExportError.cannotAddInput("字幕") }
            let ti = AVAssetWriterInput(mediaType: .text, outputSettings: nil, sourceFormatHint: fmt)
            ti.expectsMediaDataInRealTime = false
            ti.languageCode = subtitleEmbed.languageCode
            guard writer.canAdd(ti) else { throw ExportError.cannotAddInput("字幕") }
            writer.add(ti)
            tInput = ti; tFormat = fmt
        }

        guard writer.startWriting() else { throw ExportError.cannotStartWriting(writer.error) }
        writer.startSession(atSourceTime: .zero)
        assets.beginExportMode()
        defer { assets.endExportMode() }

        // 映像と音声を別々のキューで送る
        let group = DispatchGroup()
        let vQueue = DispatchQueue(label: "moviecut.export.video")
        let aQueue = DispatchQueue(label: "moviecut.export.audio")

        var vDone = false          // vQueue からだけ触る
        var nextFrame = 0          // 同上
        var lastReported = -1.0    // 同上
        nonisolated(unsafe) var pixelPool: CVPixelBufferPool?  // 同上(毎コマ adaptor から取ると VideoToolbox のロックを待つので 1 回だけ)
        group.enter()
        vInput.requestMediaDataWhenReady(on: vQueue) {
            if vDone { return }
            func finish() { vDone = true; vInput.markAsFinished(); group.leave() }
            while vInput.isReadyForMoreMediaData {
                if control.shouldStop || nextFrame >= N { finish(); return }
                let i = nextFrame
                var ok = true
                autoreleasepool {
                    if pixelPool == nil { pixelPool = adaptor.pixelBufferPool }
                    guard let pool = pixelPool else { control.fail(ExportError.pixelBufferFailed(-1)); ok = false; return }
                    var pbOut: CVPixelBuffer?
                    let rc = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbOut)
                    guard rc == kCVReturnSuccess, let pb = pbOut else { control.fail(ExportError.pixelBufferFailed(rc)); ok = false; return }
                    CVPixelBufferLockBaseAddress(pb, [])
                    if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: ew, height: eh, bitsPerComponent: 8,
                                           bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: exportSRGB, bitmapInfo: exportBitmapInfo) {
                        renderer.render(t: t0 + rate.time(ofFrame: i), into: ctx)
                    }
                    CVPixelBufferUnlockBaseAddress(pb, [])
                    if !adaptor.append(pb, withPresentationTime: rate.cmTime(frame: i)) {
                        control.fail(ExportError.appendFailed(frame: i, underlying: writer.error)); ok = false
                    }
                }
                if !ok { finish(); return }
                nextFrame += 1
                let p = Double(nextFrame) / Double(N)
                if p - lastReported >= 0.001 || nextFrame == N { lastReported = p; progress?(p) }
            }
        }

        if let ai0 = aInput, let ao0 = aOutput, let ar0 = aReader {
            nonisolated(unsafe) let ai = ai0, ao = ao0, ar = ar0
            var aDone = false
            group.enter()
            ai.requestMediaDataWhenReady(on: aQueue) {
                if aDone { return }
                func finish() { aDone = true; ai.markAsFinished(); group.leave() }
                while ai.isReadyForMoreMediaData {
                    if control.shouldStop { finish(); return }
                    guard let raw = ao.copyNextSampleBuffer() else {
                        if ar.status == .failed { control.fail(ExportError.audioReadFailed(ar.error)) }
                        finish(); return
                    }
                    var sb = raw
                    if let fmt = aacFormat {
                        // 5.1: canonical 順 → AAC 5.1 の並びへ(Surround51Export.swift)
                        guard let r = Surround51AAC.reordered(raw, format: fmt) else { control.fail(ExportError.audioReadFailed(nil)); finish(); return }
                        sb = r
                    }
                    if !ai.append(sb) { control.fail(ExportError.appendFailed(frame: -1, underlying: writer.error)); finish(); return }
                }
            }
        }

        if let ti0 = tInput, let fmt0 = tFormat {
            nonisolated(unsafe) let ti = ti0, fmt = fmt0
            let tQueue = DispatchQueue(label: "moviecut.export.subtitles")
            var tDone = false          // tQueue からだけ触る
            var nextCue = 0            // 同上
            group.enter()
            ti.requestMediaDataWhenReady(on: tQueue) {
                if tDone { return }
                func finish() { tDone = true; ti.markAsFinished(); group.leave() }
                while ti.isReadyForMoreMediaData {
                    if control.shouldStop || nextCue >= embedSamples.count { finish(); return }
                    guard let sb = SubtitleEmbed.makeSample(format: fmt, cue: embedSamples[nextCue]) else {
                        control.fail(ExportError.appendFailed(frame: -2, underlying: writer.error)); finish(); return
                    }
                    if !ti.append(sb) { control.fail(ExportError.appendFailed(frame: -2, underlying: writer.error)); finish(); return }
                    nextCue += 1
                }
            }
        }

        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            group.notify(queue: .global()) { c.resume() }
        }

        func discard() {
            writer.cancelWriting()
            aReader?.cancelReading()
            try? FileManager.default.removeItem(at: url)
        }
        if control.cancelled || Task.isCancelled { discard(); throw CancellationError() }
        if let e = control.failure { discard(); throw e }

        await writer.finishWriting()
        guard writer.status == .completed else {
            let e = writer.error
            try? FileManager.default.removeItem(at: url)
            throw ExportError.writerFailed(e)
        }
        progress?(1.0)
    }
}

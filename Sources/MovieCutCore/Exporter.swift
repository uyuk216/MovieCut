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
private final class ExportControl {
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

// MARK: - Exporter

/// プロジェクトを MP4(H.264 / HEVC + AAC)に書き出す。再生を待たず、フレームを順に描いて AVAssetWriter へ渡す。
public final class Exporter {
    public let project: Project
    public let assets: RenderAssets

    public init(project: Project, assets: RenderAssets) {
        self.project = project
        self.assets = assets
    }

    /// 正確な分数のフレームレート(29.97 → 30000/1001 など)。
    public var frameRate: FrameRate { project.frameRate }

    /// 書き出すコマ数 = ceil(長さ × fps)。浮動小数の誤差(3.7×60=222.00000000000003)で 1 コマ増えないよう少し引く。
    public var totalFrames: Int { frameRate.frameCount(duration: project.endTime) }

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
        let renderer = Renderer(project: rp, assets: assets)

        // 先に音声をミックスする(一時ファイル)
        let mixURL = FileManager.default.temporaryDirectory.appendingPathComponent("moviecut-mix-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: mixURL) }
        let proj = project
        let mix: AudioMixer.MixResult
        do {
            mix = try await Task.detached { try AudioMixer.mixdownDetailed(project: proj, to: mixURL) }.value
        } catch {
            if error is CancellationError { throw error }
            throw ExportError.audioMixFailed(error)
        }
        if control.cancelled || Task.isCancelled { throw CancellationError() }
        let hasAudio = mix.sourceCount > 0

        try? FileManager.default.removeItem(at: url)
        let writer: AVAssetWriter
        do { writer = try AVAssetWriter(outputURL: url, fileType: .mp4) }
        catch { throw ExportError.cannotCreateWriter(error) }
        writer.shouldOptimizeForNetworkUse = true

        // 映像入力
        let isHEVC = plan.codec == "hevc"
        let base = Double(ew) * Double(eh) * fpsValue * 0.1
        let h264Rate = min(60_000_000, max(8_000_000, base))
        var props: [String: Any] = [
            AVVideoAverageBitRateKey: Int(isHEVC ? h264Rate * 0.75 : h264Rate),
            AVVideoExpectedSourceFrameRateKey: fpsValue,
            AVVideoMaxKeyFrameIntervalKey: max(1, Int((2 * fpsValue).rounded())),
        ]
        if !isHEVC { props[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
        let vSettings: [String: Any] = [
            AVVideoCodecKey: isHEVC ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
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
        let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: vSettings)
        vInput.expectsMediaDataInRealTime = false
        // トラックの時間の目盛りをコマの長さの整数倍にする(既定の 1/600 だと 29.97 などの時刻が丸められて、コマの間隔がそろわない)
        vInput.mediaTimeScale = CMTimeScale(rate.num * max(1, (600 + rate.num - 1) / rate.num))
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: ew,
            kCVPixelBufferHeightKey as String: eh,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ])
        guard writer.canAdd(vInput) else { throw ExportError.cannotAddInput("映像") }
        writer.add(vInput)

        // 音声入力(ミックスした一時ファイルから)
        var aInput: AVAssetWriterInput?
        var aReader: AVAssetReader?
        var aOutput: AVAssetReaderTrackOutput?
        if hasAudio {
            let aSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 256_000,
            ]
            let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: aSettings)
            ai.expectsMediaDataInRealTime = false
            guard writer.canAdd(ai) else { throw ExportError.cannotAddInput("音声") }
            writer.add(ai)
            let mixAsset = AVURLAsset(url: mixURL)
            guard let track = try await mixAsset.loadTracks(withMediaType: .audio).first,
                  let r = try? AVAssetReader(asset: mixAsset) else { throw ExportError.audioReadFailed(nil) }
            let o = AVAssetReaderTrackOutput(track: track, outputSettings: [
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
        var pixelPool: CVPixelBufferPool?  // 同上(毎コマ adaptor から取ると VideoToolbox のロックを待つので 1 回だけ)
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
                        renderer.render(t: rate.time(ofFrame: i), into: ctx)
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

        if let ai = aInput, let ao = aOutput, let ar = aReader {
            var aDone = false
            group.enter()
            ai.requestMediaDataWhenReady(on: aQueue) {
                if aDone { return }
                func finish() { aDone = true; ai.markAsFinished(); group.leave() }
                while ai.isReadyForMoreMediaData {
                    if control.shouldStop { finish(); return }
                    guard let sb = ao.copyNextSampleBuffer() else {
                        if ar.status == .failed { control.fail(ExportError.audioReadFailed(ar.error)) }
                        finish(); return
                    }
                    if !ai.append(sb) { control.fail(ExportError.appendFailed(frame: -1, underlying: writer.error)); finish(); return }
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

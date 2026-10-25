import Foundation
import AVFoundation

/// 書き出しプリセット(M7)。プロジェクトの「写し」に解像度・コーデック・fps を当てて書き出すので、元のドキュメントは変わらない。
public enum ExportPreset: String, CaseIterable, Sendable {
    case youtube1080, youtube4k, short, light, audio

    /// 日本語の表示名(メニュー)。
    public var title: String {
        switch self {
        case .youtube1080: return "YouTube 1080p"
        case .youtube4k: return "YouTube 4K"
        case .short: return "ショート縦"
        case .light: return "軽量 720p"
        case .audio: return "音声のみ"
        }
    }

    /// 仕様の短い説明(メニューのヒント・ツールチップ用)。
    public var summary: String {
        switch self {
        case .youtube1080: return "1920×1080 · H.264"
        case .youtube4k: return "3840×2160 · HEVC"
        case .short: return "1080×1920 · H.264"
        case .light: return "1280×720 · H.264 · 30fps まで"
        case .audio: return "AAC · .m4a"
        }
    }

    public var isAudioOnly: Bool { self == .audio }
    public var fileExtension: String { isAudioOnly ? "m4a" : "mp4" }

    /// コマンドラインの `--preset` の名前(= rawValue)から。
    public init?(cliName: String) {
        guard let p = Self.allCases.first(where: { $0.rawValue == cliName.lowercased() }) else { return nil }
        self = p
    }

    /// 保存パネルの提案名 `<書類名>-<プリセット>.mp4|.m4a`。
    public func suggestedFileName(documentName: String) -> String {
        "\(documentName)-\(rawValue).\(fileExtension)"
    }

    /// プリセットを当てた写しを返す(元は変えない)。解像度は `scaledForResolution`(文字・ぼかしの大きさも合わせる)。
    /// 音声のみは映像の設定を変えない。
    public func apply(to project: Project) -> Project {
        func sized(_ w: Int, _ h: Int, _ codec: String) -> Project {
            var p = project.scaledForResolution(newWidth: w, newHeight: h)
            p.codec = codec
            return p
        }
        switch self {
        case .youtube1080: return sized(1920, 1080, "h264")
        case .youtube4k: return sized(3840, 2160, "hevc")
        case .short: return sized(1080, 1920, "h264")
        case .light:
            var p = sized(1280, 720, "h264")
            p.fps = min(project.fps, 30)
            return p
        case .audio: return project
        }
    }
}

/// プリセット(または現在の設定)で書き出す入口。アプリもコマンドラインもこれを通る。
public enum ExportJob {
    /// 書き出すプロジェクト(プリセットの写し。nil なら現在の設定のまま)。
    public static func resolvedProject(_ project: Project, preset: ExportPreset?) -> Project {
        preset?.apply(to: project) ?? project
    }

    public static func run(project: Project, preset: ExportPreset?, to url: URL, assets: RenderAssets = RenderAssets(), progress: ((Double) -> Void)? = nil) async throws {
        let p = resolvedProject(project, preset: preset)
        if preset?.isAudioOnly == true {
            try await AudioExporter.export(project: p, to: url, progress: progress)
        } else {
            try await Exporter(project: p, assets: assets).export(to: url, progress: progress)
        }
    }
}

/// ミックスダウンを AAC(256 kbps・48 kHz・ステレオ)の .m4a にする。
public enum AudioExporter {
    private final class Control: @unchecked Sendable {
        private let lock = NSLock()
        private var _cancelled = false
        private var _failure: Error?
        func cancel() { lock.withLock { _cancelled = true } }
        func fail(_ e: Error) { lock.withLock { if _failure == nil { _failure = e } } }
        var cancelled: Bool { lock.withLock { _cancelled } }
        var failure: Error? { lock.withLock { _failure } }
        var shouldStop: Bool { lock.withLock { _cancelled || _failure != nil } }
    }

    public static func export(project: Project, to url: URL, progress: ((Double) -> Void)? = nil) async throws {
        let control = Control()
        try await withTaskCancellationHandler {
            try await run(project: project, to: url, progress: progress, control: control)
        } onCancel: { control.cancel() }
    }

    private static func run(project: Project, to url: URL, progress: ((Double) -> Void)?, control: Control) async throws {
        guard project.endTime > 0 else { throw ExportError.emptyProject }
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
        guard mix.sourceCount > 0 else { throw ExportError.noAudio }
        progress?(0.05)

        try? FileManager.default.removeItem(at: url)
        let writer: AVAssetWriter
        do { writer = try AVAssetWriter(outputURL: url, fileType: .m4a) } catch { throw ExportError.cannotCreateWriter(error) }
        let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 256_000,
        ])
        ai.expectsMediaDataInRealTime = false
        guard writer.canAdd(ai) else { throw ExportError.cannotAddInput("音声") }
        writer.add(ai)

        let mixAsset = AVURLAsset(url: mixURL)
        guard let track = try await mixAsset.loadTracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: mixAsset) else { throw ExportError.audioReadFailed(nil) }
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2,
        ])
        guard reader.canAdd(out) else { throw ExportError.audioReadFailed(nil) }
        reader.add(out)
        guard reader.startReading() else { throw ExportError.audioReadFailed(reader.error) }
        guard writer.startWriting() else { throw ExportError.cannotStartWriting(writer.error) }
        writer.startSession(atSourceTime: .zero)

        let total = max(0.001, mix.duration)
        let queue = DispatchQueue(label: "moviecut.export.audioonly")
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            var done = false
            ai.requestMediaDataWhenReady(on: queue) {
                if done { return }
                func finish() { done = true; ai.markAsFinished(); c.resume() }
                while ai.isReadyForMoreMediaData {
                    if control.shouldStop { finish(); return }
                    guard let sb = out.copyNextSampleBuffer() else {
                        if reader.status == .failed { control.fail(ExportError.audioReadFailed(reader.error)) }
                        finish(); return
                    }
                    let pts = CMSampleBufferGetPresentationTimeStamp(sb).seconds
                    if !ai.append(sb) { control.fail(ExportError.appendFailed(frame: -1, underlying: writer.error)); finish(); return }
                    if pts.isFinite { progress?(min(0.99, 0.05 + 0.94 * pts / total)) }
                }
            }
        }
        if control.cancelled || Task.isCancelled {
            writer.cancelWriting(); reader.cancelReading(); try? FileManager.default.removeItem(at: url)
            throw CancellationError()
        }
        if let e = control.failure {
            writer.cancelWriting(); reader.cancelReading(); try? FileManager.default.removeItem(at: url)
            throw e
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            let e = writer.error
            try? FileManager.default.removeItem(at: url)
            throw ExportError.writerFailed(e)
        }
        progress?(1.0)
    }
}

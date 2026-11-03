import Foundation
import AVFoundation

/// 書き出しの fps の決め方。`keep` はプロジェクトのまま、`cap` は上限、`fixed` は固定。
public enum ExportFPS: Equatable, Sendable {
    case keep
    case cap(Double)
    case fixed(Double)

    public func resolve(_ fps: Double) -> Double {
        switch self {
        case .keep: return fps
        case .cap(let m): return min(fps, m)
        case .fixed(let v): return v
        }
    }
}

/// 書き出しの仕様(組み込みプリセットでも、ユーザーが保存したプリセットでも、この形に直して使う)。
/// 元のプロジェクトは変えず、`apply(to:)` で写しに当てる。
public struct ExportSpec: Equatable, Sendable {
    /// 表示名(保存パネルの提案名の一部にもなる)。
    public var name: String
    /// 提案名・CLI の名前(組み込みは rawValue、保存したものは名前)。
    public var stem: String
    /// 音声のみのときは 0。
    public var width: Int
    public var height: Int
    /// "h264" か "hevc"。
    public var codec: String
    public var fps: ExportFPS
    /// nil なら解像度から決まる既定値。
    public var bitrateMbps: Double?
    public var audioOnly: Bool

    public init(name: String, stem: String, width: Int, height: Int, codec: String, fps: ExportFPS = .keep, bitrateMbps: Double? = nil, audioOnly: Bool = false) {
        self.name = name; self.stem = stem; self.width = width; self.height = height
        self.codec = codec; self.fps = fps; self.bitrateMbps = bitrateMbps; self.audioOnly = audioOnly
    }

    /// ビットレートとして受け付ける範囲(Mbps)。外れた値は nil(既定)として扱う。
    public static let bitrateRangeMbps: ClosedRange<Double> = 1...100
    /// 解像度として受け付ける範囲(偶数・この範囲だけ)。
    public static let sideRange: ClosedRange<Int> = 16...7680

    public static func validBitrate(_ v: Double?) -> Double? {
        guard let v, v.isFinite, bitrateRangeMbps.contains(v) else { return nil }
        return v
    }

    /// プロジェクトの写し(解像度・文字の大きさ・コーデック・fps)。音声のみは映像の設定を変えない。
    public func apply(to project: Project) -> Project {
        guard !audioOnly else { return project }
        var p = project.scaledForResolution(newWidth: width, newHeight: height)
        p.codec = codec
        p.fps = fps.resolve(project.fps)
        return p
    }

    /// 保存パネルの提案名 `<書類名>-<stem>.mp4|.m4a`。
    public func suggestedFileName(documentName: String) -> String {
        "\(documentName)-\(stem).\(audioOnly ? "m4a" : "mp4")"
    }
}

/// 書き出しプリセット(M7 + 拡充)。プロジェクトの「写し」に解像度・コーデック・fps・ビットレートを当てて書き出すので、元のドキュメントは変わらない。
public enum ExportPreset: String, CaseIterable, Sendable {
    case youtube1080, youtube1080p60, youtube4k, short, shorts, tiktok, reels, x720, x1080, light, audio

    /// 日本語の表示名(メニュー)。
    public var title: String {
        switch self {
        case .youtube1080: return "YouTube 1080p"
        case .youtube1080p60: return "YouTube 1080p60"
        case .youtube4k: return "YouTube 4K"
        case .short: return "ショート縦"
        case .shorts: return "YouTube Shorts"
        case .tiktok: return "TikTok"
        case .reels: return "Instagram リール"
        case .x720: return "X 720p"
        case .x1080: return "X 1080p"
        case .light: return "軽量 720p"
        case .audio: return "音声のみ"
        }
    }

    /// 仕様の短い説明(メニューのヒント・ツールチップ用)。
    public var summary: String {
        switch self {
        case .youtube1080: return "1920×1080 · H.264"
        case .youtube1080p60: return "1920×1080 · H.264 · 60fps"
        case .youtube4k: return "3840×2160 · HEVC"
        case .short: return "1080×1920 · H.264"
        case .shorts, .tiktok, .reels: return "1080×1920 · H.264 · 30fps · 8 Mbps"
        case .x720: return "1280×720 · H.264 · 30fps · 8 Mbps"
        case .x1080: return "1920×1080 · H.264 · 60fps · 8 Mbps"
        case .light: return "1280×720 · H.264 · 30fps まで"
        case .audio: return "AAC · .m4a"
        }
    }

    /// 組み込みの仕様表。ここを変えると書き出しの中身が変わるので、テストで値を固定している。
    public var spec: ExportSpec {
        func s(_ w: Int, _ h: Int, _ codec: String, fps: ExportFPS = .keep, mbps: Double? = nil) -> ExportSpec {
            ExportSpec(name: title, stem: rawValue, width: w, height: h, codec: codec, fps: fps, bitrateMbps: mbps)
        }
        switch self {
        case .youtube1080: return s(1920, 1080, "h264")
        case .youtube1080p60: return s(1920, 1080, "h264", fps: .fixed(60))
        case .youtube4k: return s(3840, 2160, "hevc")
        case .short: return s(1080, 1920, "h264")
        case .shorts, .tiktok, .reels: return s(1080, 1920, "h264", fps: .fixed(30), mbps: 8)
        case .x720: return s(1280, 720, "h264", fps: .fixed(30), mbps: 8)
        case .x1080: return s(1920, 1080, "h264", fps: .fixed(60), mbps: 8)
        case .light: return s(1280, 720, "h264", fps: .cap(30))
        case .audio:
            return ExportSpec(name: title, stem: rawValue, width: 0, height: 0, codec: "aac", audioOnly: true)
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
        spec.suggestedFileName(documentName: documentName)
    }

    /// プリセットを当てた写しを返す(元は変えない)。解像度は `scaledForResolution`(文字・ぼかしの大きさも合わせる)。
    /// 音声のみは映像の設定を変えない。
    public func apply(to project: Project) -> Project { spec.apply(to: project) }
}

/// プリセット(または現在の設定)で書き出す入口。アプリもコマンドラインもこれを通る。
public enum ExportJob {
    /// 書き出すプロジェクト(プリセットの写し。nil なら現在の設定のまま)。
    public static func resolvedProject(_ project: Project, preset: ExportPreset?) -> Project {
        preset?.apply(to: project) ?? project
    }

    /// `spec`(保存したプリセットなど)があればそれを優先する。`bitrateMbps` は仕様の値より優先する(`--bitrate`)。
    public static func run(project: Project, preset: ExportPreset?, spec: ExportSpec? = nil, bitrateMbps: Double? = nil, range: ExportRange? = nil, to url: URL, assets: RenderAssets = RenderAssets(), progress: ((Double) -> Void)? = nil) async throws {
        let chosen = spec ?? preset?.spec
        let p = chosen?.apply(to: project) ?? project
        let audioOnly = chosen?.audioOnly ?? false
        if audioOnly {
            try await AudioExporter.export(project: p, range: range, to: url, progress: progress)
        } else {
            let mbps = ExportSpec.validBitrate(bitrateMbps) ?? chosen?.bitrateMbps
            let rate = mbps.map { Int(($0 * 1_000_000).rounded()) }
            try await Exporter(project: p, assets: assets, range: range, videoBitrate: rate).export(to: url, progress: progress)
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

    public static func export(project: Project, range: ExportRange? = nil, to url: URL, progress: ((Double) -> Void)? = nil) async throws {
        let control = Control()
        try await withTaskCancellationHandler {
            try await run(project: project, range: range, to: url, progress: progress, control: control)
        } onCancel: { control.cancel() }
    }

    private static func run(project: Project, range: ExportRange?, to url: URL, progress: ((Double) -> Void)?, control: Control) async throws {
        guard project.endTime > 0 else { throw ExportError.emptyProject }
        let mixURL = FileManager.default.temporaryDirectory.appendingPathComponent("moviecut-mix-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: mixURL) }
        let proj = project
        let mix: AudioMixer.MixResult
        do {
            mix = try await Task.detached { try AudioMixer.mixdownDetailed(project: proj, to: mixURL, range: range) }.value
        } catch {
            if error is CancellationError { throw error }
            throw ExportError.audioMixFailed(error)
        }
        if control.cancelled || Task.isCancelled { throw CancellationError() }
        guard mix.sourceCount > 0 else { throw ExportError.noAudio }
        progress?(0.05)

        try? FileManager.default.removeItem(at: url)
        nonisolated(unsafe) let writer: AVAssetWriter
        do { writer = try AVAssetWriter(outputURL: url, fileType: .m4a) } catch { throw ExportError.cannotCreateWriter(error) }
        nonisolated(unsafe) let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: [
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
              let reader0 = try? AVAssetReader(asset: mixAsset) else { throw ExportError.audioReadFailed(nil) }
        nonisolated(unsafe) let reader = reader0
        nonisolated(unsafe) let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
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

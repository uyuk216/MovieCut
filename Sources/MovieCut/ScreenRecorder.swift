import Foundation
import Combine
import CoreGraphics
import ScreenCaptureKit
import AVFoundation
import MovieCutCore

// MARK: - 画面収録の許可

/// 画面収録の許可(TCC)の確認と要求。許可が無くてもアプリは落とさず、案内を出すためのもの。
enum ScreenCapturePermission {
    static func isGranted() -> Bool { CGPreflightScreenCaptureAccess() }
    /// OS の確認を出す(まだ決まっていないとき)。すでに拒否されているときは false が返るだけで、案内は画面側が出す。
    @discardableResult
    static func request() -> Bool { CGRequestScreenCaptureAccess() }
}

// MARK: - エンジンの境界(テストで差し替えられるように)

/// 収録対象の一覧(ディスプレイとウィンドウ)。
struct ScreenRecordingTargets: Equatable {
    var displays: [ScreenCaptureTarget] = []
    var windows: [ScreenCaptureTarget] = []
}

/// 実物のキャプチャを行う部分の境界。本番は `ScreenCaptureKitEngine`、テストは偽物に差し替える。
protocol ScreenRecordingEngine: AnyObject {
    func loadTargets() async throws -> ScreenRecordingTargets
    func start(settings: ScreenRecordingSettings, outputURL: URL) async throws
    func stop() async throws -> URL
    func cancel() async
}

// MARK: - コントローラ(画面と状態)

/// 画面収録シートの状態と操作。状態遷移は Core の `ScreenRecordingStateMachine` に従い、
/// あり得ない操作(収録中にもう一度開始、など)は静かに無視する。失敗はすべて `error` に日本語で残す。
@MainActor
final class ScreenRecordingController: ObservableObject {
    @Published private(set) var machine = ScreenRecordingStateMachine()
    @Published private(set) var error: ScreenRecordingError?
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var finishedURL: URL?
    @Published private(set) var targets = ScreenRecordingTargets()
    @Published private(set) var permissionGranted = false
    @Published private(set) var isLoadingTargets = false

    // 選択(シートの入力)
    @Published var kind: ScreenCaptureSourceKind = .display
    @Published var displayID: UInt32 = 0
    @Published var windowID: UInt32 = 0
    @Published var regionX: Double = 0
    @Published var regionY: Double = 0
    @Published var regionWidth: Double = 640
    @Published var regionHeight: Double = 360
    @Published var includeSystemAudio = true
    @Published var fps: Int = 30
    /// 保存先フォルダ(既定は「ムービー」)。
    @Published var outputDirectory: URL = ScreenRecordingController.defaultOutputDirectory()

    private let engine: any ScreenRecordingEngine
    private var startedAt: Date?
    private var timerTask: Task<Void, Never>?

    init(engine: any ScreenRecordingEngine = ScreenCaptureKitEngine()) {
        self.engine = engine
    }

    static func defaultOutputDirectory() -> URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    var phase: ScreenRecordingPhase { machine.phase }

    // MARK: 許可

    func refreshPermission() {
        permissionGranted = ScreenCapturePermission.isGranted()
    }

    func requestPermission() {
        ScreenCapturePermission.request()
        refreshPermission()
        if permissionGranted { Task { await refreshTargets() } }
    }

    // MARK: 対象の一覧

    func refreshTargets() async {
        isLoadingTargets = true
        defer { isLoadingTargets = false }
        do {
            targets = try await engine.loadTargets()
            error = nil
            if displayID == 0, let first = targets.displays.first { displayID = first.displayID }
            if windowID == 0, let first = targets.windows.first { windowID = first.windowID }
        } catch let e as ScreenRecordingError {
            error = e
        } catch {
            self.error = .captureFailed("対象の一覧を取得できませんでした: \(error.localizedDescription)")
        }
    }

    // MARK: 設定の組み立て

    /// いまの選択から収録設定を作る。対象が無ければ nil。
    func makeSettings() -> ScreenRecordingSettings? {
        let target: ScreenCaptureTarget?
        switch kind {
        case .display:
            target = targets.displays.first { $0.displayID == displayID }
        case .window:
            target = targets.windows.first { $0.windowID == windowID }
        case .region:
            guard var base = targets.displays.first(where: { $0.displayID == displayID }) else { target = nil; break }
            base.kind = .region
            base.region = ScreenRecordingRegion(x: regionX, y: regionY, width: regionWidth, height: regionHeight)
            target = base
        }
        guard let target else { return nil }
        return ScreenRecordingSettings(target: target, includeSystemAudio: includeSystemAudio, fps: fps)
    }

    // MARK: 開始・停止

    func startRecording() async {
        guard machine.canStart else { return }
        error = nil
        finishedURL = nil
        refreshPermission()
        guard permissionGranted else {
            machine.transition(to: .preparing)
            machine.transition(to: .failed)
            error = .permissionDenied
            return
        }
        guard let settings = makeSettings() else {
            machine.transition(to: .preparing)
            machine.transition(to: .failed)
            error = .noTargetAvailable
            return
        }
        if let problem = settings.validate() {
            machine.transition(to: .preparing)
            machine.transition(to: .failed)
            error = problem
            return
        }
        machine.transition(to: .preparing)
        do {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            let url = ScreenRecordingFileNaming.outputURL(in: outputDirectory, date: Date()) {
                FileManager.default.fileExists(atPath: $0.path)
            }
            try await engine.start(settings: settings.clampedToDisplay, outputURL: url)
            machine.transition(to: .recording)
            startedAt = Date()
            elapsed = 0
            startTimer()
        } catch let e as ScreenRecordingError {
            machine.transition(to: .failed)
            error = e
        } catch {
            machine.transition(to: .failed)
            self.error = .captureFailed("収録を始められませんでした: \(error.localizedDescription)")
        }
    }

    func stopRecording() async {
        guard machine.canStop else { return }
        machine.transition(to: .stopping)
        stopTimer()
        do {
            let url = try await engine.stop()
            finishedURL = url
            machine.transition(to: .finished)
        } catch let e as ScreenRecordingError {
            machine.transition(to: .failed)
            error = e
        } catch {
            machine.transition(to: .failed)
            self.error = .writerFailed("収録の保存に失敗しました: \(error.localizedDescription)")
        }
    }

    /// シートを閉じるときの後片付け(収録中なら取り消す)。
    func cancelIfNeeded() async {
        guard machine.isActive else { return }
        stopTimer()
        await engine.cancel()
        machine.reset()
    }

    /// 終わった/失敗した状態から、もう一度始められる状態へ。
    func backToIdle() {
        if machine.phase == .finished || machine.phase == .failed {
            machine.transition(to: .idle)
            error = nil
            finishedURL = nil
            elapsed = 0
        }
    }

    private func startTimer() {
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self, let startedAt = self.startedAt else { return }
                self.elapsed = Date().timeIntervalSince(startedAt)
            }
        }
    }

    private func stopTimer() { timerTask?.cancel(); timerTask = nil }
}

// MARK: - ScreenCaptureKit エンジン(本番)

/// ScreenCaptureKit で画面・ウィンドウ・矩形を .mov(H.264)に書く本番エンジン。
/// 自分(Movie Cut)のウィンドウは画面全体・矩形の収録から除く(操作用のシートが映り込まないように)。
/// 失敗はすべて `ScreenRecordingError` で返し、強制アンラップや例外でアプリを落とさない。
final class ScreenCaptureKitEngine: NSObject, ScreenRecordingEngine, SCStreamDelegate, SCStreamOutput {
    private var content: SCShareableContent?
    private var stream: SCStream?
    private var writer: RecordingFileWriter?
    private var outputURL: URL?
    private var streamError: Error?

    func loadTargets() async throws -> ScreenRecordingTargets {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            // 一覧の取得自体が許可の壁に当たる代表的な失敗。許可なしとして案内する。
            if !ScreenCapturePermission.isGranted() { throw ScreenRecordingError.permissionDenied }
            throw ScreenRecordingError.captureFailed("対象の一覧を取得できませんでした: \(error.localizedDescription)")
        }
        self.content = content
        let displays = content.displays.map {
            ScreenCaptureTarget(kind: .display, displayID: $0.displayID,
                                title: "ディスプレイ \($0.displayID)(\(Int($0.frame.width))×\(Int($0.frame.height)))",
                                displayWidth: Double($0.frame.width), displayHeight: Double($0.frame.height))
        }
        let windows = content.windows.compactMap { w -> ScreenCaptureTarget? in
            guard w.isOnScreen, w.frame.width >= 16, w.frame.height >= 16 else { return nil }
            let app = w.owningApplication?.applicationName ?? ""
            let title = (w.title?.isEmpty == false) ? w.title! : app
            guard !title.isEmpty else { return nil }
            return ScreenCaptureTarget(kind: .window, displayID: 0, windowID: w.windowID,
                                       title: app.isEmpty ? title : "\(title)(\(app))")
        }
        return ScreenRecordingTargets(displays: displays, windows: windows)
    }

    func start(settings: ScreenRecordingSettings, outputURL: URL) async throws {
        guard stream == nil else { throw ScreenRecordingError.alreadyRunning }
        if content == nil { _ = try await loadTargets() }
        guard let content else { throw ScreenRecordingError.noTargetAvailable }

        let filter: SCContentFilter
        let config = SCStreamConfiguration()
        config.queueDepth = 5
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(settings.fps))
        config.capturesAudio = settings.includeSystemAudio
        if settings.includeSystemAudio {
            config.sampleRate = 48000
            config.channelCount = 2
        }
        let ownApps = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }

        switch settings.target.kind {
        case .display:
            guard let display = content.displays.first(where: { $0.displayID == settings.target.displayID }) else {
                throw ScreenRecordingError.noTargetAvailable
            }
            filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
            config.width = max(2, Int(filter.contentRect.width * CGFloat(filter.pointPixelScale)))
            config.height = max(2, Int(filter.contentRect.height * CGFloat(filter.pointPixelScale)))
        case .window:
            guard let window = content.windows.first(where: { $0.windowID == settings.target.windowID }) else {
                throw ScreenRecordingError.noTargetAvailable
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
            config.width = max(2, Int(filter.contentRect.width * CGFloat(filter.pointPixelScale)))
            config.height = max(2, Int(filter.contentRect.height * CGFloat(filter.pointPixelScale)))
        case .region:
            guard let display = content.displays.first(where: { $0.displayID == settings.target.displayID }),
                  let region = settings.target.region else {
                throw ScreenRecordingError.invalidRegion("範囲が指定されていません")
            }
            filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
            config.sourceRect = region.cgRect
            let scale = CGFloat(filter.pointPixelScale)
            config.width = max(2, Int(region.width * Double(scale)))
            config.height = max(2, Int(region.height * Double(scale)))
        }
        config.width -= config.width % 2
        config.height -= config.height % 2

        let writer: RecordingFileWriter
        do {
            writer = try RecordingFileWriter(outputURL: outputURL, width: config.width, height: config.height,
                                             includeAudio: settings.includeSystemAudio)
        } catch {
            throw ScreenRecordingError.writerFailed("保存先ファイルを用意できませんでした: \(error.localizedDescription)")
        }
        self.writer = writer
        self.outputURL = outputURL
        streamError = nil

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: writer.queue)
            if settings.includeSystemAudio {
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: writer.queue)
            }
            try await stream.startCapture()
        } catch {
            self.writer = nil
            throw ScreenRecordingError.captureFailed("収録を始められませんでした: \(error.localizedDescription)")
        }
        self.stream = stream
    }

    func stop() async throws -> URL {
        guard let stream, let writer, let outputURL else { throw ScreenRecordingError.notRecording }
        do { try await stream.stopCapture() } catch {
            // 停止の失敗でも、書ける分は閉じて返すよう試みる
            NSLog("screen recording stopCapture failed: %@", error.localizedDescription)
        }
        self.stream = nil
        self.writer = nil
        try await writer.finish()
        if let streamError {
            throw ScreenRecordingError.captureFailed("収録が途中で止まりました: \(streamError.localizedDescription)")
        }
        return outputURL
    }

    func cancel() async {
        if let stream { try? await stream.stopCapture() }
        stream = nil
        if let writer, let outputURL = self.outputURL {
            await writer.cancel()
            try? FileManager.default.removeItem(at: outputURL)
        }
        writer = nil
    }

    // MARK: SCStreamDelegate / SCStreamOutput

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        streamError = error
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        switch type {
        case .screen:
            // 収録中のフレームだけを使う(空フレーム・停止中などは状態で見分ける)
            if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
               let statusRaw = attachments.first?[.status] as? Int,
               let status = SCFrameStatus(rawValue: statusRaw), status != .complete {
                return
            }
            writer?.appendVideo(sampleBuffer)
        case .audio:
            writer?.appendAudio(sampleBuffer)
        default:
            break
        }
    }
}

// MARK: - ファイル書き込み(AVAssetWriter)

/// サンプルを受けて .mov に書く担当。直列キューで動き、失敗は握って状態に残す(落とさない)。
final class RecordingFileWriter {
    let queue = DispatchQueue(label: "jp.local.moviecut.screen-recording-writer")
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput?
    private var started = false
    private var failed: Error?

    init(outputURL: URL, width: Int, height: Int, includeAudio: Bool) throws {
        writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        videoInput.expectsMediaDataInRealTime = true
        if includeAudio {
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000,
            ])
            a.expectsMediaDataInRealTime = true
            audioInput = a
        } else {
            audioInput = nil
        }
        if writer.canAdd(videoInput) { writer.add(videoInput) }
        if let audioInput, writer.canAdd(audioInput) { writer.add(audioInput) }
    }

    private func beginIfNeeded(at pts: CMTime) {
        guard !started else { return }
        started = true
        if !writer.startWriting() {
            failed = writer.error ?? ScreenRecordingError.writerFailed("ファイルへの書き込みを始められませんでした")
            return
        }
        writer.startSession(atSourceTime: pts)
    }

    func appendVideo(_ buffer: CMSampleBuffer) {
        queue.async { [self] in
            guard failed == nil else { return }
            beginIfNeeded(at: buffer.presentationTimeStamp)
            guard started, writer.status == .writing, videoInput.isReadyForMoreMediaData else { return }
            if !videoInput.append(buffer), let e = writer.error { failed = e }
        }
    }

    func appendAudio(_ buffer: CMSampleBuffer) {
        queue.async { [self] in
            guard failed == nil, started, writer.status == .writing,
                  let audioInput, audioInput.isReadyForMoreMediaData else { return }
            if !audioInput.append(buffer), let e = writer.error { failed = e }
        }
    }

    func finish() async throws {
        let done = await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                guard started, writer.status == .writing else { c.resume(); return }
                videoInput.markAsFinished()
                audioInput?.markAsFinished()
                writer.finishWriting { c.resume() }
            }
        }
        _ = done
        if let failed { throw ScreenRecordingError.writerFailed("収録の保存に失敗しました: \(failed.localizedDescription)") }
        if writer.status == .failed, let e = writer.error {
            throw ScreenRecordingError.writerFailed("収録の保存に失敗しました: \(e.localizedDescription)")
        }
        if !started { throw ScreenRecordingError.writerFailed("映像を受け取れず、収録できませんでした") }
    }

    func cancel() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                if writer.status == .writing || writer.status == .unknown { writer.cancelWriting() }
                c.resume()
            }
        }
    }
}

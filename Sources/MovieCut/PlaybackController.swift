import Foundation
import AppKit
import AVFoundation
import QuartzCore
import MovieCutCore

// MARK: - 音声バックエンドと時計(差し替えてテストできる)

/// 再生用の音声出力。マスタークロック(今どこを鳴らしているか)も返す。
protocol AudioBackend: AnyObject {
    /// 音が実際に流れている(エンジンが動いていて、プレイヤーが再生中)。
    var isRunning: Bool { get }
    /// 音声ファイルを読み込む(以前のものは捨てる)。長さ(秒)を返す。
    func load(url: URL) throws -> Double
    /// 読み込んだ音声を捨てる(無音で再生するとき)。
    func unload()
    /// プロジェクトの time 秒から鳴らし始める(鳴っていれば鳴らし直す)。
    func start(at time: Double) throws
    /// 止める(位置は覚えない)。
    func pause()
    /// いま鳴っているプロジェクト時刻(秒)。時計が使えないとき(まだ最初の音が出ていない等)は nil。
    func currentTime() -> Double?
    func shutdown()
    /// 出力デバイスの変更などでエンジンが止まったときの通知先。
    var onConfigurationChange: (() -> Void)? { get set }
}

protocol PlaybackClock {
    /// 単調増加する秒。
    func now() -> Double
}

struct HostClock: PlaybackClock {
    func now() -> Double { ProcessInfo.processInfo.systemUptime }
}

/// AVAudioEngine + AVAudioPlayerNode。時計はプレイヤーノードのサンプル時刻(出力の遅延ぶんは引く)。
final class EngineAudioBackend: AudioBackend {
    private var engine: AVAudioEngine?
    private let player = AVAudioPlayerNode()
    private var file: AVAudioFile?
    private var attached = false
    private var baseTime = 0.0
    private var observer: NSObjectProtocol?
    var onConfigurationChange: (() -> Void)?

    var isRunning: Bool { (engine?.isRunning ?? false) && player.isPlaying }

    private func makeEngineIfNeeded() -> AVAudioEngine {
        if let e = engine { return e }
        let e = AVAudioEngine()
        engine = e
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: e, queue: .main) { [weak self] _ in
            self?.onConfigurationChange?()
        }
        return e
    }

    func load(url: URL) throws -> Double {
        let e = makeEngineIfNeeded()
        player.stop()
        let f = try AVAudioFile(forReading: url)
        if !attached { e.attach(player); attached = true } else { e.disconnectNodeOutput(player) }
        e.connect(player, to: e.mainMixerNode, format: f.processingFormat)
        e.prepare()
        file = f
        return Double(f.length) / f.processingFormat.sampleRate
    }

    func unload() {
        player.stop()
        file = nil
    }

    func start(at time: Double) throws {
        guard let f = file, let e = engine else { return }  // 音声なし: エンジンは使わず、呼び出し側がホスト時計で進める
        player.stop()
        if !e.isRunning { try e.start() }
        let sr = f.processingFormat.sampleRate
        let frame = AVAudioFramePosition(max(0, time) * sr)
        let count = f.length - frame
        if count > 0 {
            player.scheduleSegment(f, startingFrame: frame, frameCount: AVAudioFrameCount(count), at: nil)
        }
        baseTime = time
        player.play()
    }

    func pause() { player.stop() }

    func currentTime() -> Double? {
        guard player.isPlaying, let nt = player.lastRenderTime, let pt = player.playerTime(forNodeTime: nt), pt.sampleRate > 0 else { return nil }
        // 「描いた時刻」と「聞こえる時刻」の差(出力遅延)を引く。極端な値は無視する。
        let latency = min(0.3, max(0, engine?.outputNode.presentationLatency ?? 0))
        return baseTime + max(0, Double(pt.sampleTime) / pt.sampleRate - latency)
    }

    func shutdown() {
        player.stop()
        engine?.stop()
        if let o = observer { NotificationCenter.default.removeObserver(o) }
        observer = nil
        engine = nil
        file = nil
        attached = false
    }
}

// MARK: - 再生コントローラ

/// ディスプレイリンクの呼び出し先(Objective-C のセレクタが要る)。
private final class DisplayLinkTarget: NSObject {
    let fire: () -> Void
    init(_ fire: @escaping () -> Void) { self.fire = fire }
    @objc func tick(_ link: CADisplayLink) { fire() }
}

/// 再生・一時停止・シーク・コマ送り。音は「プロジェクト全体のミックス(CAF)」をプレイヤーノードで鳴らし、
/// 画面の時刻は毎ティック、音のクロックから読み直す(ずれが溜まらない)。
@MainActor
final class PlaybackController {
    typealias Mixer = (Project, URL) throws -> Double

    weak var model: ProjectModel?
    let backend: AudioBackend
    let clock: PlaybackClock
    let mixer: Mixer
    /// 編集が止まってからミックスを作り直すまでの待ち(秒)。
    var debounce: TimeInterval
    /// ディスプレイリンクが作れないとき(ウィンドウなし)に 60Hz のタイマーで代用する。テストでは切る。
    var timerFallback = true
    /// ディスプレイリンクを付けるビュー(無ければ model.window の contentView)。
    weak var displayHost: NSView?

    private(set) var isPlaying = false { didSet { if oldValue != isPlaying { model?.isPlaying = isPlaying } } }
    private(set) var isPreparing = false
    private(set) var tickCount = 0
    /// ミックスを作り直した回数(検証用)。
    private(set) var rebuildCount = 0
    private(set) var lastMixError: String?
    /// J/K/L シャトルの速度段。停止・通常再生(1 倍)以外のときは音を出さず、時刻だけを速さに合わせて進める。
    private(set) var shuttleState = ShuttleState.stopped
    private var shuttling = false
    private var shuttleClock = 0.0

    private var startT = 0.0, clockStart = 0.0, lastT = 0.0
    private var scrubbing = false
    private var cacheKey: AudioCacheKey?
    private var cacheURL: URL?
    private var failedKey: AudioCacheKey?
    private var buildingKey: AudioCacheKey?
    private var armed = false
    private var generation = 0
    private var debounceTask: Task<Void, Never>?
    /// 再生前のミックス待ち(テストが await する)。
    private(set) var preparation: Task<Void, Never>?
    private var link: CADisplayLink?
    private var timer: Timer?
    private lazy var linkTarget = DisplayLinkTarget { [weak self] in
        MainActor.assumeIsolated { self?.tick() }
    }

    init(model: ProjectModel?, backend: AudioBackend = EngineAudioBackend(), clock: PlaybackClock = HostClock(),
         debounce: TimeInterval = 0.25,
         mixer: @escaping Mixer = { p, u in try AudioMixer.mixdown(project: p, assets: RenderAssets(), to: u) }) {
        self.model = model
        self.backend = backend
        self.clock = clock
        self.mixer = mixer
        self.debounce = debounce
        backend.onConfigurationChange = { [weak self] in
            MainActor.assumeIsolated { self?.configurationChanged() }
        }
    }

    deinit {
        backend.shutdown()
        if let u = cacheURL { try? FileManager.default.removeItem(at: u) }
    }

    // MARK: 操作

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        guard let model, !isPlaying, !isPreparing, !model.isLocked else { return }
        model.auditionPlayer.stop()                 // 試聴の短い音は止めて、全体を鳴らす(試聴のオンオフはそのまま)
        armed = true
        shuttleState = .normal
        let end = model.project.endTime
        guard end > 0 else { return }
        if let r = model.activeLoopRange {
            model.currentTime = ExportRangeLoop.startTime(current: model.currentTime, range: r)   // 範囲の外なら範囲の頭から
        } else if model.currentTime >= end - 1e-6 {
            model.currentTime = 0   // 終わりにいるときは先頭から
        }
        let key = currentKey()
        if key == cacheKey || key == failedKey {
            begin()
        } else {
            isPreparing = true
            model.statusText = "音声を準備しています…"
            let p = model.project
            preparation = Task { [weak self] in
                await self?.rebuild(project: p, key: key)
                guard let self else { return }
                self.isPreparing = false
                self.preparation = nil
                if self.model?.statusText == "音声を準備しています…" { self.model?.statusText = "" }
                // 待っている間に編集されていたら、その版の音で始める(鍵が合わなければ無音で始めるより作り直す)
                if self.currentKey() == self.cacheKey || self.currentKey() == self.failedKey { self.begin() }
            }
        }
    }

    func pause() {
        guard isPlaying else { return }
        stopInternal()
    }

    /// ⏮: 先頭へ(鳴っていれば先頭から鳴らし直す)。
    func goToStart() { seek(to: 0) }

    /// J(step -1)/ L(step 1): 速さを一段動かす。停止からの J は逆 1 倍、L は順 1 倍(音あり)。
    func shuttle(by step: Int) {
        guard let model, !isPreparing, !model.isLocked, model.project.endTime > 0 else { return }
        applyShuttle(shuttleState.moved(by: step), model: model)
    }

    /// K: 停止。
    func shuttleStop() { pause() }

    private func applyShuttle(_ next: ShuttleState, model: ProjectModel) {
        if next.isStopped { pause(); return }
        if next.speed == 1 {
            // 順 1 倍は通常の再生(音あり)
            if isPlaying {
                if shuttling { shuttling = false; shuttleState = .normal; restartAudio(at: model.currentTime) }
            } else {
                play()
            }
            return
        }
        // 2 倍以上・逆再生は音を止めて、時刻だけを進める
        if isPlaying && !shuttling { backend.pause() }
        if !isPlaying {
            model.assets.beginExportMode(preview: true)
            isPlaying = true
            scrubbing = false
            startTicking()
        }
        shuttleState = next
        shuttling = true
        shuttleClock = clock.now()
    }

    /// ←/→: 1 コマ(1/fps)ずつ。
    func step(frames: Int) {
        guard let model else { return }
        let end = model.project.endTime
        var t = model.project.frameRate.stepped(from: model.currentTime, frames: frames)
        t = max(0, end > 0 ? min(t, max(end, model.currentTime)) : t)
        seek(to: t)
    }

    /// 時刻を動かす。鳴っていれば、その位置から鳴らし直す。
    func seek(to t: Double) {
        guard let model else { return }
        let nt = max(0, t)
        model.currentTime = nt
        guard isPlaying, !scrubbing else {
            if !isPlaying { model.auditionAtPlayhead() }   // 止まっているとき: 試聴がオンなら、その位置の対象の音だけを鳴らす
            return
        }
        restartAudio(at: nt)
    }

    /// ルーラーのドラッグ中は音を止めておき、離したところから鳴らし直す(細切れに鳴らし直さない)。
    func beginScrub() {
        guard isPlaying, !scrubbing else { return }
        scrubbing = true
        backend.pause()
    }

    func endScrub() {
        guard scrubbing else { return }
        scrubbing = false
        if isPlaying, let model { restartAudio(at: model.currentTime) }
    }

    /// 編集が入った(ProjectModel.edit / Undo)。再生中なら止め、音が変わったならミックスを作り直す。
    func projectDidChange() {
        if isPlaying { stopInternal() }
        scheduleRebuildIfNeeded()
    }

    /// 開いた直後など: 先にミックスを作っておく(再生ボタンですぐ鳴らせるように)。
    func warmUp() {
        armed = true
        scheduleRebuildIfNeeded()
    }

    /// ドキュメントを閉じるとき: 止めて、エンジンと一時ファイルを手放す。
    func shutdown() {
        debounceTask?.cancel(); debounceTask = nil
        preparation?.cancel()
        generation += 1
        if isPlaying { stopInternal() }
        stopTicking()
        backend.shutdown()
        if let u = cacheURL { try? FileManager.default.removeItem(at: u) }
        cacheURL = nil; cacheKey = nil
        model?.assets.endExportMode()
    }

    /// 検証用: いまの状態。
    var debugBackendRunning: Bool { backend.isRunning }

    // MARK: 内部: 開始と停止

    private func currentKey() -> AudioCacheKey {
        AudioCacheKey.make(for: model?.project ?? Project())
    }

    private func restartAudio(at t: Double) {
        startT = t; clockStart = clock.now(); lastT = t
        do { try backend.start(at: t) } catch { reportAudioError(error) }
    }

    private func begin() {
        guard let model else { return }
        let t = model.currentTime
        model.assets.beginExportMode(preview: true)          // 再生中は動画を順次読みにする
        restartAudio(at: t)
        isPlaying = true
        scrubbing = false
        startTicking()
    }

    private func stopInternal() {
        backend.pause()
        stopTicking()
        scrubbing = false
        shuttling = false
        shuttleState = .stopped
        isPlaying = false
        model?.trimLoop = nil                   // 反復再生は止めたら終わり(Space でも止まる)
        model?.assets.endExportMode()           // 止まったら正確なフレーム(generator)に戻す
        model?.previewEpoch += 1                // 止まった位置の絵を描き直させる
    }

    private func reportAudioError(_ e: Error) {
        model?.statusText = "音を出せませんでした: \(e.localizedDescription)"
    }

    private func configurationChanged() {
        guard isPlaying, !scrubbing, let model else { return }
        restartAudio(at: model.currentTime)
    }

    // MARK: 内部: ティック

    /// 毎フレーム。画面の時刻を音のクロックから読み直す。
    func tick() {
        guard isPlaying, !scrubbing, let model else { return }
        tickCount += 1
        if shuttling { tickShuttle(model: model); return }
        var t = backend.currentTime() ?? (startT + clock.now() - clockStart)
        t = max(t, lastT)                        // 巻き戻らない
        if let r = model.activeLoopRange, let back = ExportRangeLoop.wrap(t, range: r) {
            model.currentTime = back             // 範囲ループ: 範囲の終わりで頭へ戻して鳴らし直す
            restartAudio(at: back)
            return
        }
        lastT = t
        let end = model.project.endTime
        if t >= end {
            model.currentTime = end
            stopInternal()
            return
        }
        model.currentTime = t
    }

    /// シャトル中: 時計の経過 × 速さだけ進める。端に着いたら止まる。
    private func tickShuttle(model: ProjectModel) {
        let now = clock.now()
        let dt = now - shuttleClock
        shuttleClock = now
        let end = model.project.endTime
        let t = model.currentTime + shuttleState.speed * dt
        if t <= 0 && shuttleState.speed < 0 { model.currentTime = 0; stopInternal(); return }
        if t >= end { model.currentTime = end; stopInternal(); return }
        model.currentTime = max(0, t)
    }

    private func startTicking() {
        stopTicking()
        if let host = displayHost ?? model?.window?.contentView {
            let l = host.displayLink(target: linkTarget, selector: #selector(DisplayLinkTarget.tick(_:)))
            l.add(to: .main, forMode: .common)
            link = l
        } else if timerFallback {
            let tm = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(tm, forMode: .common)
            timer = tm
        }
    }

    private func stopTicking() {
        link?.invalidate(); link = nil
        timer?.invalidate(); timer = nil
    }

    // MARK: 内部: ミックスのキャッシュ

    private func scheduleRebuildIfNeeded() {
        guard armed, let model else { return }
        let key = AudioCacheKey.make(for: model.project)
        if key == cacheKey || key == failedKey || key == buildingKey { debounceTask?.cancel(); return }
        debounceTask?.cancel()
        let delay = debounce
        debounceTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard !Task.isCancelled, let self, let model = self.model else { return }
            let p = model.project
            await self.rebuild(project: p, key: AudioCacheKey.make(for: p))
        }
    }

    /// ミックスを背景で作り、できたらバックエンドへ読み込む。作っている間に新しい依頼が来たら、古い結果は捨てる。
    func rebuild(project: Project, key: AudioCacheKey) async {
        if key == cacheKey || key == failedKey { return }
        generation += 1
        let gen = generation
        buildingKey = key
        let url = PlaybackTempFiles.newFileURL()
        let mixer = self.mixer
        let assets = model?.assets
        let result: Result<Double, Error> = await Task.detached(priority: .userInitiated) {
            do {
                let d = try mixer(project, url)
                // 口パク用の音量エンベロープも先に作っておく(最初のフレームで待たされないように)
                if let assets { for c in project.allClips where c.type == .voice { if let s = c.src { _ = assets.mouthEnvelope(for: s) } } }
                // ビジュアライザがあれば、合成音声の音量も先に作る(もう 1 回ミックスするので、ある時だけ)
                if let assets, project.allClips.contains(where: { $0.type == .visualizer }) { _ = assets.mixEnvelope(for: project) }
                return .success(d)
            } catch { return .failure(error) }
        }.value
        guard gen == generation else { try? FileManager.default.removeItem(at: url); return }  // 古い依頼
        buildingKey = nil
        rebuildCount += 1
        switch result {
        case .success:
            do {
                _ = try backend.load(url: url)
                if let old = cacheURL { try? FileManager.default.removeItem(at: old) }
                cacheURL = url; cacheKey = key; failedKey = nil; lastMixError = nil
            } catch {
                try? FileManager.default.removeItem(at: url)
                markFailed(key, error)
            }
        case .failure(let e):
            try? FileManager.default.removeItem(at: url)
            markFailed(key, e)
        }
    }

    /// 読めない素材があったとき: 音なしで進める(エラーは状態欄に出す)。
    private func markFailed(_ key: AudioCacheKey, _ error: Error) {
        failedKey = key
        cacheKey = nil
        backend.unload()
        if let old = cacheURL { try? FileManager.default.removeItem(at: old); cacheURL = nil }
        lastMixError = error.localizedDescription
        model?.statusText = "音声を準備できませんでした(無音で再生します): \(error.localizedDescription)"
    }
}

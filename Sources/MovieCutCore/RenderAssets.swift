import Foundation
import CoreGraphics
import ImageIO
import AVFoundation

/// 描画に使う素材のキャッシュ(画像・動画フレーム・口パク用の音量エンベロープ)。
/// 読めないファイルは nil を返すだけで、クラッシュしない。スレッドセーフ。
public final class RenderAssets {
    private let lock = NSLock()
    private var images: [String: CGImage] = [:]
    private var missingImages: Set<String> = []
    private var envelopes: [String: [Float]] = [:]
    private var mouthStateCache: [String: [Bool]] = [:]
    private var visemeCache: [String: [Viseme]?] = [:]
    private var missingEnvelopes: Set<String> = []
    private var generators: [String: AVAssetImageGenerator] = [:]
    private var missingVideos: Set<String> = []
    private var exportMode = false
    private var sequentials: [String: SequentialVideoFrames] = [:]
    private var reversers: [String: ReverseVideoFrames] = [:]
    private var videoSizes: [String: CGSize] = [:]
    /// 合成音声の音量エンベロープ(直前の 1 件だけ)。キーは音に関わる内容の指紋。
    private var mixEnvelopeKey: String?
    private var mixEnvelopeValue: [Float]?
    /// プロキシ編集: プレビューの映像だけ、プロキシのファイルを読む(書き出しは読まない)。
    private var useProxies = false
    private var proxyLookup: ((String) -> String?)?
    /// 元のパス → プロキシのパス(nil = プロキシなし)。設定や作成のあとに `setPreviewProxies` で作り直す。
    private var proxyCache: [String: String?] = [:]
    /// 今の順次読みがプレビューの再生か(書き出しの順次読みと区別する)。
    private var previewSession = false

    /// オプティカルフロー補間のフロー(素材のコマの組ごと。プレビューと書き出しで同じ組を何度も描くので、求めた動きを覚えておく)。
    public let flowCache = FlowCache()

    public init() {}

    /// プレビューのプロキシを使うか。`lookup` は元のパスからプロキシのパスを返す(無ければ nil)。
    /// 書き出しで使う `RenderAssets` には呼ばない(既定はオフ)。
    public func setPreviewProxies(_ on: Bool, lookup: ((String) -> String?)? = nil) {
        lock.lock(); defer { lock.unlock() }
        useProxies = on
        proxyLookup = lookup
        proxyCache = [:]
    }

    /// 読むファイル: プレビューで、設定がオンでプロキシがあるときだけプロキシ。書き出しは常に元の素材。
    /// ロックを持って呼ぶこと。
    func sourcePathLocked(_ path: String) -> String {
        guard useProxies, !exportMode || previewSession, let lookup = proxyLookup else { return path }
        if let c = proxyCache[path] { return c ?? path }
        let p = lookup(path)
        proxyCache[path] = .some(p)
        return p ?? path
    }

    /// テスト・検証用: 今この素材を読むときのファイル(プロキシがあればそれ)。
    public func sourcePath(for path: String) -> String {
        lock.lock(); defer { lock.unlock() }
        return sourcePathLocked(path)
    }

    /// 画像(ImageIO)。パスをキーにキャッシュする。
    public func image(at path: String) -> CGImage? {
        lock.lock(); defer { lock.unlock() }
        if let i = images[path] { return i }
        if missingImages.contains(path) { return nil }
        let url = URL(fileURLWithPath: path)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            missingImages.insert(path)
            return nil
        }
        images[path] = img
        return img
    }

    /// 口パク用のエンベロープ: チャンネル 0 の 1/60 秒ごとの RMS(renderer.js getBuffer と同じ)。
    public func mouthEnvelope(for path: String) -> [Float]? {
        lock.lock(); defer { lock.unlock() }
        if let e = envelopes[path] { return e }
        if missingEnvelopes.contains(path) { return nil }
        guard let env = Self.computeEnvelope(path) else {
            missingEnvelopes.insert(path)
            return nil
        }
        envelopes[path] = env
        return env
    }

    /// 口の開閉(`MouthGate` のヒステリシス)を 1/60 秒ごとに。エンベロープから決まるので、結果も素材ごとにキャッシュする。
    public func mouthStates(for path: String) -> [Bool]? {
        guard let env = mouthEnvelope(for: path) else { return nil }
        lock.lock(); defer { lock.unlock() }
        if let s = mouthStateCache[path] { return s }
        let s = MouthGate.states(env)
        mouthStateCache[path] = s
        return s
    }

    /// あいうえお口パク: コマ(1/60 秒)ごとの口の形。セリフの文字・音声・使う範囲が同じならキャッシュを返す。作れなければ nil。
    public func visemes(src: String, text: String, offset: Double, duration: Double) -> [Viseme]? {
        let key = "\(src)|\(offset)|\(duration)|\(text)"
        lock.lock()
        if let c = visemeCache[key] { lock.unlock(); return c }
        lock.unlock()
        var result: [Viseme]? = nil
        if let env = mouthEnvelope(for: src) {
            let lo = Int(floor(offset * LipSync.envelopeRate)), hi = Int(ceil((offset + duration) * LipSync.envelopeRate))
            result = LipSync.frames(moras: LipSync.moras(of: text), envelope: env, range: lo..<max(lo, hi))
        }
        lock.lock(); visemeCache[key] = .some(result); lock.unlock()
        return result
    }

    /// プロジェクトの合成音声(書き出しと同じミックス)の 1/60 秒ごとの RMS(プロジェクトの時刻 0 から)。
    /// ビジュアライザが使う。音に関わる内容が同じならキャッシュを返す。作れなければ nil。
    public func mixEnvelope(for project: Project) -> [Float]? {
        let key = Self.mixKey(project)
        lock.lock(); defer { lock.unlock() }
        if key == mixEnvelopeKey, let v = mixEnvelopeValue { return v }
        guard let env = Self.computeMixEnvelope(project, assets: self) else { return nil }
        mixEnvelopeKey = key
        mixEnvelopeValue = env
        return env
    }

    /// 音に関わる部分の指紋(音のあるクリップと、トラックが鳴るかどうか)。映像・文字だけの変更では変わらない。
    static func mixKey(_ project: Project) -> String {
        struct AudioTrack: Encodable { let audible: Bool; let clips: [Clip] }
        let parts = project.tracks.map { tr in
            AudioTrack(audible: project.isAudible(tr),
                       clips: tr.clips.filter { [ClipType.audio, .voice, .video].contains($0.type) })
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        guard let data = try? enc.encode(parts) else { return UUID().uuidString }
        return String(decoding: data, as: UTF8.self)
    }

    static func computeMixEnvelope(_ project: Project, assets: RenderAssets) -> [Float]? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mc-viz-mix-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        guard let dur = try? AudioMixer.mixdown(project: project, assets: assets, to: url) else { return nil }
        // 音が 1 つも無いときは書かれないことがある。その場合は無音の長さ分の 0
        guard FileManager.default.fileExists(atPath: url.path),
              let file = try? AVAudioFile(forReading: url) else {
            return [Float](repeating: 0, count: Int((dur * 60).rounded(.up)))
        }
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames),
              (try? file.read(into: buf)) != nil,
              let ch = buf.floatChannelData else { return [] }
        let n = Int(buf.frameLength)
        let nch = Int(file.processingFormat.channelCount)
        let step = max(1, Int(file.processingFormat.sampleRate / 60))
        var env = [Float](repeating: 0, count: (n + step - 1) / step)
        for i in 0..<env.count {
            let s = i * step, e = min(n, s + step)
            var sum: Float = 0
            for c in 0..<nch {
                let data = ch[c]
                var j = s
                while j < e { sum += data[j] * data[j]; j += 1 }
            }
            env[i] = (sum / Float(max(1, (e - s) * nch))).squareRoot()
        }
        return env
    }

    static func computeEnvelope(_ path: String) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else { return nil }
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames),
              (try? file.read(into: buf)) != nil,
              let ch = buf.floatChannelData else { return nil }
        let n = Int(buf.frameLength)
        let step = max(1, Int(file.processingFormat.sampleRate / 60))
        let data = ch[0]
        var env = [Float](repeating: 0, count: (n + step - 1) / step)
        for i in 0..<env.count {
            var sum: Float = 0
            let s = i * step, e = min(n, s + step)
            var j = s
            while j < e { sum += data[j] * data[j]; j += 1 }
            env[i] = (sum / Float(step)).squareRoot()
        }
        return env
    }

    /// 書き出しモード: 動画フレームを AVAssetReader で前から順に読む(時刻が戻ったときだけ generator)。
    /// `preview: true` はプレビューの再生(順次読み)。プロキシが使えるのはこの場合だけ(書き出しは preview を付けない)。
    public func beginExportMode(preview: Bool = false) {
        lock.lock(); exportMode = true; previewSession = preview; lock.unlock()
    }

    /// 書き出しモードを終えて、読み取り用のリソースを手放す。
    public func endExportMode() {
        lock.lock()
        exportMode = false
        previewSession = false
        let seqs = sequentials
        let revs = reversers
        sequentials = [:]
        reversers = [:]
        lock.unlock()
        seqs.values.forEach { $0.close() }
        revs.values.forEach { $0.close() }
    }

    /// 動画の time 秒のフレーム。通常はパスごとに generator、書き出しモードでは順次読み。
    /// - `reverse`: 逆再生のクリップ。書き出しモードでは、後ろから読んだ区間をメモリの束に置いて返す(`ReverseVideoFrames`)。
    /// - `exact`: 速度が変わる・逆再生・フリーズのクリップ。generator の許容幅を 0 にして「その時刻に出ているコマ」を返す
    ///   (書き出しの順次読みと同じコマになる)。速度 1 の順再生は従来どおり(許容幅 1/120 秒)。
    public func videoFrame(path: String, time: Double, reverse: Bool = false, exact: Bool = false) -> CGImage? {
        let img = videoFrameUncounted(path: path, time: time, reverse: reverse, exact: exact)
        if let img {
            lock.lock()
            if videoSizes[path] == nil {
                // プロキシのコマは小さいので、大きさは元の素材から取る(プレビューの取っ手・配置の計算に使う)
                let proxied = sourcePathLocked(path) != path
                lock.unlock()
                let size = proxied ? Self.naturalSize(ofVideo: path) ?? CGSize(width: img.width, height: img.height) : CGSize(width: img.width, height: img.height)
                lock.lock()
                if videoSizes[path] == nil { videoSizes[path] = size }
            }
            lock.unlock()
        }
        return img
    }

    /// 一度でもフレームを読んだ動画の大きさ(プレビューの取っ手用)。まだなら nil。
    public func knownVideoSize(path: String) -> CGSize? {
        lock.lock(); defer { lock.unlock() }
        return videoSizes[path]
    }

    /// 元の素材の大きさ(向きを直した後)。読めなければ nil。
    static func naturalSize(ofVideo path: String) -> CGSize? {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        guard let t = asset.tracks(withMediaType: .video).first else { return nil }
        let r = CGRect(origin: .zero, size: t.naturalSize).applying(t.preferredTransform)
        return CGSize(width: abs(r.width), height: abs(r.height))
    }

    private func videoFrameUncounted(path: String, time: Double, reverse: Bool, exact: Bool) -> CGImage? {
        lock.lock()
        let src = sourcePathLocked(path)     // プロキシを読むのはプレビューだけ
        if exportMode, reverse, !missingVideos.contains(src) {
            var rev = reversers[src]
            if rev == nil {
                rev = ReverseVideoFrames(url: URL(fileURLWithPath: src)) { [unowned self] t in self.generatorFrame(path: src, time: t, exact: true) }
                reversers[src] = rev
            }
            lock.unlock()
            return rev?.frame(at: time)
        }
        if exportMode, !missingVideos.contains(src) {
            var seq = sequentials[src]
            if seq == nil {
                seq = SequentialVideoFrames(url: URL(fileURLWithPath: src)) { [unowned self] t in self.generatorFrame(path: src, time: t, exact: exact) }
                sequentials[src] = seq
            }
            lock.unlock()
            return seq?.frame(at: time)
        }
        lock.unlock()
        return generatorFrame(path: src, time: time, exact: exact || reverse)
    }

    /// AVAssetImageGenerator で任意時刻のフレームを取る(正確・低速)。
    func generatorFrame(path: String, time: Double, exact: Bool = false) -> CGImage? {
        lock.lock()
        if missingVideos.contains(path) { lock.unlock(); return nil }
        let key = exact ? path + "\u{0}exact" : path
        var gen = generators[key]
        if gen == nil {
            let g = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: path)))
            g.appliesPreferredTrackTransform = true
            let tol = exact ? CMTime.zero : CMTime(value: 1, timescale: 120)
            g.requestedTimeToleranceBefore = tol
            g.requestedTimeToleranceAfter = tol
            generators[key] = g
            gen = g
        }
        lock.unlock()
        guard let g = gen else { return nil }
        // exact は「その時刻に出ているコマ」。計算の誤差で 1 コマ手前にならないよう 1 ms 足す(順次読みの許容と同じ)
        // 素材の終わりを越えた時刻は最後のコマ(書き出しの順次読み `SequentialVideoFrames` と同じ)。
        // 越えた時刻を失敗扱いにすると、その素材が「見つからない」として記録され、以後のコマが全部黒になる。
        let total = g.asset.duration.seconds
        let wanted = max(0, time + (exact ? 0.001 : 0))
        let clamped = total.isFinite && total > 0 ? min(wanted, max(0, total - 0.002)) : wanted
        let t = CMTime(seconds: clamped, preferredTimescale: 600)
        if let img = try? g.copyCGImage(at: t, actualTime: nil) { return img }
        lock.lock(); missingVideos.insert(path); lock.unlock()
        return nil
    }
}

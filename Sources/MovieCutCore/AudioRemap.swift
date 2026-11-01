import Foundation
import AVFoundation

/// 速度・逆再生のかかったクリップの音声を、タイムラインの長さ(`duration`)に合わせた一時ファイル(48 kHz ステレオ Float32 CAF)に作る。
///
/// 手順(どれも塊ごとに流すので、長いクリップでもメモリは一定):
/// 1. 使う素材の範囲 [offset, offset + duration × speed] を読んで一時ファイル A に書く(素材が足りなければ、無音で埋める)。
/// 2. 逆再生なら、A を後ろから塊ごとに読んで、逆順にした B を作る。
/// 3. 速度が 1 でなければ、AVAudioEngine のオフラインレンダリングで速度を変えた C を作る。
///    音程を保つ(既定)ときは AVAudioUnitTimePitch(rate = speed, pitch = 0)、保たないときは AVAudioUnitVarispeed。
/// 出力の長さはちょうど round(duration × 48000) フレーム(AVAudioUnitTimePitch の遅れぶんは頭を捨てて合わせる)。
enum AudioRemap {
    private static let sampleRate = 48000.0
    private static let blockFrames = 16384

    enum Failure: Error { case noSource, engine(String) }

    /// 素材を開く関数(ミキサーの openSource と同じもの)。範囲の長さを渡す。
    typealias OpenSource = (_ clip: Clip, _ offset: Double, _ span: Double) throws -> PCMSource?

    static func render(clip c: Clip, open: OpenSource, in dir: URL) throws -> URL {
        let sr = sampleRate
        let speed = c.effectiveSpeed
        let span = ClipTiming.sourceSpan(c)   // 速度ランプは積分(素材の長さ)
        let spanFrames = max(1, Int((span * sr).rounded()))
        let outFrames = max(1, Int((c.duration * sr).rounded()))
        guard let src = try open(c, c.offset, span) else { throw Failure.noSource }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let id = UUID().uuidString
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sr, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
        ]

        // 1. 範囲を書き出す
        let aURL = dir.appendingPathComponent("\(id)-a.caf")
        do {
            let out = try AVAudioFile(forWriting: aURL, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let l = UnsafeMutablePointer<Float>.allocate(capacity: blockFrames), r = UnsafeMutablePointer<Float>.allocate(capacity: blockFrames)
            defer { l.deallocate(); r.deallocate() }
            var done = 0
            var sourceEnded = false
            while done < spanFrames {
                let n = min(blockFrames, spanFrames - done)
                var got = 0
                if !sourceEnded {
                    got = src.read(left: l, right: r, frames: n)
                    if got < n { sourceEnded = true }
                }
                if got < n { // 素材が足りない分は無音
                    (l + got).update(repeating: 0, count: n - got)
                    (r + got).update(repeating: 0, count: n - got)
                }
                try write(out, l, r, n)
                done += n
            }
        }

        // 2. 逆順
        var cur = aURL
        if c.effectiveReverse {
            let bURL = dir.appendingPathComponent("\(id)-b.caf")
            let inFile = try AVAudioFile(forReading: cur)
            let out = try AVAudioFile(forWriting: bURL, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let total = Int(inFile.length)
            guard let buf = AVAudioPCMBuffer(pcmFormat: inFile.processingFormat, frameCapacity: AVAudioFrameCount(blockFrames)) else { throw Failure.engine("buffer") }
            var pos = total
            while pos > 0 {
                let n = min(blockFrames, pos)
                pos -= n
                inFile.framePosition = AVAudioFramePosition(pos)
                try inFile.read(into: buf, frameCount: AVAudioFrameCount(n))
                guard let ch = buf.floatChannelData else { throw Failure.engine("channels") }
                let m = Int(buf.frameLength)
                for k in 0..<(m / 2) { for c in 0..<2 { let t = ch[c][k]; ch[c][k] = ch[c][m - 1 - k]; ch[c][m - 1 - k] = t } }
                try out.write(from: buf)
            }
            try? FileManager.default.removeItem(at: cur)
            cur = bURL
        }

        // 3. 速度
        if let ramp = c.rampPoints {
            // 速度ランプ: 出力のコマごとに、積分で決まる素材の位置を直線補間で読む(音程は速度に従って変わる)
            let cURL = dir.appendingPathComponent("\(id)-c.caf")
            try resampleRamp(from: cur, to: cURL, points: ramp, outFrames: outFrames, settings: settings)
            try? FileManager.default.removeItem(at: cur)
            cur = cURL
        } else if abs(speed - 1) > 1e-9 {
            let cURL = dir.appendingPathComponent("\(id)-c.caf")
            try stretch(from: cur, to: cURL, rate: speed, keepPitch: c.keepPitchOrDefault, outFrames: outFrames, settings: settings)
            try? FileManager.default.removeItem(at: cur)
            cur = cURL
        }
        return cur
    }

    /// 速度ランプ: 出力の各コマ(時刻 k/sr)に対応する素材の位置 = 積分 × sr を、直線補間で読んで書く。
    /// 入力は塊ごとに読む(位置は単調増加なので、読む範囲は前へ進むだけ)。速度は 0.25〜4 なので、一塊の入力は高々 4 倍の長さ。
    private static func resampleRamp(from inURL: URL, to outURL: URL, points: [SpeedKey], outFrames: Int, settings: [String: Any]) throws {
        let inFile = try AVAudioFile(forReading: inURL)
        let total = Int(inFile.length)
        let out = try AVAudioFile(forWriting: outURL, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let block = 4096
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFile.processingFormat, frameCapacity: AVAudioFrameCount(block * 4 + 16)),
              let ob = AVAudioPCMBuffer(pcmFormat: out.processingFormat, frameCapacity: AVAudioFrameCount(block)),
              let och = ob.floatChannelData else { throw Failure.engine("buffer") }
        var o = 0
        while o < outFrames {
            let n = min(block, outFrames - o)
            var pos = [Double](repeating: 0, count: n)
            for j in 0..<n { pos[j] = SpeedRamp.integral(points, upTo: Double(o + j) / sampleRate) * sampleRate }
            let kLo = max(0, Int(floor(pos[0])))
            let kHi = min(total - 1, Int(floor(pos[n - 1])) + 1)
            var lOut = [Float](repeating: 0, count: n), rOut = [Float](repeating: 0, count: n)
            if kLo <= kHi {
                let cnt = min(kHi - kLo + 1, Int(inBuf.frameCapacity))
                inFile.framePosition = AVAudioFramePosition(kLo)
                try inFile.read(into: inBuf, frameCount: AVAudioFrameCount(cnt))
                let got = Int(inBuf.frameLength)
                guard let ich = inBuf.floatChannelData else { throw Failure.engine("channels") }
                for j in 0..<n {
                    let p = pos[j], k = Int(floor(p)), f = Float(p - Double(k))
                    for c in 0..<2 {
                        func s(_ idx: Int) -> Float { let q = min(idx, total - 1) - kLo; return (q >= 0 && q < got) ? ich[c][q] : 0 }   // 終わりの先は最後のコマを保つ
                        let v = s(k) * (1 - f) + s(k + 1) * f
                        if c == 0 { lOut[j] = v } else { rOut[j] = v }
                    }
                }
            }
            for j in 0..<n { och[0][j] = lOut[j]; och[1][j] = rOut[j] }
            ob.frameLength = AVAudioFrameCount(n)
            try out.write(from: ob)
            o += n
        }
    }

    private static func write(_ f: AVAudioFile, _ l: UnsafePointer<Float>, _ r: UnsafePointer<Float>, _ n: Int) throws {
        guard let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(n)), let ch = buf.floatChannelData else { throw Failure.engine("buffer") }
        buf.frameLength = AVAudioFrameCount(n)
        ch[0].update(from: l, count: n); ch[1].update(from: r, count: n)
        try f.write(from: buf)
    }

    /// オフラインレンダリングで速度を変える。出力は outFrames フレームちょうど。
    private static func stretch(from inURL: URL, to outURL: URL, rate: Double, keepPitch: Bool, outFrames: Int, settings: [String: Any]) throws {
        let file = try AVAudioFile(forReading: inURL)
        let fmt = file.processingFormat
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let unit: AVAudioUnit
        var latencyFrames = 0
        if keepPitch {
            let u = AVAudioUnitTimePitch()
            u.rate = Float(rate); u.pitch = 0
            unit = u
        } else {
            let u = AVAudioUnitVarispeed()
            u.rate = Float(rate)
            unit = u
        }
        engine.attach(player); engine.attach(unit)
        engine.connect(player, to: unit, format: fmt)
        engine.connect(unit, to: engine.mainMixerNode, format: fmt)
        let maxFrames: AVAudioFrameCount = 4096
        do { try engine.enableManualRenderingMode(.offline, format: fmt, maximumFrameCount: maxFrames) }
        catch { throw Failure.engine("manual rendering: \(error.localizedDescription)") }
        engine.prepare()
        do { try engine.start() } catch { throw Failure.engine("start: \(error.localizedDescription)") }
        defer { player.stop(); engine.stop() }
        if keepPitch { latencyFrames = Int((unit.latency * sampleRate).rounded()) }
        player.scheduleFile(file, at: nil, completionHandler: nil)
        player.play()

        guard let buf = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: maxFrames) else { throw Failure.engine("buffer") }
        let out = try AVAudioFile(forWriting: outURL, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        var skip = latencyFrames          // 先頭の遅れ(TimePitch の処理の遅れ)は捨てる
        var written = 0
        var stalls = 0
        while written < outFrames {
            let want = AVAudioFrameCount(min(Int(maxFrames), outFrames - written + skip))
            let st: AVAudioEngineManualRenderingStatus
            do { st = try engine.renderOffline(want, to: buf) } catch { throw Failure.engine("render: \(error.localizedDescription)") }
            switch st {
            case .success:
                stalls = 0
            case .insufficientDataFromInputNode, .cannotDoInCurrentContext:
                stalls += 1
                if stalls > 200 { throw Failure.engine("render stalled") }
                Thread.sleep(forTimeInterval: 0.001)
                continue
            case .error: throw Failure.engine("render error")
            @unknown default: throw Failure.engine("render status")
            }
            guard let ch = buf.floatChannelData else { throw Failure.engine("channels") }
            var n = Int(buf.frameLength)
            var from = 0
            if skip > 0 { let d = min(skip, n); skip -= d; from = d; n -= d }
            n = min(n, outFrames - written)
            if n > 0 {
                guard let ob = AVAudioPCMBuffer(pcmFormat: out.processingFormat, frameCapacity: AVAudioFrameCount(n)), let och = ob.floatChannelData else { throw Failure.engine("buffer") }
                ob.frameLength = AVAudioFrameCount(n)
                och[0].update(from: ch[0] + from, count: n); och[1].update(from: ch[1] + from, count: n)
                try out.write(from: ob)
                written += n
            }
        }
    }
}

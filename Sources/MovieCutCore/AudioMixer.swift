import Foundation
import AVFoundation
import CoreMedia

// MARK: - エラー

public enum AudioMixerError: LocalizedError {
    case cannotRead(path: String, underlying: Error?)
    case cannotWrite(url: URL, underlying: Error?)

    public var errorDescription: String? {
        switch self {
        case .cannotRead(let path, let e):
            return "音声素材を読み込めませんでした: \(path)" + (e.map { "(\($0.localizedDescription))" } ?? "")
        case .cannotWrite(let url, let e):
            return "音声ミックスを書き出せませんでした: \(url.lastPathComponent)" + (e.map { "(\($0.localizedDescription))" } ?? "")
        }
    }
}

// MARK: - 音声ソース(1クリップぶん、順番に読む)

/// 48 kHz ステレオ Float32(左右別)で、先頭から順番に取り出せる音声。
protocol PCMSource: AnyObject {
    /// 最大 frames フレームを left / right に書く。返り値は書いたフレーム数(終端では frames 未満)。
    func read(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) -> Int
}

private let mixSampleRate = 48000.0

/// AVAudioFile(WAV / MP3 / M4A / CAF など)から読む。サンプルレート違いは AVAudioConverter、チャンネル数はここで揃える(モノ → 左右同じ)。
final class FilePCMSource: PCMSource {
    private static let chunk: AVAudioFrameCount = 16384
    private let file: AVAudioFile
    private var converter: AVAudioConverter?
    private let inBuf: AVAudioPCMBuffer
    private let outBuf: AVAudioPCMBuffer
    private var outCount = 0
    private var outPos = 0
    private var inputEOF = false
    private var finished = false

    init(url: URL, offset: Double) throws {
        file = try AVAudioFile(forReading: url)
        let inFmt = file.processingFormat
        let pos = AVAudioFramePosition(max(0, offset) * inFmt.sampleRate)
        if pos >= file.length { finished = true } else { file.framePosition = pos }
        guard let ib = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: Self.chunk) else {
            throw AudioMixerError.cannotRead(path: url.path, underlying: nil)
        }
        inBuf = ib
        if abs(inFmt.sampleRate - mixSampleRate) > 0.5 {
            guard let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: mixSampleRate, channels: inFmt.channelCount, interleaved: false),
                  let conv = AVAudioConverter(from: inFmt, to: outFmt),
                  let ob = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: Self.chunk) else {
                throw AudioMixerError.cannotRead(path: url.path, underlying: nil)
            }
            converter = conv
            outBuf = ob
        } else {
            outBuf = ib
        }
    }

    /// outBuf を次の塊で満たす。もう無ければ false。
    private func refill() -> Bool {
        if finished { return false }
        outPos = 0; outCount = 0
        guard let conv = converter else {
            do { try file.read(into: inBuf, frameCount: Self.chunk) } catch { finished = true; return false }
            outCount = Int(inBuf.frameLength)
            if outCount == 0 { finished = true; return false }
            return true
        }
        var err: NSError?
        let st = conv.convert(to: outBuf, error: &err) { [self] _, status in
            if inputEOF { status.pointee = .endOfStream; return nil }
            do { try file.read(into: inBuf, frameCount: Self.chunk) } catch { inputEOF = true; status.pointee = .endOfStream; return nil }
            if inBuf.frameLength == 0 { inputEOF = true; status.pointee = .endOfStream; return nil }
            status.pointee = .haveData
            return inBuf
        }
        outCount = Int(outBuf.frameLength)
        if st == .endOfStream || st == .error { finished = true }
        return outCount > 0
    }

    func read(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) -> Int {
        var done = 0
        while done < frames {
            if outPos >= outCount, !refill() { break }
            guard let ch = outBuf.floatChannelData else { break }
            let nch = Int(outBuf.format.channelCount)
            let n = min(frames - done, outCount - outPos)
            let l = ch[0] + outPos, r = nch >= 2 ? ch[1] + outPos : ch[0] + outPos
            (left + done).update(from: l, count: n)
            (right + done).update(from: r, count: n)
            outPos += n; done += n
        }
        return done
    }
}

/// AVAssetReader から読む(動画の音声トラックなど)。出力側で 48 kHz / 2ch の Float32 インターリーブに変換させる。
final class AssetPCMSource: PCMSource {
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private let rangeStart: Double
    private var pending: [Float] = []   // インターリーブ L R L R ...
    private var pendingPos = 0          // フレーム単位
    private var leadFrames = 0          // 最初のバッファまでの無音(フレーム)
    private var started = false
    private var ended = false

    init?(url: URL, offset: Double, duration: Double) {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .audio).first,
              let r = try? AVAssetReader(asset: asset) else { return nil }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: mixSampleRate,
            AVNumberOfChannelsKey: 2,
        ]
        let o = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        guard r.canAdd(o) else { return nil }
        r.add(o)
        rangeStart = max(0, offset)
        r.timeRange = CMTimeRange(start: CMTime(seconds: rangeStart, preferredTimescale: 48000),
                                  duration: CMTime(seconds: max(0.001, duration), preferredTimescale: 48000))
        guard r.startReading() else { return nil }
        reader = r; output = o
    }

    /// 次のサンプルバッファを pending に足す。無ければ false。
    private func fetch() -> Bool {
        guard !ended else { return false }
        guard let sb = output.copyNextSampleBuffer() else { ended = true; return false }
        if !started {
            started = true
            let lead = CMSampleBufferGetPresentationTimeStamp(sb).seconds - rangeStart
            if lead > 1.0 / mixSampleRate { leadFrames = Int((lead * mixSampleRate).rounded()) }
        }
        guard let bb = CMSampleBufferGetDataBuffer(sb) else { return true }
        let bytes = CMBlockBufferGetDataLength(bb)
        let floats = bytes / MemoryLayout<Float>.size
        if floats == 0 { return true }
        // 読み終えた分を捨ててから足す
        if pendingPos > 0 { pending.removeFirst(pendingPos * 2); pendingPos = 0 }
        let old = pending.count
        pending.append(contentsOf: [Float](repeating: 0, count: floats))
        pending.withUnsafeMutableBytes { raw in
            _ = CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: bytes, destination: raw.baseAddress! + old * MemoryLayout<Float>.size)
        }
        return true
    }

    func read(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) -> Int {
        var done = 0
        if !started { _ = fetch() }  // 先頭の無音(leadFrames)を知るため
        while done < frames, leadFrames > 0 {
            left[done] = 0; right[done] = 0; done += 1; leadFrames -= 1
        }
        while done < frames {
            if pendingPos * 2 >= pending.count, !fetch() { break }
            let avail = (pending.count - pendingPos * 2) / 2
            if avail == 0 { continue }
            let n = min(frames - done, avail)
            for k in 0..<n {
                left[done + k] = pending[(pendingPos + k) * 2]
                right[done + k] = pending[(pendingPos + k) * 2 + 1]
            }
            pendingPos += n; done += n
        }
        return done
    }
}

// MARK: - ミックス

public enum AudioMixer {
    public static let sampleRate = mixSampleRate

    struct MixResult {
        var duration: Double
        /// 実際に音を読めたクリップの数(0 なら音声なし)
        var sourceCount: Int
    }

    /// プロジェクト全体の音声を 48 kHz ステレオ Float32 の CAF/WAV(拡張子で決まる)に書き、長さ(秒)を返す。
    /// 対象: audio / voice クリップと、video クリップの音声トラック。消音レイヤーは飛ばす。
    @discardableResult
    public static func mixdown(project: Project, assets: RenderAssets, to url: URL) throws -> Double {
        try mixdownDetailed(project: project, to: url).duration
    }

    private struct Item {
        var clip: Clip
        var startFrame: Int
        var endFrame: Int
        var offset: Double
        /// 速度・逆再生のかかったクリップ(音声を一時ファイルに作ってから読む。`offset` はその一時ファイルの中の位置)
        var remapped = false
        var gain: Float
        /// フェード(クリップ本来の頭からのサンプル数)。`fadeStart` は負の開始を切る前の頭、`length` はクリップ全体の長さ。
        var fadeStart = 0
        var length = 0
        var fadeInFrames = 0
        var fadeOutFrames = 0
        var equalPower = false
        var hasFade: Bool { fadeInFrames > 0 || fadeOutFrames > 0 }
    }

    static func mixdownDetailed(project: Project, to url: URL) throws -> MixResult {
        let sr = mixSampleRate
        let total = Int((project.endTime * sr).rounded())
        // 対象クリップを開始フレーム順に
        var items: [Item] = []
        for tr in project.tracks where !tr.isMuted {
            for c in tr.clips where c.type == .audio || c.type == .voice || c.type == .video {
                guard let s = c.src, !s.isEmpty, c.duration > 0, !c.isFreeze else { continue }   // フリーズフレームは無音
                var sf = Int((c.start * sr).rounded())
                let fullStart = sf, fullLength = Int((c.duration * sr).rounded())
                let ef = min(total, sf + fullLength)
                let remap = c.hasAudioRemap
                // 速度・逆再生は、タイムライン上の長さに直した一時ファイルを読む(その中の位置 = クリップの頭からの秒)
                var off = remap ? 0 : c.offset
                if sf < 0 { off += Double(-sf) / sr; sf = 0 }  // 負の開始は頭を切る
                guard ef > sf else { continue }
                var item = Item(clip: c, startFrame: sf, endFrame: ef, offset: off, remapped: remap, gain: Float(c.volume ?? 1))
                if c.hasAudioFade {
                    item.fadeStart = fullStart; item.length = fullLength
                    item.fadeInFrames = min(fullLength, Int((c.fadeInOrDefault * sr).rounded()))
                    item.fadeOutFrames = min(fullLength, Int((c.fadeOutOrDefault * sr).rounded()))
                    item.equalPower = c.fadeIsEqualPower
                }
                items.append(item)
            }
        }
        items.sort { $0.startFrame < $1.startFrame }

        try? FileManager.default.removeItem(at: url)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sr,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let out: AVAudioFile
        do { out = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false) }
        catch { throw AudioMixerError.cannotWrite(url: url, underlying: error) }

        // 10 秒ずつ処理して、長いプロジェクトでも全部をメモリに置かない
        let chunk = Int(sr) * 10
        let mL = UnsafeMutablePointer<Float>.allocate(capacity: chunk), mR = UnsafeMutablePointer<Float>.allocate(capacity: chunk)
        let tL = UnsafeMutablePointer<Float>.allocate(capacity: chunk), tR = UnsafeMutablePointer<Float>.allocate(capacity: chunk)
        defer { mL.deallocate(); mR.deallocate(); tL.deallocate(); tR.deallocate() }

        var sources: [Int: PCMSource] = [:]
        var failed: Set<Int> = []
        var opened = 0
        // 速度・逆再生用の一時ファイル置き場(ミックスを終えたら消す)
        let remapDir = FileManager.default.temporaryDirectory.appendingPathComponent("moviecut-remap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: remapDir) }
        var cs = 0
        while cs < total {
            let ce = min(total, cs + chunk)
            let n = ce - cs
            mL.update(repeating: 0, count: n); mR.update(repeating: 0, count: n)
            for (idx, it) in items.enumerated() where it.startFrame < ce && it.endFrame > cs && !failed.contains(idx) {
                let src: PCMSource
                if let s = sources[idx] { src = s } else {
                    guard let s = try openItem(it, remapDir: remapDir) else { failed.insert(idx); continue }
                    sources[idx] = s; opened += 1; src = s
                }
                let a = max(cs, it.startFrame), b = min(ce, it.endFrame)
                let got = src.read(left: tL, right: tR, frames: b - a)
                let base = a - cs
                let g = it.gain
                if it.hasFade {
                    // フェード: サンプルごとに倍率をかける(クリップ本来の頭からの位置で決まるので、10 秒の塊の境目でも途切れない)
                    for k in 0..<got {
                        let fg = g * AudioFade.gain(pos: a + k - it.fadeStart, length: it.length, fadeIn: it.fadeInFrames, fadeOut: it.fadeOutFrames, equalPower: it.equalPower)
                        mL[base + k] += tL[k] * fg
                        mR[base + k] += tR[k] * fg
                    }
                } else {
                    for k in 0..<got {
                        mL[base + k] += tL[k] * g
                        mR[base + k] += tR[k] * g
                    }
                }
                if it.endFrame <= ce { sources[idx] = nil }
            }
            guard let buf = AVAudioPCMBuffer(pcmFormat: out.processingFormat, frameCapacity: AVAudioFrameCount(n)),
                  let ch = buf.floatChannelData else { throw AudioMixerError.cannotWrite(url: url, underlying: nil) }
            buf.frameLength = AVAudioFrameCount(n)
            for k in 0..<n {
                ch[0][k] = min(1, max(-1, mL[k]))
                ch[1][k] = min(1, max(-1, mR[k]))
            }
            do { try out.write(from: buf) } catch { throw AudioMixerError.cannotWrite(url: url, underlying: error) }
            cs = ce
        }
        return MixResult(duration: Double(total) / sr, sourceCount: opened)
    }

    /// ミキサーが読むソースを開く。速度・逆再生のクリップは、音声を作り直した一時ファイルから。作り直せないときは警告を出して無音にする。
    private static func openItem(_ it: Item, remapDir: URL) throws -> PCMSource? {
        guard it.remapped else { return try openSource(it.clip, offset: it.offset, span: it.clip.duration) }
        let c = it.clip
        let url: URL
        do {
            url = try AudioRemap.render(clip: c, open: { clip, off, span in try openSource(clip, offset: off, span: span) }, in: remapDir)
        } catch {
            if case AudioMixerError.cannotRead = error { throw error }
            if case AudioRemap.Failure.noSource = error { return nil }   // 音声トラックが無い動画: 無音でよい(警告は要らない)
            FileHandle.standardError.write(Data("警告: 速度・逆再生の音声を作れなかったので無音にします(\((c.src as NSString?)?.lastPathComponent ?? "?"): \(error))\n".utf8))
            return nil
        }
        do { return try FilePCMSource(url: url, offset: it.offset) }
        catch {
            FileHandle.standardError.write(Data("警告: 速度・逆再生の音声を読めなかったので無音にします(\(error))\n".utf8))
            return nil
        }
    }

    /// クリップの音声を開く。video に音声が無い・読めないときは nil(無音扱い)、audio / voice が読めないときは例外。
    /// `span` は読む長さ(秒。動画の音声トラックを範囲で読むのに使う)。
    private static func openSource(_ c: Clip, offset: Double, span: Double) throws -> PCMSource? {
        let url = URL(fileURLWithPath: c.src ?? "")
        if c.type == .video {
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return AssetPCMSource(url: url, offset: offset, duration: span)
        }
        do {
            return try FilePCMSource(url: url, offset: offset)
        } catch {
            // mp4 の音声など AVAudioFile で開けないものは AVAssetReader で
            if FileManager.default.fileExists(atPath: url.path),
               let s = AssetPCMSource(url: url, offset: offset, duration: span) { return s }
            throw AudioMixerError.cannotRead(path: url.path, underlying: error)
        }
    }
}

public extension Project {
    /// プロジェクトの終わり(全クリップの start+duration の最大、秒)。
    var endTime: Double {
        allClips.map { $0.start + $0.duration }.max().map { max(0, $0) } ?? 0
    }
}

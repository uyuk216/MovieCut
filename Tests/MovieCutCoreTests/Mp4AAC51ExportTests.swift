import XCTest
import AVFoundation
import CoreMedia
import CoreAudio
@testable import MovieCutCore

/// W5-3 未確認点の決着(mp4/AAC 経路): 5.1ch 素材を mp4 に書き出したとき、
/// センター/サラウンド等の各チャンネルの成分が AAC 側に正しく含まれているかの実測・回帰テスト。
///
/// 前提(設計): このアプリのミックス・書き出しは 48kHz ステレオ前提で、5.1 書き出しはしない
/// (docs/マルチチャンネル音声.md「見送った範囲」)。5.1 素材は読み込み段で BS.775 Lo/Ro
/// ダウンミックスされ、AAC はステレオ 2ch で書かれる。したがってここで確かめるのは
/// 「各チャンネルの信号が、ダウンミックス先の左右に正しい係数で含まれているか」であって、
/// 出力ストリームが 5.1 になることではない(ストリームがステレオであることは仕様として固定する)。
///
/// 合成信号: チャンネルごとに異なる周波数のトーン(振幅 0.3、48kHz、1.2 秒)。
/// WAV 順 5.1: L=440, R=660, C=880, LFE=110, Ls=1320, Rs=1760 Hz。
/// ダウンミックス後の期待値(BS.775、LFE は含めない):
///   左 = 440(×1) + 880(×0.7071) + 1320(×0.7071)、110 は無し
///   右 = 660(×1) + 880(×0.7071) + 1760(×0.7071)、110 は無し
/// 照合は Goertzel 法で周波数ごとの振幅を測る(AAC は非可逆だが 256kbps の単一トーンなら誤差は小さい)。
final class Mp4AAC51ExportTests: XCTestCase {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mp451-tests-\(UUID().uuidString)")
    override func setUpWithError() throws { try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    static let freqs: [Double] = [440, 660, 880, 110, 1320, 1760]   // L, R, C, LFE, Ls, Rs
    static let names = ["L(440)", "R(660)", "C(880)", "LFE(110)", "Ls(1320)", "Rs(1760)"]
    static let amp: Float = 0.3
    static let duration = 1.2
    static let sampleRate = 48000.0
    let g = 0.70710677   // BS.775 係数

    // MARK: 素材生成

    /// チャンネルごとに異なる周波数のトーンを持つ n チャンネル WAV を書く。
    private func writeToneWAV(_ name: String, channels: Int = 6) throws -> URL {
        let url = tmp.appendingPathComponent(name)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: Self.sampleRate, AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let total = Int(Self.duration * Self.sampleRate)
        let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(total))!
        buf.frameLength = AVAudioFrameCount(total)
        for c in 0..<channels {
            let f = Self.freqs[c]
            for i in 0..<total {
                buf.floatChannelData![c][i] = Self.amp * Float(sin(2 * Double.pi * f * Double(i) / Self.sampleRate))
            }
        }
        try file.write(from: buf)
        return url
    }

    // MARK: 解析(Goertzel)

    /// 1 チャンネル分のサンプル列について、指定周波数の正弦波振幅を返す(Goertzel)。
    static func toneAmplitude(_ samples: [Float], sampleRate: Double, freq: Double, from: Int, count: Int) -> Double {
        let n = min(count, samples.count - from)
        guard n > 0, from >= 0 else { return 0 }
        let w = 2 * Double.pi * freq / sampleRate
        let coeff = 2 * cos(w)
        var s0 = 0.0, s1 = 0.0, s2 = 0.0
        for i in 0..<n {
            s0 = Double(samples[from + i]) + coeff * s1 - s2
            s2 = s1; s1 = s0
        }
        let power = s1 * s1 + s2 * s2 - coeff * s1 * s2
        return 2 * sqrt(max(0, power)) / Double(n)
    }

    /// 解析区間(AAC のエンコーダ遅延・端の影響を避けて中央を使う)。
    private func toneAmplitudes(_ samples: [Float]) -> [Double] {
        let from = Int(0.25 * Self.sampleRate), count = Int(0.7 * Self.sampleRate)
        return Self.freqs.map { Self.toneAmplitude(samples, sampleRate: Self.sampleRate, freq: $0, from: from, count: count) }
    }

    private func describe(_ label: String, _ amps: [Double]) -> String {
        zip(Self.names, amps).map { "\(label) \($0): \(String(format: "%.4f", $1))" }.joined(separator: "  ")
    }

    /// AVAssetReader で音声を読み、チャンネル別のサンプル列を返す(チャンネル数は素材のまま)。
    private func decodeChannels(_ url: URL, channels: Int?) throws -> [[Float]] {
        let asset = AVURLAsset(url: url)
        let track = try XCTUnwrap(asset.tracks(withMediaType: .audio).first, "音声トラックがない: \(url.lastPathComponent)")
        let reader = try AVAssetReader(asset: asset)
        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false, AVSampleRateKey: Self.sampleRate,
        ]
        if let channels { settings[AVNumberOfChannelsKey] = channels }
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        guard reader.canAdd(out) else { throw ExportError.audioReadFailed(nil) }
        reader.add(out)
        guard reader.startReading() else { throw reader.error ?? ExportError.audioReadFailed(nil) }
        var channelsOut: [[Float]] = []
        while let sb = out.copyNextSampleBuffer() {
            guard let bb = CMSampleBufferGetDataBuffer(sb) else { continue }
            let bytes = CMBlockBufferGetDataLength(bb)
            let floats = bytes / MemoryLayout<Float>.size
            if floats == 0 { continue }
            var raw = [Float](repeating: 0, count: floats)
            raw.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: bytes, destination: $0.baseAddress!) }
            let nch = channelsOut.isEmpty ? max(1, floats / max(1, CMSampleBufferGetNumSamples(sb))) : channelsOut.count
            if channelsOut.isEmpty { channelsOut = [[Float]](repeating: [], count: nch) }
            let frames = floats / nch
            for i in 0..<frames { for c in 0..<nch { channelsOut[c].append(raw[i * nch + c]) } }
        }
        return channelsOut
    }

    /// 音声トラックの形式(コーデック・チャンネル数・サンプルレート・レイアウトタグ)。
    private func audioFormat(of url: URL) throws -> (codec: FourCharCode, channels: Int, sampleRate: Double, layoutTag: AudioChannelLayoutTag?) {
        let asset = AVURLAsset(url: url)
        let track = try XCTUnwrap(asset.tracks(withMediaType: .audio).first, "音声トラックがない")
        let fd = try XCTUnwrap(track.formatDescriptions.first as! CMFormatDescription?)
        let codec = CMFormatDescriptionGetMediaSubType(fd)
        guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd) else { throw ExportError.audioReadFailed(nil) }
        var tag: AudioChannelLayoutTag? = nil
        if let layout = CMAudioFormatDescriptionGetChannelLayout(fd, sizeOut: nil) { tag = layout.pointee.mChannelLayoutTag }
        return (codec, Int(asbd.pointee.mChannelsPerFrame), asbd.pointee.mSampleRate, tag)
    }

    // MARK: File 経路(WAV 5.1 → Exporter → mp4/AAC)

    func testExport51WavToMp4AACContainsAllChannelsDownmixed() async throws {
        let wav = try writeToneWAV("tones51.wav")
        var p = Project.new(); p.width = 320; p.height = 180; p.fps = 30
        var c = Clip(); c.type = .audio; c.src = wav.path; c.start = 0; c.duration = Self.duration
        p.tracks[0].clips = [c]
        let out = tmp.appendingPathComponent("out51.mp4")
        try await Exporter(project: p, assets: RenderAssets()).export(to: out, progress: nil)

        let fmt = try audioFormat(of: out)
        print("[mp451] output format codec=\(fmt.codec) channels=\(fmt.channels) sr=\(fmt.sampleRate) layout=\(String(describing: fmt.layoutTag))")
        XCTAssertEqual(fmt.codec, kAudioFormatMPEG4AAC, "音声は AAC で書かれる")
        XCTAssertEqual(fmt.channels, 2, "出力は仕様どおりステレオ(5.1 書き出しは設計上しない)")
        XCTAssertEqual(fmt.sampleRate, 48000, accuracy: 1)

        let ch = try decodeChannels(out, channels: 2)
        XCTAssertEqual(ch.count, 2)
        let la = toneAmplitudes(ch[0]), ra = toneAmplitudes(ch[1])
        print("[mp451] " + describe("Lch", la))
        print("[mp451] " + describe("Rch", ra))
        // 左: L がそのまま、C と Ls が 0.7071 倍で入る。R / Rs / LFE は入らない。
        XCTAssertEqual(la[0], Double(Self.amp), accuracy: 0.06, "左に L(440) が入っている")
        XCTAssertEqual(la[2], Double(Self.amp) * g, accuracy: 0.06, "左にセンター(880) が BS.775 係数で入っている(無音化していない)")
        XCTAssertEqual(la[4], Double(Self.amp) * g, accuracy: 0.06, "左に左サラウンド(1320) が入っている")
        XCTAssertLessThan(la[1], 0.03, "左に R(660) は混ざらない")
        XCTAssertLessThan(la[5], 0.03, "左に Rs(1760) は混ざらない")
        XCTAssertLessThan(la[3], 0.03, "LFE(110) は BS.775 Lo/Ro の定義どおり含めない")
        // 右: R がそのまま、C と Rs が 0.7071 倍。
        XCTAssertEqual(ra[1], Double(Self.amp), accuracy: 0.06, "右に R(660) が入っている")
        XCTAssertEqual(ra[2], Double(Self.amp) * g, accuracy: 0.06, "右にセンター(880) が入っている")
        XCTAssertEqual(ra[5], Double(Self.amp) * g, accuracy: 0.06, "右に右サラウンド(1760) が入っている")
        XCTAssertLessThan(ra[0], 0.03, "右に L(440) は混ざらない")
        XCTAssertLessThan(ra[4], 0.03, "右に Ls(1320) は混ざらない")
        XCTAssertLessThan(ra[3], 0.03, "右に LFE(110) は含めない")
    }

    // MARK: Asset 経路用素材(5.1ch AAC 入り mp4 を AVAssetWriter で作る)

    /// MPEG 5.1 A レイアウト(L R C LFE Ls Rs = WAV 順)で 6ch AAC + 映像入りの mp4 を作る。
    private func writeTone51MP4(_ name: String) async throws -> URL {
        let url = tmp.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_MPEG_5_1_A
        layout.mNumberChannelDescriptions = 0
        let layoutData = withUnsafeBytes(of: &layout) { Data($0) }

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 160, AVVideoHeightKey: 90,
        ])
        vInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 160, kCVPixelBufferHeightKey as String: 90,
        ])
        guard writer.canAdd(vInput) else { throw ExportError.cannotAddInput("映像") }
        writer.add(vInput)
        let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 6, AVEncoderBitRateKey: 256_000, AVChannelLayoutKey: layoutData,
        ])
        aInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(aInput) else { throw ExportError.cannotAddInput("音声") }
        writer.add(aInput)

        // 音声フォーマット記述(6ch Float32 インターリーブ、MPEG 5.1 A レイアウト)
        var asbd = AudioStreamBasicDescription(mSampleRate: Self.sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 24, mFramesPerPacket: 1,
            mBytesPerFrame: 24, mChannelsPerFrame: 6, mBitsPerChannel: 32, mReserved: 0)
        var fmtOut: CMAudioFormatDescription?
        let lsize = MemoryLayout<AudioChannelLayout>.size
        let st = withUnsafePointer(to: &layout) { lp in
            CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: lsize, layout: lp,
                                           magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &fmtOut)
        }
        guard st == noErr, let audioFmt = fmtOut else { throw ExportError.audioReadFailed(nil) }

        guard writer.startWriting() else { throw writer.error ?? ExportError.cannotStartWriting(nil) }
        writer.startSession(atSourceTime: .zero)
        func waitReady(_ input: AVAssetWriterInput) async {
            while !input.isReadyForMoreMediaData { try? await Task.sleep(nanoseconds: 2_000_000) }
        }
        // 映像: 36 コマ(1.2 秒 @30fps)の単色
        let pool = adaptor.pixelBufferPool!
        for i in 0..<36 {
            await waitReady(vInput)
            var pbOut: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbOut)
            let pb = pbOut!
            CVPixelBufferLockBaseAddress(pb, [])
            if let base = CVPixelBufferGetBaseAddress(pb) {
                memset(base, 0x40, CVPixelBufferGetDataSize(pb))
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30))
        }
        vInput.markAsFinished()
        // 音声: 4096 フレームずつ
        let total = Int(Self.duration * Self.sampleRate)
        var frame = 0
        while frame < total {
            await waitReady(aInput)
            let n = min(4096, total - frame)
            var samples = [Float](repeating: 0, count: n * 6)
            for c in 0..<6 {
                let f = Self.freqs[c]
                for i in 0..<n {
                    samples[i * 6 + c] = Self.amp * Float(sin(2 * Double.pi * f * Double(frame + i) / Self.sampleRate))
                }
            }
            var block: CMBlockBuffer?
            let bytes = samples.count * MemoryLayout<Float>.size
            CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes,
                                               blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                               dataLength: bytes, flags: 0, blockBufferOut: &block)
            samples.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: bytes) }
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48000),
                                            presentationTimeStamp: CMTime(value: CMTimeValue(frame), timescale: 48000),
                                            decodeTimeStamp: .invalid)
            var sbOut: CMSampleBuffer?
            CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block!, formatDescription: audioFmt,
                                      sampleCount: n, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                      sampleSizeEntryCount: 1, sampleSizeArray: [24], sampleBufferOut: &sbOut)
            guard let sb = sbOut, aInput.append(sb) else { throw writer.error ?? ExportError.appendFailed(frame: -1, underlying: nil) }
            frame += n
        }
        aInput.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? ExportError.writerFailed(nil) }
        return url
    }

    /// Asset 経路の実測: 5.1 AAC 素材(mp4)を動画クリップとして書き出し、AAC の中身を照合する。
    func testExport51AACSourceViaAssetPath() async throws {
        let src = try await writeTone51MP4("src51.mp4")
        let sfmt = try audioFormat(of: src)
        print("[mp451] source format codec=\(sfmt.codec) channels=\(sfmt.channels) sr=\(sfmt.sampleRate) layout=\(String(describing: sfmt.layoutTag))")
        XCTAssertEqual(sfmt.channels, 6, "素材は 5.1(6ch)で作れている")

        // 素材を素材チャンネル数のまま読んだときの並び(自前ダウンミックスへ切り替える場合の前提確認)
        let native = try decodeChannels(src, channels: 6)
        XCTAssertEqual(native.count, 6)
        for c in 0..<6 { print("[mp451] native ch\(c) " + describe("", toneAmplitudes(native[c]))) }

        // AVFoundation に 2ch 変換させた素の結果(AssetPCMSource 既定経路の実体)
        let av2 = try decodeChannels(src, channels: 2)
        print("[mp451] " + describe("AV2ch L", toneAmplitudes(av2[0])))
        print("[mp451] " + describe("AV2ch R", toneAmplitudes(av2[1])))

        // MovieCut の書き出し(動画クリップ = Asset 経路でミックス → AAC)
        var p = Project.new(); p.width = 320; p.height = 180; p.fps = 30
        var c = Clip(); c.type = .video; c.src = src.path; c.start = 0; c.duration = Self.duration; c.srcDuration = Self.duration
        p.tracks[0].clips = [c]
        let out = tmp.appendingPathComponent("out51-from-aac.mp4")
        try await Exporter(project: p, assets: RenderAssets()).export(to: out, progress: nil)
        let fmt = try audioFormat(of: out)
        print("[mp451] asset-out format codec=\(fmt.codec) channels=\(fmt.channels) sr=\(fmt.sampleRate) layout=\(String(describing: fmt.layoutTag))")
        XCTAssertEqual(fmt.codec, kAudioFormatMPEG4AAC)
        XCTAssertEqual(fmt.channels, 2)
        let ch = try decodeChannels(out, channels: 2)
        let la = toneAmplitudes(ch[0]), ra = toneAmplitudes(ch[1])
        print("[mp451] " + describe("asset-out Lch", la))
        print("[mp451] " + describe("asset-out Rch", ra))
        // センター・サラウンドが黙って落ちていないこと(係数の厳密値は AVFoundation 依存なので存在を固定する)
        XCTAssertGreaterThan(la[2], 0.08, "センター(880) が左に含まれている")
        XCTAssertGreaterThan(ra[2], 0.08, "センター(880) が右に含まれている")
        XCTAssertGreaterThan(la[4], 0.08, "左サラウンド(1320) が左に含まれている")
        XCTAssertGreaterThan(ra[5], 0.08, "右サラウンド(1760) が右に含まれている")
        XCTAssertGreaterThan(la[0], 0.15, "L(440) が左に含まれている")
        XCTAssertGreaterThan(ra[1], 0.15, "R(660) が右に含まれている")
    }

    /// ステレオ素材の mp4 書き出しが従来どおり壊れていないこと(回帰)。
    func testExportStereoWavToMp4AACUnchanged() async throws {
        let wav = try writeToneWAV("tones2.wav", channels: 2)
        var p = Project.new(); p.width = 320; p.height = 180; p.fps = 30
        var c = Clip(); c.type = .audio; c.src = wav.path; c.start = 0; c.duration = Self.duration
        p.tracks[0].clips = [c]
        let out = tmp.appendingPathComponent("out2.mp4")
        try await Exporter(project: p, assets: RenderAssets()).export(to: out, progress: nil)
        let fmt = try audioFormat(of: out)
        XCTAssertEqual(fmt.channels, 2)
        let ch = try decodeChannels(out, channels: 2)
        let la = toneAmplitudes(ch[0]), ra = toneAmplitudes(ch[1])
        print("[mp451] " + describe("stereo Lch", la))
        print("[mp451] " + describe("stereo Rch", ra))
        XCTAssertEqual(la[0], Double(Self.amp), accuracy: 0.06)
        XCTAssertEqual(ra[1], Double(Self.amp), accuracy: 0.06)
        XCTAssertLessThan(la[1], 0.03); XCTAssertLessThan(ra[0], 0.03)
    }
}

import XCTest
import AVFoundation
import CoreMedia
import CoreAudio
@testable import MovieCutCore

/// 改善ラウンド5 キュー2 Phase B: 5.1 書き出し(`AudioMixer.mixdownSurround51` / `Exporter(audioChannels: .surround51)`)。
///
/// 素材はテスト内で生成し、Goertzel 法でチャンネルごとの周波数成分を数値照合する(Mp4AAC51ExportTests と同じ作法)。
/// 5.1 WAV 素材(WAV 順)の周波数: L=440, R=660, C=880, LFE=110, Ls=1320, Rs=1760 Hz、振幅 0.3、48 kHz、1.2 秒。
/// 出力(canonical 順 L R C LFE Ls Rs)では、チャンネル i に自分の周波数 `freqs[i]` だけが出る。
final class Export51Tests: XCTestCase {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("export51-tests-\(UUID().uuidString)")
    override func setUpWithError() throws { try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    /// canonical 順(= 5.1 WAV 順)の周波数と名前。
    static let freqs: [Double] = [440, 660, 880, 110, 1320, 1760]
    static let names = ["L(440)", "R(660)", "C(880)", "LFE(110)", "Ls(1320)", "Rs(1760)"]
    static let amp: Float = 0.3
    static let duration = 1.2
    static let sampleRate = 48000.0
    let g = Double(MultichannelDownmix.surroundGain)

    // MARK: 素材生成・解析

    /// チャンネルごとに指定の周波数のトーンを持つ WAV(Float32)を書く。
    private func writeToneWAV(_ name: String, freqs: [Double], amp: Float = Export51Tests.amp) throws -> URL {
        let url = tmp.appendingPathComponent(name)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: Self.sampleRate, AVNumberOfChannelsKey: freqs.count,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let total = Int(Self.duration * Self.sampleRate)
        let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(total))!
        buf.frameLength = AVAudioFrameCount(total)
        for (c, f) in freqs.enumerated() {
            for i in 0..<total { buf.floatChannelData![c][i] = amp * Float(sin(2 * Double.pi * f * Double(i) / Self.sampleRate)) }
        }
        try file.write(from: buf)
        return url
    }

    private func audioProject(_ src: URL, type: ClipType = .audio) -> (Project, Clip) {
        var p = Project.new(); p.width = 320; p.height = 180; p.fps = 30
        var c = Clip(); c.type = type; c.src = src.path; c.start = 0; c.duration = Self.duration
        if type == .video { c.srcDuration = Self.duration }
        p.tracks[0].clips = [c]
        return (p, c)
    }

    /// AVAudioFile でチャンネル別に読む(WAV / CAF の中間ファイル用)。
    private func readChannels(_ url: URL) throws -> [[Float]] {
        let f = try AVAudioFile(forReading: url)
        let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
        try f.read(into: buf)
        let n = Int(buf.frameLength)
        return (0..<Int(f.processingFormat.channelCount)).map { Array(UnsafeBufferPointer(start: buf.floatChannelData![$0], count: n)) }
    }

    /// AVAssetReader で素材のチャンネル数のまま読む(mp4 の AAC 用。並びは出力ファイルのレイアウト順)。
    private func decodeChannels(_ url: URL, channels: Int) throws -> [[Float]] {
        let asset = AVURLAsset(url: url)
        let track = try XCTUnwrap(asset.tracks(withMediaType: .audio).first, "音声トラックがない")
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false, AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: channels,
        ])
        guard reader.canAdd(out) else { throw ExportError.audioReadFailed(nil) }
        reader.add(out)
        guard reader.startReading() else { throw reader.error ?? ExportError.audioReadFailed(nil) }
        var chs = [[Float]](repeating: [], count: channels)
        while let sb = out.copyNextSampleBuffer() {
            guard let bb = CMSampleBufferGetDataBuffer(sb) else { continue }
            let bytes = CMBlockBufferGetDataLength(bb)
            let floats = bytes / MemoryLayout<Float>.size
            if floats == 0 { continue }
            var raw = [Float](repeating: 0, count: floats)
            raw.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: bytes, destination: $0.baseAddress!) }
            for i in 0..<(floats / channels) { for c in 0..<channels { chs[c].append(raw[i * channels + c]) } }
        }
        return chs
    }

    private func audioFormat(of url: URL) throws -> (codec: FourCharCode, channels: Int, layoutTag: AudioChannelLayoutTag?) {
        let asset = AVURLAsset(url: url)
        let track = try XCTUnwrap(asset.tracks(withMediaType: .audio).first, "音声トラックがない")
        let fd = try XCTUnwrap(track.formatDescriptions.first as! CMFormatDescription?)
        guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd) else { throw ExportError.audioReadFailed(nil) }
        var tag: AudioChannelLayoutTag? = nil
        if let layout = CMAudioFormatDescriptionGetChannelLayout(fd, sizeOut: nil) { tag = layout.pointee.mChannelLayoutTag }
        return (CMFormatDescriptionGetMediaSubType(fd), Int(asbd.pointee.mChannelsPerFrame), tag)
    }

    /// 解析区間(AAC の遅延・端の影響を避けて中央を使う)。指定の周波数ごとの振幅。
    private func amps(_ s: [Float], _ freqs: [Double] = Export51Tests.freqs) -> [Double] {
        let from = Int(0.25 * Self.sampleRate), count = Int(0.7 * Self.sampleRate)
        return freqs.map { Mp4AAC51ExportTests.toneAmplitude(s, sampleRate: Self.sampleRate, freq: $0, from: from, count: count) }
    }

    /// 出力チャンネル `c` に、周波数 `expected`(添字)だけが指定の振幅で出て、他は小さいこと。
    private func assertOnly(_ ch: [Float], tones: [Int: Double], accuracy: Double, other: Double = 0.03, _ label: String,
                            file: StaticString = #filePath, line: UInt = #line) {
        let a = amps(ch)
        for (i, v) in a.enumerated() {
            if let want = tones[i] { XCTAssertEqual(v, want, accuracy: accuracy, "\(label): \(Self.names[i]) が \(want) で出る", file: file, line: line) }
            else { XCTAssertLessThan(v, other, "\(label): \(Self.names[i]) は出ない(実測 \(v))", file: file, line: line) }
        }
    }

    /// 出力 mp4 の 6ch AAC をレイアウトタグに従って読み、役割ごとに「そのチャンネルの周波数だけ」が出ることを確かめる。
    private func assertSurroundMp4(_ url: URL, expected: [AudioChannelRole: Int], accuracy: Double = 0.06, _ label: String,
                                   file: StaticString = #filePath, line: UInt = #line) throws {
        let fmt = try audioFormat(of: url)
        XCTAssertEqual(fmt.codec, kAudioFormatMPEG4AAC, "\(label): AAC", file: file, line: line)
        XCTAssertEqual(fmt.channels, 6, "\(label): 6ch", file: file, line: line)
        let tag = try XCTUnwrap(fmt.layoutTag, "\(label): レイアウトタグが取れる", file: file, line: line)
        let roles = MultichannelDownmix.roles(forLayoutTag: UInt32(tag)) ?? MultichannelDownmix.roles(channelCount: 6)
        print("[export51] \(label) layoutTag=\(tag) roles=\(roles)")
        let ch = try decodeChannels(url, channels: 6)
        XCTAssertEqual(ch.count, 6, file: file, line: line)
        // 役割 → 周波数の添字(canonical 順)
        let freqIndex: [AudioChannelRole: Int] = [.left: 0, .right: 1, .center: 2, .lfe: 3, .leftSurround: 4, .rightSurround: 5]
        for (pos, role) in roles.enumerated() {
            guard let fi = freqIndex[role] else { continue }
            if let want = expected[role] {
                assertOnly(ch[pos], tones: [fi: Double(Self.amp)], accuracy: accuracy, "\(label) 位置\(pos)=\(role.label)(want \(want))", file: file, line: line)
            } else {
                assertOnly(ch[pos], tones: [:], accuracy: accuracy, "\(label) 位置\(pos)=\(role.label)", file: file, line: line)
            }
        }
    }

    // MARK: 1. 純粋ロジック

    func testSurround51PlacementRules() {
        let g = MultichannelDownmix.surroundGain
        func p(_ r: AudioChannelRole, _ i: Int? = nil) -> [(Int, Float)] { MultichannelDownmix.surround51Placement(for: r, extraIndex: i).map { ($0.channel, $0.gain) } }
        XCTAssertEqual(p(.left).map(\.0), [0]); XCTAssertEqual(p(.left).map(\.1), [1])
        XCTAssertEqual(p(.right).map(\.0), [1])
        XCTAssertEqual(p(.center).map(\.0), [2]); XCTAssertEqual(p(.center).map(\.1), [1])
        XCTAssertEqual(p(.lfe).map(\.0), [3])
        XCTAssertEqual(p(.leftSurround).map(\.0), [4]); XCTAssertEqual(p(.leftSurround).map(\.1), [1])
        XCTAssertEqual(p(.rightSurround).map(\.0), [5])
        XCTAssertEqual(p(.leftBack).map(\.0), [4]); XCTAssertEqual(p(.leftBack).map(\.1), [g], "Lb → Ls へ 0.7071")
        XCTAssertEqual(p(.rightBack).map(\.0), [5]); XCTAssertEqual(p(.rightBack).map(\.1), [g], "Rb → Rs へ 0.7071")
        XCTAssertEqual(p(.centerSurround).map(\.0), [4, 5]); XCTAssertEqual(p(.centerSurround).map(\.1), [g, g], "Cs → 両サラウンドへ各 0.7071")
        XCTAssertEqual(p(.leftCenter).map(\.0), [0]); XCTAssertEqual(p(.rightCenter).map(\.0), [1])
        XCTAssertEqual(p(.unknown, 0).map(\.0), [4]); XCTAssertEqual(p(.unknown, 1).map(\.0), [5], "8ch 超の余りは左右交互")
        XCTAssertEqual(p(.unknown, 2).map(\.1), [g])
        XCTAssertEqual(p(.unknown).map(\.0), [4, 5])
    }

    func testSurround51PlacementsByMode() {
        // 5.1(AAC 順)の downmix: 役割どおり
        let aac: [AudioChannelRole] = [.center, .left, .right, .leftSurround, .rightSurround, .lfe]
        let d = MultichannelDownmix.surround51Placements(roles: aac, mode: .downmix)
        XCTAssertEqual(d.map { $0.map(\.channel) }, [[2], [0], [1], [4], [5], [3]], "AAC 順の素材でも役割どおりの出力チャンネルへ")
        // center: C だけ
        let c = MultichannelDownmix.surround51Placements(roles: aac, mode: .center)
        XCTAssertEqual(c.map { $0.map(\.channel) }, [[2], [], [], [], [], []])
        // firstPair: L/R の役割だけ
        let f = MultichannelDownmix.surround51Placements(roles: aac, mode: .firstPair)
        XCTAssertEqual(f.map { $0.map(\.channel) }, [[], [0], [1], [], [], []])
        // center でセンターが無い素材は、ステレオ係数(ダウンミックス)で L/R へ
        let quad: [AudioChannelRole] = [.left, .right, .leftSurround, .rightSurround]
        let q = MultichannelDownmix.surround51Placements(roles: quad, mode: .center)
        XCTAssertEqual(q.map { $0.map(\.channel) }, [[0], [1], [0], [1]])
        // モノラル: 既定は C、firstPair は左右
        XCTAssertEqual(MultichannelDownmix.surround51Placements(roles: [.center], mode: .downmix).map { $0.map(\.channel) }, [[2]])
        XCTAssertEqual(MultichannelDownmix.surround51Placements(roles: [.center], mode: .firstPair).map { $0.map(\.channel) }, [[0, 1]])
        // ステレオ: そのまま L/R
        XCTAssertEqual(MultichannelDownmix.surround51Placements(roles: [.left, .right], mode: .downmix).map { $0.map(\.channel) }, [[0], [1]])
    }

    // MARK: 2. WAV(mixdownSurround51 → 6ch WAV)

    func testMixdownSurround51WritesSixChannelWav() throws {
        let src = try writeToneWAV("tones51.wav", freqs: Self.freqs)
        let (p, _) = audioProject(src)
        let out = tmp.appendingPathComponent("mix51.wav")
        let r = try AudioMixer.mixdownSurround51(project: p, to: out)
        XCTAssertEqual(r.sourceCount, 1)
        let ch = try readChannels(out)
        XCTAssertEqual(ch.count, 6, "6ch WAV")
        for c in 0..<6 { assertOnly(ch[c], tones: [c: Double(Self.amp)], accuracy: 0.02, "WAV ch\(c)=\(Self.names[c])") }
    }

    func testMixdownSurround51Folds71BackChannelsIntoSurrounds() throws {
        // WAV 順 7.1: L R C LFE Lb Rb Ls Rs
        let f8: [Double] = [440, 660, 880, 110, 2000, 2500, 1320, 1760]
        let src = try writeToneWAV("tones71.wav", freqs: f8)
        let (p, _) = audioProject(src)
        let out = tmp.appendingPathComponent("mix71.wav")
        _ = try AudioMixer.mixdownSurround51(project: p, to: out)
        let ch = try readChannels(out)
        XCTAssertEqual(ch.count, 6)
        let ls = amps(ch[4], f8), rs = amps(ch[5], f8)
        XCTAssertEqual(ls[6], Double(Self.amp), accuracy: 0.02, "Ls に Ls トーン 0.3")
        XCTAssertEqual(ls[4], Double(Self.amp) * g, accuracy: 0.02, "Ls に Lb トーンが 0.7071 で折り畳まれる(0.212)")
        XCTAssertEqual(rs[7], Double(Self.amp), accuracy: 0.02, "Rs に Rs トーン 0.3")
        XCTAssertEqual(rs[5], Double(Self.amp) * g, accuracy: 0.02, "Rs に Rb トーンが 0.7071 で折り畳まれる")
        XCTAssertLessThan(ls[5], 0.03); XCTAssertLessThan(rs[4], 0.03)
        // L/R/C/LFE はそのまま
        XCTAssertEqual(amps(ch[0], f8)[0], Double(Self.amp), accuracy: 0.02)
        XCTAssertEqual(amps(ch[2], f8)[2], Double(Self.amp), accuracy: 0.02)
        XCTAssertEqual(amps(ch[3], f8)[3], Double(Self.amp), accuracy: 0.02)
    }

    // MARK: 6. ステレオ / モノラル素材

    func testStereoSourceGoesToLeftRightOnlyAndMonoToCenterOnly() throws {
        let st = try writeToneWAV("st.wav", freqs: [440, 660])
        let (p, _) = audioProject(st)
        let out = tmp.appendingPathComponent("st51.wav")
        _ = try AudioMixer.mixdownSurround51(project: p, to: out)
        let ch = try readChannels(out)
        XCTAssertEqual(ch.count, 6)
        assertOnly(ch[0], tones: [0: Double(Self.amp)], accuracy: 0.02, "ステレオ L")
        assertOnly(ch[1], tones: [1: Double(Self.amp)], accuracy: 0.02, "ステレオ R")
        for c in 2..<6 { assertOnly(ch[c], tones: [:], accuracy: 0.02, "ステレオ素材は ch\(c) に出ない") }

        let mono = try writeToneWAV("mono.wav", freqs: [880])
        let (pm, _) = audioProject(mono)
        let outM = tmp.appendingPathComponent("mono51.wav")
        _ = try AudioMixer.mixdownSurround51(project: pm, to: outM)
        let cm = try readChannels(outM)
        assertOnly(cm[2], tones: [2: Double(Self.amp)], accuracy: 0.02, "モノラルは C にゲイン 1.0")
        for c in [0, 1, 3, 4, 5] { assertOnly(cm[c], tones: [:], accuracy: 0.02, "モノラル素材は ch\(c) に出ない") }
    }

    // MARK: 7. ステレオ寄与(パン / エフェクト)

    func testPanClipStaysInLeftRightAndChangesBalance() throws {
        let st = try writeToneWAV("stpan.wav", freqs: [440, 660])
        var (p, c) = audioProject(st)
        c.pan = 1   // 右いっぱい: 左 0、右 √2 倍(AudioPan)
        p.tracks[0].clips = [c]
        let out = tmp.appendingPathComponent("pan51.wav")
        _ = try AudioMixer.mixdownSurround51(project: p, to: out)
        let ch = try readChannels(out)
        XCTAssertLessThan(amps(ch[0])[0], 0.02, "右いっぱいなら L は消える")
        XCTAssertEqual(amps(ch[1])[1], Double(Self.amp) * 2.0.squareRoot(), accuracy: 0.03, "R は √2 倍")
        for k in 2..<6 { assertOnly(ch[k], tones: [:], accuracy: 0.02, "パンは L/R だけ: ch\(k)") }
    }

    func testClipWithAudioFxIsTreatedAsStereoContribution() throws {
        let src = try writeToneWAV("fx51.wav", freqs: Self.freqs)
        var (p, c) = audioProject(src)
        c.audioFx = AudioFx(eq: AudioFx.EQ(low: 6))   // 効くエフェクト → ステレオ寄与(L/R へ)
        XCTAssertTrue(c.hasAudioFx)
        p.tracks[0].clips = [c]
        let out = tmp.appendingPathComponent("fx51.wav")
        _ = try AudioMixer.mixdownSurround51(project: p, to: out)
        let ch = try readChannels(out)
        // 5.1 がステレオにダウンミックスされて L/R に入る(C は 0.7071 で左右へ)。C/LFE/Ls/Rs は無音。
        XCTAssertEqual(amps(ch[0])[2], Double(Self.amp) * g, accuracy: 0.04, "L にセンターが 0.7071 で入る")
        XCTAssertEqual(amps(ch[1])[2], Double(Self.amp) * g, accuracy: 0.04, "R にセンターが 0.7071 で入る")
        for k in 2..<6 { assertOnly(ch[k], tones: [:], accuracy: 0.02, "エフェクト付きは L/R のみ: ch\(k)") }
    }

    // MARK: mp4(Exporter)

    func testExporterSurround51WavToMp4SixChannelAAC() async throws {
        let src = try writeToneWAV("src51-mp4.wav", freqs: Self.freqs)
        let (p, _) = audioProject(src)
        let out = tmp.appendingPathComponent("out51.mp4")
        try await Exporter(project: p, assets: RenderAssets(), audioChannels: .surround51).export(to: out, progress: nil)
        try assertSurroundMp4(out, expected: [.left: 0, .right: 1, .center: 2, .lfe: 3, .leftSurround: 4, .rightSurround: 5], "WAV→mp4")
    }

    func testExporterSurround51ProResFallsBackToStereo() async throws {
        let src = try writeToneWAV("src51-prores.wav", freqs: Self.freqs)
        var (p, _) = audioProject(src)
        p.codec = "prores422"
        let out = tmp.appendingPathComponent("out51.mov")
        try await Exporter(project: p, assets: RenderAssets(), audioChannels: .surround51).export(to: out, progress: nil)
        let fmt = try audioFormat(of: out)
        XCTAssertEqual(fmt.channels, 2, "ProRes(.mov)は 5.1 にせず従来のステレオ")
    }

    // MARK: Asset 経路(AAC 5.1 入り mp4 素材)

    /// AAC 5.1(C L R Ls Rs LFE)の 6ch AAC + 映像入り mp4 を作る(Mp4AAC51ExportTests と同じ生成法)。
    private func writeTone51MP4(_ name: String) async throws -> URL {
        let url = tmp.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_AAC_5_1
        layout.mNumberChannelDescriptions = 0
        let layoutData = withUnsafeBytes(of: &layout) { Data($0) }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 160, AVVideoHeightKey: 90])
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
        func waitReady(_ input: AVAssetWriterInput) async { while !input.isReadyForMoreMediaData { try? await Task.sleep(nanoseconds: 2_000_000) } }
        let pool = adaptor.pixelBufferPool!
        for i in 0..<36 {
            await waitReady(vInput)
            var pbOut: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbOut)
            let pb = pbOut!
            CVPixelBufferLockBaseAddress(pb, [])
            if let base = CVPixelBufferGetBaseAddress(pb) { memset(base, 0x40, CVPixelBufferGetDataSize(pb)) }
            CVPixelBufferUnlockBaseAddress(pb, [])
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30))
        }
        vInput.markAsFinished()
        let total = Int(Self.duration * Self.sampleRate)
        var frame = 0
        while frame < total {
            await waitReady(aInput)
            let n = min(4096, total - frame)
            var samples = [Float](repeating: 0, count: n * 6)
            for c in 0..<6 {
                let f = Mp4AAC51ExportTests.aac51Freqs[c]
                for i in 0..<n { samples[i * 6 + c] = Self.amp * Float(sin(2 * Double.pi * f * Double(frame + i) / Self.sampleRate)) }
            }
            var block: CMBlockBuffer?
            let bytes = samples.count * MemoryLayout<Float>.size
            CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes,
                                               blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                               dataLength: bytes, flags: 0, blockBufferOut: &block)
            samples.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: bytes) }
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48000),
                                            presentationTimeStamp: CMTime(value: CMTimeValue(frame), timescale: 48000), decodeTimeStamp: .invalid)
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

    /// 4. レイアウト順(C L R Ls Rs LFE)の AAC 素材でも、役割どおりのチャンネルへ出る(役割がずれない証明)。
    func testAssetPathAAC51RolesLandOnCorrectOutputChannels() async throws {
        let src = try await writeTone51MP4("src51-aac.mp4")
        let (p, _) = audioProject(src, type: .video)
        // 中間 6ch(canonical 順)の段階で確かめる
        let mix = tmp.appendingPathComponent("asset51.wav")
        let r = try AudioMixer.mixdownSurround51(project: p, to: mix)
        XCTAssertEqual(r.sourceCount, 1)
        let ch = try readChannels(mix)
        XCTAssertEqual(ch.count, 6)
        for c in 0..<6 { assertOnly(ch[c], tones: [c: Double(Self.amp)], accuracy: 0.05, "Asset 中間 ch\(c)=\(Self.names[c])") }
        // mp4 まで通した結果
        let out = tmp.appendingPathComponent("out51-asset.mp4")
        try await Exporter(project: p, assets: RenderAssets(), audioChannels: .surround51).export(to: out, progress: nil)
        try assertSurroundMp4(out, expected: [.left: 0, .right: 1, .center: 2, .lfe: 3, .leftSurround: 4, .rightSurround: 5], "Asset→mp4")
    }

    /// 5. channelMode: .center は C のみ、.firstPair は L/R のみ。
    func testChannelModeCenterAndFirstPairOnAssetSource() async throws {
        let src = try await writeTone51MP4("src51-mode.mp4")
        var (p, c) = audioProject(src, type: .video)
        c.channelMode = .center
        p.tracks[0].clips = [c]
        let outC = tmp.appendingPathComponent("mode-center.wav")
        _ = try AudioMixer.mixdownSurround51(project: p, to: outC)
        let cc = try readChannels(outC)
        assertOnly(cc[2], tones: [2: Double(Self.amp)], accuracy: 0.05, ".center の C")
        for k in [0, 1, 3, 4, 5] { assertOnly(cc[k], tones: [:], accuracy: 0.05, ".center は ch\(k) に出ない") }

        c.channelMode = .firstPair
        p.tracks[0].clips = [c]
        let outP = tmp.appendingPathComponent("mode-pair.wav")
        _ = try AudioMixer.mixdownSurround51(project: p, to: outP)
        let cp = try readChannels(outP)
        assertOnly(cp[0], tones: [0: Double(Self.amp)], accuracy: 0.05, ".firstPair の L")
        assertOnly(cp[1], tones: [1: Double(Self.amp)], accuracy: 0.05, ".firstPair の R")
        for k in 2..<6 { assertOnly(cp[k], tones: [:], accuracy: 0.05, ".firstPair は ch\(k) に出ない") }
    }

    // MARK: m4a(AudioExporter)

    func testAudioExporterSurround51M4A() async throws {
        let src = try writeToneWAV("src51-m4a.wav", freqs: Self.freqs)
        let (p, _) = audioProject(src)
        let out = tmp.appendingPathComponent("out51.m4a")
        try await AudioExporter.export(project: p, to: out, audioChannels: .surround51)
        let fmt = try audioFormat(of: out)
        if fmt.channels == 6 {
            try assertSurroundMp4(out, expected: [.left: 0, .right: 1, .center: 2, .lfe: 3, .leftSurround: 4, .rightSurround: 5], "WAV→m4a")
        } else {
            // この環境の m4a が 6ch AAC を受けない場合は仕様どおりステレオに倒れている(docs 参照)
            XCTAssertEqual(fmt.channels, 2, "6ch でなければステレオに倒れる")
        }
    }

    // MARK: 8. 既定の回帰

    func testDefaultAudioChannelsIsStereo() {
        let p = Project.new()
        XCTAssertEqual(Exporter(project: p, assets: RenderAssets()).audioChannels, .stereo)
        XCTAssertEqual(ExportAudioChannels.allCases, [.stereo, .surround51])
        XCTAssertEqual(ExportAudioChannels.stereo.label, "ステレオ")
        XCTAssertEqual(ExportAudioChannels.surround51.label, "5.1 サラウンド")
    }
}

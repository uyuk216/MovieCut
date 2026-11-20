import XCTest
import AVFoundation
import CoreMedia
import CoreAudio
@testable import MovieCutCore

/// 改善ラウンド5 キュー2 Phase A: Asset 経路のチャンネル選択(.center / .firstPair)が
/// 素材のレイアウト(AudioChannelLayout)の役割どおりに効くことの数値照合と、
/// 7.1ch(File 経路)のダウンミックス係数の照合。
///
/// 背景(docs/マルチチャンネル音声.md): `AssetPCMSource` はチャンネル選択を指定すると素材のチャンネル数のまま読み、
/// 並びは素材のレイアウト順(AAC 5.1 は C L R Ls Rs LFE)で返る(Mp4AAC51ExportTests で実測済み)。
/// 修正前は係数を位置前提(WAV 順 L R C LFE Ls Rs)で割り当てていたため、AAC 5.1 では
/// ch0(= C)を L、ch2(= R)を C と取り違え、`.center` は R(660Hz) を出し、`.firstPair` は C と L を出していた。
/// 修正後はトラックのレイアウトから役割を決めるので、下のテストの期待値(役割どおり)になる。
///
/// 素材: レイアウト順 C=880, L=440, R=660, Ls=1320, Rs=1760, LFE=110 Hz、振幅 0.3、48 kHz、1.2 秒の AAC 5.1 入り mp4。
/// 照合は Goertzel 法(AAC は非可逆だが単一トーンなら誤差は小さい)。
final class AssetChannelModeLayoutTests: XCTestCase {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("assetlayout-tests-\(UUID().uuidString)")
    override func setUpWithError() throws { try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    /// 周波数の添字(結果配列の並び): 440(L), 660(R), 880(C), 110(LFE), 1320(Ls), 1760(Rs)。Mp4AAC51ExportTests と同じ。
    static let freqs: [Double] = [440, 660, 880, 110, 1320, 1760]
    static let names = ["L(440)", "R(660)", "C(880)", "LFE(110)", "Ls(1320)", "Rs(1760)"]
    static let amp: Float = 0.3
    static let duration = 1.2
    static let sampleRate = 48000.0
    let g = 0.70710677   // BS.775 係数
    private let gf: Float = 0.70710677

    // MARK: 純粋ロジック(レイアウトタグ・ラベル → 役割、役割ベースの係数)

    func testRolesForLayoutTagAAC51AndMPEG51A() {
        XCTAssertEqual(MultichannelDownmix.roles(forLayoutTag: UInt32(kAudioChannelLayoutTag_AAC_5_1)),
                       [.center, .left, .right, .leftSurround, .rightSurround, .lfe], "AAC 5.1 = C L R Ls Rs LFE")
        XCTAssertEqual(MultichannelDownmix.roles(forLayoutTag: UInt32(kAudioChannelLayoutTag_MPEG_5_1_A)),
                       [.left, .right, .center, .lfe, .leftSurround, .rightSurround], "MPEG 5.1 A = L R C LFE Ls Rs")
    }

    /// 手書きしたタグの数値が、実際の CoreAudio 定数と一致していること(取り違え防止)。
    func testLayoutTagTableMatchesCoreAudioConstants() {
        let table: [(AudioChannelLayoutTag, [AudioChannelRole])] = [
            (kAudioChannelLayoutTag_Mono, [.center]),
            (kAudioChannelLayoutTag_Stereo, [.left, .right]),
            (kAudioChannelLayoutTag_MatrixStereo, [.left, .right]),
            (kAudioChannelLayoutTag_Quadraphonic, [.left, .right, .leftSurround, .rightSurround]),
            (kAudioChannelLayoutTag_MPEG_5_0_A, [.left, .right, .center, .leftSurround, .rightSurround]),
            (kAudioChannelLayoutTag_MPEG_5_0_B, [.left, .right, .leftSurround, .rightSurround, .center]),
            (kAudioChannelLayoutTag_MPEG_5_0_C, [.left, .center, .right, .leftSurround, .rightSurround]),
            (kAudioChannelLayoutTag_MPEG_5_0_D, [.center, .left, .right, .leftSurround, .rightSurround]),
            (kAudioChannelLayoutTag_MPEG_5_1_A, [.left, .right, .center, .lfe, .leftSurround, .rightSurround]),
            (kAudioChannelLayoutTag_MPEG_5_1_B, [.left, .right, .leftSurround, .rightSurround, .center, .lfe]),
            (kAudioChannelLayoutTag_MPEG_5_1_C, [.left, .center, .right, .leftSurround, .rightSurround, .lfe]),
            (kAudioChannelLayoutTag_MPEG_5_1_D, [.center, .left, .right, .leftSurround, .rightSurround, .lfe]),
            (kAudioChannelLayoutTag_MPEG_6_1_A, [.left, .right, .center, .lfe, .leftSurround, .rightSurround, .centerSurround]),
            (kAudioChannelLayoutTag_MPEG_7_1_A, [.left, .right, .center, .lfe, .leftSurround, .rightSurround, .leftCenter, .rightCenter]),
            (kAudioChannelLayoutTag_MPEG_7_1_B, [.center, .leftCenter, .rightCenter, .left, .right, .leftSurround, .rightSurround, .lfe]),
            (kAudioChannelLayoutTag_MPEG_7_1_C, [.left, .right, .center, .lfe, .leftSurround, .rightSurround, .leftBack, .rightBack]),
            (kAudioChannelLayoutTag_AAC_6_0, [.center, .left, .right, .leftSurround, .rightSurround, .centerSurround]),
            (kAudioChannelLayoutTag_AAC_6_1, [.center, .left, .right, .leftSurround, .rightSurround, .centerSurround, .lfe]),
            (kAudioChannelLayoutTag_AAC_7_0, [.center, .left, .right, .leftSurround, .rightSurround, .leftBack, .rightBack]),
            (kAudioChannelLayoutTag_AAC_7_1, [.center, .leftCenter, .rightCenter, .left, .right, .leftSurround, .rightSurround, .lfe]),
        ]
        for (tag, roles) in table {
            XCTAssertEqual(MultichannelDownmix.roles(forLayoutTag: UInt32(tag)), roles, "タグ 0x\(String(tag, radix: 16)) の役割表")
        }
        // 取れないタグは nil(位置前提へフォールバックさせる)
        XCTAssertNil(MultichannelDownmix.roles(forLayoutTag: UInt32(kAudioChannelLayoutTag_UseChannelDescriptions)))
        XCTAssertNil(MultichannelDownmix.roles(forLayoutTag: UInt32(kAudioChannelLayoutTag_UseChannelBitmap)))
        XCTAssertNil(MultichannelDownmix.roles(forLayoutTag: UInt32(kAudioChannelLayoutTag_Unknown)))
    }

    func testRoleForChannelLabel() {
        XCTAssertEqual(MultichannelDownmix.role(forChannelLabel: kAudioChannelLabel_Left), .left)
        XCTAssertEqual(MultichannelDownmix.role(forChannelLabel: kAudioChannelLabel_Right), .right)
        XCTAssertEqual(MultichannelDownmix.role(forChannelLabel: kAudioChannelLabel_Center), .center)
        XCTAssertEqual(MultichannelDownmix.role(forChannelLabel: kAudioChannelLabel_LFEScreen), .lfe)
        XCTAssertEqual(MultichannelDownmix.role(forChannelLabel: kAudioChannelLabel_LeftSurround), .leftSurround)
        XCTAssertEqual(MultichannelDownmix.role(forChannelLabel: kAudioChannelLabel_RightSurround), .rightSurround)
        XCTAssertEqual(MultichannelDownmix.role(forChannelLabel: kAudioChannelLabel_LeftCenter), .leftCenter)
        XCTAssertEqual(MultichannelDownmix.role(forChannelLabel: kAudioChannelLabel_RightCenter), .rightCenter)
        XCTAssertEqual(MultichannelDownmix.role(forChannelLabel: kAudioChannelLabel_CenterSurround), .centerSurround)
        XCTAssertEqual(MultichannelDownmix.role(forChannelLabel: kAudioChannelLabel_Unknown), .unknown)
        // 1 つでも不明が混じるラベル列は nil(位置前提へ)
        XCTAssertNil(MultichannelDownmix.roles(forChannelLabels: [kAudioChannelLabel_Left, kAudioChannelLabel_Unknown]))
        XCTAssertEqual(MultichannelDownmix.roles(forChannelLabels: [kAudioChannelLabel_Center, kAudioChannelLabel_Left]), [.center, .left])
    }

    func testStereoWeightsByRoles() {
        let aac51: [AudioChannelRole] = [.center, .left, .right, .leftSurround, .rightSurround, .lfe]
        let c = MultichannelDownmix.stereoWeights(roles: aac51, mode: .center)
        XCTAssertEqual(c.map(\.l), [1, 0, 0, 0, 0, 0]); XCTAssertEqual(c.map(\.r), [1, 0, 0, 0, 0, 0])
        let p = MultichannelDownmix.stereoWeights(roles: aac51, mode: .firstPair)
        XCTAssertEqual(p.map(\.l), [0, 1, 0, 0, 0, 0], "L の役割(ch1)だけ左へ。先頭の C ではない")
        XCTAssertEqual(p.map(\.r), [0, 0, 1, 0, 0, 0], "R の役割(ch2)だけ右へ")
        let d = MultichannelDownmix.stereoWeights(roles: aac51, mode: .downmix)
        XCTAssertEqual(d.map(\.l), [gf, 1, 0, gf, 0, 0]); XCTAssertEqual(d.map(\.r), [gf, 0, 1, 0, gf, 0])
        // センター役割が無ければ .center はダウンミックスに倒れる
        let q = MultichannelDownmix.stereoWeights(roles: [.left, .right, .leftSurround, .rightSurround], mode: .center)
        XCTAssertEqual(q.map(\.l), [1, 0, gf, 0]); XCTAssertEqual(q.map(\.r), [0, 1, 0, gf])
        // モノラルはどのモードでも (1,1)、空は空
        XCTAssertEqual(MultichannelDownmix.stereoWeights(roles: [.center], mode: .firstPair).map(\.l), [1])
        XCTAssertTrue(MultichannelDownmix.stereoWeights(roles: [], mode: .center).isEmpty)
    }

    /// 既存の stereoWeights(channelCount:mode:) は位置前提のまま挙動不変(薄いラッパ)。
    func testChannelCountWrapperUnchanged() {
        for n in 0...10 {
            for mode in SourceChannelMode.allCases {
                let a = MultichannelDownmix.stereoWeights(channelCount: n, mode: mode)
                let b = MultichannelDownmix.stereoWeights(roles: MultichannelDownmix.roles(channelCount: n), mode: mode)
                XCTAssertEqual(a.map(\.l), b.map(\.l)); XCTAssertEqual(a.map(\.r), b.map(\.r))
            }
        }
        // 位置前提の firstPair は先頭 2 つ、center は WAV 順の C
        XCTAssertEqual(MultichannelDownmix.stereoWeights(channelCount: 6, mode: .firstPair).map(\.l), [1, 0, 0, 0, 0, 0])
        XCTAssertEqual(MultichannelDownmix.stereoWeights(channelCount: 6, mode: .center).map(\.l), [0, 0, 1, 0, 0, 0])
    }

    // MARK: 素材生成(Mp4AAC51ExportTests.writeTone51MP4 の複製)

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


    // MARK: 素材(AAC 5.1 mp4)

    /// AAC 5.1 レイアウト(= MPEG 5.1 D: C L R Ls Rs LFE)で 6ch AAC + 映像入りの mp4 を作る(Mp4AAC51ExportTests と同じ作り)。
    /// 給餌するサンプルの並びもこのレイアウト順。並びと周波数の対応: C=880, L=440, R=660, Ls=1320, Rs=1760, LFE=110。
    static let aac51Freqs: [Double] = [880, 440, 660, 1320, 1760, 110]
    private func writeTone51MP4(_ name: String) async throws -> URL {
        let url = tmp.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_AAC_5_1
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
                let f = Self.aac51Freqs[c]
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

    /// AVAssetReader で素材のチャンネル数のまま読む(素材の並びの確認用)。
    private func decodeNative(_ url: URL, channels: Int) throws -> [[Float]] {
        let asset = AVURLAsset(url: url)
        let track = try XCTUnwrap(asset.tracks(withMediaType: .audio).first)
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false, AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: channels,
        ])
        XCTAssertTrue(reader.canAdd(out)); reader.add(out)
        XCTAssertTrue(reader.startReading())
        var chs = [[Float]](repeating: [], count: channels)
        while let sb = out.copyNextSampleBuffer() {
            guard let bb = CMSampleBufferGetDataBuffer(sb) else { continue }
            let bytes = CMBlockBufferGetDataLength(bb), floats = bytes / MemoryLayout<Float>.size
            if floats == 0 { continue }
            var raw = [Float](repeating: 0, count: floats)
            raw.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: bytes, destination: $0.baseAddress!) }
            for i in 0..<(floats / channels) { for c in 0..<channels { chs[c].append(raw[i * channels + c]) } }
        }
        return chs
    }

    // MARK: ミックス → 照合

    private func amplitudes(_ samples: [Float]) -> [Double] {
        let from = Int(0.25 * Self.sampleRate), count = Int(0.7 * Self.sampleRate)
        return Self.freqs.map { Self.toneAmplitude(samples, sampleRate: Self.sampleRate, freq: $0, from: from, count: count) }
    }

    private func describe(_ label: String, _ amps: [Double]) -> String {
        zip(Self.names, amps).map { "\(label) \($0): \(String(format: "%.4f", $1))" }.joined(separator: "  ")
    }

    /// 素材を動画クリップとして入れ、channelMode を指定して AudioMixer.mixdown(ステレオ CAF)→読み戻して周波数別の振幅を返す。
    private func mixAmplitudes(src: URL, mode: SourceChannelMode?) throws -> (l: [Double], r: [Double]) {
        var c = Clip(); c.type = .video; c.src = src.path; c.start = 0; c.duration = Self.duration; c.srcDuration = Self.duration
        c.channelMode = mode
        var p = Project.new(); p.tracks[0].clips = [c]
        let out = tmp.appendingPathComponent("mix-\(UUID().uuidString).caf")
        _ = try AudioMixer.mixdown(project: p, assets: RenderAssets(), to: out)
        let f = try AVAudioFile(forReading: out)
        XCTAssertEqual(f.processingFormat.channelCount, 2, "ミックス出力はステレオ")
        let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
        try f.read(into: buf)
        let n = Int(buf.frameLength)
        let l = Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: n))
        let r = Array(UnsafeBufferPointer(start: buf.floatChannelData![1], count: n))
        let (la, ra) = (amplitudes(l), amplitudes(r))
        print("[assetlayout] mode=\(String(describing: mode)) " + describe("L", la))
        print("[assetlayout] mode=\(String(describing: mode)) " + describe("R", ra))
        return (la, ra)
    }

    func testSourceIsAAC51WithLayoutOrder() async throws {
        let src = try await writeTone51MP4("src51.mp4")
        // 素材のレイアウトタグ → 役割が、素材チャンネル数で読んだ実際の並びと一致している
        let asset = AVURLAsset(url: src)
        let fd = try XCTUnwrap(asset.tracks(withMediaType: .audio).first?.formatDescriptions.first as! CMAudioFormatDescription?)
        let lp = try XCTUnwrap(CMAudioFormatDescriptionGetChannelLayout(fd, sizeOut: nil), "素材に AudioChannelLayout がある")
        XCTAssertEqual(lp.pointee.mChannelLayoutTag, kAudioChannelLayoutTag_AAC_5_1)
        let roles = try XCTUnwrap(MultichannelDownmix.roles(forLayoutTag: UInt32(lp.pointee.mChannelLayoutTag)))
        let native = try decodeNative(src, channels: 6)
        let expectIdx: [AudioChannelRole: Int] = [.left: 0, .right: 1, .center: 2, .lfe: 3, .leftSurround: 4, .rightSurround: 5]
        for (c, role) in roles.enumerated() {
            let amps = amplitudes(native[c])
            let idx = try XCTUnwrap(expectIdx[role])
            XCTAssertEqual(amps[idx], Double(Self.amp), accuracy: 0.02, "素材 ch\(c) の役割 \(role.label) は \(Self.names[idx]) の音")
        }
    }

    /// .center: 修正前は位置前提で ch2(= R の 660Hz)を出していた。レイアウト対応後は C(880Hz)だけが左右に出る。
    func testAssetCenterModeOutputsOnlyCenter() async throws {
        let src = try await writeTone51MP4("src51-center.mp4")
        let m = try mixAmplitudes(src: src, mode: .center)
        for (name, a) in [("左", m.l), ("右", m.r)] {
            XCTAssertEqual(a[2], Double(Self.amp), accuracy: 0.06, "\(name)に C(880) が振幅 0.3")
            for j in [0, 1, 3, 4, 5] { XCTAssertLessThan(a[j], 0.03, "\(name)に \(Self.names[j]) は出ない") }
        }
    }

    /// .firstPair: 左に L(440)、右に R(660)だけ。位置前提だと先頭 2ch(C と L)になってしまう。
    func testAssetFirstPairModeOutputsOnlyLeftRight() async throws {
        let src = try await writeTone51MP4("src51-pair.mp4")
        let m = try mixAmplitudes(src: src, mode: .firstPair)
        XCTAssertEqual(m.l[0], Double(Self.amp), accuracy: 0.06, "左に L(440)")
        XCTAssertEqual(m.r[1], Double(Self.amp), accuracy: 0.06, "右に R(660)")
        for j in 1..<6 { XCTAssertLessThan(m.l[j], 0.03, "左に \(Self.names[j]) は出ない") }
        for j in [0, 2, 3, 4, 5] { XCTAssertLessThan(m.r[j], 0.03, "右に \(Self.names[j]) は出ない") }
    }

    /// 既定(未指定)も明示 .downmix も、BS.775 の値になる。
    /// 明示 .downmix は `Clip.channelModeOrDefault` で .downmix のまま `AssetPCMSource` に渡り、
    /// `native == nil`(= AVFoundation に 2ch 変換を任せる既定経路)を通る。自前係数の経路は通らない。
    func testAssetDefaultAndExplicitDownmixAreBS775() async throws {
        let src = try await writeTone51MP4("src51-down.mp4")
        for mode in [nil, SourceChannelMode.downmix] {
            let m = try mixAmplitudes(src: src, mode: mode)
            let label = String(describing: mode)
            XCTAssertEqual(m.l[0], Double(Self.amp), accuracy: 0.06, "[\(label)] 左 440: 0.3")
            XCTAssertEqual(m.l[2], Double(Self.amp) * g, accuracy: 0.06, "[\(label)] 左 880: 0.212")
            XCTAssertEqual(m.l[4], Double(Self.amp) * g, accuracy: 0.06, "[\(label)] 左 1320: 0.212")
            XCTAssertEqual(m.r[1], Double(Self.amp), accuracy: 0.06, "[\(label)] 右 660: 0.3")
            XCTAssertEqual(m.r[2], Double(Self.amp) * g, accuracy: 0.06, "[\(label)] 右 880: 0.212")
            XCTAssertEqual(m.r[5], Double(Self.amp) * g, accuracy: 0.06, "[\(label)] 右 1760: 0.212")
            for j in [1, 3, 5] { XCTAssertLessThan(m.l[j], 0.03, "[\(label)] 左に \(Self.names[j]) は出ない(LFE 無し)") }
            for j in [0, 3, 4] { XCTAssertLessThan(m.r[j], 0.03, "[\(label)] 右に \(Self.names[j]) は出ない(LFE 無し)") }
        }
    }

    // MARK: 7.1ch(File 経路、WAV 順 L R C LFE Lb Rb Ls Rs)

    /// 「実素材」の代わりに、WAV 順の 7.1 WAV をテスト内で生成して照合する(チャンネルごとに違う DC)。
    /// 期待値は MultichannelDownmix の documented な係数: C・Lb/Rb・Ls/Rs は 0.7071 で左右へ、LFE は含めない。
    func testMix71WavFilePathMatchesDocumentedCoefficients() throws {
        let values: [Float] = [0.42, -0.36, 0.30, 0.12, 0.10, -0.08, 0.24, -0.20]   // L R C LFE Lb Rb Ls Rs
        let url = tmp.appendingPathComponent("dc8.wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: Self.sampleRate, AVNumberOfChannelsKey: 8,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let total = Int(0.5 * Self.sampleRate)
        let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(total))!
        buf.frameLength = AVAudioFrameCount(total)
        for c in 0..<8 { for i in 0..<total { buf.floatChannelData![c][i] = values[c] } }
        try file.write(from: buf)

        var c = Clip(); c.type = .audio; c.src = url.path; c.start = 0; c.duration = 0.5
        var p = Project.new(); p.tracks[0].clips = [c]
        let out = tmp.appendingPathComponent("mix71.caf")
        _ = try AudioMixer.mixdown(project: p, assets: RenderAssets(), to: out)
        let f = try AVAudioFile(forReading: out)
        let rb = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
        try f.read(into: rb)
        let n = Int(rb.frameLength), lo = n / 4, hi = n * 3 / 4
        func mean(_ ch: Int) -> Float { var s: Float = 0; for i in lo..<hi { s += rb.floatChannelData![ch][i] }; return s / Float(hi - lo) }
        // 左 = L + g*(C + Lb + Ls)、右 = R + g*(C + Rb + Rs)。LFE(0.12)は入らない。
        XCTAssertEqual(mean(0), 0.42 + gf * (0.30 + 0.10 + 0.24), accuracy: 0.002)
        XCTAssertEqual(mean(1), -0.36 + gf * (0.30 - 0.08 - 0.20), accuracy: 0.002)
    }
}

import XCTest
import AVFoundation
@testable import MovieCutCore

/// マルチチャンネル音声(W5-3): probe(旧 MultichannelProbeTests / MultichannelProbe2Tests、
/// print のみで assert が無かった調査用テスト)を置き換える回帰テスト。
/// probe が調べていた前提は次のとおりで、ここでは結果を assert で固定する:
/// - File 経路(`FilePCMSource`): 従来は ch0/ch1 だけを拾い、3ch 以上の残りを黙って捨てていた。
/// - Asset 経路: 従来どおり AVFoundation に 2ch 変換を任せる(レイアウト依存の並びを自前で決めない)。
/// 合成信号は「チャンネルごとに違う DC 値」を使う(probe と同じ手法。周波数推定より確実)。
final class MultichannelAudioTests: XCTestCase {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("multichannel-tests-\(UUID().uuidString)")
    override func setUpWithError() throws { try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    private let g: Float = 0.70710677   // 1/√2(BS.775 のセンター/サラウンド係数)

    // MARK: 純粋な係数・ダウンミックス

    func testRolesForCommonLayouts() {
        XCTAssertEqual(MultichannelDownmix.roles(channelCount: 2), [.left, .right])
        XCTAssertEqual(MultichannelDownmix.roles(channelCount: 5), [.left, .right, .center, .leftSurround, .rightSurround])
        XCTAssertEqual(MultichannelDownmix.roles(channelCount: 6), [.left, .right, .center, .lfe, .leftSurround, .rightSurround])
        XCTAssertEqual(MultichannelDownmix.roles(channelCount: 8).count, 8)
        XCTAssertEqual(MultichannelDownmix.roles(channelCount: 0), [])
        XCTAssertTrue(MultichannelDownmix.isMultichannel(channelCount: 6))
        XCTAssertFalse(MultichannelDownmix.isMultichannel(channelCount: 2))
    }

    func testDownmix51Coefficients() {
        // L=1, R=0.5, C=0.4, LFE=0.9(捨てる), Ls=0.3, Rs=0.2
        let (l, r) = MultichannelDownmix.downmix(channels: [[1], [0.5], [0.4], [0.9], [0.3], [0.2]])
        XCTAssertEqual(l[0], 1 + 0.4 * g + 0.3 * g, accuracy: 1e-6)
        XCTAssertEqual(r[0], 0.5 + 0.4 * g + 0.2 * g, accuracy: 1e-6)
    }

    func testDownmixMonoAndStereoAreIdentity() {
        let mono = MultichannelDownmix.downmix(channels: [[0.25, -0.5]])
        XCTAssertEqual(mono.left, [0.25, -0.5]); XCTAssertEqual(mono.right, [0.25, -0.5])
        let st = MultichannelDownmix.downmix(channels: [[0.25, -0.5], [0.75, 0.1]])
        XCTAssertEqual(st.left, [0.25, -0.5]); XCTAssertEqual(st.right, [0.75, 0.1])
        XCTAssertEqual(MultichannelDownmix.downmix(channels: []).left, [])
    }

    func testDownmixModes() {
        let src: [[Float]] = [[1], [0.5], [0.4], [0.9], [0.3], [0.2]]
        let pair = MultichannelDownmix.downmix(channels: src, mode: .firstPair)
        XCTAssertEqual(pair.left, [1]); XCTAssertEqual(pair.right, [0.5])
        let center = MultichannelDownmix.downmix(channels: src, mode: .center)
        XCTAssertEqual(center.left, [0.4]); XCTAssertEqual(center.right, [0.4])
        // センターの無い 4ch(クアッド)で center を選んでも無音にならない(ダウンミックスに倒す)
        let quad = MultichannelDownmix.downmix(channels: [[1], [0.5], [0.3], [0.2]], mode: .center)
        XCTAssertEqual(quad.left[0], 1 + 0.3 * g, accuracy: 1e-6)
        XCTAssertEqual(quad.right[0], 0.5 + 0.2 * g, accuracy: 1e-6)
    }

    func testDownmix71AndExtraChannelsAreNotDroppedSilently() {
        // 8ch: Lb/Rb(4,5番)も Ls/Rs と同じ係数で左右へ入る
        let (l, r) = MultichannelDownmix.downmix(channels: [[0], [0], [0], [0], [0.4], [0.2], [0.3], [0.1]])
        XCTAssertEqual(l[0], (0.4 + 0.3) * g, accuracy: 1e-6)
        XCTAssertEqual(r[0], (0.2 + 0.1) * g, accuracy: 1e-6)
        // 9ch 目も捨てない(左右交互の前提。9 番目は左サラウンド扱い)
        let nine = MultichannelDownmix.downmix(channels: [[0], [0], [0], [0], [0], [0], [0], [0], [0.5]])
        XCTAssertEqual(nine.left[0], 0.5 * g, accuracy: 1e-6)
        XCTAssertEqual(nine.right[0], 0, accuracy: 1e-6)
    }

    // MARK: ファイル経路のミックス(probe の DC ケースを assert 化)

    /// チャンネルごとに違う DC 値を持つ WAV を書く(probe と同じ作り方)。
    private func writeDC(_ name: String, values: [Float], sampleRate: Double = 48000) throws -> String {
        let url = tmp.appendingPathComponent(name)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: values.count,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let total = Int(0.5 * sampleRate)
        let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(total))!
        buf.frameLength = AVAudioFrameCount(total)
        for c in 0..<values.count { for i in 0..<total { buf.floatChannelData![c][i] = values[c] } }
        try file.write(from: buf)
        return url.path
    }

    private func mixMeans(src: String, mode: SourceChannelMode? = nil, duration: Double = 0.5) throws -> (l: Float, r: Float) {
        var c = Clip(); c.type = .audio; c.src = src; c.start = 0; c.duration = duration; c.channelMode = mode
        var p = Project(); var t = Track(name: "L0"); t.clips = [c]; p.tracks = [t]
        let out = tmp.appendingPathComponent("mix-\(UUID().uuidString).caf")
        _ = try AudioMixer.mixdown(project: p, assets: RenderAssets(), to: out)
        let f = try AVAudioFile(forReading: out)
        XCTAssertEqual(f.processingFormat.channelCount, 2, "ミックス出力は従来どおりステレオ")
        let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
        try f.read(into: buf)
        let n = Int(buf.frameLength)
        // 変換の端の影響を避けて中央部分の平均を取る
        let lo = n / 4, hi = n * 3 / 4
        func mean(_ ch: Int) -> Float {
            var s: Float = 0; for i in lo..<hi { s += buf.floatChannelData![ch][i] }; return s / Float(hi - lo)
        }
        return (mean(0), mean(1))
    }

    func testMixMonoAndStereoUnchanged() throws {
        let mono = try mixMeans(src: try writeDC("mono.wav", values: [0.42]))
        XCTAssertEqual(mono.l, 0.42, accuracy: 0.001); XCTAssertEqual(mono.r, 0.42, accuracy: 0.001)
        let st = try mixMeans(src: try writeDC("st.wav", values: [0.42, -0.36]))
        XCTAssertEqual(st.l, 0.42, accuracy: 0.001); XCTAssertEqual(st.r, -0.36, accuracy: 0.001)
    }

    func testMix51IncludesCenterAndSurroundsAndDropsLFE() throws {
        // probe の 6ch ケース: [L, R, C, LFE, Ls, Rs]
        let m = try mixMeans(src: try writeDC("dc6.wav", values: [0.42, -0.36, 0.30, 0.12, 0.24, -0.24]))
        XCTAssertEqual(m.l, 0.42 + 0.30 * g + 0.24 * g, accuracy: 0.002, "センターと左サラウンドが左に入る(LFE 0.12 は入らない)")
        XCTAssertEqual(m.r, -0.36 + 0.30 * g - 0.24 * g, accuracy: 0.002)
    }

    func testMix51ResampledFromOtherSampleRate() throws {
        // サンプルレート変換(AVAudioConverter)を経てもダウンミックスされる
        let m = try mixMeans(src: try writeDC("dc6-24k.wav", values: [0.42, -0.36, 0.30, 0.12, 0.24, -0.24], sampleRate: 24000))
        XCTAssertEqual(m.l, 0.42 + 0.30 * g + 0.24 * g, accuracy: 0.01)
        XCTAssertEqual(m.r, -0.36 + 0.30 * g - 0.24 * g, accuracy: 0.01)
    }

    func testMixThreeAndFourChannels() throws {
        let three = try mixMeans(src: try writeDC("dc3.wav", values: [0.42, -0.36, 0.30]))
        XCTAssertEqual(three.l, 0.42 + 0.30 * g, accuracy: 0.002)
        XCTAssertEqual(three.r, -0.36 + 0.30 * g, accuracy: 0.002)
        let quad = try mixMeans(src: try writeDC("dc4.wav", values: [0.42, -0.36, 0.30, 0.18]))
        XCTAssertEqual(quad.l, 0.42 + 0.30 * g, accuracy: 0.002, "4ch はクアッド前提(Ls が左へ)")
        XCTAssertEqual(quad.r, -0.36 + 0.18 * g, accuracy: 0.002)
    }

    func testMixChannelModes() throws {
        let src = try writeDC("dc6m.wav", values: [0.42, -0.36, 0.30, 0.12, 0.24, -0.24])
        let pair = try mixMeans(src: src, mode: .firstPair)
        XCTAssertEqual(pair.l, 0.42, accuracy: 0.001); XCTAssertEqual(pair.r, -0.36, accuracy: 0.001)
        let center = try mixMeans(src: src, mode: .center)
        XCTAssertEqual(center.l, 0.30, accuracy: 0.001); XCTAssertEqual(center.r, 0.30, accuracy: 0.001)
    }

    // MARK: 保存形式

    func testChannelModeRoundTripAndUnusedIsByteStable() throws {
        var p = Project.new()
        var c = Clip(); c.type = .audio; c.src = "/m/a.wav"; c.duration = 1
        var t = Track(name: "L0"); t.clips = [c]; p.tracks = [t]
        let data1 = try p.encoded()
        XCTAssertFalse(String(decoding: data1, as: UTF8.self).contains("\"channelMode\""), "未使用なら書かない")
        XCTAssertEqual(try Project.decode(from: data1).encoded(), data1, "未使用プロジェクトはバイト一致")

        XCTAssertTrue(AudioFxEditing.setChannelMode(&c, .center))
        XCTAssertEqual(c.channelModeOrDefault, .center); XCTAssertTrue(c.hasChannelMode)
        var p2 = Project.new(); var t2 = Track(name: "L0"); t2.clips = [c]; p2.tracks = [t2]
        let data2 = try p2.encoded()
        XCTAssertTrue(String(decoding: data2, as: UTF8.self).contains("\"channelMode\""), "設定したときだけ書く(pretty-print 形式)")
        let decoded = try Project.decode(from: data2)
        XCTAssertEqual(decoded.tracks[0].clips[0].channelMode, .center)
        XCTAssertEqual(try decoded.encoded(), data2)

        // 既定に戻すと未設定に戻り、キーも消える
        var back = decoded.tracks[0].clips[0]
        XCTAssertTrue(AudioFxEditing.setChannelMode(&back, .downmix))
        XCTAssertNil(back.channelMode)
        // 知らない値は extra に残って書き戻される
        let raw = "{\"id\":\"x\",\"type\":\"audio\",\"start\":0,\"duration\":1,\"offset\":0,\"channelMode\":\"futureMode\"}"
        let weird = try Project.decode(from: Data("{\"width\":1920,\"height\":1080,\"fps\":60,\"bg\":\"#000000\",\"codec\":\"h264\",\"voicevoxUrl\":\"http://127.0.0.1:50021\",\"aquestalkCommand\":\"x\",\"characters\":[],\"tracks\":[{\"id\":\"t\",\"name\":\"L0\",\"clips\":[\(raw)]}]}".utf8))
        XCTAssertEqual(weird.tracks[0].clips[0].extra["channelMode"], .string("futureMode"))
    }
}

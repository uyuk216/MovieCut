import XCTest
@testable import MovieCutCore

/// R2-4: SoundFont(.sf2)対応。自前パーサ + サンプル再生の検証。
/// テスト用の小さい .sf2 は、このファイル内のビルダーが正弦波サンプルで組み立てる
/// (外部ファイル・同梱素材は使わない)。
final class SoundFontTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sf2tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - テスト用 .sf2 ビルダー

    private func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xff), UInt8((v >> 8) & 0xff)] }
    private func le32(_ v: Int) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * $0)) & 0xff) } }
    private func fixed(_ s: String, _ len: Int) -> [UInt8] {
        var b = Array(s.utf8.prefix(len))
        b += [UInt8](repeating: 0, count: len - b.count)
        return b
    }
    private func chunk(_ id: String, _ payload: [UInt8]) -> [UInt8] {
        var out = Array(id.utf8) + le32(payload.count) + payload
        if payload.count % 2 == 1 { out.append(0) }
        return out
    }
    private func list(_ type: String, _ payload: [UInt8]) -> [UInt8] { chunk("LIST", Array(type.utf8) + payload) }

    /// 正弦波サンプル(441Hz の倍数だとループが継ぎ目なく回る)。
    private func sineSample(freq: Double, seconds: Double = 0.1) -> [Int16] {
        let sr = 44100.0
        let count = Int(seconds * sr)
        return (0..<count).map { i in Int16(0.7 * 32767 * sin(2 * Double.pi * freq * Double(i) / sr)) }
    }

    /// プリセットごとに正弦波サンプル 1 つを持つ最小の .sf2。
    /// extraGens は楽器ゾーンへ足すジェネレータ(oper, amount)。
    private func makeSF2(presets: [(bank: Int, program: Int, name: String, freq: Double, loop: Bool, extraGens: [(UInt16, Int16)])]) -> Data {
        // サンプル実体と shdr
        var smpl: [UInt8] = []
        var shdr: [UInt8] = []
        var offset = 0
        for (i, p) in presets.enumerated() {
            let sample = sineSample(freq: p.freq)
            for s in sample { let u = UInt16(bitPattern: s); smpl += [UInt8(u & 0xff), UInt8(u >> 8)] }
            shdr += fixed("sine\(i)", 20) + le32(offset) + le32(offset + sample.count)
                + le32(offset) + le32(offset + sample.count) + le32(44100)
                + [69, 0] + le16(0) + le16(1)
            offset += sample.count
        }
        shdr += fixed("EOS", 20) + le32(0) + le32(0) + le32(0) + le32(0) + le32(0) + [0, 0] + le16(0) + le16(0)

        // phdr / pbag / pgen(プリセットゾーンは instrument ジェネレータ 1 つだけ)
        var phdr: [UInt8] = [], pbag: [UInt8] = [], pgen: [UInt8] = []
        for (i, p) in presets.enumerated() {
            phdr += fixed(p.name, 20) + le16(p.program) + le16(p.bank) + le16(i) + le32(0) + le32(0) + le32(0)
            pbag += le16(i) + le16(0)
            pgen += le16(41) + le16(i)
        }
        phdr += fixed("EOP", 20) + le16(0) + le16(0) + le16(presets.count) + le32(0) + le32(0) + le32(0)
        pbag += le16(presets.count) + le16(0)

        // inst / ibag / igen(楽器ゾーンは sampleID + sampleModes + extraGens)
        var inst: [UInt8] = [], ibag: [UInt8] = [], igen: [UInt8] = []
        var genIndex = 0
        for (i, p) in presets.enumerated() {
            inst += fixed("inst\(i)", 20) + le16(i)
            ibag += le16(genIndex) + le16(0)
            igen += le16(53) + le16(i)
            igen += le16(54) + le16(p.loop ? 1 : 0)
            genIndex += 2
            for (oper, amount) in p.extraGens {
                igen += le16(Int(oper)) + le16(Int(amount) & 0xffff)
                genIndex += 1
            }
        }
        inst += fixed("EOI", 20) + le16(presets.count)
        ibag += le16(genIndex) + le16(0)

        let info = list("INFO", chunk("ifil", le16(2) + le16(1)) + chunk("INAM", fixed("TestFont", 9)))
        let sdta = list("sdta", chunk("smpl", smpl))
        var pdtaBody: [UInt8] = []
        pdtaBody += chunk("phdr", phdr) + chunk("pbag", pbag) + chunk("pmod", [UInt8](repeating: 0, count: 10))
        pdtaBody += chunk("pgen", pgen) + chunk("inst", inst) + chunk("ibag", ibag)
        pdtaBody += chunk("imod", [UInt8](repeating: 0, count: 10)) + chunk("igen", igen) + chunk("shdr", shdr)
        let pdta = list("pdta", pdtaBody)

        let body = Array("sfbk".utf8) + info + sdta + pdta
        return Data(Array("RIFF".utf8) + le32(body.count) + body)
    }

    private func defaultSF2() -> Data {
        makeSF2(presets: [
            (bank: 0, program: 0, name: "Sine441", freq: 441, loop: true, extraGens: []),
            (bank: 0, program: 1, name: "Sine882", freq: 882, loop: true, extraGens: []),
        ])
    }

    // MARK: - テスト用 MIDI ビルダー(InputFormatsTests と同じ流儀)

    private func vlq(_ v: Int) -> [UInt8] {
        var stack = [UInt8(v & 0x7f)]
        var rest = v >> 7
        while rest > 0 { stack.insert(UInt8(rest & 0x7f) | 0x80, at: 0); rest >>= 7 }
        return stack
    }
    private func be16(_ v: Int) -> [UInt8] { [UInt8((v >> 8) & 0xff), UInt8(v & 0xff)] }
    private func be32(_ v: Int) -> [UInt8] { (0..<4).map { UInt8((v >> (24 - 8 * $0)) & 0xff) } }
    private func smf(tracks: [[UInt8]]) -> Data {
        var d = Array("MThd".utf8) + be32(6) + be16(0) + be16(tracks.count) + be16(480)
        for t in tracks { d += Array("MTrk".utf8) + be32(t.count) + t }
        return Data(d)
    }
    /// 120BPM で A4(69)を 0.5 秒鳴らす。prefix にはプログラムチェンジ等を差し込める。
    private func noteMIDI(channel: Int = 0, prefix: [UInt8] = []) -> Data {
        var ev: [UInt8] = []
        ev += vlq(0) + [0xff, 0x51, 0x03, 0x07, 0xa1, 0x20]   // テンポ 500000us
        ev += prefix
        ev += vlq(0) + [UInt8(0x90 | channel), 69, 100]
        ev += vlq(480) + [UInt8(0x80 | channel), 69, 0]
        ev += vlq(0) + [0xff, 0x2f, 0x00]
        return smf(tracks: [ev])
    }

    /// 区間のゼロ交差から概算周波数を出す。
    private func estimateFrequency(_ samples: [Float], from: Double, to: Double) -> Double {
        let sr = 44100.0
        let a = Int(from * sr), b = min(samples.count, Int(to * sr))
        guard b > a + 100 else { return 0 }
        var crossings = 0
        for i in (a + 1)..<b where (samples[i - 1] < 0) != (samples[i] < 0) { crossings += 1 }
        return Double(crossings) / 2 / (Double(b - a) / sr)
    }

    // MARK: - パース

    func testSoundFontParsesPresetsAndSamples() throws {
        let sf = try SoundFontParser.parse(defaultSF2())
        XCTAssertEqual(sf.name, "TestFont")
        XCTAssertEqual(sf.sampleCount, 2)
        XCTAssertEqual(sf.presets, [
            SoundFontPresetInfo(name: "Sine441", bank: 0, program: 0),
            SoundFontPresetInfo(name: "Sine882", bank: 0, program: 1),
        ])
        XCTAssertTrue(MidiImporter.isSoundFont(path: "a.SF2"))
        XCTAssertFalse(MidiImporter.isSoundFont(path: "a.mid"))
    }

    func testSoundFontRejectsInvalidData() {
        XCTAssertThrowsError(try SoundFontParser.parse(Data("XXXX".utf8))) {
            XCTAssertEqual($0 as? SoundFontError, .notSoundFont)
        }
        XCTAssertThrowsError(try SoundFontParser.parse(Data("RIFFxxxxsfbk".utf8))) {
            XCTAssertEqual($0 as? SoundFontError, .truncated)
        }
    }

    // MARK: - MIDI 側: プログラム/バンクの取り込み

    func testMIDIParsesProgramChangeAndBankSelect() throws {
        // CC#0=2, CC#32=3 → bank 259。プログラム 7。
        var prefix: [UInt8] = []
        prefix += vlq(0) + [0xb0, 0, 2]
        prefix += vlq(0) + [0xb0, 32, 3]
        prefix += vlq(0) + [0xc0, 7]
        let f = try MidiParser.parse(noteMIDI(prefix: prefix))
        XCTAssertEqual(f.programChanges.count, 1)
        XCTAssertEqual(f.programChanges[0].bank, 259)
        XCTAssertEqual(f.programChanges[0].program, 7)
        XCTAssertEqual(f.notes[0].program, 7)
        XCTAssertEqual(f.notes[0].bank, 259)

        // ドラムチャンネル(9)はバンク指定が無ければ 128、通常チャンネルは 0。
        let drums = try MidiParser.parse(noteMIDI(channel: 9))
        XCTAssertEqual(drums.notes[0].bank, 128)
        let plain = try MidiParser.parse(noteMIDI())
        XCTAssertEqual(plain.notes[0].bank, 0)
        XCTAssertEqual(plain.notes[0].program, 0)
    }

    // MARK: - レンダリング

    func testSoundFontRenderIsAudibleDeterministicAndDiffersFromSimpleSynth() throws {
        let sf = try SoundFontParser.parse(defaultSF2())
        let f = try MidiParser.parse(noteMIDI())
        let a = SoundFontRenderer.renderSamples(f, soundFont: sf)
        let b = SoundFontRenderer.renderSamples(f, soundFont: sf)
        XCTAssertEqual(a, b)   // 決定的
        XCTAssertEqual(a.count, Int(((f.duration + MidiImporter.tail) * 44100).rounded()))
        let peak = a.map { abs($0) }.max() ?? 0
        XCTAssertEqual(peak, BuiltInSounds.peakLevel, accuracy: 0.001)
        // サンプルの周波数(441Hz)が鳴っている(簡易シンセの 440Hz の倍音構成とは波形も違う)
        XCTAssertEqual(estimateFrequency(a, from: 0.1, to: 0.4), 441, accuracy: 15)
        XCTAssertNotEqual(a, MidiImporter.renderSamples(f))
        let wav = SoundFontRenderer.renderWAV(f, soundFont: sf)
        XCTAssertEqual(Array(wav.prefix(4)), Array("RIFF".utf8))
    }

    /// 非有限の総尺・ノート時刻でも落ちない(簡易シンセ renderSamples と同じ防御)。
    func testSoundFontRenderSurvivesNonFiniteTimes() throws {
        let sf = try SoundFontParser.parse(defaultSF2())
        let base = try MidiParser.parse(noteMIDI())
        var d = base; d.duration = .nan
        XCTAssertLessThanOrEqual(SoundFontRenderer.renderSamples(d, soundFont: sf).count, MidiImporter.maxSamples)
        var inf = base; inf.duration = .infinity
        XCTAssertLessThanOrEqual(SoundFontRenderer.renderSamples(inf, soundFont: sf).count, MidiImporter.maxSamples)
        var s = base; s.notes[0].start = .nan
        XCTAssertNoThrow(SoundFontRenderer.renderSamples(s, soundFont: sf))
        var l = base; l.notes[0].duration = .infinity
        XCTAssertNoThrow(SoundFontRenderer.renderSamples(l, soundFont: sf))
        var n = base; n.notes[0].duration = .nan
        XCTAssertNoThrow(SoundFontRenderer.renderSamples(n, soundFont: sf))
    }

    func testSoundFontProgramChangeSelectsPreset() throws {
        let sf = try SoundFontParser.parse(defaultSF2())
        let withPC = try MidiParser.parse(noteMIDI(prefix: vlq(0) + [0xc0, 1]))
        let rendered = SoundFontRenderer.renderSamples(withPC, soundFont: sf)
        XCTAssertEqual(estimateFrequency(rendered, from: 0.1, to: 0.4), 882, accuracy: 20)
    }

    func testSoundFontMissingPresetFallsBackToProgramZero() throws {
        // プリセットは program 5 だけ。program 9 のノートは (0,0) も無いので無音、
        // program 5 のノートは鳴る。program 0 指定でも (0,5) には落ちない。
        let sf = try SoundFontParser.parse(makeSF2(presets: [
            (bank: 0, program: 5, name: "Only5", freq: 441, loop: true, extraGens: []),
        ]))
        let p5 = try MidiParser.parse(noteMIDI(prefix: vlq(0) + [0xc0, 5]))
        XCTAssertGreaterThan(SoundFontRenderer.renderSamples(p5, soundFont: sf).map { abs($0) }.max() ?? 0, 0.5)
        let p9 = try MidiParser.parse(noteMIDI(prefix: vlq(0) + [0xc0, 9]))
        XCTAssertEqual(SoundFontRenderer.renderSamples(p9, soundFont: sf).map { abs($0) }.max() ?? 1, 0)
        // フォールバック (0, program) → (0, 0): bank 3 の program 0 は bank 0 の program 0 に落ちる
        let sf2 = try SoundFontParser.parse(defaultSF2())
        let banked = try MidiParser.parse(noteMIDI(prefix: vlq(0) + [0xb0, 0, 3] + vlq(0) + [0xc0, 0]))
        XCTAssertEqual(banked.notes[0].bank, 384)
        XCTAssertEqual(estimateFrequency(SoundFontRenderer.renderSamples(banked, soundFont: sf2), from: 0.1, to: 0.4), 441, accuracy: 15)
    }

    func testSoundFontLoopSustainsBeyondSampleLength() throws {
        // サンプルは 0.1 秒。ループありなら 0.5 秒のノートの後半も鳴り、無しなら止まる。
        let looped = try SoundFontParser.parse(makeSF2(presets: [
            (bank: 0, program: 0, name: "Loop", freq: 441, loop: true, extraGens: []),
        ]))
        let oneShot = try SoundFontParser.parse(makeSF2(presets: [
            (bank: 0, program: 0, name: "OneShot", freq: 441, loop: false, extraGens: []),
        ]))
        let f = try MidiParser.parse(noteMIDI())
        let a = SoundFontRenderer.renderSamples(f, soundFont: looped)
        let tailEnergy = a[Int(0.35 * 44100)..<Int(0.45 * 44100)].map { abs($0) }.max() ?? 0
        XCTAssertGreaterThan(tailEnergy, 0.3)
        let b = SoundFontRenderer.renderSamples(f, soundFont: oneShot)
        let deadTail = b[Int(0.35 * 44100)..<Int(0.45 * 44100)].map { abs($0) }.max() ?? 1
        XCTAssertEqual(deadTail, 0)
    }

    func testSoundFontEnvelopeAndAttenuationGensApply() throws {
        // sustainVolEnv 600cb(=60dB 減衰)にするとサステイン区間がほぼ無音になる。
        let quiet = try SoundFontParser.parse(makeSF2(presets: [
            (bank: 0, program: 0, name: "Quiet", freq: 441, loop: true, extraGens: [(37, 600)]),
        ]))
        let f = try MidiParser.parse(noteMIDI())
        let a = SoundFontRenderer.renderSamples(f, soundFont: quiet)
        // attack/decay は既定(約1ms)なので、0.2 秒時点はサステイン(ほぼ無音)のはず。
        // 全体ピークは attack 直後の 1.0 で正規化されるため、相対値で見る。
        let sustainBand = a[Int(0.2 * 44100)..<Int(0.3 * 44100)].map { abs($0) }.max() ?? 1
        XCTAssertLessThan(sustainBand, 0.05)
    }

    // MARK: - prepare(キャッシュ経路)

    func testSoundFontPrepareWritesSeparateCacheAndKeepsDefaultUntouched() throws {
        let midiURL = tmp.appendingPathComponent("song.mid")
        try noteMIDI().write(to: midiURL)
        let sfURL = tmp.appendingPathComponent("font.sf2")
        try defaultSF2().write(to: sfURL)
        let cache = tmp.appendingPathComponent("cache")

        let plain = try MidiImporter.prepare(atPath: midiURL.path, cacheDir: cache)
        XCTAssertEqual((plain.wavPath as NSString).lastPathComponent, "rendered.wav")
        let plainData = try Data(contentsOf: URL(fileURLWithPath: plain.wavPath))

        let withSF = try MidiImporter.prepare(atPath: midiURL.path, cacheDir: cache, soundFontPath: sfURL.path)
        XCTAssertTrue(((withSF.wavPath as NSString).lastPathComponent).hasPrefix("rendered-sf-"))
        let sfData = try Data(contentsOf: URL(fileURLWithPath: withSF.wavPath))
        XCTAssertNotEqual(sfData, plainData)
        XCTAssertEqual(Array(sfData.prefix(4)), Array("RIFF".utf8))

        // 簡易シンセのキャッシュは SoundFont 経路に汚染されない
        let plainAgain = try MidiImporter.prepare(atPath: midiURL.path, cacheDir: cache)
        XCTAssertEqual(plainAgain.wavPath, plain.wavPath)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: plainAgain.wavPath)), plainData)

        // 壊れた SoundFont は SoundFontError で弾く
        let badURL = tmp.appendingPathComponent("bad.sf2")
        try Data("not a soundfont".utf8).write(to: badURL)
        XCTAssertThrowsError(try MidiImporter.prepare(atPath: midiURL.path, cacheDir: tmp.appendingPathComponent("c2"), soundFontPath: badURL.path)) {
            XCTAssertEqual($0 as? SoundFontError, .notSoundFont)
        }
    }
}

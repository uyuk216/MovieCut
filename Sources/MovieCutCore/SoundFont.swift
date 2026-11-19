import Foundation

// MARK: - SoundFont 2 (.sf2) のパース(R2-4)
//
// 外部依存なしの自前パース。RIFF(sfbk)の INFO / sdta(smpl) / pdta(phdr・pbag・pgen・
// inst・ibag・igen・shdr)を読み、プリセット(bank/program)→ プリセットゾーン →
// 楽器ゾーン → サンプル の対応を、描画しやすい「リージョン」の列に解決しておく。
//
// 方式の判断(AVAudioUnitSampler を使わない理由):
//   AVAudioUnitSampler は SoundFont を読み込めるが、オフラインで WAV 化するには
//   AVAudioEngine のマニュアルレンダリング + MusicSequence 等のスケジューリングが要り、
//   音響デバイスや実行環境に左右されてヘッドレスの単体テスト/CLI で決定的に検証しにくい。
//   MovieCutCore は Foundation のみの純粋な層で、既存の MIDI パーサ・簡易シンセも決定的な
//   純関数として検証されている。同じ流儀で到達できる自前パース+サンプル再生を選んだ。
//   代償として、モジュレータ・フィルタ・LFO・コーラス/リバーブセンドは再現しない
//   (docs/MIDIとSoundFont.md の「到達範囲」を参照)。
//
// 対応するジェネレータ(解決時に使うもの):
//   サンプルの開始/終了/ループ位置(オフセット・粗オフセット含む)、sampleModes、
//   音量エンベロープ(delay/attack/hold/decay/sustain/release + keynumToVolEnvHold/Decay)、
//   initialAttenuation、pan(モノラルへの畳み込みで減衰として近似)、
//   coarseTune / fineTune / scaleTuning / overridingRootKey、keyRange / velRange。
// プリセット側のジェネレータは、楽器側へ「加算」する(SoundFont 仕様の作法)。
// ただし範囲・リンク系(keyRange / velRange / sampleID / instrument / sampleModes /
// keynum / velocity / exclusiveClass / overridingRootKey / scaleTuning)は加算せず、
// 楽器側の値を優先し、無ければプリセット側を使う。

public enum SoundFontError: Error, Equatable, CustomStringConvertible {
    case notSoundFont
    case truncated
    case noPresets

    public var description: String {
        switch self {
        case .notSoundFont: return "SoundFont ファイルとして読み取れませんでした"
        case .truncated: return "SoundFont ファイルが途中で終わっています"
        case .noPresets: return "SoundFont にプリセットがありません"
        }
    }
}

/// プリセット 1 件の公開情報(一覧表示用)。
public struct SoundFontPresetInfo: Equatable, Sendable {
    public var name: String
    public var bank: Int
    public var program: Int
    public init(name: String, bank: Int, program: Int) {
        self.name = name; self.bank = bank; self.program = program
    }
}

// MARK: - 内部表現

/// shdr レコード(サンプル 1 件の素性)。
struct SF2SampleHeader: Equatable {
    var name: String
    var start: Int
    var end: Int
    var startLoop: Int
    var endLoop: Int
    var sampleRate: Int
    var originalPitch: Int
    var pitchCorrection: Int   // セント
    var sampleType: Int
}

/// ゾーン 1 件分のジェネレータ(keyRange / velRange は範囲として分けて持つ)。
struct SF2ZoneData {
    var gens: [UInt16: Int] = [:]
    var keyRange: ClosedRange<Int>?
    var velRange: ClosedRange<Int>?
}

/// 解決済みリージョン: ノート 1 つがこの形に落ちれば、そのまま鳴らせる。
struct SF2Region {
    var presetKeyRange: ClosedRange<Int>?
    var presetVelRange: ClosedRange<Int>?
    var instKeyRange: ClosedRange<Int>?
    var instVelRange: ClosedRange<Int>?
    /// 解決済みジェネレータ(既定値は含まない。読み手が既定値を当てる)。
    var gens: [UInt16: Int]
    var sampleIndex: Int

    func matches(key: Int, velocity: Int) -> Bool {
        if let r = presetKeyRange, !r.contains(key) { return false }
        if let r = presetVelRange, !r.contains(velocity) { return false }
        if let r = instKeyRange, !r.contains(key) { return false }
        if let r = instVelRange, !r.contains(velocity) { return false }
        return true
    }
}

struct SF2ResolvedPreset {
    var bank: Int
    var program: Int
    var regions: [SF2Region]
}

/// パース済み SoundFont。サンプル実体と解決済みプリセットを持つ。
public struct SoundFont: Sendable {
    /// INFO の INAM(無ければ空)。
    public var name: String
    /// プリセット一覧(bank → program の順)。
    public var presets: [SoundFontPresetInfo]
    /// サンプル数(shdr の終端レコードを除く)。
    public var sampleCount: Int { sampleHeaders.count }

    var samples: [Int16]
    var sampleHeaders: [SF2SampleHeader]
    var resolvedPresets: [SF2ResolvedPreset]

    /// ノートに対応するリージョンを探す。プリセットは (bank, program) の完全一致 →
    /// (0, program) → (0, 0) の順にフォールバックする(実用上の作法)。
    func region(bank: Int, program: Int, key: Int, velocity: Int) -> (region: SF2Region, sample: SF2SampleHeader)? {
        for (b, p) in [(bank, program), (0, program), (0, 0)] {
            guard let preset = resolvedPresets.first(where: { $0.bank == b && $0.program == p }) else { continue }
            if let region = preset.regions.first(where: { $0.matches(key: key, velocity: velocity) }),
               sampleHeaders.indices.contains(region.sampleIndex) {
                return (region, sampleHeaders[region.sampleIndex])
            }
        }
        return nil
    }
}

// MARK: - パーサ

public enum SoundFontParser {
    // ジェネレータ番号(SoundFont 仕様)
    static let genInstrument: UInt16 = 41
    static let genKeyRange: UInt16 = 43
    static let genVelRange: UInt16 = 44
    static let genSampleID: UInt16 = 53
    /// 加算しないジェネレータ(範囲は別持ちなので含めない)。
    static let nonSummableGens: Set<UInt16> = [41, 46, 47, 54, 56, 57, 58]

    public static func parseFile(atPath path: String) throws -> SoundFont {
        try parse(Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe))
    }

    public static func parse(_ data: Data) throws -> SoundFont {
        let bytes = [UInt8](data)
        guard bytes.count >= 12, Array(bytes[0..<4]) == Array("RIFF".utf8),
              Array(bytes[8..<12]) == Array("sfbk".utf8) else { throw SoundFontError.notSoundFont }

        var name = ""
        var sampleData: ArraySlice<UInt8>?
        var pdta: [String: ArraySlice<UInt8>] = [:]

        // トップレベルの LIST チャンクを走査する(RIFF チャンクは偶数境界にパディングされる)。
        var pos = 12
        while pos + 8 <= bytes.count {
            let id = String(bytes: bytes[pos..<(pos + 4)], encoding: .ascii) ?? ""
            let size = Int(u32le(bytes, pos + 4))
            let bodyStart = pos + 8
            guard bodyStart + size <= bytes.count else { throw SoundFontError.truncated }
            let body = bytes[bodyStart..<(bodyStart + size)]
            if id == "LIST", size >= 4 {
                let kind = String(bytes: body.prefix(4), encoding: .ascii) ?? ""
                var sub = bodyStart + 4
                let end = bodyStart + size
                while sub + 8 <= end {
                    let subID = String(bytes: bytes[sub..<(sub + 4)], encoding: .ascii) ?? ""
                    let subSize = Int(u32le(bytes, sub + 4))
                    guard sub + 8 + subSize <= end else { throw SoundFontError.truncated }
                    let payload = bytes[(sub + 8)..<(sub + 8 + subSize)]
                    switch (kind, subID) {
                    case ("INFO", "INAM"): name = cString(payload)
                    case ("sdta", "smpl"): sampleData = payload
                    case ("pdta", _): pdta[subID] = payload
                    default: break
                    }
                    sub += 8 + subSize + (subSize & 1)
                }
            }
            pos = bodyStart + size + (size & 1)
        }

        guard let smpl = sampleData, let phdr = pdta["phdr"], let pbag = pdta["pbag"],
              let pgen = pdta["pgen"], let inst = pdta["inst"], let ibag = pdta["ibag"],
              let igen = pdta["igen"], let shdr = pdta["shdr"] else { throw SoundFontError.truncated }

        // サンプル実体(16 ビット・リトルエンディアン)
        var samples = [Int16](repeating: 0, count: smpl.count / 2)
        for i in samples.indices {
            let lo = smpl[smpl.startIndex + i * 2], hi = smpl[smpl.startIndex + i * 2 + 1]
            samples[i] = Int16(bitPattern: UInt16(lo) | (UInt16(hi) << 8))
        }

        // shdr(46 バイト/件、末尾に終端レコード)
        let sampleHeaders: [SF2SampleHeader] = try records(shdr, size: 46).dropLast().map { r in
            SF2SampleHeader(name: fixedString(r, 0, 20),
                            start: Int(u32le(r, 20)), end: Int(u32le(r, 24)),
                            startLoop: Int(u32le(r, 28)), endLoop: Int(u32le(r, 32)),
                            sampleRate: Int(u32le(r, 36)), originalPitch: Int(r[40]),
                            pitchCorrection: Int(Int8(bitPattern: r[41])), sampleType: Int(u16le(r, 44)))
        }

        // inst(22 バイト/件、末尾に終端レコード)
        let instRecords = try records(inst, size: 22)
        // phdr(38 バイト/件、末尾に終端レコード)
        let phdrRecords = try records(phdr, size: 38)
        guard phdrRecords.count >= 2 else { throw SoundFontError.noPresets }
        let pbagRecords = try records(pbag, size: 4)
        let ibagRecords = try records(ibag, size: 4)
        let pgenRecords = try records(pgen, size: 4)
        let igenRecords = try records(igen, size: 4)

        func zone(_ bags: [[UInt8]], _ gens: [[UInt8]], index: Int) throws -> SF2ZoneData {
            guard bags.indices.contains(index), bags.indices.contains(index + 1) else { throw SoundFontError.truncated }
            let from = Int(u16le(bags[index], 0)), to = Int(u16le(bags[index + 1], 0))
            guard from <= to, to <= gens.count else { throw SoundFontError.truncated }
            var zone = SF2ZoneData()
            for g in gens[from..<to] {
                let oper = u16le(g, 0)
                let raw = u16le(g, 2)
                switch oper {
                case genKeyRange: zone.keyRange = clampRange(Int(raw & 0xff), Int((raw >> 8) & 0xff))
                case genVelRange: zone.velRange = clampRange(Int(raw & 0xff), Int((raw >> 8) & 0xff))
                default: zone.gens[oper] = Int(Int16(bitPattern: raw))
                }
            }
            return zone
        }

        // 楽器ゾーンの解決(楽器 index → ゾーン列。先頭が sampleID を持たなければグローバルゾーン)
        func instrumentZones(_ instIndex: Int) throws -> (global: SF2ZoneData?, locals: [SF2ZoneData]) {
            guard instRecords.indices.contains(instIndex), instRecords.indices.contains(instIndex + 1) else { throw SoundFontError.truncated }
            let from = Int(u16le(instRecords[instIndex], 20)), to = Int(u16le(instRecords[instIndex + 1], 20))
            guard from <= to, to <= ibagRecords.count - 1 else { throw SoundFontError.truncated }
            var global: SF2ZoneData?
            var locals: [SF2ZoneData] = []
            for zi in from..<to {
                let z = try zone(ibagRecords, igenRecords, index: zi)
                if z.gens[genSampleID] == nil, global == nil, locals.isEmpty { global = z } else { locals.append(z) }
            }
            return (global, locals)
        }

        var presetInfos: [SoundFontPresetInfo] = []
        var resolved: [SF2ResolvedPreset] = []
        for pi in 0..<(phdrRecords.count - 1) {
            let rec = phdrRecords[pi]
            let presetName = fixedString(rec, 0, 20)
            let program = Int(u16le(rec, 20)), bank = Int(u16le(rec, 22))
            let bagFrom = Int(u16le(rec, 24))
            guard phdrRecords.indices.contains(pi + 1) else { throw SoundFontError.truncated }
            let bagTo = Int(u16le(phdrRecords[pi + 1], 24))
            guard bagFrom <= bagTo, bagTo <= pbagRecords.count - 1 else { throw SoundFontError.truncated }
            presetInfos.append(SoundFontPresetInfo(name: presetName, bank: bank, program: program))

            var presetGlobal: SF2ZoneData?
            var regions: [SF2Region] = []
            for zi in bagFrom..<bagTo {
                let pz = try zone(pbagRecords, pgenRecords, index: zi)
                guard let instIndex = pz.gens[genInstrument] else {
                    if presetGlobal == nil, regions.isEmpty { presetGlobal = pz }
                    continue
                }
                let (instGlobal, instLocals) = try instrumentZones(instIndex)
                for iz in instLocals {
                    guard let sampleID = iz.gens[genSampleID] else { continue }
                    // ジェネレータ解決: 楽器(グローバル→ローカルの上書き)を土台に、
                    // プリセット(グローバル→ローカル)を加算(非加算系は楽器優先)。
                    var eff: [UInt16: Int] = instGlobal?.gens ?? [:]
                    for (k, v) in iz.gens { eff[k] = v }
                    var presetGens: [UInt16: Int] = presetGlobal?.gens ?? [:]
                    for (k, v) in pz.gens { presetGens[k] = v }
                    for (k, v) in presetGens where k != genInstrument {
                        if nonSummableGens.contains(k) {
                            if eff[k] == nil { eff[k] = v }
                        } else {
                            eff[k] = (eff[k] ?? 0) + v
                        }
                    }
                    regions.append(SF2Region(presetKeyRange: pz.keyRange, presetVelRange: pz.velRange,
                                             instKeyRange: iz.keyRange, instVelRange: iz.velRange,
                                             gens: eff, sampleIndex: sampleID))
                }
            }
            resolved.append(SF2ResolvedPreset(bank: bank, program: program, regions: regions))
        }
        guard !resolved.isEmpty else { throw SoundFontError.noPresets }
        presetInfos.sort { ($0.bank, $0.program) < ($1.bank, $1.program) }

        return SoundFont(name: name, presets: presetInfos, samples: samples,
                         sampleHeaders: sampleHeaders, resolvedPresets: resolved)
    }

    // MARK: 読み取り補助

    private static func u32le(_ b: [UInt8], _ at: Int) -> UInt32 {
        guard at + 4 <= b.count else { return 0 }
        return UInt32(b[at]) | (UInt32(b[at + 1]) << 8) | (UInt32(b[at + 2]) << 16) | (UInt32(b[at + 3]) << 24)
    }
    private static func u32le(_ s: ArraySlice<UInt8>, _ at: Int) -> UInt32 { u32le([UInt8](s), at) }
    private static func u16le(_ b: [UInt8], _ at: Int) -> UInt16 {
        guard at + 2 <= b.count else { return 0 }
        return UInt16(b[at]) | (UInt16(b[at + 1]) << 8)
    }
    private static func clampRange(_ lo: Int, _ hi: Int) -> ClosedRange<Int> {
        let a = min(127, max(0, lo)), b = min(127, max(0, hi))
        return min(a, b)...max(a, b)
    }
    /// 固定長・NUL 終端の文字列。
    private static func fixedString(_ b: [UInt8], _ at: Int, _ len: Int) -> String {
        let slice = b[at..<min(b.count, at + len)]
        return cString(ArraySlice(slice))
    }
    private static func cString(_ s: ArraySlice<UInt8>) -> String {
        let bytes = Array(s.prefix { $0 != 0 })
        return String(bytes: bytes, encoding: .utf8) ?? String(bytes: bytes, encoding: .shiftJIS) ?? ""
    }
    /// 固定長レコードの列に割る(割り切れなければ truncated)。
    private static func records(_ chunk: ArraySlice<UInt8>, size: Int) throws -> [[UInt8]] {
        guard chunk.count % size == 0 else { throw SoundFontError.truncated }
        return stride(from: 0, to: chunk.count, by: size).map { Array(chunk[(chunk.startIndex + $0)..<(chunk.startIndex + $0 + size)]) }
    }
}

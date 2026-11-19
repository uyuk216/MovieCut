import Foundation

// MARK: - 標準 MIDI ファイル(SMF)のパース(#5)
//
// 外部依存なしの自前パース。ヘッダ(MThd)・トラック(MTrk)・可変長数・ランニングステータス・
// メタイベント(テンポ・トラック名・拍子)を読み、ノートオン/オフを対にして秒単位のノート列にする。
// プログラムチェンジとバンクセレクト(CC#0/#32)も拾い、ノートごとに有効だった
// プログラム/バンクを記録する(SoundFont のプリセット選択用。R2-4)。
// テンポマップ(PPQ)と SMPTE 分解能の両方に対応する。壊れたファイルは例外で知らせる(黙って空にしない)。

/// MIDI のノート 1 つ(秒単位に直したもの)。
public struct MidiNote: Equatable, Sendable {
    public var track: Int
    public var channel: Int
    /// 音の高さ(0〜127。60 = 中央のド)。
    public var pitch: Int
    /// 強さ(1〜127)。
    public var velocity: Int
    public var startTick: Int
    public var endTick: Int
    /// 開始(秒、テンポマップ適用後)。
    public var start: Double
    /// 長さ(秒)。
    public var duration: Double
    /// ノートオン時点で有効だったプログラム番号(0〜127。プログラムチェンジが無ければ 0)。
    /// SoundFont レンダリング(R2-4)でプリセットを選ぶために使う。簡易シンセは使わない。
    public var program: Int
    /// ノートオン時点で有効だったバンク番号(CC#0/#32 の合成値。指定が無く
    /// チャンネル 10(インデックス 9)のときはドラム用の 128)。
    public var bank: Int

    public init(track: Int, channel: Int, pitch: Int, velocity: Int, startTick: Int, endTick: Int, start: Double, duration: Double, program: Int = 0, bank: Int = 0) {
        self.track = track; self.channel = channel; self.pitch = pitch; self.velocity = velocity
        self.startTick = startTick; self.endTick = endTick; self.start = start; self.duration = duration
        self.program = program; self.bank = bank
    }

    /// 音名("C4" など。60 = C4)。
    public var name: String { MidiNote.noteName(pitch) }

    public static func noteName(_ pitch: Int) -> String {
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        let p = min(127, max(0, pitch))
        return "\(names[p % 12])\(p / 12 - 1)"
    }

    /// 周波数(Hz、平均律、A4 = 440)。
    public var frequency: Double { 440 * pow(2, Double(pitch - 69) / 12) }
}

/// テンポの変化点。
public struct MidiTempo: Equatable, Sendable {
    public var tick: Int
    /// 4 分音符あたりのマイクロ秒。
    public var microsecondsPerQuarter: Int
    public init(tick: Int, microsecondsPerQuarter: Int) {
        self.tick = tick; self.microsecondsPerQuarter = microsecondsPerQuarter
    }
    public var bpm: Double { 60_000_000 / Double(max(1, microsecondsPerQuarter)) }
}

/// プログラムチェンジ 1 件(バンクセレクト CC#0/#32 を合成済み)。
public struct MidiProgramChange: Equatable, Sendable {
    public var tick: Int
    /// 時刻(秒、テンポマップ適用後)。
    public var time: Double
    public var channel: Int
    public var bank: Int
    public var program: Int
    public init(tick: Int, time: Double, channel: Int, bank: Int, program: Int) {
        self.tick = tick; self.time = time; self.channel = channel; self.bank = bank; self.program = program
    }
}

/// パースした MIDI ファイル。
public struct MidiFileData: Equatable, Sendable {
    /// SMF フォーマット(0 / 1 / 2)。
    public var format: Int
    public var trackCount: Int
    /// 4 分音符あたりのティック数(SMPTE のときは nil)。
    public var ticksPerQuarter: Int?
    /// SMPTE のフレームレート(PPQ のときは nil)。
    public var smpteFramesPerSecond: Int?
    /// SMPTE の 1 フレームあたりのティック数。
    public var smpteTicksPerFrame: Int?
    /// テンポ列(ティック順)。
    public var tempos: [MidiTempo]
    /// トラック名(メタ 0x03。無いトラックは入らない)。
    public var trackNames: [Int: String]
    /// ノート列(開始秒→トラック→音の高さ の順)。
    public var notes: [MidiNote]
    /// 全体の長さ(秒。最後のノートの終わり。ノートが無ければ最後のイベント)。
    public var duration: Double
    /// プログラムチェンジの列(出現順)。SoundFont のプリセット選択の記録用。
    public var programChanges: [MidiProgramChange] = []

    public var isSMPTE: Bool { ticksPerQuarter == nil }

    /// 使われている音の高さの範囲(ノートが無ければ nil)。
    public var pitchRange: ClosedRange<Int>? {
        guard let lo = notes.map(\.pitch).min(), let hi = notes.map(\.pitch).max() else { return nil }
        return lo...hi
    }
}

public enum MidiError: Error, Equatable, CustomStringConvertible {
    case notMIDI
    case truncated
    case unsupportedFormat(Int)
    /// 総尺が取り込み上限を超えた(F-4 のガード。巨大な WAV を作らないため、取り込まない)。
    case tooLong(seconds: Double, limit: Double)
    /// ノート数が取り込み上限を超えた(F-4 のガード。病的に密なファイルで描画が爆発しないように)。
    case tooManyNotes(count: Int, limit: Int)

    public var description: String {
        switch self {
        case .notMIDI: return "MIDI ファイルとして読み取れませんでした"
        case .truncated: return "MIDI ファイルが途中で終わっています"
        case .unsupportedFormat(let f): return "対応していない MIDI フォーマットです(\(f))"
        case .tooLong(let s, let limit): return "MIDI が長すぎます(\(Int(s.rounded())) 秒。上限は \(Int(limit)) 秒です)"
        case .tooManyNotes(let n, let limit): return "MIDI のノートが多すぎます(\(n) 個。上限は \(limit) 個です)"
        }
    }
}

public enum MidiParser {
    /// 既定のテンポ(120 BPM)。
    public static let defaultMicrosecondsPerQuarter = 500_000

    public static func parse(_ data: Data) throws -> MidiFileData {
        var r = Reader(data)
        guard r.take(4) == Array("MThd".utf8) else { throw MidiError.notMIDI }
        guard let headerLength = r.u32(), headerLength >= 6 else { throw MidiError.truncated }
        guard let format = r.u16(), let ntrks = r.u16(), let division = r.u16() else { throw MidiError.truncated }
        if headerLength > 6 { r.skip(headerLength - 6) }
        guard format <= 2 else { throw MidiError.unsupportedFormat(format) }

        var ticksPerQuarter: Int? = nil
        var smpteFPS: Int? = nil
        var smpteTPF: Int? = nil
        if division & 0x8000 == 0 {
            ticksPerQuarter = division
        } else {
            // 上位バイトは -fps の 2 の補数(例: 0xE7 = -25 → 25fps)
            let raw = Int((division >> 8) & 0xff)
            smpteFPS = raw >= 128 ? 256 - raw : raw
            smpteTPF = division & 0xff
        }

        struct RawNote { var track, channel, pitch, velocity, startTick, endTick, program, bank: Int }
        struct RawProgramChange { var tick, channel, bank, program: Int }
        var rawNotes: [RawNote] = []
        var rawProgramChanges: [RawProgramChange] = []
        var tempos: [MidiTempo] = []
        var trackNames: [Int: String] = [:]
        var lastTick = 0
        // チャンネルごとのプログラム/バンクの現在値。SMF では本来チャンネル状態は
        // トラックをまたいで共有されるが、このパーサはトラック順に読むため、
        // 辞書をトラック間で共有して近似する(通常のファイルは同じトラック内で完結する)。
        var channelProgram: [Int: Int] = [:]
        var channelBankMSB: [Int: Int] = [:]
        var channelBankLSB: [Int: Int] = [:]
        func effectiveBank(_ ch: Int) -> Int {
            if channelBankMSB[ch] == nil, channelBankLSB[ch] == nil { return ch == 9 ? 128 : 0 }
            return ((channelBankMSB[ch] ?? 0) << 7) | (channelBankLSB[ch] ?? 0)
        }

        for trackIndex in 0..<ntrks {
            guard r.take(4) == Array("MTrk".utf8), let trackLength = r.u32() else { throw MidiError.truncated }
            let trackEnd = min(r.pos + trackLength, data.count)
            var tick = 0
            var runningStatus: UInt8? = nil
            // 鳴っているノート: (チャンネル, 音の高さ) → 開始の列(同じ音の重なりは先入れ先出し)
            var active: [Int: [(tick: Int, velocity: Int, program: Int, bank: Int)]] = [:]
            func key(_ ch: Int, _ pitch: Int) -> Int { ch * 128 + pitch }

            while r.pos < trackEnd {
                guard let delta = r.vlq(limit: trackEnd) else { throw MidiError.truncated }
                tick += delta
                lastTick = max(lastTick, tick)
                guard r.pos < trackEnd else { break }
                var status = data[r.pos]
                if status < 0x80 {
                    guard let rs = runningStatus else { throw MidiError.truncated }
                    status = rs
                } else {
                    r.pos += 1
                    if status < 0xf0 { runningStatus = status }
                }
                switch status {
                case 0x80...0x8f, 0x90...0x9f:   // ノートオフ / ノートオン
                    guard r.pos + 2 <= trackEnd else { throw MidiError.truncated }
                    let pitch = Int(data[r.pos]) & 0x7f, velocity = Int(data[r.pos + 1]) & 0x7f
                    r.pos += 2
                    let ch = Int(status & 0x0f)
                    if status >= 0x90, velocity > 0 {
                        active[key(ch, pitch), default: []].append((tick, velocity, channelProgram[ch] ?? 0, effectiveBank(ch)))
                    } else if var queue = active[key(ch, pitch)], !queue.isEmpty {
                        let head = queue.removeFirst()
                        active[key(ch, pitch)] = queue
                        rawNotes.append(RawNote(track: trackIndex, channel: ch, pitch: pitch, velocity: head.velocity, startTick: head.tick, endTick: tick, program: head.program, bank: head.bank))
                    }
                case 0xb0...0xbf:                // コントロールチェンジ(2 バイト)。バンクセレクト(CC#0/#32)だけ拾う
                    guard r.pos + 2 <= trackEnd else { throw MidiError.truncated }
                    let controller = Int(data[r.pos]) & 0x7f, value = Int(data[r.pos + 1]) & 0x7f
                    r.pos += 2
                    let ch = Int(status & 0x0f)
                    if controller == 0 { channelBankMSB[ch] = value }
                    if controller == 32 { channelBankLSB[ch] = value }
                case 0xa0...0xaf, 0xe0...0xef:   // ポリフォニックキー圧 / ピッチベンド(2 バイト)
                    guard r.pos + 2 <= trackEnd else { throw MidiError.truncated }
                    r.pos += 2
                case 0xc0...0xcf:                // プログラムチェンジ(1 バイト)
                    guard r.pos + 1 <= trackEnd else { throw MidiError.truncated }
                    let program = Int(data[r.pos]) & 0x7f
                    r.pos += 1
                    let ch = Int(status & 0x0f)
                    channelProgram[ch] = program
                    rawProgramChanges.append(RawProgramChange(tick: tick, channel: ch, bank: effectiveBank(ch), program: program))
                case 0xd0...0xdf:                // チャンネル圧(1 バイト)
                    guard r.pos + 1 <= trackEnd else { throw MidiError.truncated }
                    r.pos += 1
                case 0xff:                       // メタイベント
                    guard r.pos < trackEnd else { throw MidiError.truncated }
                    let type = data[r.pos]; r.pos += 1
                    guard let len = r.vlq(limit: trackEnd), r.pos + len <= trackEnd else { throw MidiError.truncated }
                    let payload = Array(data[r.pos..<(r.pos + len)])
                    r.pos += len
                    switch type {
                    case 0x51 where len == 3:
                        let us = (Int(payload[0]) << 16) | (Int(payload[1]) << 8) | Int(payload[2])
                        tempos.append(MidiTempo(tick: tick, microsecondsPerQuarter: us))
                    case 0x03:
                        trackNames[trackIndex] = String(bytes: payload, encoding: .utf8) ?? String(bytes: payload, encoding: .shiftJIS) ?? ""
                    default:
                        break
                    }
                case 0xf0, 0xf7:                 // SysEx
                    guard let len = r.vlq(limit: trackEnd) else { throw MidiError.truncated }
                    r.pos += len
                    guard r.pos <= trackEnd else { throw MidiError.truncated }
                default:
                    throw MidiError.truncated
                }
            }
            // トラックの終わりまで鳴りっぱなしのノートは、最後のティックで切る
            for (k, queue) in active {
                for head in queue {
                    rawNotes.append(RawNote(track: trackIndex, channel: k / 128, pitch: k % 128, velocity: head.velocity, startTick: head.tick, endTick: tick, program: head.program, bank: head.bank))
                }
            }
            r.pos = trackEnd
        }

        tempos.sort { $0.tick < $1.tick }

        // ティック → 秒
        func seconds(atTick t: Int) -> Double {
            if let tpq = ticksPerQuarter {
                var acc = 0.0
                var prevTick = 0
                var tempo = MidiTempo(tick: 0, microsecondsPerQuarter: defaultMicrosecondsPerQuarter)
                for change in tempos {
                    if change.tick >= t { break }
                    if change.tick > prevTick {
                        acc += Double(change.tick - prevTick) * Double(tempo.microsecondsPerQuarter) / 1_000_000 / Double(tpq)
                        prevTick = change.tick
                    }
                    tempo = change
                }
                acc += Double(t - prevTick) * Double(tempo.microsecondsPerQuarter) / 1_000_000 / Double(tpq)
                return acc
            }
            let fps = Double(smpteFPS ?? 30), tpf = Double(smpteTPF ?? 1)
            return Double(t) / (fps * tpf)
        }

        let notes = rawNotes.map { n -> MidiNote in
            let s = seconds(atTick: n.startTick)
            let e = seconds(atTick: n.endTick)
            return MidiNote(track: n.track, channel: n.channel, pitch: n.pitch, velocity: n.velocity,
                            startTick: n.startTick, endTick: n.endTick, start: s, duration: max(0, e - s),
                            program: n.program, bank: n.bank)
        }.sorted { ($0.start, $0.track, $0.pitch) < ($1.start, $1.track, $1.pitch) }

        let programChanges = rawProgramChanges.map {
            MidiProgramChange(tick: $0.tick, time: seconds(atTick: $0.tick), channel: $0.channel, bank: $0.bank, program: $0.program)
        }

        let duration = max(notes.map { $0.start + $0.duration }.max() ?? 0, seconds(atTick: lastTick))
        return MidiFileData(format: format, trackCount: ntrks, ticksPerQuarter: ticksPerQuarter,
                            smpteFramesPerSecond: smpteFPS, smpteTicksPerFrame: smpteTPF,
                            tempos: tempos, trackNames: trackNames, notes: notes, duration: duration,
                            programChanges: programChanges)
    }

    /// ファイルから読む(開けなければ IO 例外)。
    public static func parseFile(atPath path: String) throws -> MidiFileData {
        try parse(Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe))
    }

    // MARK: 読み取り

    private struct Reader {
        let data: Data
        var pos = 0
        init(_ data: Data) { self.data = data }

        mutating func take(_ n: Int) -> [UInt8]? {
            guard pos + n <= data.count else { return nil }
            defer { pos += n }
            return Array(data[pos..<(pos + n)])
        }
        mutating func u32() -> Int? {
            guard let b = take(4) else { return nil }
            return (Int(b[0]) << 24) | (Int(b[1]) << 16) | (Int(b[2]) << 8) | Int(b[3])
        }
        mutating func u16() -> Int? {
            guard let b = take(2) else { return nil }
            return (Int(b[0]) << 8) | Int(b[1])
        }
        mutating func skip(_ n: Int) { pos = min(data.count, pos + max(0, n)) }
        /// 可変長数(最大 4 バイト)。`limit` を超えたら nil。
        mutating func vlq(limit: Int) -> Int? {
            var value = 0
            for _ in 0..<4 {
                guard pos < limit, pos < data.count else { return nil }
                let b = data[pos]; pos += 1
                value = (value << 7) | Int(b & 0x7f)
                if b & 0x80 == 0 { return value }
            }
            return value
        }
    }
}

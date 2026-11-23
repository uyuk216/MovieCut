import Foundation

// MARK: - MIDI の取り込み(#5)
//
// 取り込んだ MIDI は 2 つの形でタイムラインに載せる:
//   1. 音声化: ノートを WAV に描き、通常の音声クリップとして置く。
//      既存の音声基盤(再生・波形・書き出し・フェード・音量)がそのまま使える。
//      音色は 2 系統ある:
//        - 既定: 簡易シンセ(倍音つき正弦波 + 減衰)。従来どおりで、出力は不変。
//        - SoundFont(.sf2)を指定した場合: SoundFontRenderer がプリセットのサンプルで描く
//          (R2-4。自前 .sf2 パーサ + サンプル再生。到達範囲は docs/MIDIとSoundFont.md)。
//   2. マーカー: ノートの開始ごとにマーカーを置き、ノート情報(音名)をタイムライン上で辿れるようにする。

public enum MidiImporter {
    public static let sampleRate = 44100
    /// マーカーにするノート開始の上限(病的に多いファイルでマーカーが爆発しないように)。
    public static let markerLimit = 1000
    /// 音の余韻(秒)。最後のノートの後ろに足す。
    public static let tail = 0.5
    /// 取り込みの総尺上限(秒)。これを超える MIDI は音声化で巨大な WAV(と巨大な中間バッファ)を
    /// 作ってしまうため、取り込まない(F-4 のガード。prepare が MidiError.tooLong で弾く)。
    public static let maxDurationSeconds = 600.0
    /// 取り込みのノート数上限。病的に密なファイル(いわゆる黒 MIDI 級)で描画コストと
    /// マーカー・クリップ生成が爆発しないようにする上限(prepare が MidiError.tooManyNotes で弾く)。
    public static let maxNotes = 50_000
    /// renderSamples が確保するサンプルの上限(= 総尺上限 + 余韻ぶん)。
    /// prepare を通らない直接呼び出しでも、メモリ確保がこの範囲を超えないための防御。
    public static let maxSamples = Int(((maxDurationSeconds + tail) * Double(sampleRate)).rounded())
    /// renderSamples が 1 回で処理するノートサンプルの総量の上限(防御)。
    /// 総尺・ノート数の上限内でも、全ノートが総尺いっぱいに重なる病的な入力で内側のループが
    /// 爆発しないようにする。これを超えた分のノートは描かない(prepare 経由では通常起きない)。
    public static let maxNoteSamples = 300_000_000

    /// 取り込み上限の検査(総尺・ノート数)。超えていれば MidiError を投げる。
    /// 取り込みの入口(prepare)がパース直後に呼び、アプリ側は既存のエラーパス
    /// (errorTitle / errorMessage)でそのまま表示する。
    public static func validate(_ file: MidiFileData) throws {
        guard file.duration.isFinite, file.duration <= maxDurationSeconds else {
            throw MidiError.tooLong(seconds: file.duration.isFinite ? file.duration : maxDurationSeconds + 1, limit: maxDurationSeconds)
        }
        guard file.notes.count <= maxNotes else {
            throw MidiError.tooManyNotes(count: file.notes.count, limit: maxNotes)
        }
        // 描画側にはノートサンプルの総量上限があり、超えると後半のノートが黙って消える。同じ計算で先に弾く
        let sr = Double(sampleRate)
        var budget = Double(maxNoteSamples)
        for note in file.notes {
            let audible = min(note.duration + 0.35, max(0, file.duration + tail - note.start))
            budget -= audible * sr
            if budget < 0 { throw MidiError.tooDense }
        }
    }

    public static func isMIDI(path: String) -> Bool {
        ["mid", "midi"].contains((path as NSString).pathExtension.lowercased())
    }

    public static func isSoundFont(path: String) -> Bool {
        (path as NSString).pathExtension.lowercased() == "sf2"
    }

    // MARK: 音声化(簡易シンセ)

    /// ノート列をモノラルサンプルに描く(決定的: 同じ入力なら毎回同じサンプル)。
    /// 音色は基音 + 2 倍音・3 倍音の減衰音。ベロシティで音量を変え、全体のピークを
    /// `BuiltInSounds.peakLevel` にそろえる(同梱効果音と同じ流儀)。
    public static func renderSamples(_ file: MidiFileData) -> [Float] {
        let sr = Double(sampleRate)
        let total = file.duration + tail
        // 防御: 総尺が上限を超える入力でも、確保するサンプルは maxSamples まで(prepare 経由では validate が先に弾く)。
        let nd = (total * sr).rounded()
        let n = nd.isFinite ? min(maxSamples, Int(nd)) : maxSamples
        guard n > 0 else { return [] }
        var out = [Double](repeating: 0, count: n)
        var noteSampleBudget = maxNoteSamples
        for note in file.notes {
            let sd = (note.start * sr).rounded()
            let start = sd.isFinite ? Int(sd) : -1
            // 減衰はノートの長さ + 0.35 秒でほぼ消えるようにする
            let length = note.duration + 0.35
            let cd = (length * sr).rounded()
            let count = cd.isFinite ? min(n - start, Int(cd)) : 0
            guard start >= 0, count > 0 else { continue }
            // 防御: ノートサンプルの総量が上限に達したら、それ以降のノートは描かない。
            guard noteSampleBudget > 0 else { break }
            let allowed = min(count, noteSampleBudget)
            noteSampleBudget -= allowed
            let f = note.frequency
            let gain = Double(note.velocity) / 127 * 0.5
            for i in 0..<allowed {
                let t = Double(i) / sr
                let env = min(1, t / 0.005) * exp(-3 * t / max(0.05, length))
                let phase = 2 * Double.pi * f * t
                out[start + i] += gain * env * (sin(phase) + 0.5 * sin(phase * 2) + 0.25 * sin(phase * 3))
            }
        }
        let peak = out.reduce(0.0) { max($0, abs($1)) }
        guard peak > 0 else { return [Float](repeating: 0, count: n) }
        let k = Double(BuiltInSounds.peakLevel) / peak
        return out.map { Float($0 * k) }
    }

    /// ノート列を WAV(44.1kHz・モノラル・16 ビット)に描く。
    public static func renderWAV(_ file: MidiFileData) -> Data {
        BuiltInSounds.wavData(renderSamples(file), sampleRate: sampleRate)
    }

    // MARK: マーカー

    /// ノートの開始ごとのマーカー(同じ開始のノートは 1 つにまとめ、名前は一番低い音 + 残りの数)。
    /// プロジェクトの時刻は `start`(クリップの置き場所)+ ノートの開始。
    public static func noteMarkers(for file: MidiFileData, at start: Double) -> [Marker] {
        var byStart: [(time: Double, notes: [MidiNote])] = []
        for note in file.notes {
            if let last = byStart.last, abs(last.time - note.start) < 1e-9 {
                byStart[byStart.count - 1].notes.append(note)
            } else {
                byStart.append((note.start, [note]))
            }
        }
        return byStart.prefix(markerLimit).map { group in
            let lowest = group.notes.map(\.pitch).min() ?? 60
            var name = "MIDI \(MidiNote.noteName(lowest))"
            if group.notes.count > 1 { name += " +\(group.notes.count - 1)" }
            return Marker(time: start + group.time, name: name)
        }
    }

    // MARK: キャッシュへの書き出しと配置

    /// キャッシュフォルダの名前(PSD と同じ決め方)。
    public static func cacheKey(path: String, modified: Date?, size: Int64?) -> String {
        PSDImporter.cacheKey(path: path, modified: modified, size: size)
    }

    /// MIDI を WAV に描いて `cacheDir` へ書き、そのパスとパース結果を返す。すでにあれば作り直さない
    /// (ただしパースは毎回行い、呼び出し側がノート数などを知れるようにする)。
    @discardableResult
    public static func prepare(atPath path: String, cacheDir: URL) throws -> (wavPath: String, file: MidiFileData) {
        try prepare(atPath: path, cacheDir: cacheDir, soundFontPath: nil)
    }

    /// SoundFont を指定できる版。`soundFontPath` が nil のときは従来の簡易シンセで、
    /// 従来のキャッシュ(rendered.wav)をそのまま使う(従来互換)。
    /// SoundFont を指定したときは、そのファイルの同一性(パス+更新日時+サイズ)から決まる
    /// 別名のキャッシュ(rendered-sf-<key>.wav)に描くので、簡易シンセのキャッシュと混ざらない。
    /// 取り込み上限ガード(総尺・ノート数)はどちらの経路でも同じく prepare が先に弾く。
    @discardableResult
    public static func prepare(atPath path: String, cacheDir: URL, soundFontPath: String?) throws -> (wavPath: String, file: MidiFileData) {
        let file = try MidiParser.parseFile(atPath: path)
        try validate(file)
        let fm = FileManager.default
        guard let soundFontPath else {
            let url = cacheDir.appendingPathComponent("rendered.wav")
            if let a = try? fm.attributesOfItem(atPath: url.path), (a[.size] as? NSNumber)?.intValue ?? 0 > 0 {
                return (url.path, file)
            }
            try fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            try renderWAV(file).write(to: url, options: .atomic)
            return (url.path, file)
        }
        let soundFont = try SoundFontParser.parseFile(atPath: soundFontPath)
        let sfAttrs = try? fm.attributesOfItem(atPath: soundFontPath)
        let sfKey = cacheKey(path: soundFontPath, modified: sfAttrs?[.modificationDate] as? Date,
                             size: (sfAttrs?[.size] as? NSNumber)?.int64Value)
        let url = cacheDir.appendingPathComponent("rendered-sf-\(sfKey).wav")
        if let a = try? fm.attributesOfItem(atPath: url.path), (a[.size] as? NSNumber)?.intValue ?? 0 > 0 {
            return (url.path, file)
        }
        try fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try SoundFontRenderer.renderWAV(file, soundFont: soundFont).write(to: url, options: .atomic)
        return (url.path, file)
    }

    /// 音声クリップを置き、ノートのマーカーも足す(呼び出し側の 1 回の編集に載せる前提の純粋関数)。
    /// 戻り値は置いた音声クリップの id。
    @discardableResult
    public static func place(wavPath: String, file: MidiFileData, at start: Double, in project: inout Project) -> [String] {
        // 生成した WAV は末尾の余韻(tail)まで含む。配置の長さもそろえないと、余韻が再生・書き出しで切れる
        let duration = max(0.05, file.duration + tail)
        let ids = ClipEditing.place(media: [(path: wavPath, kind: .audio, duration: duration)], at: start, in: &project)
        let markers = noteMarkers(for: file, at: start)
        if !markers.isEmpty {
            project.markers = MarkerEditing.sorted(project.markers + markers)
        }
        return ids
    }
}

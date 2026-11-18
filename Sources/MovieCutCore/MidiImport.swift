import Foundation

// MARK: - MIDI の取り込み(#5)
//
// 取り込んだ MIDI は 2 つの形でタイムラインに載せる:
//   1. 音声化: ノートを簡易シンセ(倍音つき正弦波 + 減衰)で WAV に描き、通常の音声クリップとして置く。
//      既存の音声基盤(再生・波形・書き出し・フェード・音量)がそのまま使える。SoundFont は使わない
//      (YMM4 の方式とは違う。到達範囲はここまでで、音色の再現はしない)。
//   2. マーカー: ノートの開始ごとにマーカーを置き、ノート情報(音名)をタイムライン上で辿れるようにする。

public enum MidiImporter {
    public static let sampleRate = 44100
    /// マーカーにするノート開始の上限(病的に多いファイルでマーカーが爆発しないように)。
    public static let markerLimit = 1000
    /// 音の余韻(秒)。最後のノートの後ろに足す。
    public static let tail = 0.5

    public static func isMIDI(path: String) -> Bool {
        ["mid", "midi"].contains((path as NSString).pathExtension.lowercased())
    }

    // MARK: 音声化(簡易シンセ)

    /// ノート列をモノラルサンプルに描く(決定的: 同じ入力なら毎回同じサンプル)。
    /// 音色は基音 + 2 倍音・3 倍音の減衰音。ベロシティで音量を変え、全体のピークを
    /// `BuiltInSounds.peakLevel` にそろえる(同梱効果音と同じ流儀)。
    public static func renderSamples(_ file: MidiFileData) -> [Float] {
        let sr = Double(sampleRate)
        let total = file.duration + tail
        let n = Int((total * sr).rounded())
        guard n > 0 else { return [] }
        var out = [Double](repeating: 0, count: n)
        for note in file.notes {
            let start = Int((note.start * sr).rounded())
            // 減衰はノートの長さ + 0.35 秒でほぼ消えるようにする
            let length = note.duration + 0.35
            let count = min(n - start, Int((length * sr).rounded()))
            guard start >= 0, count > 0 else { continue }
            let f = note.frequency
            let gain = Double(note.velocity) / 127 * 0.5
            for i in 0..<count {
                let t = Double(i) / sr
                let env = min(1, t / 0.005) * exp(-3 * t / max(0.05, length))
                let phase = 2 * Double.pi * f * t
                out[start + i] += gain * env * (sin(phase) + 0.5 * sin(phase * 2) + 0.25 * sin(phase * 3))
            }
        }
        let peak = out.map { abs($0) }.max() ?? 0
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
        let file = try MidiParser.parseFile(atPath: path)
        let fm = FileManager.default
        let url = cacheDir.appendingPathComponent("rendered.wav")
        if let a = try? fm.attributesOfItem(atPath: url.path), (a[.size] as? NSNumber)?.intValue ?? 0 > 0 {
            return (url.path, file)
        }
        try fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try renderWAV(file).write(to: url, options: .atomic)
        return (url.path, file)
    }

    /// 音声クリップを置き、ノートのマーカーも足す(呼び出し側の 1 回の編集に載せる前提の純粋関数)。
    /// 戻り値は置いた音声クリップの id。
    @discardableResult
    public static func place(wavPath: String, file: MidiFileData, at start: Double, in project: inout Project) -> [String] {
        let duration = max(0.05, file.duration)
        let ids = ClipEditing.place(media: [(path: wavPath, kind: .audio, duration: duration)], at: start, in: &project)
        let markers = noteMarkers(for: file, at: start)
        if !markers.isEmpty {
            project.markers = MarkerEditing.sorted(project.markers + markers)
        }
        return ids
    }
}

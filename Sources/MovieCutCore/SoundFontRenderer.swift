import Foundation

// MARK: - SoundFont による MIDI のレンダリング(R2-4)
//
// パース済み SoundFont のサンプルを、MIDI のノート列に沿ってモノラルサンプルへ描く。
// 簡易シンセ(MidiImporter.renderSamples)と同じ約束を守る:
//   - 標本化周波数・余韻(tail)・総尺/ノートサンプルの上限ガードは簡易シンセと共通。
//   - 決定的(同じ入力なら毎回同じサンプル)。全体のピークを BuiltInSounds.peakLevel にそろえる。
//   - 出力はモノラル。ステレオサンプル対は左右ともリージョンとして拾い、混ぜて畳む。
//     pan は定位ではなく減衰として近似する(定位そのものは再現しない)。
//
// 再現する範囲: サンプルの線形補間リサンプリング、ループ(sampleModes 1 = 連続、
// 3 = リリースでループを抜ける)、音量エンベロープ(delay/attack/hold/decay/sustain/release、
// dB 直線の decay/release)、ベロシティ、initialAttenuation、チューニング一式。
// 再現しない範囲: モジュレータ、フィルタ、LFO、エフェクトセンド、exclusiveClass。

public enum SoundFontRenderer {
    /// ノート列を SoundFont の音色でモノラルサンプルに描く。
    public static func renderSamples(_ file: MidiFileData, soundFont: SoundFont) -> [Float] {
        let sr = Double(MidiImporter.sampleRate)
        let total = file.duration + MidiImporter.tail
        // 防御: 非有限の総尺でも Int 変換で落とさない(簡易シンセ renderSamples と同じ)
        let nd = (total * sr).rounded()
        let n = nd.isFinite ? min(MidiImporter.maxSamples, Int(nd)) : MidiImporter.maxSamples
        guard n > 0 else { return [] }
        var out = [Double](repeating: 0, count: n)
        var noteSampleBudget = MidiImporter.maxNoteSamples

        for note in file.notes {
            guard noteSampleBudget > 0 else { break }
            guard let (region, header) = soundFont.region(bank: note.bank, program: note.program,
                                                           key: note.pitch, velocity: note.velocity) else { continue }
            let sd = (note.start * sr).rounded()
            guard sd.isFinite, sd >= 0, sd < Double(n), note.duration.isFinite else { continue }
            let voice = Voice(region: region, header: header, note: note)
            let start = Int(sd)
            // 声の長さの上限: ノート長 + リリース。ループ無しならサンプルの残り長でも止まる。
            let pd = ((note.duration + voice.releaseSeconds + 0.05) * sr).rounded()
            guard pd.isFinite else { continue }
            let planned = Int(min(pd, Double(n)))
            let allowed = min(n - start, planned, noteSampleBudget)
            guard allowed > 0 else { continue }
            noteSampleBudget -= allowed
            voice.render(into: &out, start: start, count: allowed, sampleRate: sr, samples: soundFont.samples)
        }

        let peak = out.reduce(0.0) { max($0, abs($1)) }
        guard peak > 0 else { return [Float](repeating: 0, count: n) }
        let k = Double(BuiltInSounds.peakLevel) / peak
        return out.map { Float($0 * k) }
    }

    /// ノート列を SoundFont の音色で WAV(44.1kHz・モノラル・16 ビット)に描く。
    public static func renderWAV(_ file: MidiFileData, soundFont: SoundFont) -> Data {
        BuiltInSounds.wavData(renderSamples(file, soundFont: soundFont), sampleRate: MidiImporter.sampleRate)
    }

    // MARK: - 声 1 つ分の描画

    private struct Voice {
        // サンプル位置(実数インデックス)と進み幅
        var startPos: Double
        var endPos: Double
        var loopStart: Double
        var loopEnd: Double
        var loopMode: Int          // 0 = ループなし, 1 = 連続, 3 = リリースで抜ける
        var step: Double           // 出力 1 サンプルあたりの進み
        var gain: Double
        // エンベロープ(秒 / dB)
        var delay: Double
        var attack: Double
        var hold: Double
        var decay: Double
        var sustainLevel: Double   // 振幅比(1 = 減衰なし)
        var sustainDb: Double
        var releaseSeconds: Double
        var noteOffLevel: Double   // ノートオフ時点の振幅比
        var releaseStart: Double   // ノートの長さ(= リリース開始時刻)

        init(region: SF2Region, header: SF2SampleHeader, note: MidiNote) {
            let g = region.gens
            func gen(_ oper: UInt16, _ def: Int) -> Int { g[oper] ?? def }
            // 位置: オフセット(粗 = 32768 単位)をサンプルヘッダへ足す
            let start = header.start + gen(0, 0) + gen(4, 0) * 32768
            let end = header.end + gen(1, 0) + gen(12, 0) * 32768
            startPos = Double(max(0, start))
            endPos = Double(max(0, end))
            loopStart = Double(max(0, header.startLoop + gen(2, 0) + gen(45, 0) * 32768))
            loopEnd = Double(max(0, header.endLoop + gen(3, 0) + gen(50, 0) * 32768))
            loopMode = gen(54, 0) & 3
            if loopEnd <= loopStart { loopMode = 0 }

            // 音程: ルートキー(overridingRootKey があれば優先)との差 + チューニング
            let rootKey = (0...127).contains(gen(58, -1)) ? gen(58, -1) : header.originalPitch
            let scaleTuning = Double(gen(56, 100))
            let cents = Double(note.pitch - rootKey) * scaleTuning
                + Double(gen(51, 0)) * 100 + Double(gen(52, 0)) + Double(header.pitchCorrection)
            let sampleRate = header.sampleRate > 0 ? Double(header.sampleRate) : Double(MidiImporter.sampleRate)
            step = pow(2, cents / 1200) * sampleRate / Double(MidiImporter.sampleRate)

            // 音量: ベロシティ × initialAttenuation(センチベル)× pan のモノラル近似
            let attenuation = pow(10, -Double(gen(48, 0)) / 200)
            let pan = min(500, max(-500, gen(17, 0)))
            let panGain = 1 - 0.25 * abs(Double(pan)) / 500
            gain = Double(note.velocity) / 127 * attenuation * panGain

            // エンベロープ(timecents → 秒。keynumToVolEnvHold/Decay はキー 60 からの差で補正)
            func seconds(_ oper: UInt16, keyAdjustOper: UInt16? = nil) -> Double {
                var tc = gen(oper, -12000)
                if let adj = keyAdjustOper { tc += (note.pitch - 60) * gen(adj, 0) }
                return pow(2, Double(min(8000, max(-12000, tc))) / 1200)
            }
            delay = seconds(33)
            attack = seconds(34)
            hold = seconds(35, keyAdjustOper: 39)
            decay = seconds(36, keyAdjustOper: 40)
            let sustainCb = min(1440, max(0, gen(37, 0)))
            sustainDb = -Double(sustainCb) / 10
            sustainLevel = pow(10, sustainDb / 20)
            releaseSeconds = seconds(38)
            releaseStart = note.duration
            noteOffLevel = Self.envelopeLevel(at: note.duration, delay: delay, attack: attack, hold: hold,
                                              decay: decay, sustainDb: sustainDb, sustainLevel: sustainLevel)
        }

        /// ノート開始からの時刻 t におけるエンベロープ振幅比(リリース前)。
        func level(at t: Double) -> Double {
            Self.envelopeLevel(at: t, delay: delay, attack: attack, hold: hold,
                               decay: decay, sustainDb: sustainDb, sustainLevel: sustainLevel)
        }

        static func envelopeLevel(at t: Double, delay: Double, attack: Double, hold: Double,
                                  decay: Double, sustainDb: Double, sustainLevel: Double) -> Double {
            if t < delay { return 0 }
            let t1 = t - delay
            if t1 < attack { return attack > 0 ? t1 / attack : 1 }
            let t2 = t1 - attack
            if t2 < hold { return 1 }
            let t3 = t2 - hold
            if t3 < decay {
                guard decay > 0, sustainDb < 0 else { return 1 }
                return pow(10, (sustainDb * (t3 / decay)) / 20)
            }
            return sustainLevel
        }

        func render(into out: inout [Double], start: Int, count: Int, sampleRate sr: Double, samples: [Int16]) {
            var pos = startPos
            for i in 0..<count {
                let t = Double(i) / sr
                // エンベロープ(リリースはノートオフ時点のレベルから -100dB へ直線)
                var level: Double
                if t <= releaseStart {
                    level = self.level(at: t)
                } else {
                    let rt = t - releaseStart
                    guard rt < releaseSeconds, releaseSeconds > 0 else { break }
                    let offDb = noteOffLevel > 1e-5 ? 20 * log10(noteOffLevel) : -100
                    let db = offDb + (-100 - offDb) * (rt / releaseSeconds)
                    level = pow(10, db / 20)
                }
                if level > 0 {
                    // ループ処理(モード 3 はリリース後にループを抜ける)
                    let looping = loopMode == 1 || (loopMode == 3 && t <= releaseStart)
                    if looping, pos >= loopEnd {
                        let span = loopEnd - loopStart
                        if span > 0 { pos = loopStart + (pos - loopStart).truncatingRemainder(dividingBy: span) }
                    }
                    if pos >= endPos { break }
                    out[start + i] += gain * level * interpolated(samples, at: pos)
                }
                pos += step
                if loopMode == 0, pos >= endPos { break }
            }
        }

        /// 線形補間サンプル値(-1〜1)。
        func interpolated(_ samples: [Int16], at pos: Double) -> Double {
            let i0 = Int(pos)
            guard i0 >= 0, i0 < samples.count else { return 0 }
            let frac = pos - Double(i0)
            let s0 = Double(samples[i0]) / 32768
            if frac == 0 || i0 + 1 >= samples.count { return s0 }
            let s1 = Double(samples[i0 + 1]) / 32768
            return s0 + (s1 - s0) * frac
        }
    }
}

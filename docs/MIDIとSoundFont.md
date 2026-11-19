# MIDI と SoundFont(R2-4)

MIDI ファイル(.mid / .midi)の取り込みと、SoundFont(.sf2)による音色再現の到達範囲。

## 取り込みの流れ(従来どおり)

- メニュー「MIDIを読み込む…」、素材の追加、ドラッグ&ドロップのいずれでも取り込める。
- パースは自前 SMF パーサ(`MidiParser`、外部依存なし)。テンポマップ(PPQ / SMPTE 両対応)で
  ノートを秒単位に直し、WAV に描いて通常の音声クリップとして置く。ノート開始はマーカーにもなる。
- 取り込み上限ガードは従来のまま: 総尺 600 秒・ノート 5 万個を超えるファイルは弾く
  (`MidiImporter.validate`。SoundFont 経路でも同じ)。

## 音色の 2 系統

| 経路 | 音色 | 備考 |
|---|---|---|
| 簡易シンセ(既定) | 基音 + 2 倍音・3 倍音の減衰音 | 従来どおり。SoundFont 未指定時の出力は従来と同一 |
| SoundFont(任意指定) | .sf2 のプリセットのサンプル | R2-4 で追加。下記 |

### SoundFont の指定方法

- 「MIDIを読み込む…」パネルのアクセサリ「SoundFont (.sf2) を選ぶ…」から 1 つ選ぶ。
  未選択なら簡易シンセ。選択はそのパネルを開いている間だけ有効で、設定には保存しない。
- CLI: `moviecut-cli midi-render <file.mid> --out <file.wav> --sf2 <file.sf2>`。
  プリセット一覧は `moviecut-cli sf2-info <file.sf2>`。
- キャッシュは簡易シンセと分ける: SoundFont 経路は `rendered-sf-<sf2の同一性キー>.wav`、
  簡易シンセは従来の `rendered.wav`。混ざることはない。

### プリセットの選び方

- MIDI パーサがプログラムチェンジとバンクセレクト(CC#0 = MSB、CC#32 = LSB)を拾い、
  ノートごとに「ノートオン時点で有効だった (bank, program)」を記録する
  (`MidiNote.program` / `MidiNote.bank`、`MidiFileData.programChanges`)。
- バンク指定が無いチャンネル 10(インデックス 9)はドラム用に bank 128 として扱う。
- プリセットが見つからないときは (bank, program) → (0, program) → (0, 0) の順に
  フォールバックする。どこにも無ければそのノートは無音になる(簡易シンセには落ちない)。

## 実装方式と判断

- **自前 .sf2 パーサ + 自前サンプル再生**(`SoundFont.swift` / `SoundFontRenderer.swift`、
  MovieCutCore、Foundation のみ)。
- AVAudioUnitSampler は SoundFont を読み込めるが、オフラインで WAV 化するには
  AVAudioEngine のマニュアルレンダリングとスケジューリングが要り、音響デバイスや
  実行環境に左右されてヘッドレスの単体テスト / CLI で決定的に検証しにくい。
  既存の MIDI 基盤(パーサ・簡易シンセ)が「決定的な純関数」である流儀に合わせ、
  同じ形で到達できる自前実装を選んだ。

## 到達範囲(SoundFont 経路で再現するもの)

- プリセット/楽器ゾーンの解決(グローバルゾーン、keyRange / velRange)。
  プリセット側ジェネレータは仕様どおり楽器側へ加算(範囲・リンク系は楽器側優先)。
- サンプル再生: 線形補間リサンプリング、開始/終了/ループ位置(粗オフセット含む)、
  sampleModes(1 = 連続ループ、3 = リリースでループを抜ける)。
- 音量エンベロープ: delay / attack / hold / decay / sustain / release(timecents、
  decay・release は dB 直線、keynumToVolEnvHold / Decay の補正含む)。
- initialAttenuation、ベロシティ、coarseTune / fineTune / scaleTuning /
  overridingRootKey / サンプルの pitchCorrection。
- 出力は簡易シンセと同じ約束: 44.1kHz モノラル WAV、余韻 0.5 秒、ピーク正規化、
  総尺・ノートサンプルの上限ガード、決定的な出力。

## 未達・留保

- モジュレータ、フィルタ(initialFilterFc/Q)、LFO(mod/vib)、コーラス/リバーブセンド、
  exclusiveClass(ハイハットの排他など)は再現しない。
- 出力はモノラルのため、ステレオサンプル対は左右を混ぜて畳み、pan は定位ではなく
  減衰として近似する。
- 24 ビットサンプル(sm24)は 16 ビットとして読む。
- チャンネルのプログラム/バンク状態はトラックをまたいで辞書を共有する近似
  (通常の SMF は同一トラック内で完結するため実用上問題ない)。
- SoundFont は同梱しない(ユーザーが手持ちの .sf2 を指定する形)。同梱候補としては
  ライセンスが明確な小さい GM フォント(例: GeneralUser GS〈独自の無料ライセンス〉、
  MuseScore General〈MIT〉)があるが、再配布条件の確認が済むまで入れない。
  検証では TimGM6mb(約 6MB、136 プリセット/520 サンプル)で読み込みと描画を確認した
  (検証用に一時取得しただけで、リポジトリには含めていない)。

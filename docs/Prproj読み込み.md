# Premiere Pro プロジェクト(.prproj)の読み込み

Premiere Pro のプロジェクトファイル `.prproj` を MovieCut のプロジェクトとして読み込む機能の仕様と対応範囲。実装は `Sources/MovieCutCore/PrprojImport.swift`(`PrprojImporter`)。書き出し(.prproj への出力)は対象外で、読み込みだけを行う。

導線:

- アプリ: ファイル ▸「Premiere Pro プロジェクト(.prproj)を読み込む…」(今のプロジェクトを置き換え、1 回の Undo で戻せる)
- CLI: `moviecut-cli import-prproj <in.prproj> <out.mcpjc>`
- どちらも、対応できなかった要素は理由つきの変換レポートとして必ず提示する(黙って落とさない。FCP XML 読み込みと同じ作法)

## 形式の根拠(推測で書いていない)

Adobe 公式の仕様書は公開されていないため、公開資料と実ファイル調査の記録で裏取りした。

- 米国国立公文書館(NARA)の形式登録 NF00818: .prproj は XML ベースで GZIP 圧縮。
- Adobe コミュニティでの Adobe 側回答: CC 以降は gzip 圧縮された XML。
- prproj-parser(GitHub: catastrofia/prproj-parser)の形式ノート `docs/prproj-format/`(実ファイル群を直接調査した記録。Premiere Pro 2023〜2026、プロジェクト形式バージョン 40/42/43/45 で確認): オブジェクトグラフの構造、tick 定数、参照連鎖、Motion のパラメータ ID、2026 形式での `<Start>` 省略などを本実装の根拠にした。
- redrob-film(GitHub: redrob-labs/redrob-film)の prproj リーダー実装: プロジェクト形式バージョン 22〜45 の実サンプルから起こした読み込みで、Motion(Position は画面に対する割合、Scale はパーセント、Rotation は度)、Opacity、Volume の Level(線形値で 1.0 = +15dB)の解釈が上記ノートと一致することを相互確認した。

### 形式の要点

- 実体は UTF-8 XML。先頭 2 バイトが `1F 8B` なら gzip 圧縮、そうでなければ素の XML(どちらも Premiere が出しうる)。ルートは `<PremiereData Version="3">`。
- 中身は入れ子の木ではなく、`<PremiereData>` 直下に平らに並んだオブジェクトのグラフ。各オブジェクトは `ObjectID`(整数)か `ObjectUID`(UUID)を持ち、`ObjectRef` / `ObjectURef` 属性で相互参照する。ObjectID は直下の要素の間でのみ一意(UI 設定内の深い要素と衝突しうる)ため、索引は直下の要素だけから作る。
- 時刻はすべて tick 単位。**254,016,000,000 tick = 1 秒**(全レート共通)。
- 参照連鎖(タイムラインのクリップから素材ファイルまで):
  `Sequence` →(TrackGroups: Index 0=映像 / 1=音声 / 2=データ)→ `VideoTrackGroup` / `AudioTrackGroup` →(Tracks)→ `VideoClipTrack` / `AudioClipTrack` →(ClipItems/TrackItems)→ `VideoClipTrackItem` / `AudioClipTrackItem`(配置は ClipTrackItem/TrackItem の Start・End)→ `SubClip`(表示名、`Clip` と `MasterClip` への参照)→ `VideoClip` / `AudioClip`(Clip の InPoint・OutPoint・PlaybackSpeed)→ `VideoMediaSource` / `AudioMediaSource` →(MediaSource/Media)→ `Media`(FilePath、Start=素材の開始タイムコード)。
- 素材内の使用開始位置は `InPoint − Media の Start` で求める。カメラ素材は開始タイムコードが 1 時間(3600 秒)等になり、InPoint がそのままでは巨大な値になるため、この差し引きが必須。

## 対応表

| Premiere の要素 | MovieCut への対応 | 備考 |
|---|---|---|
| シーケンス(主シーケンス) | プロジェクト全体 | クリップのある最初のシーケンスを主シーケンスにする |
| 他のシーケンス | 読み込まない | レポートに理由つきで残す(MovieCut は 1 本のタイムライン + シーンのモデルで、本実装ではシーンへの振り分けはしない) |
| VideoTrackGroup の FrameRate | プロジェクトの fps | 1 コマあたりの tick 数から換算 |
| VideoTrackGroup の FrameRect | 画面サイズ(幅・高さ) | 左,上,右,下 の差分 |
| 映像・音声トラック | レイヤー(V1… / A1…) | 順序を保持 |
| トラックの IsLocked / IsMuted | レイヤーのロック / 非表示・ミュート | |
| ClipTrackItem の Start / End | クリップの開始・長さ | Start が無い(2026 形式で 0 のとき省略)場合は 0 として扱う |
| VideoClip の InPoint / OutPoint | 使用開始(offset)・素材の長さの手がかり | Media の Start を差し引く。静止画は offset 0 |
| Media の FilePath | 素材参照(src)・素材プール | Windows パスはスラッシュへ変換(ドライブ文字はそのまま。再リンクで対応付けする旨を注記) |
| VideoStream の Duration / MediaSource の OriginalDuration | 素材の長さ(srcDuration) | 先に見つかった方 |
| 静止画(IsStill / 画像の拡張子) | 画像クリップ | |
| MasterClip の IsAdjustmentLayer | 調整レイヤークリップ | |
| クリップの IsMuted | クリップの無効化 | |
| PlaybackSpeed(一定速度) | 速度(speed) | MovieCut の範囲 0.25〜4 に収め、範囲外は注記。負の値は逆再生 |
| Motion: Position(割合の点) | x / y(中心 0.5 の割合) | そのまま対応する |
| Motion: Scale(パーセント) | scale(倍率) | 100% = 1.0 |
| Motion: Rotation(度) | rotation | |
| Opacity: Opacity(パーセント) | opacity | 100% = 1.0 |
| Volume: Level(1.0 = +15dB の線形値) | volume(線形ゲイン) | dB = 20·log10(Level) + 15 として換算 |
| シーケンスのマーカー(DVAMarker JSON) | マーカー | 種類(Comment 以外)は通常のマーカーとして取り込み、注記する |

## 落ちる要素一覧(すべて変換レポートに理由つきで残る)

- 主シーケンス以外のシーケンス
- トランジション(TransitionItems の各トランジション。カットとして扱う)
- Motion / Opacity / Volume 以外のエフェクト全般(Lumetri Color など。エフェクト名を残す)
- キーフレームのあるパラメータ(静止値だけを取り込み、キーフレームがあった項目を注記する)
- 横だけのスケール(Scale Width、Uniform Scale オフ時)、アンカーポイント、Opacity のブレンドモード(Normal 以外)
- 速度ランプ(TimeRemapping。可変速度は取り込まず一定速度として扱う)
- 入れ子(ネスト)になったシーケンス(VideoSequenceSource / AudioSequenceSource を引くクリップ)
- 字幕(キャプション)トラック(DataTrackGroup)
- 実ファイルを持たない生成素材(カラーマット、Black Video、バー&トーン、タイトル/グラフィック等。FilePath が内部 ID の数字だけのもの)
- クリップに付けられたマーカー(シーケンスのマーカーだけを取り込む)
- シーケンスの開始タイムコード(MZ.ZeroPoint。タイムラインは 0 秒から始まる)
- リンク(映像と音声の連動)、トラックミキサー、マルチカメラ、Essential Graphics の中身など、上表に無い要素すべて

## エラーになる場合(黙って空にはしない)

- 空のファイル / gzip が壊れている(CRC32・展開サイズを照合する) / XML として壊れている → 明示エラー
- `<PremiereData>` が無い(別形式。例: FCP XML) → 「.prproj ではありません」エラー
- シーケンスが 1 つも無い → 明示エラー
- 配置(End)が読めない・長さ 0 のクリップ、素材(Media)が見つからないクリップは、そのクリップだけを落としてレポートに残す

## 未検証事項・既知の制限

- **実 Premiere Pro のファイルでの検証は未実施。** 本実装のフィクスチャは、公開資料の実例構造に沿って自作したもので、実機の Premiere Pro(どのバージョンでも)が出力した実ファイルでの読み込み確認はしていない。実ファイルが手に入ったら、まず小さなプロジェクト(1 シーケンス・数クリップ・Motion/Opacity 変更あり)で配置と変換の一致を確認すること。
- バージョン差: 形式ノートで確認できたのはプロジェクト形式バージョン 40〜45(Premiere Pro 2023〜2026 相当)。それより古い形式(CS6 以前など)や今後のバージョンでは、要素の有無や省略のされ方が違う可能性がある。2026 形式(バージョン 45)では `<Start>0</Start>` が要素ごと省略されることを確認済みで対応している。要素の `Version` 属性はバージョンごとに変わるため、本実装はタグ名だけで照合し、`Version` には依存していない。
- 大きなファイル: 展開後の XML が 1GiB を超えるものはエラーにする(gzip 爆弾対策)。実プロジェクトでは数百 MB 級もありうるため、上限に当たった場合は上限の見直しとストリーミング化が要る。
- 素材パスの対応付け: Premiere の FilePath は作成環境の絶対パス(Windows 含む)。MovieCut 側での再リンクは既存の素材再リンク機能に任せており、本読み込みではパスの文字列変換(バックスラッシュ→スラッシュ)までしかしない。
- Position の解釈: Motion の Position は「シーケンス画面に対する割合」で、中心が (0.5, 0.5)。MovieCut の x / y と同じ定義として取り込んでいるが、素材のアスペクトやアンカーポイントが中心でない場合は見た目がずれる可能性がある(アンカーポイント自体は取り込まない)。
- 音量の換算: Volume の Level は「1.0 = +15dB」の解釈に基づく(複数実装で一致)。Premiere の表示 dB との厳密な一致は実機未検証。
- マーカーの DVAMarker JSON の細部(色、種類の詳細)は取り込んでいない。

# MovieCut デザイン統一パス（feat/ui-unify）

- 実施日: 2026-11-19
- 起点: `feat/muse-access` 054e6b9（UI刷新案＝ツールバーの SF Symbols 化・配色の意味トークン集約・下部ステータスバー・節の開閉化・空状態カード、の統合後）
- 目的: メイン画面（ContentView / InspectorView / TimelineView）以外の画面を、刷新後のデザイン言語に統一する。ユーザーの指示「統一感欲しい」への対応。
- 前提資料: `~/workspace/moviecut-overnight-2026-11-19/UI-AUDIT.md`（問題点28件。うち U-01「DesignSystem トークンの未適用」が本パスの主対象）

## 統一の基準（刷新後のデザイン言語）

1. **色**: `MCDesign.Color` の意味トークン（background / panelBackground / barBackground / divider / textSecondary / textTertiary / fieldBackground / accent、ほか label / secondaryLabel / destructive / selection / separator / window / control / underPage）を使い、`Color(nsColor:)` 等の直書きを排除する。アクセントは `Color.accentColor` 系に統一。
2. **フォント**: `MCDesign.Font` のトークン（largeTitle / title / title2 / title3 / headline / body / callout / calloutSemibold / subheadline / footnote / caption / badge / monospaced）に寄せ、`.system(size:)` の直書きリテラルを排除する。
3. **ボタン・操作要素**: SF Symbols アイコン＋ラベルの流儀に統一。絵文字・記号文字をアイコン代わりにしているものがあれば置き換える。ただしシート内の標準ボタン（キャンセル／完了など）は macOS の慣例どおり文言ボタンのまま。
4. **節見出し・区切り・余白**: メイン画面（InspectorView の節）のリズムに揃える。見出しは headline 相当＋既定色または textSecondary、余白は 8pt グリッド（MCDesign.Spacing: 4/8/12/16/24）。
5. **空状態**: 未選択・データなしの表示は、刷新で入った `InspectorGuideCard`（アイコン＋見出し＋説明、InspectorView.swift 定義・同一モジュールから再利用可）の流儀に揃える。

## 対象外（触らない）

- タイムラインの機能色 `TimelinePalette`（TimelineView.swift）
- 機能ロジック・モデル・合成・書き出しの挙動すべて（見た目と文言の統一のみ）
- 製品名表記（U-02「Movie Cut / MovieCut」の揺れ）はユーザーの名称決定待ちのため対象外
- ContentView / InspectorView / TimelineView の本体（刷新済み）。ただし ContentView.swift 内の `SettingsSheet` は独立した画面として対象に含める
- `TextGenerationDialogs.swift`: NSAlert ベースの AppKit ダイアログで、システム外観に従うため SwiftUI トークン統一の対象外
- `AppMenu.swift` / `AppCommands.swift` のメニュー本体: システム描画のため対象外（文言の確認のみ）
- `PreviewView.swift` のキャンバス描画色・ `SoundLevelMeterView.swift` のメーター色: 機能色として対象外（ラベル等のクローム部分のみ対象）

## 対象画面の棚卸し

凡例: font = `.system(size:` 直書き件数（起点時点）、nscolor = `Color(nsColor:` 直書き件数（同）。

### A. インスペクタ系（メイン画面の右パネルに載る別ファイル群）

| ファイル | font | nscolor | 主な統一ポイント |
|---|---|---|---|
| AudioFxExtendedInspector.swift | 17 | 0 | フォントトークン化 |
| AudioFxInspector.swift | 10 | 0 | フォントトークン化 |
| TextStyleInspector.swift | 11 | 0 | フォントトークン化 |
| InspectorRig.swift | 11 | 2 | フォント＋色トークン化 |
| InspectorTachie.swift | 7 | 0 | フォントトークン化 |
| CameraInspector.swift | 0 | 0 | 様式確認（見出し・余白・空状態） |
| ClipNoteField.swift | 1 | 0 | フォントトークン化 |
| EaseCurveEditor.swift | 4 | 0 | フォントトークン化（イージング曲線エディタ。初版の棚卸し表から漏れていたため検証時に追加） |

### B. シート／ダイアログ

| ファイル | font | nscolor | 主な統一ポイント |
|---|---|---|---|
| VoicevoxAccentSheet.swift | 8 | 0 | フォントトークン化 |
| DiarizationSheet.swift | 5 | 0 | フォントトークン化、空状態 |
| DialogueSuggestionSheet.swift | 4 | 0 | フォントトークン化 |
| ReadingDictionarySheet.swift | 4 | 0 | フォントトークン化、空状態（辞書なし） |
| ScriptTableSheet.swift | 4 | 0 | フォントトークン化 |
| VoicePresetSheet.swift | 4 | 0 | フォントトークン化 |
| AudioLibrarySheet.swift | 2 | 0 | フォントトークン化、空状態（素材なし）。素材ブラウザウィンドウ（MediaBrowserWindow）がホストする中身 |
| TachieSheets.swift | 3 | 0 | フォントトークン化。立ち絵リスト節は刷新済み、それ以外のシート部分が対象 |
| FillerCutSheet.swift | 1 | 0 | フォントトークン化 |
| FindReplaceSheet.swift | 1 | 0 | フォントトークン化 |
| ShortcutSheet.swift | 1 | 0 | フォントトークン化 |
| SubclipBatchSheet.swift | 1 | 0 | フォントトークン化 |
| AIDialogs.swift | 0 | 0 | 様式確認 |
| CandidateSwapSheet.swift | 0 | 0 | 様式確認 |
| ClipListSheet.swift | 0 | 0 | 様式確認、空状態 |
| LoudnessSheet.swift | 0 | 0 | 様式確認 |
| MulticamSheets.swift | 0 | 0 | 様式確認 |
| NoteListSheet.swift | 0 | 0 | 様式確認、空状態 |
| OutputSheets.swift | 0 | 0 | 様式確認（書き出し系シート群） |
| PitchLayoutSheets.swift | 0 | 0 | 様式確認 |
| RelinkResultSheet.swift | 0 | 0 | 様式確認 |
| RollSlipSheet.swift | 0 | 0 | 様式確認 |
| SceneListSheet.swift | 0 | 0 | 様式確認、空状態 |
| ScopeSheet.swift | 0 | 0 | 様式確認 |
| ScreenRecordingSheet.swift | 0 | 0 | 様式確認 |
| SubtitleQuickSheet.swift | 0 | 0 | 様式確認 |
| TakeCompareSheet.swift | 0 | 0 | 様式確認 |
| TranscriptEditSheet.swift | 0 | 0 | 様式確認 |
| UnusedMediaSheet.swift | 0 | 0 | 様式確認、空状態 |

### C. ウィンドウ／パネル／その他

| ファイル | font | nscolor | 主な統一ポイント |
|---|---|---|---|
| DockViews.swift | 3 | 3 | フォント＋色トークン化 |
| MediaThumbnail.swift | 1 | 0 | フォントトークン化 |
| DependencyBanner.swift | 1 | 0 | フォントトークン化 |
| SettingsSheet（ContentView.swift 内） | 0 | 0 | 様式確認（見出し・余白） |
| WelcomeWindow.swift | 0 | 0 | 様式確認。製品名表記は対象外（名称決定待ち） |
| ExportPanel.swift | 0 | 0 | 様式確認（書き出しパネル） |
| ExportQueueController.swift | 0 | 0 | 様式確認（書き出しキュー表示） |
| DockWindows.swift | 0 | 0 | 様式確認 |
| PreviewView.swift | 0 | 0 | クローム部分（ヒント・オーバーレイ文言）のみ様式確認。キャンバス描画は対象外 |
| SoundLevelMeterView.swift | 3 | 0 | ラベルのフォントトークン化のみ。メーター色は機能色として対象外 |
| VST3Panel.swift | 0 | 0 | 様式確認（プラグインパネル）。空状態（VST3なし） |
| AppCommands.swift | 0 | 0 | 様式確認（ビューを含む場合のみ）。メニュー本体は対象外 |

## フォント対応表（直書き → トークン）

| 直書き | トークン |
|---|---|
| size 26 | MCDesign.Font.largeTitle |
| size 22 | MCDesign.Font.title |
| size 17 | MCDesign.Font.title2 |
| size 15 | MCDesign.Font.title3 |
| size 13, weight .semibold | MCDesign.Font.headline |
| size 13 | MCDesign.Font.body |
| size 12, weight .semibold | MCDesign.Font.calloutSemibold |
| size 12 | MCDesign.Font.callout |
| size 11 | MCDesign.Font.subheadline |
| size 10, weight .semibold | MCDesign.Font.badge |
| size 10 | MCDesign.Font.footnote（補足ラベルの役割なら caption） |
| design .monospaced | MCDesign.Font.monospaced(size)（トークン経由なので可） |
| 上記に無いサイズ | 役割を見て最も近いテキストスタイルへ。数値表示で等幅のものは monospaced を維持。寄せられないものは無理に変えず本ドキュメントに残す |

## 色対応表（直書き → トークン）

| 直書き | トークン |
|---|---|
| Color(nsColor: .separatorColor) | MCDesign.Color.divider |
| Color(nsColor: .secondaryLabelColor) | MCDesign.Color.textSecondary |
| Color(nsColor: .tertiaryLabelColor) | MCDesign.Color.textTertiary |
| Color(nsColor: .textBackgroundColor) | MCDesign.Color.fieldBackground |
| Color(nsColor: .windowBackgroundColor) | MCDesign.Color.background（面の役割で panelBackground） |
| Color(nsColor: .controlBackgroundColor) | MCDesign.Color.control |
| Color(nsColor: .underPageBackgroundColor) | MCDesign.Color.barBackground |
| 対応が無いもの | 残して本ドキュメントに記録する |

## 実施結果

### 集計（起点 27cd75b → 最終コミット）

- 変更ファイル: 31（`Sources/MovieCut/` 配下）
- `.system(size:)` 直書き: 101 件をトークン化（新規の直書きは 0）
- `Color(nsColor:)` 直書き: 5 件をトークン化（`DockViews` 3、`InspectorRig` 2）
- 空状態をガイドカード化: 19 箇所（下表の各ファイル参照）
- 数値はファイル単位の diff から数えた。目視確認は未実施（後述の留保を参照）。

### A. インスペクタ系

- **AudioFxExtendedInspector.swift** — 変更あり。フォント 17 件（節見出し 12pt semibold → `calloutSemibold`、補足 11pt → `subheadline`）。色の直書き無し。
- **AudioFxInspector.swift** — 変更あり。フォント 10 件（同じ対応）。
- **TextStyleInspector.swift** — 変更あり。フォント 11 件（チェックボックス 12pt → `callout`、補足 11pt → `subheadline`）。
- **InspectorRig.swift** — 変更あり。フォント 11 件、色 2 件（`.textBackgroundColor` → `fieldBackground`、`.separatorColor` → `divider`）。
- **InspectorTachie.swift** — 変更あり。フォント 7 件（11pt → `subheadline`、12pt → `callout`）。「連動する声がありません」はボタンと同じ行の状態表示のためカード化の対象外。
- **CameraInspector.swift** — 変更なし。既に `.caption` や `InspectorSection` など意味的スタイルのみで、直書き・空状態が無い。
- **ClipNoteField.swift** — 変更あり。フォント 1 件（12pt → `callout`）。

### B. シート／ダイアログ

- **VoicevoxAccentSheet.swift** — 変更あり。フォント 8 件（12pt → `callout`、11pt → `subheadline`、13pt → `body`）。11pt の `.secondary` を `textSecondary` に。空状態無し。
- **DiarizationSheet.swift** — 変更あり。フォント 5 件、空状態 1 件をカード化（`text.magnifyingglass`）。message は新規文言（留保参照）。
- **DialogueSuggestionSheet.swift** — 変更あり。フォント 4 件、空状態「案はまだありません」をカード化（`text.bubble`）。message は新規文言。
- **ReadingDictionarySheet.swift** — 変更あり。フォント 4 件。辞書が空のときだけカード（`book.closed`）を出し、それ以外は既存の `List` をそのまま残す（`if rows.isEmpty` の分岐のみ追加）。message は新規文言。
- **ScriptTableSheet.swift** — 変更あり。フォント 4 件、「ボイスクリップがありません」をカード化（`waveform`）。heading は既存、message は新規。
- **VoicePresetSheet.swift** — 変更あり。フォント 4 件。空状態無し（メッセージは結果通知なので残す）。
- **AudioLibrarySheet.swift** — 変更あり。フォント 2 件（26pt → `largeTitle`、22pt → `title`）、見出し `.title3.bold()` は `MCDesign.Font.title3.bold()`。空状態 4 件をカード化：フォルダ未選択（`folder.badge.plus`、既存文言）、素材なし（`tray`、既存文言）、検索一致なし（`magnifyingglass`、グリッドとリスト両方、message は新規）。
- **TachieSheets.swift** — 変更あり。フォント 11pt → `subheadline`、13pt 太字 → `headline`。立ち絵素材なしをカード化（`person.crop.rectangle`、既存文言）。取り込みメニューの「＋」を `Image(systemName: "plus")` に。**保留**：`TachieListSection` 内の `.system(size: 13)` は刷新済みの節のため触らず（`body` 相当）。
- **FillerCutSheet.swift** — 変更あり。フォント 1 件。「フィラー語は見つかりませんでした」をカード化（`magnifyingglass`）。message は新規文言。
- **FindReplaceSheet.swift** — 変更あり。フォント 1 件。
- **ShortcutSheet.swift** — 変更あり。フォント 1 件（12pt semibold → `calloutSemibold`）。
- **SubclipBatchSheet.swift** — 変更あり。フォント 1 件（等幅 13pt → `monospaced(13)`）、見出し `title3.bold()` → トークン。
- **AIDialogs.swift** — 変更なし。NSAlert ベースの AppKit ダイアログ（`tv.font = .systemFont(ofSize: 12)` は NSTextView 用）のため SwiftUI トークンの対象外。
- **CandidateSwapSheet.swift** — 変更なし。直書き・空状態無し。`.title3.bold()` と `.caption` は意味的スタイル。
- **ClipListSheet.swift** — 変更あり。空状態「クリップがありません」をカード化（`film.stack`）。message は新規文言。
- **LoudnessSheet.swift** — 変更あり。`.noAudio` の空状態をカード化（`waveform.slash`）。message は新規文言。測定中・エラーは空状態ではないので据え置き。
- **MulticamSheets.swift** — 変更なし。直書きなし。`.red` / `.green` / `.orange` は状態の意味色で対応表に無いため残す。
- **NoteListSheet.swift** — 変更あり。空状態を既存文言の「。」で heading / message に分割してカード化（`note.text`）。
- **OutputSheets.swift** — 変更なし。直書き・空状態・絵文字ボタン無し。
- **PitchLayoutSheets.swift** — 変更なし。「置ける位置がありません。」は計算結果の警告であり空状態ではない。
- **RelinkResultSheet.swift** — 変更なし。「つながった素材はありません。」等は節ごとの結果表示。カードにすると節の見た目が崩れるため保留。
- **RollSlipSheet.swift** — 変更なし。テキストスタイルのみ。空状態無し。
- **SceneListSheet.swift** — 変更あり。空状態をカード化（`film.stack`）。既存文言を heading / message に分割。
- **ScopeSheet.swift** — 変更なし。「このコマを読めませんでした。」は読み込み失敗のステータス文で対象外。`Color.black.opacity` は波形・ヒストグラムの機能色。
- **ScreenRecordingSheet.swift** — 変更なし。直書き・空状態・絵文字ボタン無し。
- **SubtitleQuickSheet.swift** — 変更なし。`Color.secondary.opacity(0.3)` の枠線は対応表に無いため残す。
- **TakeCompareSheet.swift** — 変更あり。空状態をカード化（`waveform.badge.magnifyingglass`）。message は新規文言。`Color.green`（最短テイクの意味色）は残す。
- **TranscriptEditSheet.swift** — 変更なし。「文は見つかりませんでした。」は文字起こし結果のステータス文で対象外。
- **UnusedMediaSheet.swift** — 変更あり。空状態をカード化（`checkmark.circle`）。message は新規文言。
- **ContentView.swift（SettingsSheet のみ）** — 変更あり。見出しを `headline`、補足 `caption`、色 `textSecondary`、余白を `Spacing`（8pt グリッド）へ。`SettingsSheet` 以外は触らない（hunk は全て 566〜828 行の範囲内）。

### C. ウィンドウ／パネル／その他

- **DockViews.swift** — 変更あり。フォント 3 件（タブ・ドロップゾーンラベル → `callout` / `calloutSemibold`）、色 3 件（`.underPageBackgroundColor` → `barBackground`、`.separatorColor` → `divider`、タブの primary/secondary → `label` / `textSecondary`）。「パネルがありません」をカード化（`rectangle.3.group`）。ボタンの spacing 10 → `Spacing.m`。`Color.accentColor` / `white` / `black` のドロップゾーン色は対応表に無いため残す。
- **MediaThumbnail.swift** — 変更なし。`.system(size: min(width, height) * 0.4)` はサムネイルの大きさに比例するアイコンのため固定トークンに寄せられず保留。
- **DependencyBanner.swift** — 変更あり。メッセージ 12pt → `callout`（1 件）。
- **SettingsSheet（ContentView.swift 内）** — 変更あり（上記 B 参照）。
- **WelcomeWindow.swift** — 変更あり。フォント・色・余白をトークンへ。「最近使ったプロジェクトはありません」をカード化（`clock.arrow.circlepath`、heading は既存、message は新規）。製品名表記は据え置き。`QuickStartHint` は残す。
- **ExportPanel.swift** — 変更なし。AppKit（NSSavePanel のアクセサリ、NSPopUpButton 等）で構成され、SwiftUI のフォント・色・空状態が無い。
- **ExportQueueController.swift** — 変更あり。見出しを `title3.bold()`、`caption2` → `caption`、色を `textTertiary` / `textSecondary`。空状態をカード化（`tray`、既存文を heading / message に分割）。
- **DockWindows.swift** — 変更なし。フォント・色の直書きが無く、ボタンは標準の文言ボタン。
- **PreviewView.swift** — 変更なし。SwiftUI の文言・フォントが無く（NSViewRepresentable と CALayer の描画のみ）、キャンバス色は機能色のため対象外。
- **SoundLevelMeterView.swift** — 変更あり。ラベルのフォント 3 件（9pt semibold → `badge`、9pt monospacedDigit → `footnote.monospacedDigit()`、8pt → `caption`）。メーター色は機能色のため据え置き。
- **VST3Panel.swift** — 変更あり。補足 3 箇所を `caption` / `textSecondary` に、節見出しを `calloutSemibold` ＋ `textSecondary` に。節は `DisclosureGroup` のまま（構造を変えない方針）。「VST3 プラグインが見つかりません」はメニュー内の Text のためカード化せず。
- **AppCommands.swift** — 変更なし。メニュー項目のみで独立した画面ビューが無い。

### 対象外として据え置いたもの（全体）

- `InspectorView.swift` / `ContentView.swift`（SettingsSheet 以外）/ `TimelineView.swift` の本体、`TimelinePalette`：刷新済み・対象外。
- `DesignSystem.swift` のトークン定義自体（`Color(nsColor:)` 7 件・`.system(size:)` 3 件はトークンの実体）。
- `EaseCurveEditor.swift`（`.system(size:)` 4 件）：棚卸し表に含まれていないため未着手。必要なら次の対象として追加する。
- `TextGenerationDialogs.swift` / AppMenu・AppCommands のメニュー本体：対象外（仕様どおり）。

### 留保・保留した点

- **新規の message 文言**：InspectorGuideCard の message は既存文言に振り分けられないものがあり、以下は新しく書いた日本語文。`L10nTable` に英訳が無いため英語表示では日本語のまま出る。文言の確認と英訳の要否はユーザーに確認が必要。
  - DiarizationSheet、DialogueSuggestionSheet、ReadingDictionarySheet、ScriptTableSheet、AudioLibrarySheet（検索一致なし）、FillerCutSheet、ClipListSheet、LoudnessSheet、TakeCompareSheet、UnusedMediaSheet、WelcomeWindow。
- **フォントの対応を寄せた箇所**：AudioFx の節見出しは 12pt semibold（`calloutSemibold`）のまま。InspectorView の節見出しが `headline`（13pt）なので約 1pt の差が残る。`headline` への変更は未実施。
- **SettingsSheet の見出し**：`title3.bold()`（15pt 相当）→ `headline`（13pt）に縮小。元の大きさに戻す場合は見出しだけ差し替える。
- **SoundLevelMeterView**：9pt / 8pt を 10pt 相当（`badge` / `footnote` / `caption`）に上げた。モノラルメーター幅 48pt で「LUFS」が `lineLimit(1)` に収まるかは目視が必要。
- **VST3Panel**：節は `DisclosureGroup` のまま。`MCDisclosure` への置き換えは未実施。
- **RelinkResultSheet**：節ごとの「ありません」表示をカードにしなかった（節の見た目を崩すため）。
- **目視未確認**：ガイドカードの幅・はみ出し（特に List 行内に入れた AudioLibrarySheet の検索一致なし、ReadingDictionarySheet）は未確認。実機確認が必要。


### テスト結果（最終）

- `swift build`：成功（警告・エラー無し）
- `swift test`：合計 3,398 件（アプリ `MovieCutTests` 853 件 ＋ Core `MovieCutCoreTests` 2,545 件）、スキップ 8、失敗 0。基準と一致。
- テストの文言・定数・フォント期待値は変更していない。

## 検証担当による追加・訂正（2026-11-19）

- **EaseCurveEditor.swift を追加実施**：初版の棚卸し表から漏れていた4件のフォント直書き（12→callout、11→subheadline、10→footnote、12 monospacedDigit→callout.monospacedDigit()）をトークン化し、ボタンアイコンの色も  に寄せた。Canvas 描画色（曲線・制御点）は機能色として対象外のまま。
- **TachieSheets.swift の TachieListSection**：残っていた （立ち絵名ラベル）を  に置換（13pt 通常ウェイトで描画は同一）。
- **AudioFx の節見出しについて訂正**：実施報告では「InspectorView の節は headline（13pt）で約1pt差」とされたが、実際の  の見出しは （12pt）＋ textSecondary であり、AudioFx 側の calloutSemibold はメイン画面の節見出しと一致している。追加変更は不要。
- **MediaThumbnail.swift の **：サムネイル寸法に比例する動的サイズ（アイコンのグリフ）であり、テキストスタイルのトークン化になじまないため据え置きが妥当と確認。
- 検証担当が全テストを再実行し、結果をこのドキュメント末尾ではなく完了報告に記載する（テスト総数・失敗・スキップは実施報告の基準どおりであることを確認する）。

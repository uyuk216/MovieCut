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

（実装時にファイルごとに追記する：変更内容／変更なしの理由／保留した点）

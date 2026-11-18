import SwiftUI
import AppKit

// MARK: - デザインシステム(Apple Human Interface Guidelines に沿うための土台)
//
// 見た目の定数はここに集める。新しい画面・部品を作るときは、色・フォント・余白・
// 角丸を直書きせず、ここのトークンを使うこと(既存の直書きも、触るついでに移す)。
//
// 根拠(HIG の各ページ):
// - Branding: ブランドの主張は控えめに。ロゴを画面のあちこちに出さない。
//   アクセントカラーは選択や主要な操作の印などに絞って使い、利用者が
//   システム設定で選んだアクセントカラーを尊重する(Color.accentColor が担う)。
// - Color: システムカラーは「意味」で定義された動的な色で、ライト/ダークや
//   コントラスト強調に自動で追随する。色の値を直書き(ハードコード)しない。
//   赤は破壊的な操作のために取っておく。
// - Typography: システムフォント(SF)とテキストスタイルで階層を表す。
//   macOS で読める最小のサイズは 10pt 前後。それ未満の文字は使わない。
// - Layout: 余白は 8pt グリッド(必要に応じて 4pt の半刻み)にそろえる。
//
// 意図的な例外:
// - 画面全体はダーク固定(ContentView の .preferredColorScheme(.dark))。
//   動画編集という用途と、タイムライン/プレビューのキャンバスが暗色前提で
//   設計されているため。外枠の色はセマンティックカラーに寄せてあるので、
//   将来ライトモードに対応する余地は残してある。
// - タイムラインのクリップ種別色(TimelinePalette)はキャンバス上の機能色
//   なので、このトークンの対象外(従来どおり)。

enum MCDesign {

    enum Color {
        /// 主要な文字
        static let label = SwiftUI.Color.primary
        /// 補足の文字
        static let secondaryLabel = SwiftUI.Color.secondary
        /// 破壊的な操作(削除など)の印。システムレッド。
        static let destructive = SwiftUI.Color.red
        /// 選択の印。システムのアクセントカラー(利用者の設定に従う)。
        static let selection = SwiftUI.Color.accentColor
        /// 区切り線
        static let separator = SwiftUI.Color(nsColor: .separatorColor)
        /// ウィンドウの地
        static let window = SwiftUI.Color(nsColor: .windowBackgroundColor)
        /// 大きな面(リスト・カードなど)の地
        static let control = SwiftUI.Color(nsColor: .controlBackgroundColor)
        /// ウィンドウより一段沈んだ地(ツールバーなど)
        static let underPage = SwiftUI.Color(nsColor: .underPageBackgroundColor)

        // 意味トークン(役割で名前を付けた別名。外枠はシステムのセマンティック色に寄せる)
        /// アプリ全体の背景
        static let background = window
        /// パネル(左・右)の地
        static let panelBackground = window
        /// ツールバー・ステータスバーの地
        static let barBackground = underPage
        /// 区切り(Divider 相当)
        static let divider = separator
        /// 二次テキスト
        static let textSecondary = SwiftUI.Color(nsColor: .secondaryLabelColor)
        /// 三次テキスト(解像度・fps の表示など、控えめな文字)
        static let textTertiary = SwiftUI.Color(nsColor: .tertiaryLabelColor)
        /// 入力欄の地
        static let fieldBackground = SwiftUI.Color(nsColor: .textBackgroundColor)
        /// アクセント(システム設定のアクセントカラー)
        static let accent = SwiftUI.Color.accentColor
    }

    enum Font {
        // macOS のテキストスタイル(括弧内は標準サイズ)。階層はこの段差で作る。
        static let largeTitle = SwiftUI.Font.largeTitle   // 26pt
        static let title = SwiftUI.Font.title             // 22pt
        static let title2 = SwiftUI.Font.title2           // 17pt
        static let title3 = SwiftUI.Font.title3           // 15pt
        static let headline = SwiftUI.Font.headline       // 13pt semibold
        static let body = SwiftUI.Font.body               // 13pt
        static let callout = SwiftUI.Font.callout         // 12pt
        static let calloutSemibold = SwiftUI.Font.system(size: 12, weight: .semibold)
        static let subheadline = SwiftUI.Font.subheadline // 11pt
        static let footnote = SwiftUI.Font.footnote       // 10pt
        static let caption = SwiftUI.Font.caption         // 10pt
        /// ごく小さい印(バッジ・つまみの字)。可読の下限として 10pt を使う。
        static let badge = SwiftUI.Font.system(size: 10, weight: .semibold)
        /// 時刻など、等幅で読む数字
        static func monospaced(_ size: CGFloat) -> SwiftUI.Font {
            .system(size: size, design: .monospaced)
        }
    }

    /// 余白(8pt グリッド。xs だけ 4pt の半刻み)
    enum Spacing {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
    }

    /// 角の丸み(既存の画面で使ってきた値にそろえた)
    enum Radius {
        static let chip: CGFloat = 5
        static let control: CGFloat = 6
        static let panel: CGFloat = 10
    }
}

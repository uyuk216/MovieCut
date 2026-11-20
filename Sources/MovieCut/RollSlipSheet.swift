import SwiftUI
import MovieCutCore

/// クリップ ▸ ロール編集… / スリップ編集… / スライド編集… / J/Lカット… のシート。コマ数(負 = 前へ)で動かす。
/// タイムラインではロール = ⌥ + 端ドラッグ、スリップ = ⌥⇧ + 本体ドラッグ、スライド = ⌥ + 本体ドラッグでも同じ編集ができる。
struct RollSlipSheet: View {
    @ObservedObject var model: ProjectModel
    let kind: Kind
    @State private var framesText = "1"
    @State private var failed = false

    enum Kind { case roll, slip, slide, splitEdit }

    init(model: ProjectModel, kind: Kind) {
        self.model = model
        self.kind = kind
    }

    /// 互換: 従来の (ロール / スリップ) 指定。
    init(model: ProjectModel, slip: Bool) {
        self.model = model
        self.kind = slip ? .slip : .roll
    }

    private var title: String {
        switch kind {
        case .roll: return "ロール編集"
        case .slip: return "スリップ編集"
        case .slide: return "スライド編集"
        case .splitEdit: return "J/Lカット"
        }
    }

    private var explanation: String {
        switch kind {
        case .roll: return "選んでいるクリップと隣のクリップの境界を動かします。片方の終わりを縮め、もう片方の頭を同じだけ延ばします。正の数で後ろへ、負の数で前へ。"
        case .slip: return "選んでいるクリップの位置と長さはそのままで、使う素材の区間を動かします。正の数で後ろの素材へ、負の数で前の素材へ。"
        case .slide: return "選んでいるクリップの位置を動かし、前後のクリップの終わりと頭が連動します。真ん中のクリップの長さと使う素材の区間は変わりません。正の数で後ろへ、負の数で前へ。"
        case .splitEdit: return "映像の境界はそのままに、音だけのクリップ(音声・ボイス)の境界を動かします。正の数で後ろへ(Lカット: 前の音が映像の後まで残ります)、負の数で前へ(Jカット: 次の音が映像より先に出ます)。"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.t(title)).font(.headline)
            Text(L10n.t(explanation))
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: 380, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(L10n.t("動かす量"))
                TextField("1", text: $framesText).textFieldStyle(.roundedBorder).frame(width: 80)
                Text(L10n.t("コマ")).foregroundStyle(.secondary)
                if failed { Text(L10n.t("整数で入れてください")).font(.caption).foregroundStyle(.red) }
            }
            Text(L10n.t("素材の範囲を超える分は手前で止まります。ロックされたクリップは編集できません。"))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(L10n.t("キャンセル")) { close() }.keyboardShortcut(.cancelAction)
                Button(L10n.t("実行")) { commit() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }

    private func close() {
        model.showRollSheet = false; model.showSlipSheet = false
        model.showSlideSheet = false; model.showSplitEditSheet = false
    }

    private func commit() {
        let n = framesText.replacingOccurrences(of: "−", with: "-").trimmingCharacters(in: .whitespaces)
        guard let f = Int(n) else { failed = true; return }
        failed = false
        switch kind {
        case .roll: _ = model.rollSelected(frames: f)
        case .slip: _ = model.slipSelected(frames: f)
        case .slide: _ = model.slideSelected(frames: f)
        case .splitEdit: _ = model.splitEditSelected(frames: f)
        }
        close()
    }
}

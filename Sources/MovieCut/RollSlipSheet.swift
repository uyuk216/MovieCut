import SwiftUI
import MovieCutCore

/// クリップ ▸ ロール編集… / スリップ編集… のシート。コマ数(負 = 前へ)で動かす。タイムラインでは ⌥ ドラッグでも同じ編集ができる。
struct RollSlipSheet: View {
    @ObservedObject var model: ProjectModel
    let slip: Bool
    @State private var framesText = "1"
    @State private var failed = false

    private var title: String { slip ? "スリップ編集" : "ロール編集" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            Text(slip ? "選んでいるクリップの位置と長さはそのままで、使う素材の区間を動かします。正の数で後ろの素材へ、負の数で前の素材へ。"
                      : "選んでいるクリップと隣のクリップの境界を動かします。片方の終わりを縮め、もう片方の頭を同じだけ延ばします。正の数で後ろへ、負の数で前へ。")
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: 380, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("動かす量")
                TextField("1", text: $framesText).textFieldStyle(.roundedBorder).frame(width: 80)
                Text("コマ").foregroundStyle(.secondary)
                if failed { Text("整数で入れてください").font(.caption).foregroundStyle(.red) }
            }
            Text("素材の範囲を超える分は手前で止まります。ロックされたクリップは編集できません。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("キャンセル") { close() }.keyboardShortcut(.cancelAction)
                Button("実行") { commit() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }

    private func close() { model.showRollSheet = false; model.showSlipSheet = false }

    private func commit() {
        let n = framesText.replacingOccurrences(of: "−", with: "-").trimmingCharacters(in: .whitespaces)
        guard let f = Int(n) else { failed = true; return }
        failed = false
        _ = slip ? model.slipSelected(frames: f) : model.rollSelected(frames: f)
        close()
    }
}

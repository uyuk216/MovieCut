import SwiftUI
import MovieCutCore

/// クリップ ▸ 縦動画に自動リフレーム のオプション。比率・被写体の追い方・縦追従・ズームを選んで「リフレーム」。
/// 既定のまま実行すると、従来(9:16・横のみ・ズームなし・主な被写体)と同じ結果。
struct ReframeSheet: View {
    @ObservedObject var model: ProjectModel
    @State private var options = ReframeOptions()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.t("自動リフレーム")).font(.title3.bold())
            Picker(L10n.t("出力の比率"), selection: $options.aspect) {
                ForEach(ReframeAspect.allCases, id: \.self) { Text(L10n.t($0.title)).tag($0) }
            }
            Picker(L10n.t("複数の被写体"), selection: $options.subjectMode) {
                ForEach(ReframeSubjectMode.allCases, id: \.self) { Text(L10n.t($0.title)).tag($0) }
            }
            Toggle(L10n.t("縦(上下)にも追従"), isOn: $options.followY)
            Toggle(L10n.t("被写体の大きさに合わせてズーム"), isOn: $options.zoomEnabled)
            if options.zoomEnabled {
                HStack {
                    Text(L10n.t("ズームの上限"))
                    Slider(value: $options.zoomMax, in: 1.1...2.5, step: 0.05)
                    Text(String(format: "×%.2f", options.zoomMax)).monospacedDigit().frame(width: 56, alignment: .trailing)
                }
            }
            Text(L10n.t("出力の解像度はプロジェクト全体に効きます(1 回の Undo で戻せます)。")).font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(L10n.t("キャンセル")) { model.showReframeSheet = false }.keyboardShortcut(.cancelAction)
                Button(L10n.t("リフレーム")) {
                    model.showReframeSheet = false
                    model.autoReframeSelected(options: options)
                }
                .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

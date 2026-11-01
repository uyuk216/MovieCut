import SwiftUI
import MovieCutCore

/// 出力 ▸ ラウドネスを測る…: プロジェクトの音の全体(書き出しと同じミックス)を測って見せる。読み取りだけで、音量は変えない。
struct LoudnessSheet: View {
    @ObservedObject var model: ProjectModel
    @State private var state: State = .measuring

    enum State {
        case measuring
        case done(LoudnessReport)
        case noAudio
        case failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ラウドネス").font(.title3.bold())
            Text("書き出しと同じミックスを ITU-R BS.1770 で測ります。読み取りだけで、音量は変えません。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            switch state {
            case .measuring:
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("測っています…") }
                    .frame(maxWidth: .infinity, minHeight: 160, alignment: .center)
            case .noAudio:
                Text("音声がありません。").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 160, alignment: .center)
            case .failed(let message):
                Text("測れませんでした: \(message)").foregroundStyle(.red)
                    .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
            case .done(let r):
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                    row("統合ラウドネス", value(r.integrated, "LUFS"), id: "loudness-integrated")
                    row("ショートターム最大", value(r.shortTermMax, "LUFS"), id: "loudness-short")
                    row("真のピーク", value(r.truePeakDb, "dBTP"), id: "loudness-true-peak")
                    row("サンプルのピーク", value(r.samplePeakDb, "dBFS"), id: "loudness-sample-peak")
                    row("測った長さ", String(format: "%.2f 秒", r.duration), id: "loudness-duration")
                }
                if let d = r.differenceToYouTube() {
                    Text(String(format: "YouTube の目安(−14 LUFS)との差: %+.1f dB。目安として見せるだけで、自動では音量を変えません。", d))
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if r.truePeakDb.isFinite, r.truePeakDb > -1 {
                    Text("真のピークが −1 dBTP を超えています。配信先で音が割れることがあります。")
                        .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Spacer()
                Button("閉じる") { model.showLoudnessSheet = false }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .task { await measure() }
    }

    private func row(_ label: String, _ value: String, id: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).monospacedDigit().accessibilityIdentifier(id)
        }
    }

    private func value(_ v: Double, _ unit: String) -> String {
        v.isFinite ? String(format: "%.1f %@", v, unit) : "−∞ \(unit)"
    }

    private func measure() async {
        let snapshot = model.project
        do {
            let r = try await Task.detached(priority: .userInitiated) { try LoudnessAnalysis.measure(project: snapshot) }.value
            state = r.map { .done($0) } ?? .noAudio
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

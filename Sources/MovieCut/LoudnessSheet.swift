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
            Text(L10n.t("ラウドネス")).font(.title3.bold())
            Text(L10n.t("書き出しと同じミックスを ITU-R BS.1770 で測ります。読み取りだけで、音量は変えません。"))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            switch state {
            case .measuring:
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(L10n.t("測っています…")) }
                    .frame(maxWidth: .infinity, minHeight: 160, alignment: .center)
            case .noAudio:
                InspectorGuideCard(symbol: "waveform.slash", heading: "音声がありません", message: "音のあるクリップを置くと測れます。")
                    .frame(maxWidth: .infinity, minHeight: 160, alignment: .center)
            case .failed(let message):
                Text(String(format: L10n.t("測れませんでした: %@"), message)).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
            case .done(let r):
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                    row("統合ラウドネス", value(r.integrated, "LUFS"), id: "loudness-integrated")
                    row("ショートターム最大", value(r.shortTermMax, "LUFS"), id: "loudness-short")
                    row("真のピーク", value(r.truePeakDb, "dBTP"), id: "loudness-true-peak")
                    row("サンプルのピーク", value(r.samplePeakDb, "dBFS"), id: "loudness-sample-peak")
                    row("測った長さ", String(format: L10n.t("%.2f 秒"), r.duration), id: "loudness-duration")
                }
                if let d = r.differenceToYouTube() {
                    Text(String(format: L10n.t("YouTube の目安(−14 LUFS)との差: %+.1f dB。目安として見せるだけで、自動では音量を変えません。"), d))
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if r.truePeakDb.isFinite, r.truePeakDb > -1 {
                    Text(L10n.t("真のピークが −1 dBTP を超えています。配信先で音が割れることがあります。"))
                        .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Spacer()
                Button(L10n.t("閉じる")) { model.showLoudnessSheet = false }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .task { await measure() }
    }

    private func row(_ label: String, _ value: String, id: String) -> some View {
        GridRow {
            Text(L10n.t(label)).foregroundStyle(.secondary)
            Text(value).monospacedDigit().accessibilityIdentifier(id)
        }
    }

    private func value(_ v: Double, _ unit: String) -> String {
        v.isFinite ? String(format: "%.1f %@", v, unit) : "−∞ \(unit)"
    }

    private func measure() async {
        let snapshot = model.project
        do {
            // シートを閉じる(.task の取り消し)と待つ側は抜ける。取り消し後は結果を反映しない。
            let r = try await Task.detached(priority: .userInitiated) { try LoudnessAnalysis.measure(project: snapshot, vst3Provider: AppServices.vst3EffectProvider) }.value
            if Task.isCancelled { return }
            state = r.map { .done($0) } ?? .noAudio
        } catch {
            if Task.isCancelled { return }
            state = .failed(error.localizedDescription)
        }
    }
}

import SwiftUI
import MovieCutCore

/// クリップ ▸ Remixツール…: 音楽クリップを目標の尺へ、ビート(取れなければ音の切り替わり点)を
/// 候補に区間を選び直してつなぎ直し、元クリップのレイヤーの末尾に新しいクリップ列を作る。
/// 元クリップは変更しない。作れないときは理由を表示して止める。
struct RemixSheet: View {
    @ObservedObject var model: ProjectModel
    @State private var scan: RemixScan?
    @State private var failure: String?
    @State private var targetText = ""
    @State private var crossfade: Double = 0.1

    private var clipId: String? { model.remixClipId }
    private var sourceDuration: Double { clipId.flatMap { model.clip($0)?.duration } ?? 0 }

    private var target: Double? {
        let t = Double(targetText.trimmingCharacters(in: .whitespaces))
        return (t?.isFinite ?? false) && (t ?? 0) > 0 ? t : nil
    }

    private var params: RemixParams? {
        guard let t = target else { return nil }
        return RemixParams(targetDuration: t, crossfadeDuration: crossfade)
    }

    /// 目標の尺の上限(秒)。これを超える入力では計画を作らない
    private static let maxTarget: Double = 3600
    private var targetTooLong: Bool { (target ?? 0) > Self.maxTarget }

    private var planResult: Result<RemixPlan, RemixError>? {
        guard !targetTooLong else { return nil }
        guard let s = scan, let p = params, sourceDuration > 0 else { return nil }
        return Remix.plan(duration: sourceDuration, candidates: s.candidates, params: p, usedFallback: s.usedFallback)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.t("Remixツール")).font(.headline)
            Text(L10n.t("元のクリップは変更せず、同じレイヤーの末尾に新しいクリップ列を作ります。"))
                .font(.callout)
            Group {
                if let s = scan {
                    if s.usedFallback {
                        Text(String(format: L10n.t("ビートが取れなかったため、音の切り替わり点 %d 個を候補にします。"), s.candidates.count))
                    } else {
                        Text(String(format: L10n.t("ビート検出: 約 %d BPM、候補 %d 個"), Int((s.bpm ?? 0).rounded()), s.candidates.count))
                    }
                } else if let e = failure {
                    Text(e).foregroundStyle(.red)
                } else {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text(L10n.t("音声を解析しています…")) }
                }
            }
            .font(.callout)
            HStack {
                Text(L10n.t("目標の尺(秒)"))
                TextField(L10n.t("目標の尺(秒)"), text: $targetText)
                    .frame(width: 90)
                Text(String(format: L10n.t("元の尺は %.1f 秒"), sourceDuration))
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text(L10n.t("クロスフェード(秒)"))
                Slider(value: $crossfade, in: 0 ... 0.3, step: 0.01)
                    .frame(width: 160)
                Text(String(format: "%.2f", crossfade)).monospacedDigit()
            }
            Group {
                if targetTooLong {
                    Text(L10n.t("目標の尺は 3600 秒までです")).foregroundStyle(.red)
                } else {
                switch planResult {
                case .success(let p):
                    Text(String(format: L10n.t("出来上がり: 約 %.1f 秒 / %d 区間 / つなぎ目 %d か所"), p.totalDuration, p.segments.count, max(0, p.segments.count - 1)))
                case .failure(let e):
                    Text(e.message).foregroundStyle(.red)
                case nil:
                    Text(L10n.t("目標の尺を入力してください。")).foregroundStyle(.secondary)
                }
                }
            }
            .font(.callout)
            Text(L10n.t("歌詞のある素材では、歌詞の連続性は保証されません。"))
                .font(MCDesign.Font.subheadline).foregroundStyle(MCDesign.Color.textSecondary)
            HStack {
                Spacer()
                Button(L10n.t("キャンセル")) { model.showRemixSheet = false }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.t("Remixを作成")) { commit() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCommit)
            }
        }
        .padding(20)
        .frame(width: 480)
        .task { await load() }
    }

    private var canCommit: Bool {
        guard case .success = planResult else { return false }
        return clipId != nil
    }

    private func load() async {
        do {
            let r = try await model.scanRemix()
            scan = r
            if targetText.isEmpty, sourceDuration > 0 {
                targetText = String(format: "%.0f", max(1, min(30, sourceDuration / 2)))
            }
        } catch is CancellationError {
            // 閉じたときは何もしない
        } catch {
            failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func commit() {
        guard let id = clipId, let s = scan, let p = params else { return }
        if model.applyRemix(clipId: id, candidates: s.candidates, usedFallback: s.usedFallback, params: p) {
            model.showRemixSheet = false
        }
    }
}

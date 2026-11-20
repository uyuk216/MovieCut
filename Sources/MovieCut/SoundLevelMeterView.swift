import SwiftUI
import MovieCutCore

/// タイムライン脇のサウンドレベルメーター(YMM4 式: ピーク/ラウドネス切替)。
/// 値は PlaybackController が再生用ミックスから先に測っておいた `PlaybackLevelEnvelope` を
/// 現在時刻で引くだけ(再生経路には触らない)。止まっているときも再生位置の値を出すので、
/// スクラブしながら大きな音の場所を探せる。
struct SoundLevelMeterView: View {
    @ObservedObject var model: ProjectModel
    @AppStorage("soundLevelMeter.mode") private var modeRaw: String = PlaybackLevelMode.peak.rawValue

    private var mode: PlaybackLevelMode { PlaybackLevelMode(rawValue: modeRaw) ?? .peak }

    private var db: Double? {
        guard let env = model.playback.levelEnvelope else { return nil }
        let v = env.levelDb(at: model.currentTime, mode: mode)
        return v.isFinite ? v : nil
    }

    private var fraction: Double {
        guard let env = model.playback.levelEnvelope else { return 0 }
        return PlaybackLevelEnvelope.normalized(env.levelDb(at: model.currentTime, mode: mode), mode: mode)
    }

    var body: some View {
        VStack(spacing: 4) {
            Button {
                modeRaw = (mode == .peak ? PlaybackLevelMode.loudness : .peak).rawValue
            } label: {
                Text(mode == .peak ? "ピーク" : "ラウドネス")
                    .font(MCDesign.Font.badge)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .buttonStyle(.borderless)
            .help(L10n.t("サウンドレベルメーターの表示を切り替えます(ピーク dBFS / ラウドネス LUFS モーメンタリ)"))
            GeometryReader { g in
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.08))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(barColor)
                        .frame(height: max(0, g.size.height * CGFloat(fraction)))
                    // 0 dB の位置(天井)
                    Rectangle().fill(Color.red.opacity(0.7)).frame(height: 1).offset(y: -g.size.height + 1)
                }
            }
            .frame(width: 14)
            Text(db.map { String(format: "%.0f", $0) } ?? "--")
                .font(MCDesign.Font.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(mode == .peak ? "dB" : "LUFS")
                .font(MCDesign.Font.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.vertical, 6)
        .frame(maxHeight: .infinity)
        .background(Color.black.opacity(0.18))
        .help(model.playback.levelEnvelope == nil ? "サウンドレベルメーター(音声を準備すると表示されます)" : "サウンドレベルメーター")
    }

    private var barColor: Color {
        if fraction > 0.9 { return .red }
        if fraction > 0.75 { return .yellow }
        return .green
    }
}

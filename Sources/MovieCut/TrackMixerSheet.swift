import SwiftUI
import MovieCutCore

/// 出力 ▸ トラックミキサー…: レイヤーごとの音量フェーダー・パン・ミュート・ソロ。全レイヤーを並べる(映像レイヤーの音量は動画クリップの音に効く)。
/// スライダーのドラッグは `beginGesture` 〜 `commitGesture` で 1 回の Undo にまとまる。
struct TrackMixerSheet: View {
    @ObservedObject var model: ProjectModel

    var body: some View {
        VStack(alignment: .leading, spacing: MCDesign.Spacing.m) {
            Text(L10n.t("トラックミキサー")).font(MCDesign.Font.title3.bold())
            Text(L10n.t("レイヤーごとの音量とパンを調整します。クリップ自身の音量・パンに掛け合わされます。"))
                .font(MCDesign.Font.callout).foregroundStyle(MCDesign.Color.secondaryLabel)
                .fixedSize(horizontal: false, vertical: true)
            if model.project.tracks.isEmpty {
                InspectorGuideCard(symbol: "slider.vertical.3", heading: L10n.t("レイヤーがありません"), message: L10n.t("レイヤーを足すとミキサーに並びます。"))
                    .frame(maxWidth: .infinity, minHeight: 160, alignment: .center)
            } else {
                ScrollView {
                    VStack(spacing: MCDesign.Spacing.s) {
                        ForEach(Array(model.project.tracks.enumerated()), id: \.offset) { i, track in
                            row(i, track)
                        }
                    }
                }
                .frame(maxHeight: 360)
            }
            HStack {
                Spacer()
                Button(L10n.t("閉じる")) { model.showTrackMixerSheet = false }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(MCDesign.Spacing.xl)
        .frame(width: 560)
    }

    private func row(_ i: Int, _ track: Track) -> some View {
        let mix = TrackMix.of(track)
        return VStack(alignment: .leading, spacing: MCDesign.Spacing.xs) {
            HStack(spacing: MCDesign.Spacing.s) {
                Text(track.name).font(MCDesign.Font.calloutSemibold).lineLimit(1)
                Spacer()
                Toggle(L10n.t("ミュート"), isOn: Binding(get: { track.isMuted }, set: { _ in model.toggleTrackMuted(i) }))
                    .toggleStyle(.button).controlSize(.small)
                    .accessibilityIdentifier("track-mixer-mute-\(i)")
                Toggle(L10n.t("ソロ"), isOn: Binding(get: { track.isSolo }, set: { _ in model.toggleTrackSolo(i) }))
                    .toggleStyle(.button).controlSize(.small)
                    .accessibilityIdentifier("track-mixer-solo-\(i)")
                Button(L10n.t("リセット")) { model.resetTrackMix(i) }
                    .controlSize(.small)
                    .disabled(!track.hasTrackMix && !track.isMuted && !track.isSolo)
                    .accessibilityIdentifier("track-mixer-reset-\(i)")
            }
            slider(L10n.t("音量"), value: mix.gain, range: 0...2, text: Self.dbText(mix.gain),
                   undo: ProjectModel.trackVolumeUndoName, live: { model.liveTrackVolume(i, $0) })
            slider(L10n.t("パン"), value: mix.pan, range: -1...1, text: Self.panText(mix.pan),
                   undo: ProjectModel.trackPanUndoName, live: { model.liveTrackPan(i, $0) })
        }
        .padding(MCDesign.Spacing.s)
        .background(MCDesign.Color.control, in: RoundedRectangle(cornerRadius: MCDesign.Radius.control))
        .opacity(track.isMuted ? 0.6 : 1)
    }

    private func slider(_ label: String, value: Double, range: ClosedRange<Double>, text: String,
                        undo: String, live: @escaping (Double) -> Void) -> some View {
        HStack(spacing: MCDesign.Spacing.s) {
            Text(label).font(MCDesign.Font.callout).foregroundStyle(MCDesign.Color.secondaryLabel).frame(width: 40, alignment: .leading)
            Slider(value: Binding(get: { value }, set: { live($0) }), in: range) { editing in
                if editing { model.beginGesture() } else { model.commitGesture(undo) }
            }
            .controlSize(.small)
            Text(text).font(MCDesign.Font.monospaced(11)).foregroundStyle(MCDesign.Color.secondaryLabel)
                .frame(width: 64, alignment: .trailing)
        }
    }

    /// 音量の dB 表示(下限は −60 dB で「−∞」扱い)。
    static func dbText(_ gain: Double) -> String {
        let db = TrackMix.db(forGain: gain)
        return db <= TrackMix.minDb ? "−∞ dB" : String(format: "%+.1f dB", db)
    }

    /// パンの表示(左 30 / 中央 / 右 30)。
    static func panText(_ pan: Double) -> String {
        let pct = Int((abs(pan) * 100).rounded())
        if pct == 0 { return L10n.t("中央") }
        return pan < 0 ? "\(L10n.t("左")) \(pct)" : "\(L10n.t("右")) \(pct)"
    }
}

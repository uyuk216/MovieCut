import SwiftUI
import MovieCutCore

/// カメラ(W3-02 / 監査 #54)のプロパティ欄。プロジェクト設定なので、クリップ未選択のときと
/// クリップ選択時の末尾の両方に出す。値の編集・キーフレームはクリップの項目と同じ作法。
struct CameraSection: View {
    @ObservedObject var model: ProjectModel

    private static let positionKeys = ["x", "y", "targetX", "targetY"]

    var body: some View {
        InspectorTopSection("inspector.camera") {
        VStack(alignment: .leading, spacing: 6) {
            if model.project.camera == nil {
                Text(L10n.t("未設定（従来どおりの描画です）。値を変えるとカメラが付きます。"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Self.positionKeys, id: \.self) { key in field(key, step: 0.01, decimals: 2) }
            field("orbit", step: 1, decimals: 1)
            field("fov", step: 1, decimals: 0)
            HStack(spacing: 8) {
                Button(L10n.t("カメラをリセット")) { model.resetCamera() }
                    .disabled(model.project.camera == nil)
                Text(L10n.t("注目点は回り込み・拡大の軸、視野角は小さいほど拡大です。"))
                    .font(.caption).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .disabled(model.isLocked)
        }
    }

    private func field(_ key: String, step: Double, decimals: Int) -> some View {
        let range = CameraSettings.range(of: key)
        return InspectorField(label: CameraSettings.label(of: key),
                              key: KeyframeControl(state: model.cameraKeyState(key),
                                                   canPrev: model.cameraKeyTimes(key).contains { $0 < model.currentTime - model.keyTolerance },
                                                   canNext: model.cameraKeyTimes(key).contains { $0 > model.currentTime + model.keyTolerance },
                                                   toggle: { model.toggleCameraKeyframe(key) },
                                                   prev: { model.seekCameraKeyframe(key, forward: false) },
                                                   next: { model.seekCameraKeyframe(key, forward: true) })) {
            NumField(value: model.cameraValue(key), step: step, decimals: decimals,
                     clamp: { CameraSettings.clamp(key, $0) },
                     onCommit: { model.setCameraValue(key, $0) },
                     onStep: { model.setCameraValue(key, $0) })
        }
    }
}

/// トラッキング(W3-03 / 監査 #53)のプロパティ欄。追従の実行・進捗・中止・解除と、
/// 映像クリップ自身を元にした「ぼかし範囲の追従」の追加。
struct TrackingSection: View {
    @ObservedObject var model: ProjectModel
    let clip: Clip

    var body: some View {
        let canFollow = model.canObjectTrack(clip)
        let isSource = (clip.type == .video || clip.type == .image) && clip.src != nil
        if canFollow || isSource || clip.tracking != nil {
            InspectorTopSection("inspector.tracking") {
            VStack(alignment: .leading, spacing: 6) {
                if let p = model.objectTrackingProgress {
                    ProgressView(value: p) { Text(L10n.t("対象を追跡しています…")) }
                    Button(L10n.t("追跡を中止")) { model.cancelObjectTracking() }
                } else {
                    if canFollow {
                        Button(clip.type == .blur ? "この範囲を対象に追従させる" : "対象に追従させる（位置・大きさ）") {
                            model.runObjectTracking(clipId: clip.id)
                        }
                        .help(L10n.t("下のレイヤーの映像の中央の対象を追い、位置と大きさのキーフレームを作ります"))
                    }
                    if isSource {
                        Button(L10n.t("この映像の対象をぼかしで追従")) { model.addBlurFollower(clipId: clip.id) }
                            .help(L10n.t("映像の中央の対象を追うぼかし範囲クリップを新しく作ります"))
                    }
                    if let track = clip.tracking {
                        Text(String(format: L10n.t("追従中: %d サンプル（元クリップ %@）"), track.samples.count, L10n.t(track.sourceClipId == clip.id ? "自身" : "下のレイヤー")))
                            .font(.caption).foregroundStyle(.secondary)
                        if let lostAt = track.lostAt {
                            Text(String(format: L10n.t("%.1f 秒で対象を見失ったため、追従はそこまでです"), lostAt))
                                .font(.caption).foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Button(L10n.t("追従を消す")) { model.clearObjectFollow(clipId: clip.id) }
                    } else if !canFollow && !isSource {
                        Text(L10n.t("追従には、このクリップより下のレイヤーに映像・画像が必要です。"))
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .disabled(model.isLocked && model.objectTrackingProgress == nil)
            }
        }
    }
}

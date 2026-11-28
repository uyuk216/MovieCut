import SwiftUI
import MovieCutCore

/// オブジェクトマスク(Premiere の AI オブジェクトマスクのローカル等価)のプロパティ欄。
/// 対象の指定(プレビューのクリック / 矩形の下書き)→ 作成(種マスク+追跡伝播)の実行・進捗・中止と、
/// 羽根・反転の調整、作り直し・削除。値の編集は形のマスクと同じ作法(ドラッグは 1 回の Undo)。
struct ObjectMaskSection: View {
    @ObservedObject var model: ProjectModel
    let clip: Clip

    private static let pct: (Double) -> String = { "\(Int(($0 * 100).rounded()))%" }

    var body: some View {
        if model.canCreateObjectMask(clip) || clip.objectMask != nil {
            InspectorTopSection("inspector.objectMask") {
            VStack(alignment: .leading, spacing: 6) {
                if let p = model.objectMaskProgress {
                    ProgressView(value: p) { Text(L10n.t("対象を追跡しています…")) }
                    Button(L10n.t("作成を中止")) { model.cancelObjectMaskCreation() }
                } else if let om = clip.objectMask {
                    Text(L10n.t("対象を追跡中"))
                        .font(MCDesign.Font.subheadline).foregroundStyle(.secondary)
                    Text(String(format: L10n.t("%d サンプル"), om.samples.count))
                        .font(MCDesign.Font.subheadline).foregroundStyle(.secondary)
                    LiveSlider(label: L10n.t("羽根（ぼかし）"), value: om.feather, range: 0...1, step: 0.01, format: Self.pct,
                               begin: { model.beginGesture() },
                               change: { v in model.liveObjectMaskField(clipId: clip.id) { $0.feather = v } },
                               end: { model.commitGesture(ProjectModel.objectMaskUndoName) })
                    Toggle(L10n.t("反転（中を透明にする）"), isOn: Binding(get: { om.invert }, set: { on in
                        model.setObjectMaskField(clipId: clip.id) { $0.invert = on }
                    }))
                    .toggleStyle(.checkbox)
                    HStack(spacing: 8) {
                        Button(L10n.t("作り直す")) { model.createObjectMaskFromSeedRect(clipId: clip.id) }
                            .help(L10n.t("指定した範囲で対象を選び直し、追跡をやり直します"))
                        Button(L10n.t("オブジェクトマスクを削除")) { model.setObjectMask(nil, clipId: clip.id) }
                    }
                    .controlSize(.small)
                } else {
                    Text(L10n.t("人物や物を選んでマスクし、ショット全体を追跡します。プレビューで対象をクリックするか、下の範囲で指定してください。"))
                        .font(MCDesign.Font.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    seedSlider(L10n.t("横位置"), \.x, range: 0...1)
                    seedSlider(L10n.t("縦位置"), \.y, range: 0...1)
                    seedSlider(L10n.t("幅"), \.w, range: 0.01...1)
                    seedSlider(L10n.t("高さ"), \.h, range: 0.01...1)
                    if model.objectMaskPickingClipId == clip.id {
                        Text(L10n.t("プレビューで対象をクリックしてください"))
                            .font(MCDesign.Font.subheadline).foregroundStyle(.secondary)
                        Button(L10n.t("クリック指定をやめる")) { model.cancelObjectMaskPicking() }
                            .controlSize(.small)
                    } else {
                        HStack(spacing: 8) {
                            Button(L10n.t("人物（自動）で残す")) { model.createPersonObjectMask(clipId: clip.id, keepPerson: true) }
                                .help(L10n.t("クリック不要。画面内の人物を自動で選び、人物だけ残します"))
                            Button(L10n.t("人物（自動）を消す")) { model.createPersonObjectMask(clipId: clip.id, keepPerson: false) }
                                .help(L10n.t("クリック不要。画面内の人物を自動で選び、人物だけ透明にします"))
                        }
                        .controlSize(.small)
                        HStack(spacing: 8) {
                            Button(L10n.t("プレビューでクリックして指定")) { model.armObjectMaskPicking(clipId: clip.id) }
                            Button(L10n.t("指定した範囲で作成")) { model.createObjectMaskFromSeedRect(clipId: clip.id) }
                        }
                        .controlSize(.small)
                    }
                }
            }
            .disabled(model.isLocked && model.objectMaskProgress == nil)
            }
        }
    }

    /// 矩形指定の下書きのスライダー(下書きは保存しないので、Undo には載せない)。
    private func seedSlider(_ label: String, _ key: WritableKeyPath<TrackRect, Double>, range: ClosedRange<Double>) -> some View {
        InspectorField(label: label, trailing: Self.pct(model.objectMaskSeedRect[keyPath: key])) {
            Slider(value: Binding(get: { model.objectMaskSeedRect[keyPath: key] },
                                  set: { v in model.setObjectMaskSeedRectField { $0[keyPath: key] = v } }),
                   in: range, step: 0.01)
                .controlSize(.small)
        }
    }
}

import SwiftUI
import MovieCutCore

/// インスペクタ「音声」の VST3 節。
///
/// 到達範囲は「検出と指定の保存まで」で、音声処理は未対応。そのことを節の先頭に常時表示し、
/// 「対応した」ように見せない。スキャンはメタ情報だけを読む(`VST3Scanner`)ので軽く、
/// バイナリは一切読み込まない。スロットの追加・削除・有効切替は 1 操作 = 1 回の Undo。
struct VST3Panel: View {
    @ObservedObject var model: ProjectModel
    let clipId: String
    /// 起動時に開いておくか(撮影・試験用)。
    var forceExpanded = false

    @State private var open: Bool?
    @State private var scanResult: VST3ScanResult?

    private var clip: Clip? { model.clip(clipId) }
    private var slots: [AudioFx.VST3Slot] { clip?.audioFx?.vst3Slots ?? [] }

    var body: some View {
        if let c = clip, AudioFxEditing.supports(c) {
            DisclosureGroup(isExpanded: Binding(get: { open ?? (forceExpanded || !slots.isEmpty) },
                                                set: { open = $0 })) {
                VStack(alignment: .leading, spacing: 6) {
                    // 誤解させないための明示(到達状態の単一の置き場は Core の VST3HostAvailability)
                    Label(VST3HostAvailability.current.userFacingNote, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(Array(slots.enumerated()), id: \.offset) { index, slot in
                        slotRow(index: index, slot: slot)
                    }

                    HStack {
                        Menu {
                            if let scanResult {
                                let available = scanResult.usablePlugins.filter { info in
                                    !slots.contains { $0.bundleID.lowercased() == info.slotIdentifier.lowercased() }
                                }
                                if available.isEmpty {
                                    Text(scanResult.plugins.isEmpty ? "VST3 プラグインが見つかりません" : "検出したプラグインはすべて追加済みです")
                                } else {
                                    ForEach(Array(available.enumerated()), id: \.offset) { _, info in
                                        Button(info.name) {
                                            model.setAudioFx({ _ = AudioFxEditing.addVST3Slot(&$0, bundleID: info.slotIdentifier, name: info.name) },
                                                             name: ProjectModel.vst3UndoName, clipId: clipId)
                                        }
                                    }
                                }
                            } else {
                                Text("スキャン中…")
                            }
                        } label: {
                            Label("検出したプラグインを追加", systemImage: "plus")
                        }
                        Button("再スキャン") { rescan() }
                    }
                    if let scanResult {
                        Text(scanSummary(scanResult))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 4)
            } label: {
                Text("VST3 プラグイン(検出のみ)")
            }
            .onAppear { if scanResult == nil { rescan() } }
        }
    }

    private func slotRow(index: Int, slot: AudioFx.VST3Slot) -> some View {
        let detected = scanResult?.plugin(forSlotIdentifier: slot.bundleID)
        return HStack(spacing: 6) {
            Toggle(isOn: Binding(
                get: { slot.enabled },
                set: { on in model.setAudioFx({ _ = AudioFxEditing.setVST3SlotEnabled(&$0, at: index, enabled: on) },
                                              name: ProjectModel.vst3UndoName, clipId: clipId) })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(slot.displayName)
                    Text(slotStatus(slot: slot, detected: detected))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(role: .destructive) {
                model.setAudioFx({ _ = AudioFxEditing.removeVST3Slot(&$0, at: index) },
                                 name: ProjectModel.vst3UndoName, clipId: clipId)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("この VST3 指定を外す")
        }
    }

    private func slotStatus(slot: AudioFx.VST3Slot, detected: VST3BundleInfo?) -> String {
        var parts: [String] = []
        if let detected {
            parts.append("検出済み" + (detected.version.map { " v\($0)" } ?? ""))
            if !detected.supportsHostArchitecture {
                parts.append("この Mac 向けのビルドなし(\(detected.architectures.joined(separator: "/")))")
            }
        } else if scanResult != nil {
            parts.append("この Mac では未検出")
        }
        parts.append(slot.processingStatus.userFacingNote)
        return parts.joined(separator: "・")
    }

    private func scanSummary(_ result: VST3ScanResult) -> String {
        if result.plugins.isEmpty {
            return "置き場(/Library/Audio/Plug-Ins/VST3 など)に VST3 プラグインは見つかりませんでした。"
        }
        let broken = result.plugins.count - result.usablePlugins.count
        var s = "\(result.plugins.count) 件の VST3 プラグインを検出しました。"
        if broken > 0 { s += "うち \(broken) 件は構造が不完全です。" }
        return s
    }

    private func rescan() {
        scanResult = VST3Scanner.scanStandard()
    }
}

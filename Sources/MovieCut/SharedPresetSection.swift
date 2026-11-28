import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MovieCutCore

/// 設定の「プリセット共有」。書き出し/読み込みの入口をここ 1 箇所にまとめる(文言は全種別で共通)。
/// ファイルパネルは、ボタンを押したときだけ出す(テスト・検証環境では出さない)。
struct SharedPresetSection: View {
    let model: ProjectModel?
    @State private var kind: SharedPresetKind = .exportPreset
    @State private var pick = ""
    @State private var message = ""

    private static let uiKinds: [SharedPresetKind] = [.exportPreset, .itemTemplate, .colorCorrection, .gradeNodes]
    static var contentType: UTType { UTType(filenameExtension: SharedPresetFormat.fileExtension) ?? .json }

    private var names: [String] {
        switch kind {
        case .exportPreset: return CustomExportPresetStore.load(from: CustomExportPresetStore.defaultURL()).map(\.name)
        case .itemTemplate: return (ItemTemplateStore.standard()?.load() ?? []).map(\.name)
        default: return []
        }
    }

    var body: some View {
        GroupBox(L10n.t("プリセット共有")) {
            VStack(alignment: .leading, spacing: MCDesign.Spacing.xs) {
                Text(L10n.t("プリセットを共有ファイル(.mcpreset)にして、ほかの人へ渡したり読み込んだりできます。中身は設定の値だけです。色補正とグレーディングは選択中のクリップが対象です。音声プリセットは「おすすめ音声設定」から読み込みます。"))
                    .font(MCDesign.Font.caption).foregroundStyle(MCDesign.Color.textSecondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Picker("", selection: $kind) { ForEach(Self.uiKinds, id: \.self) { Text(L10n.t($0.label)).tag($0) } }
                        .labelsHidden().frame(width: 220)
                        .onChange(of: kind) { _, _ in pick = names.first ?? "" }
                    if !names.isEmpty {
                        Picker("", selection: $pick) { ForEach(names, id: \.self) { Text($0).tag($0) } }.labelsHidden().frame(width: 200)
                    }
                }
                HStack {
                    Button(L10n.t("共有ファイルへ書き出し…")) { exportFile() }
                    Button(L10n.t("共有ファイルから読み込み…")) { importFile() }
                }
                if !message.isEmpty { Text(message).font(MCDesign.Font.caption).fixedSize(horizontal: false, vertical: true) }
            }.padding(MCDesign.Spacing.s)
        }
        .onAppear { if pick.isEmpty { pick = names.first ?? "" } }
    }

    private func currentContent() -> SharedPresetContent? {
        switch kind {
        case .exportPreset:
            return CustomExportPresetStore.load(from: CustomExportPresetStore.defaultURL()).first { $0.name == pick }.map { .exportPreset($0) }
        case .itemTemplate:
            return (ItemTemplateStore.standard()?.load() ?? []).first { $0.name == pick }.map { .itemTemplate($0) }
        case .colorCorrection:
            return model?.selectedClip?.effects.first { SharedPresetFormat.colorKinds.contains($0.kind) }.map { .colorCorrection($0) }
        case .gradeNodes:
            guard let n = model?.selectedClip?.gradeNodes, !n.isEmpty else { return nil }
            return .gradeNodes(n)
        case .voicePreset: return nil
        }
    }

    private func exportFile() {
        guard let content = currentContent() else { message = L10n.t("書き出せるものがありません。種類と対象(選択クリップなど)を確認してください。"); return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.contentType]
        let name = kind == .exportPreset || kind == .itemTemplate ? pick : L10n.t(kind.label)
        panel.nameFieldStringValue = "\(name).\(SharedPresetFormat.fileExtension)"
        FilePanelPresenter.shared.present(panel, window: nil) { resp in
            guard resp == .OK, let url = panel.url else { return }
            let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            do { try SharedPresetFormat.write(SharedPreset(name: name, content: content), to: url, appVersion: v); message = L10n.t("書き出しました。") }
            catch { message = error.localizedDescription }
        }
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.contentType, .json]
        panel.allowsMultipleSelection = false
        FilePanelPresenter.shared.present(panel, window: nil) { resp in
            guard resp == .OK, let url = panel.url else { return }
            do { message = try apply(SharedPresetFormat.read(from: url)) }
            catch let e as LocalizedError { message = e.errorDescription ?? "" }
            catch { message = L10n.t("共有ファイルを読み込めませんでした。") }
        }
    }

    private func apply(_ p: SharedPreset) throws -> String {
        switch p.content {
        case .exportPreset(let e):
            guard let url = CustomExportPresetStore.defaultURL(), SharedPresetLibrary.add(e, toExportPresetsAt: url) else { return L10n.t("書き出しプリセットを追加できませんでした(上限など)。") }
            return String(format: L10n.t("書き出しプリセット「%@」を読み込みました。"), e.name)
        case .itemTemplate(let t):
            guard let store = ItemTemplateStore.standard(), SharedPresetLibrary.add(t, to: store) else { return L10n.t("アイテムテンプレートを追加できませんでした(上限など)。") }
            Task { @MainActor in ItemTemplateLibraryCache.invalidate() }
            return String(format: L10n.t("アイテムテンプレート「%@」を読み込みました。"), t.name)
        case .colorCorrection(let e):
            guard let model, let ids = Optional(model.selectedClipIDs), !ids.isEmpty else { return L10n.t("色補正を入れるクリップを選んでください。") }
            let ok = model.edit("共有ファイルの色補正") { proj in
                for ti in proj.tracks.indices { for ci in proj.tracks[ti].clips.indices where ids.contains(proj.tracks[ti].clips[ci].id) {
                    SharedPresetFormat.apply(colorCorrection: e, to: &proj.tracks[ti].clips[ci])
                } }
            }
            return ok ? L10n.t("選択クリップに色補正を入れました。") : L10n.t("色補正を入れられるクリップがありませんでした。")
        case .gradeNodes(let n):
            guard let model, let ids = Optional(model.selectedClipIDs), !ids.isEmpty else { return L10n.t("ノードを入れるクリップを選んでください。") }
            let ok = model.edit("共有ファイルのグレーディングノード") { proj in
                for ti in proj.tracks.indices { for ci in proj.tracks[ti].clips.indices where ids.contains(proj.tracks[ti].clips[ci].id) {
                    SharedPresetFormat.apply(gradeNodes: n, to: &proj.tracks[ti].clips[ci])
                } }
            }
            return ok ? L10n.t("選択クリップにグレーディングノードを入れました。") : L10n.t("ノードを入れられるクリップがありませんでした。")
        case .voicePreset:
            return L10n.t("音声プリセットは、キャラの「おすすめ音声設定」画面の「ファイルから読み込み」で読み込みます。")
        }
    }
}

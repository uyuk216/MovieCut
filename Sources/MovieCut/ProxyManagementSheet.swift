import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MovieCutCore

/// 出力 ▸ プロキシを管理…: 素材ごとのプロキシ(作成・外部の関連付け・削除)と、取り込み時の自動作成の設定。
/// プロキシはプレビュー専用で、書き出しは常に原本。外部のファイルは「削除」の対象にしない(生成したものだけを消す)。
struct ProxyManagementSheet: View {
    @ObservedObject var model: ProjectModel
    @State private var autoCreate = ProxySettings.autoCreateEnabled()

    var body: some View {
        let items = ProxySources.collect(in: model.rootProject)
        let generatedCount = items.filter { hasGenerated($0.path) }.count
        VStack(alignment: .leading, spacing: MCDesign.Spacing.m) {
            HStack {
                Text(L10n.t("プロキシの管理")).font(MCDesign.Font.title3.bold())
                Spacer()
                Text("\(items.count) 件").foregroundStyle(MCDesign.Color.secondaryLabel).monospacedDigit()
            }
            Text(L10n.t("プロキシはプレビューを軽くするための映像です。書き出しは常に元の素材を使います。"))
                .font(MCDesign.Font.caption).foregroundStyle(MCDesign.Color.secondaryLabel)
            if items.isEmpty {
                InspectorGuideCard(symbol: "film", heading: L10n.t("映像の素材がありません"),
                                   message: L10n.t("映像を取り込むと、ここで管理できます。"))
                    .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                List(items, id: \.path) { item in row(item) }
                    .frame(minHeight: 240)
            }
            Toggle(L10n.t("取り込み時にプロキシを自動作成"), isOn: $autoCreate)
                .help(L10n.t("既定はオフです。オンにすると、大きい映像を取り込んだときに背景でプロキシを作ります。"))
                .onChange(of: autoCreate) { _, on in ProxySettings.setAutoCreate(on) }
            HStack {
                Button(L10n.t("すべて削除")) { _ = model.deleteGeneratedProxiesForProject() }
                    .disabled(model.isLocked || generatedCount == 0)
                    .help(L10n.t("この書類の生成済みプロキシを消します。元の素材と外部のプロキシのファイルは消えません。"))
                Spacer()
                Button(L10n.t("閉じる")) { model.showProxySheet = false }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(MCDesign.Spacing.l)
        .frame(width: 640)
    }

    private func row(_ item: ProxySourceInfo) -> some View {
        let status = model.proxyStatus(for: item.path)
        let linked = model.rootProject.proxyLinks[item.path] != nil
        let generated = generatedURL(item.path)
        return HStack(alignment: .center, spacing: MCDesign.Spacing.m) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: MCDesign.Spacing.xs) {
                    Text(URL(fileURLWithPath: item.path).lastPathComponent).lineLimit(1)
                    ForEach(contextBadges(item.contexts), id: \.self) { badge in
                        Text(badge).font(MCDesign.Font.badge)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(MCDesign.Color.control))
                    }
                }
                Text(item.path).font(MCDesign.Font.caption).foregroundStyle(MCDesign.Color.secondaryLabel)
                    .lineLimit(1).truncationMode(.middle)
                Text(statusLabel(status, generated: generated))
                    .font(MCDesign.Font.caption).foregroundStyle(MCDesign.Color.secondaryLabel)
            }
            Spacer()
            if case .none = status {
                Button(L10n.t("作成")) { model.makeProxy(source: item.path) }.disabled(model.isLocked)
            }
            Button(linked ? L10n.t("変更…") : L10n.t("関連付ける…")) { chooseProxy(for: item.path) }
                .disabled(model.isLocked)
            if linked {
                Button(L10n.t("解除")) { _ = model.detachProxyLink(source: item.path) }.disabled(model.isLocked)
            }
            if generated != nil {
                Button(L10n.t("削除")) { _ = model.deleteGeneratedProxy(source: item.path) }
                    .disabled(model.isLocked)
                    .help(L10n.t("生成したプロキシだけを消します。元の素材と外部のプロキシのファイルは消えません。"))
            }
        }
        .padding(.vertical, 2)
    }

    /// 複合・シーンの中で使われている素材に付ける印(トップレベルは印なし)。
    private func contextBadges(_ contexts: Set<ProxySourceContext>) -> [String] {
        var out: [String] = []
        if contexts.contains(.compound) { out.append(L10n.t("複合クリップ内")) }
        if contexts.contains(.scene) { out.append(L10n.t("シーン内")) }
        return out
    }

    private func generatedURL(_ source: String) -> URL? {
        ProxyStore.existingProxy(for: URL(fileURLWithPath: source), directory: model.proxyDirectory)
    }

    private func hasGenerated(_ source: String) -> Bool { generatedURL(source) != nil }

    /// 状態の文字: 外部を使っているならその名前、無ければ生成済み(サイズ付き)か未作成。
    private func statusLabel(_ status: ProxyStatus, generated: URL?) -> String {
        switch status {
        case .external(let path):
            return L10n.t("外部プロキシを使用中") + ": " + URL(fileURLWithPath: path).lastPathComponent
        case .generated, .none:
            guard let u = generated else { return L10n.t("未作成") }
            let bytes = ((try? FileManager.default.attributesOfItem(atPath: u.path))?[.size] as? NSNumber)?.int64Value ?? 0
            return L10n.t("生成済み") + "（" + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) + "）"
        }
    }

    /// 関連付けるプロキシの映像をファイルから選ぶ。
    private func chooseProxy(for source: String) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.movie]
        panel.message = L10n.t("プレビューに使う映像を選んでください。書き出しは元の素材を使います。")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.attachProxyLink(source: source, proxyPath: url.path)
    }
}

import Foundation
import AppKit
import UniformTypeIdentifiers
import MovieCutCore

/// プラグイン配線(F-1): プラグインエフェクトの追加(メニュー・インスペクタから)と、
/// プラグイン書き出し形式の実行(出力メニューから)。
/// 境界は W2-13 の PluginHost / EffectPipeline / PluginExportJob のまま変えず、
/// ここではアプリ側の到達経路だけを足す(追加方式: プラグインが無い・引けないときは何もしない)。
extension ProjectModel {

    // MARK: エフェクトプラグイン

    /// エフェクト識別子からプラグインの記述子を引く(大文字小文字は区別しない)。無ければ nil。
    func pluginEffectDescriptor(for kind: String) -> PluginEffectDescriptor? {
        let key = kind.trimmingCharacters(in: .whitespaces).lowercased()
        return AppServices.pluginEffectDescriptors.first { $0.id.lowercased() == key }
    }

    /// プラグインエフェクトをクリップへ足す(記述子の初期値で。1 回の Undo)。
    @discardableResult
    func addPluginEffect(_ descriptor: PluginEffectDescriptor, clipId: String? = nil) -> Bool {
        guard !isLocked, let id = clipId ?? selectedClipId, let c = clip(id) else { return false }
        var effect = Effect(kind: descriptor.id)
        for s in descriptor.params { effect.params[s.key] = s.defaultValue }
        effect.color = descriptor.defaultColor
        var probe = c
        guard EffectEditing.append(&probe, [effect]) else { return false }
        setClipProperty({ _ = EffectEditing.append(&$0, [effect]) }, name: "エフェクトの追加: \(descriptor.label)", clipId: c.id)
        return true
    }

    /// メニュー「クリップ ▸ エフェクト ▸ (プラグインのエフェクト名)」。記述子が引けないときは何もしない。
    @discardableResult
    func addPluginEffectSelected(_ effectID: String) -> Bool {
        guard let descriptor = pluginEffectDescriptor(for: effectID) else { return false }
        return addPluginEffect(descriptor)
    }

    // MARK: 書き出しプラグイン

    /// 出力 ▸ プラグイン形式で書き出す ▸ 形式名。保存パネルで場所を選び、書き出し、終わったら Finder で見せる。
    func chooseAndExportPluginFormat(_ formatID: String) {
        guard canExport else { return }
        let key = formatID.trimmingCharacters(in: .whitespaces).lowercased()
        guard let format = AppServices.pluginExportFormats.first(where: { $0.id.lowercased() == key }) else { return }
        if reportMissingMediaForExport() { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension) ?? .data]
        panel.nameFieldStringValue = documentName + "." + format.fileExtension
        panel.canCreateDirectories = true
        panel.title = "\(format.name)で書き出す"
        panel.message = format.detail ?? "プラグインが提供する形式で書き出します。"
        let run: (NSApplication.ModalResponse) -> Void = { [weak self] resp in
            guard resp == .OK, let picked = panel.url, let self else { return }
            let url = picked.pathExtension.lowercased() == format.fileExtension.lowercased()
                ? picked : picked.appendingPathExtension(format.fileExtension)
            Task { @MainActor in
                if case .success(let done) = await self.runPluginExport(formatID: format.id, to: url, range: self.project.exportRange) {
                    NSWorkspace.shared.activateFileViewerSelecting([done])
                }
            }
        }
        FilePanelPresenter.shared.present(panel, window: window, completion: run)
    }

    /// プラグイン形式で書き出す(進み具合・キャンセル・失敗の扱いは MP4 と同じ書き出しシート)。
    /// 担当プラグインが解決できない形式は、黙って内蔵形式に化けずエラーにする。
    func runPluginExport(formatID: String, to url: URL, range: ExportRange? = nil) async -> ExportOutcome {
        guard !directExportBlocked() else { return .failure(ExportError.writerFailed(nil)) }
        if reportMissingMediaForExport() { return .failure(ExportError.writerFailed(nil)) }
        let snapshot = project
        let assets = self.assets
        return await runJob(title: "プラグイン形式で書き出しています", fileName: url.lastPathComponent, notices: [],
                            success: "\(url.lastPathComponent) に書き出しました", result: url) { progress in
            let host = AppServices.makePluginHost(for: snapshot)
            let result = try await PluginExportJob.runIfAvailable(host: host, formatID: formatID, project: snapshot, assets: assets, range: range, to: url, progress: progress)
            if result == nil { throw PluginError.noExportPlugin(formatID: formatID) }
        }
    }
}

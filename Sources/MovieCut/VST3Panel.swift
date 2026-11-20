import SwiftUI
import AppKit
import MovieCutCore

/// インスペクタ「音声」の VST3 節。
///
/// 節の先頭には到達状態(`VST3HostAvailability`)を常時表示し、「対応した」ように見せない。
/// スキャンはメタ情報だけを読む(`VST3Scanner`)ので軽く、バイナリは一切読み込まない。
/// スロットの追加・削除・有効切替は 1 操作 = 1 回の Undo。
/// 音声処理はブリッジが使える環境で、再生・書き出し等のプロバイダ経由の経路に効く
/// (プロバイダの生成元は `AppServices.vst3EffectProvider` に一本化)。
struct VST3Panel: View {
    @ObservedObject var model: ProjectModel
    let clipId: String
    /// 起動時に開いておくか(撮影・試験用)。
    var forceExpanded = false

    @State private var open: Bool? = InspectorDisclosurePersistence.saved("inspector.audioFx.vst3")
    @State private var scanResult: VST3ScanResult?
    /// 純正 GUI を開けなかったとき/持たないときの穏やかな通知(パラメータ一覧など従来表示は壊さない)。
    @State private var editorNote: String?

    private var clip: Clip? { model.clip(clipId) }
    private var slots: [AudioFx.VST3Slot] { clip?.audioFx?.vst3Slots ?? [] }

    var body: some View {
        if let c = clip, AudioFxEditing.supports(c) {
            DisclosureGroup(isExpanded: Binding(get: { open ?? (forceExpanded || !slots.isEmpty) },
                                                set: { open = $0; InspectorDisclosurePersistence.save($0, id: "inspector.audioFx.vst3") })) {
                VStack(alignment: .leading, spacing: 6) {
                    // 誤解させないための明示(到達状態の単一の置き場は Core の VST3HostAvailability)
                    Label(VST3HostAvailability.current.userFacingNote, systemImage: "info.circle")
                        .font(MCDesign.Font.caption)
                        .foregroundStyle(MCDesign.Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    // 純正 GUI は土台のみ。実プラグインでの表示確認が未実施であることを明示する
                    Text(VST3HostAvailability.current.editorUserFacingNote)
                        .font(MCDesign.Font.caption)
                        .foregroundStyle(MCDesign.Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(Array(slots.enumerated()), id: \.offset) { index, slot in
                        slotRow(index: index, slot: slot)
                    }
                    if let editorNote {
                        Text(editorNote)
                            .font(MCDesign.Font.caption)
                            .foregroundStyle(MCDesign.Color.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
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
                                Text(L10n.t("スキャン中…"))
                            }
                        } label: {
                            Label(L10n.t("検出したプラグインを追加"), systemImage: "plus")
                        }
                        Button(L10n.t("再スキャン")) { rescan() }
                    }
                    if let scanResult {
                        Text(scanSummary(scanResult))
                            .font(MCDesign.Font.caption)
                            .foregroundStyle(MCDesign.Color.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 4)
            } label: {
                Text(VST3HostAvailability.current.canProcessAudio ? L10n.t("VST3 プラグイン") : "VST3 プラグイン(検出のみ)")
                    .font(MCDesign.Font.calloutSemibold).foregroundStyle(MCDesign.Color.textSecondary)
            }
            .onAppear { if scanResult == nil { rescan() } }
        }
    }

    /// パラメータ控えの簡易操作(W6-1)。控えがある項目だけを正規化値スライダーで出す。
    /// ドラッグは他の音声パネルと同じく 1 回の Undo にまとまる。
    @ViewBuilder
    private func paramSliders(index: Int, slot: AudioFx.VST3Slot) -> some View {
        if let params = slot.params, !params.isEmpty {
            ForEach(params.keys.sorted(), id: \.self) { key in
                LiveSlider(label: L10n.t("パラメータ") + " " + key, value: params[key] ?? 0, range: 0...1, step: 0.01,
                           format: { "\(Int(($0 * 100).rounded()))%" },
                           begin: { model.beginGesture() },
                           change: { v in model.liveAudioFx({ _ = AudioFxEditing.setVST3SlotParam(&$0, at: index, key: key, value: v) },
                                                            name: ProjectModel.vst3ParamUndoName, clipId: clipId) },
                           end: { model.commitGesture(ProjectModel.vst3ParamUndoName) })
            }
        }
        if slot.state != nil {
            Text(L10n.t("プラグイン状態データあり"))
                .font(MCDesign.Font.caption)
                .foregroundStyle(MCDesign.Color.textSecondary)
        }
    }

    private func slotRow(index: Int, slot: AudioFx.VST3Slot) -> some View {
        let detected = scanResult?.plugin(forSlotIdentifier: slot.bundleID)
        return VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 6) {
            Toggle(isOn: Binding(
                get: { slot.enabled },
                set: { on in model.setAudioFx({ _ = AudioFxEditing.setVST3SlotEnabled(&$0, at: index, enabled: on) },
                                              name: ProjectModel.vst3UndoName, clipId: clipId) })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(slot.displayName)
                    Text(slotStatus(slot: slot, detected: detected))
                        .font(MCDesign.Font.caption)
                        .foregroundStyle(MCDesign.Color.textSecondary)
                }
            }
            Spacer()
            Button(L10n.t("純正 GUI を開く")) { openEditor(slot: slot, detected: detected) }
                .disabled(!VST3HostAvailability.current.canProcessAudio)
                .help(VST3HostAvailability.current.canProcessAudio
                      ? L10n.t("プラグイン純正の画面を別ウィンドウで開く")
                      : L10n.t("VST3 ブリッジが無い環境では使えません"))
            Button(role: .destructive) {
                model.setAudioFx({ _ = AudioFxEditing.removeVST3Slot(&$0, at: index) },
                                 name: ProjectModel.vst3UndoName, clipId: clipId)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help(L10n.t("この VST3 指定を外す"))
        }
        if slot.enabled { paramSliders(index: index, slot: slot) }
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

    /// 純正 GUI を専用ウィンドウで開く。失敗は例外にせず、穏やかな文言にして出す。
    private func openEditor(slot: AudioFx.VST3Slot, detected: VST3BundleInfo?) {
        editorNote = nil
        guard let detected else {
            editorNote = L10n.t("このプラグインはこの Mac で検出できないため、純正 GUI を開けません。")
            return
        }
        guard let backend = VST3NativeBridgeBackend() else {
            editorNote = L10n.t("VST3 ブリッジが使えないため、純正 GUI を開けません。")
            return
        }
        let cid = detected.moduleClasses.first { $0.isAudioModule }?.cid
        let name = slot.displayName
        VST3EditorWindowManager.shared.open(title: name, backend: backend,
                                            bundlePath: detected.bundleURL.path, cid: cid) { message in
            editorNote = message
        }
    }
}

// MARK: - 純正 GUI の専用ウィンドウ(R5 キュー3)

/// エディタの初期コンテンツサイズ(取得できなければ 480×320)。純ロジックとしてテストする。
func vst3EditorInitialContentSize(_ size: VST3EditorSize?) -> CGSize {
    guard let size, size.isValid else { return CGSize(width: 480, height: 320) }
    return CGSize(width: CGFloat(size.width), height: CGFloat(size.height))
}

/// プラグインの IPlugView が取り付く親ビュー。`VST3EditorSession` を所有する。
/// 自分のポインタを不透明な UInt64 親ハンドルとして Core に渡す(Core は AppKit を知らない)。
final class VST3EditorHostView: NSView {
    private(set) var session: VST3EditorSession?
    /// 開けなかったとき(エディタ無しを含む)の通知。
    var onOpenFailed: ((String) -> Void)?

    /// ウィンドウ生成側が明示的に呼ぶ。viewDidMoveToWindow 等の暗黙のタイミングには頼らない。
    @discardableResult
    func openEditor(backend: any VST3BridgeBackend, bundlePath: String, cid: String?) -> VST3EditorSize? {
        let session = VST3EditorSession(backend: backend, bundlePath: bundlePath, cid: cid)
        let handle = UInt64(UInt(bitPattern: Unmanaged.passUnretained(self).toOpaque()))
        switch session.open(parentHandle: handle) {
        case .success(let size):
            self.session = session
            return size
        case .failure(let error):
            onOpenFailed?(Self.message(for: error))
            return nil
        }
    }

    func closeEditor() {
        session?.close()
        session = nil
    }

    static func message(for error: VST3EditorSessionError) -> String {
        switch error {
        case .noEditor: return L10n.t("このプラグインには純正 GUI がありません。パラメータ一覧をご利用ください。")
        case .bridgeFailure: return L10n.t("純正 GUI を開けませんでした(プラグインが画面の表示に対応していない可能性があります)。")
        case .wrongState, .invalidSize: return L10n.t("純正 GUI を開けませんでした。")
        }
    }
}

/// 開いたエディタウィンドウを閉じるまで保持するレジストリ(Panel の State が外れても生き続ける)。
@MainActor
final class VST3EditorWindowManager {
    static let shared = VST3EditorWindowManager()
    private var controllers: [ObjectIdentifier: VST3EditorWindowController] = [:]

    func open(title: String, backend: any VST3BridgeBackend, bundlePath: String, cid: String?,
              onFailure: @escaping (String) -> Void) {
        let host = VST3EditorHostView(frame: .zero)
        host.onOpenFailed = onFailure
        // 親ビューは先に用意しておく(取り付けはウィンドウ生成より前に行い、失敗ならウィンドウを出さない)
        guard let size = host.openEditor(backend: backend, bundlePath: bundlePath, cid: cid) else { return }
        let controller = VST3EditorWindowController(host: host, title: title,
                                                    contentSize: vst3EditorInitialContentSize(size))
        let key = ObjectIdentifier(controller)
        controllers[key] = controller
        controller.onClosed = { [weak self] in self?.controllers[key] = nil }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }
}

final class VST3EditorWindowController: NSWindowController, NSWindowDelegate {
    private let host: VST3EditorHostView
    var onClosed: (() -> Void)?
    /// プラグイン要求でウィンドウを動かしている間は、windowDidEndLiveResize 経由の再通知を避ける。
    private var applyingPluginResize = false

    init(host: VST3EditorHostView, title: String, contentSize: CGSize) {
        self.host = host
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: contentSize),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = title + "(" + L10n.t("純正 GUI") + ")"
        window.isReleasedWhenClosed = false
        host.frame = NSRect(origin: .zero, size: contentSize)
        host.autoresizingMask = [.width, .height]
        window.contentView = host
        super.init(window: window)
        window.delegate = self
        window.center()
        // プラグイン → ホストのリサイズ要求: ウィンドウのコンテンツサイズを合わせて受理する
        host.session?.onResizeRequested = { [weak self] size in
            guard let self, let window = self.window, size.isValid else { return false }
            let target = CGSize(width: CGFloat(size.width), height: CGFloat(size.height))
            if window.contentView?.frame.size == target { return true }
            self.applyingPluginResize = true
            window.setContentSize(target)
            self.applyingPluginResize = false
            return true
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) は使わない") }

    /// ライブリサイズの終了時に 1 回だけ伝える(windowDidResize だとドラッグ中に毎フレーム
    /// プラグインへ onSize が飛び、重い GUI で固まりやすいため)。
    func windowDidEndLiveResize(_ notification: Notification) {
        guard !applyingPluginResize, let content = window?.contentView else { return }
        let size = VST3EditorSize(width: Int32(content.frame.width.rounded()), height: Int32(content.frame.height.rounded()))
        host.session?.resize(to: size)
    }

    func windowWillClose(_ notification: Notification) {
        host.closeEditor()   // 確実に destroyEditorView → dispose の順で畳む
        onClosed?()
    }
}

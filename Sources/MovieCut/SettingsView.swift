import SwiftUI
import AppKit
import MovieCutCore

/// 設定ウィンドウの中身。シートでもウィンドウでもない単体の View。
/// アプリ全体の設定(言語・表示・セキュリティ・AquesTalk・Whisper)は常に出し、
/// 動画設定(VideoSettingsDraft 系)は前面のプロジェクト(ActiveDocument.shared)に対して編集する。
struct SettingsView: View {
    @ObservedObject private var documents: ActiveDocument

    init(documents: ActiveDocument? = nil) { self.documents = documents ?? ActiveDocument.shared }

    var body: some View {
        let model = documents.model
        // 前面のプロジェクトが替わったら中身を作り直す(draft を新しいモデルから作る)
        ScrollView { SettingsContent(model: model).id(model.map { ObjectIdentifier($0) }) }
    }
}

struct SettingsContent: View {
    /// 設定ウィンドウの節の題と識別子。ビューが実際に使う定数で、構成テストもこれを見る
    /// (SwiftUI の中身は画面の外では NSView/アクセシビリティの木に出てこないため)。
    enum Section {
        static var video: String { L10n.t("動画") }
        static var language: String { L10n.t("言語") }
        static var display: String { L10n.t("表示") }
        static let languageID = "settings-language"
        static let fontScaleID = "settings-font-scale"
        /// プロジェクトの有無で出る節の題(アプリ設定は常に出し、動画だけプロジェクトが要る)。
        static func titles(hasProject: Bool) -> [String] {
            (hasProject ? [video] : []) + [language, display]
        }
    }

    /// 音声サーバーの URL が送れない先なら、その理由(日本語)。
    private var voiceEndpointProblem: String? {
        do { try VoiceEndpointPolicy.current.validate(draft.voicevoxUrl); return nil }
        catch { return error.localizedDescription }
    }

    private func chooseAquesTalk() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.message = "AquesTalkPlayer の実行ファイルを選んでください"
        panel.prompt = "選ぶ"
        guard FilePanelPresenter.shared.runModal(panel) == .OK, let url = panel.url else { return }
        switch ExecutableTrust.validate(path: url.path) {
        case .success:
            aquesPath = url.path; aquesMessage = ""
            SecuritySettings.setAquestalkPath(url.path)
        case .failure(let why):
            aquesMessage = why.message
        }
    }

    private func chooseWhisperExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.message = L10n.t("whisper.cpp の実行ファイル(whisper-cli)を選んでください")
        panel.prompt = L10n.t("選ぶ")
        guard FilePanelPresenter.shared.runModal(panel) == .OK, let url = panel.url else { return }
        // シンボリックリンク(Homebrew など)は実体に直してから検証する(Core の WhisperLocator と同じ)。
        let real = url.resolvingSymlinksInPath().standardizedFileURL.path
        switch ExecutableTrust.validate(path: real) {
        case .success:
            whisperPath = url.path; whisperMessage = ""
            SecuritySettings.setWhisperPath(url.path)
        case .failure(let why):
            whisperMessage = why.message
        }
    }

    private func chooseWhisperModel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.init(filenameExtension: "bin") ?? .data]
        panel.message = L10n.t("Whisper のモデル(ggml-base.bin など)を選んでください")
        panel.prompt = L10n.t("選ぶ")
        guard FilePanelPresenter.shared.runModal(panel) == .OK, let url = panel.url else { return }
        guard WhisperLocator.validateModel(path: url.path) != nil else {
            whisperMessage = L10n.t("モデルは .bin のファイルを選んでください。")
            return
        }
        whisperModelPath = url.path; whisperMessage = ""
        SecuritySettings.setWhisperModelPath(url.path)
    }

    /// 前面のプロジェクト。nil のときは動画の節を出さない。
    let model: ProjectModel?
    @State private var draft: VideoSettingsDraft
    @State private var res: ResolutionInput
    @State private var fpsChoice: String
    @State private var fpsText: String
    // 安全に関わる設定は、プロジェクトではなくアプリの設定(UserDefaults)に保存する
    @State private var allowRemoteVoice = SecuritySettings.allowRemoteVoice()
    @State private var remoteHosts = SecuritySettings.remoteVoiceHosts().joined(separator: ", ")
    @State private var aquesPath = SecuritySettings.aquestalkPath() ?? ""
    @State private var aquesMessage = ""
    @State private var whisperPath = SecuritySettings.whisperPath() ?? ""
    @State private var whisperModelPath = SecuritySettings.whisperModelPath() ?? ""
    @State private var whisperMessage = ""
    @State private var original: VideoSettingsDraft
    private static let customFpsTag = "custom"

    init(model: ProjectModel?) {
        self.model = model
        let d = VideoSettingsDraft(model?.project ?? Project())
        _draft = State(initialValue: d)
        _res = State(initialValue: ResolutionInput(width: d.width, height: d.height, codec: d.codec, fps: d.fps))
        let isPreset = FrameRate.presets.contains { FrameRate.same($0, d.fps) }
        _fpsChoice = State(initialValue: isPreset ? FrameRate.label(d.fps) : Self.customFpsTag)
        _fpsText = State(initialValue: FrameRate.label(d.fps))
        _original = State(initialValue: d)
    }

    /// 前面のプロジェクトが編集中・書き出し中などでロックされているか(動画の節を無効にする)。
    private var projectLocked: Bool { model?.isLocked ?? false }

    private func load(_ d: VideoSettingsDraft) {
        draft = d
        res = ResolutionInput(width: d.width, height: d.height, codec: d.codec, fps: d.fps)
        let isPreset = FrameRate.presets.contains { FrameRate.same($0, d.fps) }
        fpsChoice = isPreset ? FrameRate.label(d.fps) : Self.customFpsTag
        fpsText = FrameRate.label(d.fps)
        original = d
    }

    /// 変更の破棄: draft をモデルの現在値で作り直す。
    private func resetDraft() {
        guard let model else { return }
        load(VideoSettingsDraft(model.project))
    }

    /// 適用: 従来どおり applySettings(draft, original:)。ウィンドウは閉じず、original を適用済みに更新する。
    private func apply() {
        guard let model, !model.isLocked, res.isValid, let w = res.width, let h = res.height,
              case .success(let f) = FrameRateInput.parse(fpsText) else { return }
        draft.width = w; draft.height = h; draft.fps = f
        model.applySettings(draft, original: original)
        original = draft
    }

    private var sizeKey: String {
        let k = "\(res.width ?? 0)x\(res.height ?? 0)"
        return ResolutionPresets.isPreset(k) ? k : ResolutionPresets.customKey
    }
    @State private var language: AppLanguage = L10n.storedOverride()
    /// 文字サイズの段(即時保存。変えるとこのシート自身も再描画される)。
    @State private var fontScaleStep: FontScaleStep = FontScaleStore.current
    static func fontScaleLabel(_ s: FontScaleStep) -> String {
        switch s {
        case .small: return L10n.t("小（見出し 13pt・本文 12pt）")
        case .mediumSmall: return L10n.t("やや小（見出し 15pt・本文 13pt）")
        case .standard: return L10n.t("標準（見出し 17pt・本文 14pt）")
        case .large: return L10n.t("大（見出し 18pt・本文 16pt）")
        case .extraLarge: return L10n.t("特大（見出し 20pt・本文 18pt）")
        }
    }
    private var fpsValid: Bool { if case .success = FrameRateInput.parse(fpsText) { return true } else { return false } }
    private var bgPreset: String {
        let b = draft.bg.lowercased()
        return ["#000000", "#ffffff", "#00b140", Project.transparentBackground].contains(b) ? b : "custom"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MCDesign.Spacing.m) {
            Text(L10n.t("設定")).font(MCDesign.Font.headline)
            Text(L10n.t("ここはアプリ全体の設定です。動画の設定だけは、前面のプロジェクトに保存されます。"))
                .font(MCDesign.Font.caption).foregroundStyle(MCDesign.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if model == nil {
                Text(L10n.t("プロジェクトを開くと動画の設定が編集できます"))
                    .font(MCDesign.Font.caption).foregroundStyle(MCDesign.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings-no-project-note")
            }
            if model != nil {
            GroupBox(Section.video) {
                Grid(alignment: .leading, horizontalSpacing: MCDesign.Spacing.m, verticalSpacing: MCDesign.Spacing.s) {
                    GridRow(alignment: .top) {
                        Text(L10n.t("サイズ"))
                        VStack(alignment: .leading, spacing: MCDesign.Spacing.s) {
                            Picker("", selection: Binding(get: { sizeKey }, set: { k in
                                if let sz = ResolutionInput.parseSize(k) { res.set(width: sz.width, height: sz.height) }
                            })) {
                                ForEach(ResolutionPresets.items, id: \.key) { Text($0.label).tag($0.key) }
                                Text(L10n.t("カスタム")).tag(ResolutionPresets.customKey)
                            }.labelsHidden().frame(width: 200)
                            ResolutionFields(input: $res)
                        }
                    }
                    GridRow(alignment: .top) {
                        Text(L10n.t("FPS"))
                        VStack(alignment: .leading, spacing: MCDesign.Spacing.s) {
                            Picker("", selection: Binding(get: { fpsChoice }, set: { k in
                                fpsChoice = k
                                if k != Self.customFpsTag { fpsText = k }
                            })) {
                                ForEach(FrameRate.presets, id: \.self) { Text("\(FrameRate.label($0)) fps").tag(FrameRate.label($0)) }
                                Text(L10n.t("カスタム")).tag(Self.customFpsTag)
                            }.labelsHidden().frame(width: 200)
                            if fpsChoice == Self.customFpsTag {
                                FrameRateFields(text: $fpsText)
                            }
                        }
                    }
                    GridRow {
                        Text(L10n.t("背景色"))
                        HStack {
                            ColorPicker("", selection: Binding(get: { Color(hex: draft.bg) }, set: { draft.bg = $0.hexString }), supportsOpacity: false)
                                .labelsHidden()
                            Picker("", selection: Binding(get: { bgPreset }, set: { v in if v != "custom" { draft.bg = v } })) {
                                Text(L10n.t("黒")).tag("#000000")
                                Text(L10n.t("白")).tag("#ffffff")
                                Text(L10n.t("緑（クロマキー）")).tag("#00b140")
                                Text(L10n.t("透明（ProRes 4444・APNG 用）")).tag(Project.transparentBackground)
                                Text(L10n.t("自由")).tag("custom")
                            }.labelsHidden().frame(width: 170)
                        }
                    }
                    GridRow {
                        Text(L10n.t("書き出し形式"))
                        VStack(alignment: .leading, spacing: MCDesign.Spacing.xs) {
                            Picker("", selection: $draft.codec) {
                                Text(L10n.t("H.264（どこでも再生できる）")).tag("h264")
                                Text(L10n.t("HEVC（同じ画質で小さい・4K向け）")).tag("hevc")
                                Text(L10n.t("ProRes 422（編集用・.mov）")).tag(OutputPlan.proRes422)
                                Text(L10n.t("ProRes 422 HQ（高画質・編集用・.mov）")).tag(OutputPlan.proRes422HQ)
                                Text(L10n.t("ProRes 422 LT（軽い・編集用・.mov）")).tag(OutputPlan.proRes422LT)
                                Text(L10n.t("ProRes 422 Proxy（最も軽い・下書き用・.mov）")).tag(OutputPlan.proRes422Proxy)
                                Text(L10n.t("ProRes 4444（透明を残せる・.mov）")).tag(OutputPlan.proRes4444)
                            }.labelsHidden().frame(width: 260)
                            if draft.codec == "h264", let w = res.width, let h = res.height, !OutputPlan.h264Supports(width: w, height: h) {
                                Text(L10n.t("注意: このサイズは H.264 で書き出せないので、書き出しは HEVC になります")).font(MCDesign.Font.caption).foregroundStyle(.orange)
                            }
                        }
                    }
                }
                .padding(MCDesign.Spacing.s)
            }
            .disabled(projectLocked)
            }
            GroupBox(Section.language) {
                VStack(alignment: .leading, spacing: MCDesign.Spacing.xs) {
                    Picker("", selection: Binding(get: { language }, set: { v in language = v; L10n.setOverride(v) })) {
                        ForEach(AppLanguage.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().frame(width: 320)
                    .accessibilityIdentifier(Section.languageID)
                    Text(L10n.t("言語の切り替えは、メニューなどを開き直すと反映されます。")).font(MCDesign.Font.caption).foregroundStyle(MCDesign.Color.textSecondary)
                }.padding(MCDesign.Spacing.s)
            }
            GroupBox(Section.display) {
                HStack {
                    Text(L10n.t("文字サイズ"))
                    Picker("", selection: Binding(get: { fontScaleStep }, set: { v in fontScaleStep = v; FontScaleStore.set(v) })) {
                        ForEach(FontScaleStep.allCases, id: \.self) { Text(Self.fontScaleLabel($0)).tag($0) }
                    }
                    .labelsHidden().frame(width: 320)
                    .accessibilityIdentifier(Section.fontScaleID)
                }.padding(MCDesign.Spacing.s)
            }
            SharedPresetSection(model: model)
            GroupBox(L10n.t("VOICEVOX（互換エンジンも可）")) {
                VStack(alignment: .leading, spacing: MCDesign.Spacing.xs) {
                    TextField("エンジンのURL", text: $draft.voicevoxUrl)
                        .disabled(model == nil || projectLocked)
                    Text(L10n.t("VOICEVOX は 50021、COEIROINK は 50031、SHAREVOX は 50025 が初期値です。"))
                        .font(MCDesign.Font.caption).foregroundStyle(MCDesign.Color.textSecondary)
                    if let reason = voiceEndpointProblem {
                        Text(reason).font(MCDesign.Font.caption).foregroundStyle(.red)
                    }
                    Divider()
                    Toggle(L10n.t("リモートの音声サーバーを許可"), isOn: Binding(get: { allowRemoteVoice }, set: { on in
                        allowRemoteVoice = on
                        SecuritySettings.setAllowRemoteVoice(on)
                    }))
                    Text(L10n.t("警告: オンにすると、セリフの文章がこの Mac の外のサーバーへ送られます。信頼できるサーバーだけを下に書いてください。プロジェクトファイルに書かれた送信先は、ここで許可したホスト以外には送りません(この設定はプロジェクトには保存されません)。"))
                        .font(MCDesign.Font.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    if allowRemoteVoice {
                        TextField("許可するホスト名(カンマ区切り。例: voice.example.com)", text: Binding(get: { remoteHosts }, set: { t in
                            remoteHosts = t
                            SecuritySettings.setRemoteVoiceHosts(t)
                        }))
                    }
                }.padding(MCDesign.Spacing.s)
            }
            GroupBox(L10n.t("ゆっくり（AquesTalk 系）")) {
                VStack(alignment: .leading, spacing: MCDesign.Spacing.xs) {
                    let found = AquesTalkLocator.resolve()
                    Text(found.map { "使う実行ファイル: \($0.path)" } ?? "AquesTalkPlayer が見つかりません(macOS の「Kyoko」で代用します)。")
                        .font(MCDesign.Font.caption).textSelection(.enabled)
                    HStack {
                        Button(L10n.t("実行ファイルを選ぶ…")) { chooseAquesTalk() }
                        if !aquesPath.isEmpty {
                            Button(L10n.t("選択を解除")) { aquesPath = ""; aquesMessage = ""; SecuritySettings.setAquestalkPath(nil) }
                        }
                    }
                    if !aquesMessage.isEmpty { Text(aquesMessage).font(MCDesign.Font.caption).foregroundStyle(.red) }
                    Text(L10n.t("安全のため、実行するのは /Applications・アプリ内・Application Support の AquesTalk フォルダ・ここで選んだファイルだけです。プロジェクトファイルに書かれたコマンドは実行しません。"))
                        .font(MCDesign.Font.caption).foregroundStyle(MCDesign.Color.textSecondary).fixedSize(horizontal: false, vertical: true)
                }.padding(MCDesign.Spacing.s)
            }
            GroupBox(L10n.t("Whisper（文字起こし）")) {
                VStack(alignment: .leading, spacing: MCDesign.Spacing.xs) {
                    let exe = WhisperLocator.resolve()
                    let mdl = WhisperLocator.resolveModel()
                    let vad = WhisperLocator.resolveVADModel()
                    let recommended = WhisperModelCatalog.recommended
                    Text(exe.map { "\(L10n.t("使う実行ファイル")): \($0.path)" } ?? L10n.t("実行ファイル(whisper-cli)が見つかりません。"))
                        .font(MCDesign.Font.caption).textSelection(.enabled)
                    Text(mdl.map { "\(L10n.t("使うモデル")): \($0.path)" } ?? L10n.t("モデルが未配置です。"))
                        .font(MCDesign.Font.caption).textSelection(.enabled)
                    if mdl?.lastPathComponent != recommended.fileName {
                        Text(L10n.t("精度を上げるには large-v3（約3.1GB）がおすすめです"))
                            .font(MCDesign.Font.caption).foregroundStyle(MCDesign.Color.textSecondary)
                        Button(L10n.t("large-v3 をダウンロード…")) { NSWorkspace.shared.open(recommended.downloadURL) }
                    }
                    Text(vad.map { "\(L10n.t("VAD(無音の区間を先に除く)")): \($0.lastPathComponent)" }
                         ?? L10n.t("VAD モデルは未配置です(ggml-silero-v5.1.2.bin を置くと自動で使います)。"))
                        .font(MCDesign.Font.caption).foregroundStyle(MCDesign.Color.textSecondary).textSelection(.enabled)
                    HStack {
                        Button(L10n.t("実行ファイルを選ぶ…")) { chooseWhisperExecutable() }
                        if !whisperPath.isEmpty {
                            Button(L10n.t("実行ファイルの選択を解除")) { whisperPath = ""; whisperMessage = ""; SecuritySettings.setWhisperPath(nil) }
                        }
                    }
                    HStack {
                        Button(L10n.t("モデルを選ぶ…")) { chooseWhisperModel() }
                        if !whisperModelPath.isEmpty {
                            Button(L10n.t("モデルの選択を解除")) { whisperModelPath = ""; whisperMessage = ""; SecuritySettings.setWhisperModelPath(nil) }
                        }
                    }
                    if !whisperMessage.isEmpty { Text(whisperMessage).font(MCDesign.Font.caption).foregroundStyle(.red) }
                    Text(L10n.t("置き場所(Application Support 内)に whisper-cli と ggml-*.bin を置くか、上のボタンで選びます。Homebrew の whisper-cpp も自動で探します。"))
                        .font(MCDesign.Font.caption).foregroundStyle(MCDesign.Color.textSecondary).fixedSize(horizontal: false, vertical: true)
                    Text("\(DataLocations.current.supportFolderName)/Whisper/")
                        .font(MCDesign.Font.caption).foregroundStyle(MCDesign.Color.textSecondary).textSelection(.enabled)
                    Text(L10n.t("モデルはアプリに入っていません。初回に自分でダウンロードしてください(精度を重視するなら ggml-large-v3.bin・約3.1GB がおすすめ)。認識は端末内で行い、音声は外に送りません。"))
                        .font(MCDesign.Font.caption).foregroundStyle(MCDesign.Color.textSecondary).fixedSize(horizontal: false, vertical: true)
                }.padding(MCDesign.Spacing.s)
            }
            if model != nil {
                HStack {
                    Spacer()
                    Button(L10n.t("キャンセル")) { resetDraft() }
                    Button(L10n.t("適用")) { apply() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!res.isValid || !fpsValid || projectLocked)
                }
                .disabled(projectLocked)
            }
        }
        .padding(MCDesign.Spacing.l)
        .frame(width: 560)
        .onChange(of: draft.codec) { _, c in res.codec = c }
        .onChange(of: fpsText) { _, t in if case .success(let v) = FrameRateInput.parse(t) { res.fps = v } }
    }
}

import SwiftUI
import MovieCutCore

/// 「アクセント編集…」: ボイスクリップの VOICEVOX アクセント句を、モーラ単位で核位置・長さ・音高を変えて再合成する画面。
/// 初期表示は保存済みのアクセント。無ければ VOICEVOX から取得する(エンジンが止まっていれば起動を試す)。
/// 「適用して再合成」は `resynthesizeVoice` で 1 回の Undo にまとめる(核位置・長さ・音高の変更は全部まとめて 1 回の Undo)。
struct VoicevoxAccentSheet: View {
    @ObservedObject var model: ProjectModel
    let clipId: String
    @Environment(\.dismiss) private var dismiss
    @State private var phrases: [VoicevoxAccentPhrase] = []
    @State private var loading = false
    @State private var errorText: String?

    private var clip: Clip? { model.clip(clipId) }
    private var bodyText: String { ExpressionTag.body(clip?.text ?? "") }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("アクセント編集").font(.headline)
            Text("読み上げ文: \(bodyText)")
                .font(MCDesign.Font.callout).foregroundStyle(MCDesign.Color.textSecondary).lineLimit(2)
            Text("モーラ(かな)を押すと、そこで音が下がる位置(核)になります。もう一度押すと平板に戻ります。各モーラの「長さ」と「音高」はスライダーで変えられます(長さは子音+母音の合計を、比率を保って伸縮します)。")
                .font(MCDesign.Font.subheadline).foregroundStyle(MCDesign.Color.textSecondary).fixedSize(horizontal: false, vertical: true)
            if loading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("VOICEVOX から取得しています…").font(MCDesign.Font.subheadline).foregroundStyle(MCDesign.Color.textSecondary)
                }
            }
            if let errorText {
                Text(errorText).font(MCDesign.Font.subheadline).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(phrases.indices, id: \.self) { i in phraseRow(i) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
            .frame(minHeight: 180, maxHeight: 420)
            HStack(spacing: 8) {
                Button("再取得") { Task { await fetch() } }
                    .disabled(loading || model.isLocked)
                Spacer()
                Text("\(phrases.count) 句").font(MCDesign.Font.subheadline).foregroundStyle(MCDesign.Color.textSecondary)
            }
            HStack {
                if clip?.voicevoxAccent != nil {
                    Button("通常の読みに戻す") { Task { await clearAccent() } }
                        .disabled(model.isLocked)
                        .help("保存したアクセントを消して、VOICEVOX の標準のアクセントで作り直します")
                }
                Spacer()
                Button("キャンセル") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("適用して再合成") { Task { await apply() } }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(phrases.isEmpty || loading || model.isLocked)
            }
        }
        .padding(16)
        .frame(width: 560)
        .onAppear {
            if let saved = clip?.voicevoxAccent, !saved.isEmpty {
                phrases = saved
            } else {
                Task { await fetch() }
            }
        }
    }

    private func phraseRow(_ i: Int) -> some View {
        let p = phrases[i]
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 2) {
                ForEach(p.moras.indices, id: \.self) { m in
                    Button {
                        setAccent(p.accent == m + 1 ? 0 : m + 1, at: i)
                    } label: {
                        Text(p.moras[m].text)
                            .font(MCDesign.Font.body)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 4)
                                .fill(p.accent == m + 1 ? Color.accentColor.opacity(0.35) : Color.secondary.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                    .help("ここで下がる(核位置 \(m + 1))。もう一度押すと平板")
                }
            }
            HStack(spacing: 8) {
                Text("核位置 \(p.accent)").font(MCDesign.Font.subheadline).foregroundStyle(MCDesign.Color.textSecondary).monospacedDigit()
                Stepper("", value: Binding(get: { p.accent }, set: { setAccent($0, at: i) }), in: 0...max(p.moras.count, 0))
                    .labelsHidden()
                if p.accent == 0 {
                    Text("平板").font(MCDesign.Font.subheadline).foregroundStyle(MCDesign.Color.textSecondary)
                }
            }
            // モーラ単位の長さ・音高スライダー(R2-1)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(p.moras.indices, id: \.self) { m in moraSliderRow(i, m) }
            }
            .padding(.top, 2)
        }
    }

    /// 1 モーラ分の長さ・音高スライダー。長さは子音+母音の合計(秒)、音高は log f0。
    /// 音高が 0 のモーラ(無声)はスライダーを出さず、その旨だけ表示する。
    private func moraSliderRow(_ i: Int, _ m: Int) -> some View {
        let mora = phrases[i].moras[m]
        return HStack(spacing: 6) {
            Text(mora.text)
                .font(MCDesign.Font.subheadline)
                .frame(width: 22, alignment: .leading)
            Text("長さ").font(MCDesign.Font.subheadline).foregroundStyle(MCDesign.Color.textSecondary)
            Slider(value: Binding(
                get: { min(max(mora.totalLength, VoicevoxAccent.moraLengthSliderRange.lowerBound), VoicevoxAccent.moraLengthSliderRange.upperBound) },
                set: { setMoraLength($0, phrase: i, mora: m) }),
                   in: VoicevoxAccent.moraLengthSliderRange, step: 0.005)
                .frame(width: 130)
                .help("モーラ全体の長さ(子音+母音)。比率を保って伸縮します")
            Text(String(format: "%.2f", mora.totalLength))
                .font(MCDesign.Font.subheadline).foregroundStyle(MCDesign.Color.textSecondary).monospacedDigit()
                .frame(width: 34, alignment: .trailing)
            Text("音高").font(MCDesign.Font.subheadline).foregroundStyle(MCDesign.Color.textSecondary)
            if mora.pitch > 0 {
                Slider(value: Binding(
                    get: { min(max(mora.pitch, VoicevoxAccent.moraPitchSliderRange.lowerBound), VoicevoxAccent.moraPitchSliderRange.upperBound) },
                    set: { setMoraPitch($0, phrase: i, mora: m) }),
                       in: VoicevoxAccent.moraPitchSliderRange, step: 0.05)
                    .frame(width: 130)
                    .help("モーラの音高")
                Text(String(format: "%.2f", mora.pitch))
                    .font(MCDesign.Font.subheadline).foregroundStyle(MCDesign.Color.textSecondary).monospacedDigit()
                    .frame(width: 34, alignment: .trailing)
            } else {
                Text("音高なし(無声)").font(MCDesign.Font.subheadline).foregroundStyle(MCDesign.Color.textSecondary)
            }
        }
    }

    /// 核位置を変える。範囲は句のモーラ数に収める(0 = 平板)。
    private func setAccent(_ v: Int, at i: Int) {
        phrases = VoicevoxAccent.settingAccent(v, at: i, in: phrases)
    }

    /// モーラ全体の長さを変える(子音・母音の比率は Core 側で保つ)。
    private func setMoraLength(_ v: Double, phrase i: Int, mora m: Int) {
        phrases = VoicevoxAccent.settingMoraLength(v, phrase: i, mora: m, in: phrases)
    }

    /// モーラの音高を変える。
    private func setMoraPitch(_ v: Double, phrase i: Int, mora m: Int) {
        phrases = VoicevoxAccent.settingMoraPitch(v, phrase: i, mora: m, in: phrases)
    }

    /// VOICEVOX から取得する。エンジンが止まっていれば起動を試し、だめなら日本語で止める。
    private func fetch() async {
        guard let c = clip, let ch = model.project.characters.first(where: { $0.id == (c.charId ?? "") }) else {
            errorText = "このセリフのキャラが見つかりません。"
            return
        }
        guard VoicevoxFamily.isVoicevoxStyleEngine(ch.engine) else {
            errorText = "アクセント編集は VOICEVOX / COEIROINK / SHAREVOX のキャラだけ使えます。"
            return
        }
        loading = true
        errorText = nil
        defer { loading = false }
        do {
            if ch.engine == "voicevox" {
                let real = RealVoiceProvider(project: model.project, engine: AppServices.engine)
                _ = try real.voicevox.validatedBaseURL()
                guard await AppServices.engine.ensureRunning(baseURL: model.project.voicevoxUrl) else {
                    errorText = "VOICEVOX に接続できません。VOICEVOX を起動してから「再取得」を押してください。"
                    return
                }
                phrases = try await real.voicevox.accentPhrases(text: bodyText, speaker: ch.speaker ?? 3)
            } else if let spec = VoicevoxFamily.spec(forEngine: ch.engine) {
                // COEIROINK / SHAREVOX: 自動起動はせず、生きていれば /audio_query から取得する
                let client = VoicevoxFamilyPluginClient(spec: spec)
                _ = try client.validatedBaseURL()
                guard await VoicevoxFamilyAvailability.isAlive(baseURL: spec.defaultBaseURL) else {
                    errorText = "\(spec.displayName) に接続できません。\(spec.displayName) を起動してから「再取得」を押してください。"
                    return
                }
                phrases = try await client.accentPhrases(text: bodyText, speaker: ch.speaker ?? 3)
            }
        } catch {
            errorText = "アクセントを取得できませんでした: \(error.localizedDescription)"
        }
    }

    /// 編集したアクセントを保存して、そのセリフを作り直す(1 回の Undo)。成功したら閉じる。
    private func apply() async {
        let clean = VoicevoxAccent.clamped(phrases)
        let ok = await model.resynthesizeVoice(clipId: clipId, name: "アクセントの変更", message: "アクセントを反映して音声を作り直しています…") { $0.voicevoxAccent = clean }
        if ok { dismiss() }
    }

    /// 保存したアクセントを消して、標準のアクセントで作り直す。
    private func clearAccent() async {
        let ok = await model.resynthesizeVoice(clipId: clipId, name: "アクセントを消す", message: "標準のアクセントで音声を作り直しています…") { $0.voicevoxAccent = nil }
        if ok { dismiss() }
    }
}

import SwiftUI
import MovieCutCore

/// 「アクセント編集…」: ボイスクリップの VOICEVOX アクセント句を、モーラ単位で核位置を変えて再合成する画面。
/// 初期表示は保存済みのアクセント。無ければ VOICEVOX から取得する(エンジンが止まっていれば起動を試す)。
/// 「適用して再合成」は `resynthesizeVoice` で 1 回の Undo にまとめる。
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
                .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
            Text("モーラ(かな)を押すと、そこで音が下がる位置(核)になります。もう一度押すと平板に戻ります。")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if loading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("VOICEVOX から取得しています…").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            if let errorText {
                Text(errorText).font(.system(size: 11)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(phrases.indices, id: \.self) { i in phraseRow(i) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
            .frame(minHeight: 180, maxHeight: 320)
            HStack(spacing: 8) {
                Button("再取得") { Task { await fetch() } }
                    .disabled(loading || model.isLocked)
                Spacer()
                Text("\(phrases.count) 句").font(.system(size: 11)).foregroundStyle(.secondary)
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
                            .font(.system(size: 13))
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 4)
                                .fill(p.accent == m + 1 ? Color.accentColor.opacity(0.35) : Color.secondary.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                    .help("ここで下がる(核位置 \(m + 1))。もう一度押すと平板")
                }
            }
            HStack(spacing: 8) {
                Text("核位置 \(p.accent)").font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                Stepper("", value: Binding(get: { p.accent }, set: { setAccent($0, at: i) }), in: 0...max(p.moras.count, 0))
                    .labelsHidden()
                if p.accent == 0 {
                    Text("平板").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// 核位置を変える。範囲は句のモーラ数に収める(0 = 平板)。
    private func setAccent(_ v: Int, at i: Int) {
        phrases = VoicevoxAccent.settingAccent(v, at: i, in: phrases)
    }

    /// VOICEVOX から取得する。エンジンが止まっていれば起動を試し、だめなら日本語で止める。
    private func fetch() async {
        guard let c = clip, let ch = model.project.characters.first(where: { $0.id == (c.charId ?? "") }) else {
            errorText = "このセリフのキャラが見つかりません。"
            return
        }
        guard ch.engine == "voicevox" else {
            errorText = "アクセント編集は VOICEVOX のキャラだけ使えます。"
            return
        }
        loading = true
        errorText = nil
        defer { loading = false }
        let real = RealVoiceProvider(project: model.project, engine: AppServices.engine)
        do {
            _ = try real.voicevox.validatedBaseURL()
            guard await AppServices.engine.ensureRunning(baseURL: model.project.voicevoxUrl) else {
                errorText = "VOICEVOX に接続できません。VOICEVOX を起動してから「再取得」を押してください。"
                return
            }
            phrases = try await real.voicevox.accentPhrases(text: bodyText, speaker: ch.speaker ?? 3)
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

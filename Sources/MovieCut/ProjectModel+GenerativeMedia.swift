import AppKit
import MovieCutCore

/// 生成メディア共通連携口の画面側の流れ(最初の実装: 画像生成の API 直接連携)。
/// 生成そのものは Core(`GenerativeMediaProvider`)。ここは入力・送信前確認・
/// 進み表示・クリップ配置(Undo 1 回)だけを持つ。
/// 流れは共通: プロンプト指定 → 確認(送信内容・送信先・想定費用) → 生成 →
/// 結果を画像クリップとして再生ヘッドに配置。将来の動画/音声生成も同じ形にする。
/// 未設定のときは `ImageGenerationSettings.makeProvider()` がエラーを返し、
/// 画面にその旨が出る(メニュー項目も無効表示)。認証情報はここでも扱わない
/// (設定画面でユーザー自身が入れたものが UserDefaults にあるだけ)。
/// 既存のローカルコマンド方式(`ProjectModel+AIImage`)とは独立で、そちらは変えない。
extension ProjectModel {
    /// いまの設定で画像生成(API)が使えるか(メニューの有効・無効と案内に使う)。
    var imageGenerationConfigured: Bool { ImageGenerationSettings.load().isConfigured }

    /// クリップ ▸ AIで画像を生成(API)…: プロンプトと大きさを入れてもらう。
    func openGenerateImageAPI() {
        guard !isLocked else { return }
        let s = ImageGenerationSettings.load()
        guard s.isConfigured else {
            errorTitle = "生成メディア(API)を使えません"
            errorMessage = GenerativeMediaError.notConfigured.errorDescription
            return
        }
        guard let v = AIDialogs.form(title: "AI で画像を生成(API)",
                                     message: "あなたの API アカウントで画像を生成し、画像クリップとして再生ヘッドに置きます。次の画面で、送る内容・送信先・費用の注意を確認できます。",
                                     fields: [("画像のプロンプト", ""), ("大きさ", s.size)], okTitle: "次へ")
        else { return }
        let size = v[1].trimmingCharacters(in: .whitespacesAndNewlines)
        Task { await generateImageViaAPI(prompt: v[0], size: size.isEmpty ? nil : size) }
    }

    /// 生成して画像クリップを置く。置いたクリップの id を返す(失敗・キャンセル・未確認なら nil)。
    @discardableResult
    func generateImageViaAPI(prompt: String, size: String? = nil, at time: Double? = nil) async -> String? {
        guard !isLocked else { return nil }
        let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { statusText = "プロンプトを入れてください"; return nil }
        let settings = ImageGenerationSettings.load()
        let provider: GenerativeMediaProvider
        do { provider = try genMediaUI.makeImageProvider() } catch {
            errorTitle = "生成メディア(API)を使えません"
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return nil
        }
        let request = GenerativeMediaRequest(kind: .image, prompt: p, size: size ?? settings.size)
        do { try request.validate() } catch {
            errorTitle = "生成メディア(API)を使えません"
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return nil
        }
        // 送信前確認(必須): 送信先と、プロンプト・モデル・大きさ・費用の注意を見せる。
        let confirmation = settings.confirmation(prompt: p, size: request.size)
        guard genMediaUI.confirmSend(confirmation.destination, confirmation.summaryText) else {
            statusText = "生成サービスには送りませんでした"
            return nil
        }
        playback?.pause()
        busyMessage = "画像を生成しています…"
        let task = Task { try await provider.generate(request) }
        genMediaCancel = { task.cancel() }
        defer { genMediaCancel = nil; busyMessage = nil }
        let result: GenerativeMediaResult
        do { result = try await task.value } catch {
            if (error as? GenerativeMediaError) == .cancelled || error is CancellationError {
                statusText = "画像の生成をキャンセルしました"
                return nil
            }
            errorTitle = "画像を生成できませんでした"
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return nil
        }
        // 生成が終わってから(busyMessage を外してから)書き換える。Undo は 1 回。
        let t = max(0, time ?? currentTime)
        var ids: [String] = []
        guard edit("生成メディア(API)で作った画像の追加", { pr in
            ids = GenerativeMediaPlacement.place(result, at: t, in: &pr)
        }) else { return nil }
        selectedClipId = ids.last
        statusText = "生成した画像を追加しました"
        return ids.last
    }

    func cancelGenerativeMedia() { genMediaCancel?() }

    // MARK: - 動画 / 音声・音楽生成(W5-4。共通口の上に画像と同じ流れで)

    /// いまの設定で動画生成(API)が使えるか(メニューの有効・無効と案内に使う)。
    var videoGenerationConfigured: Bool { VideoGenerationSettings.load().isConfigured }

    /// いまの設定で音声/音楽生成(API)が使えるか。
    var audioGenerationConfigured: Bool { AudioGenerationSettings.load().isConfigured }

    /// 選択クリップが生成延長の対象(動画・音声)か。
    var canGenerativeExtendSelected: Bool {
        selectedClip.map { GenerativeExtensionPlanner.supports($0) } ?? false
    }

    /// 選択クリップの生成延長が、種類側の設定までそろって使えるか。
    var generativeExtendConfigured: Bool {
        guard let c = selectedClip, let kind = GenerativeExtensionPlanner.kind(for: c) else { return false }
        return kind == .video ? videoGenerationConfigured : audioGenerationConfigured
    }

    /// 確認 → 生成 → 配置の共通の流れ(動画/音声用。画像は従来の流れのまま)。
    private func runGenerativeAV(request: GenerativeMediaRequest, confirmation: GenerativeMediaConfirmation,
                                 makeProvider: () throws -> GenerativeMediaProvider,
                                 busyText: String, doneText: String, failTitle: String,
                                 at time: Double?) async -> String? {
        guard !isLocked else { return nil }
        do { try request.validate() } catch {
            errorTitle = "生成メディア(API)を使えません"
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return nil
        }
        let provider: GenerativeMediaProvider
        do { provider = try makeProvider() } catch {
            errorTitle = "生成メディア(API)を使えません"
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return nil
        }
        // 送信前確認(必須): 送信先と、プロンプト・モデル・仕様・費用の注意を見せる。
        guard genMediaUI.confirmSend(confirmation.destination, confirmation.summaryText) else {
            statusText = "生成サービスには送りませんでした"
            return nil
        }
        playback?.pause()
        busyMessage = busyText
        let task = Task { try await provider.generate(request) }
        genMediaCancel = { task.cancel() }
        defer { genMediaCancel = nil; busyMessage = nil }
        let result: GenerativeMediaResult
        do { result = try await task.value } catch {
            if (error as? GenerativeMediaError) == .cancelled || error is CancellationError {
                statusText = "生成をキャンセルしました"
                return nil
            }
            errorTitle = failTitle
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return nil
        }
        let t = max(0, time ?? currentTime)
        var ids: [String] = []
        guard edit(String(format: L10n.t("生成メディア(API)で作った%@の追加"), L10n.t(request.kind.title)), { pr in
            ids = GenerativeMediaPlacement.place(result, at: t, in: &pr)
        }) else { return nil }
        selectedClipId = ids.last
        statusText = doneText
        return ids.last
    }

    /// クリップ ▸ AIで動画を生成(API)…: プロンプトと仕様を入れてもらう。
    func openGenerateVideoAPI() {
        guard !isLocked else { return }
        let s = VideoGenerationSettings.load()
        guard s.isConfigured else {
            errorTitle = "生成メディア(API)を使えません"
            errorMessage = GenerativeMediaError.notConfigured.errorDescription
            return
        }
        guard let v = AIDialogs.form(title: "AI で動画を生成(API)",
                                     message: "あなたの API アカウントで動画を生成し、動画クリップとして再生ヘッドに置きます。生成は非同期ジョブで、完了まで待ちます。次の画面で、送る内容・送信先・費用の注意を確認できます。",
                                     fields: [("動画のプロンプト", ""), ("大きさ", s.size), ("長さ(秒)", VideoGenerationSettings.secondsText(s.durationSeconds)), ("形式", s.outputFormat)], okTitle: "次へ")
        else { return }
        let size = v[1].trimmingCharacters(in: .whitespacesAndNewlines)
        let duration = Double(v[2].trimmingCharacters(in: .whitespacesAndNewlines))
        let format = v[3].trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            await generateVideoViaAPI(prompt: v[0], size: size.isEmpty ? nil : size,
                                      duration: duration, format: format.isEmpty ? nil : format)
        }
    }

    /// 生成して動画クリップを置く。置いたクリップの id を返す(失敗・キャンセル・未確認なら nil)。
    @discardableResult
    func generateVideoViaAPI(prompt: String, size: String? = nil, duration: Double? = nil,
                             format: String? = nil, at time: Double? = nil) async -> String? {
        guard !isLocked else { return nil }
        let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { statusText = "プロンプトを入れてください"; return nil }
        let settings = VideoGenerationSettings.load()
        let request = GenerativeMediaRequest(kind: .video, prompt: p, targetDuration: duration ?? settings.durationSeconds,
                                             size: size ?? settings.size, outputFormat: format ?? settings.outputFormat)
        let confirmation = settings.confirmation(prompt: p, size: request.size, duration: request.targetDuration, format: request.outputFormat)
        return await runGenerativeAV(request: request, confirmation: confirmation,
                                     makeProvider: genMediaUI.makeVideoProvider,
                                     busyText: "動画を生成しています…", doneText: "生成した動画を追加しました",
                                     failTitle: "動画を生成できませんでした", at: time)
    }

    /// クリップ ▸ AIで効果音/音楽/サウンドスケープを生成(API)…
    func openGenerateAudioAPI(kind: GenerativeMediaKind) {
        guard !isLocked else { return }
        let s = AudioGenerationSettings.load()
        guard s.isConfigured else {
            errorTitle = "生成メディア(API)を使えません"
            errorMessage = GenerativeMediaError.notConfigured.errorDescription
            return
        }
        guard let v = AIDialogs.form(title: String(format: L10n.t("AI で%@を生成(API)"), L10n.t(kind.title)),
                                     message: String(format: L10n.t("あなたの API アカウントで%@を生成し、音声クリップとして再生ヘッドに置きます。次の画面で、送る内容・送信先・費用の注意を確認できます。"), L10n.t(kind.title)),
                                     fields: [(String(format: L10n.t("%@のプロンプト"), L10n.t(kind.title)), ""), ("長さ(秒)", VideoGenerationSettings.secondsText(s.durationSeconds)), ("形式", s.outputFormat)], okTitle: "次へ")
        else { return }
        let duration = Double(v[1].trimmingCharacters(in: .whitespacesAndNewlines))
        let format = v[2].trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            await generateAudioViaAPI(kind: kind, prompt: v[0], duration: duration, format: format.isEmpty ? nil : format)
        }
    }

    /// 生成して音声クリップを置く(効果音/音楽/サウンドスケープ共通)。
    @discardableResult
    func generateAudioViaAPI(kind: GenerativeMediaKind, prompt: String, duration: Double? = nil,
                             format: String? = nil, at time: Double? = nil) async -> String? {
        guard !isLocked else { return nil }
        guard kind == .audio || kind == .music || kind == .soundscape else {
            statusText = "音声・音楽の種類を選んでください"; return nil
        }
        let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { statusText = "プロンプトを入れてください"; return nil }
        let settings = AudioGenerationSettings.load()
        let request = GenerativeMediaRequest(kind: kind, prompt: p, targetDuration: duration ?? settings.durationSeconds,
                                             outputFormat: format ?? settings.outputFormat)
        let confirmation = settings.confirmation(kind: kind, prompt: p, duration: request.targetDuration, format: request.outputFormat)
        return await runGenerativeAV(request: request, confirmation: confirmation,
                                     makeProvider: genMediaUI.makeAudioProvider,
                                     busyText: "\(kind.title)を生成しています…", doneText: "生成した\(kind.title)を追加しました",
                                     failTitle: "\(kind.title)を生成できませんでした", at: time)
    }

    // MARK: - 生成延長(W5-4。Core 計画 + 動画/音声プロバイダ経由)

    /// クリップ ▸ 生成延長(API)…: 選択クリップの前後に足す秒数とプロンプトを入れてもらう。
    func openGenerativeExtend() {
        guard !isLocked else { return }
        guard canGenerativeExtendSelected else {
            statusText = "動画か音声のクリップを選んでください"
            return
        }
        guard generativeExtendConfigured else {
            errorTitle = "生成メディア(API)を使えません"
            errorMessage = GenerativeMediaError.notConfigured.errorDescription
            return
        }
        guard let v = AIDialogs.form(title: "生成延長(API)",
                                     message: "選択クリップの前後に、あなたの API アカウントで生成した区間を追加します。元のクリップは書き換えません。生成はプロンプトから行い、元の素材そのものは送りません。次の画面で、送る内容・送信先・費用の注意を確認できます。",
                                     fields: [("延長のプロンプト", ""), ("前に足す(秒)", "0"), ("後ろに足す(秒)", "3")], okTitle: "次へ")
        else { return }
        let head = Double(v[1].trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
        let tail = Double(v[2].trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
        Task { await generativeExtendSelected(prompt: v[0], headSeconds: head, tailSeconds: tail) }
    }

    /// 選択クリップの前後に生成セグメントを置く(Undo 1 回、元クリップは不変)。
    /// 置いたクリップの id 列を返す(失敗・キャンセル・未確認なら空)。
    @discardableResult
    func generativeExtendSelected(prompt: String, headSeconds: Double, tailSeconds: Double) async -> [String] {
        guard !isLocked, let clip = selectedClip else { return [] }
        let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { statusText = "プロンプトを入れてください"; return [] }
        let plan: GenerativeExtensionPlan
        do { plan = try GenerativeExtensionPlanner.plan(clip: clip, headSeconds: headSeconds, tailSeconds: tailSeconds) } catch {
            errorTitle = "生成延長を使えません"
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return []
        }
        let isVideo = plan.kind == .video
        let model = isVideo ? VideoGenerationSettings.load().model : AudioGenerationSettings.load().model
        let provider: GenerativeMediaProvider
        do {
            if isVideo { provider = try genMediaUI.makeVideoProvider() }
            else { provider = try genMediaUI.makeAudioProvider() }
        } catch {
            errorTitle = "生成メディア(API)を使えません"
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return []
        }
        // 送信前確認(必須): 延長内容・送信先・プロンプト・費用の注意を見せる。
        let confirmation = GenerativeMediaConfirmation(
            kind: plan.kind, destination: provider.destinationDescription,
            prompt: "\(p)(生成延長: \(plan.summaryDescription))", model: model,
            sizeDescription: plan.summaryDescription)
        guard genMediaUI.confirmSend(confirmation.destination, confirmation.summaryText) else {
            statusText = "生成サービスには送りませんでした"
            return []
        }
        let size = isVideo ? VideoGenerationSettings.load().size : nil
        let format = isVideo ? VideoGenerationSettings.load().outputFormat : AudioGenerationSettings.load().outputFormat
        let requests = plan.generationRequests(prompt: p, size: size, outputFormat: format)
        playback?.pause()
        busyMessage = "生成延長しています…"
        defer { genMediaCancel = nil; busyMessage = nil }
        var headResult: GenerativeMediaResult?
        var tailResult: GenerativeMediaResult?
        for (segment, request) in zip(plan.segments, requests) {
            let task = Task { try await provider.generate(request) }
            genMediaCancel = { task.cancel() }
            do {
                let r = try await task.value
                if segment.isHead { headResult = r } else { tailResult = r }
            } catch {
                if (error as? GenerativeMediaError) == .cancelled || error is CancellationError {
                    statusText = "生成延長をキャンセルしました"
                    return []
                }
                errorTitle = "生成延長できませんでした"
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                return []
            }
        }
        genMediaCancel = nil
        var ids: [String] = []
        guard edit("生成延長で作った区間の追加", { pr in
            ids = GenerativeExtensionPlacement.place(plan: plan, headResult: headResult, tailResult: tailResult, in: &pr)
        }) else { return [] }
        selectedClipId = ids.last
        statusText = "生成延長で前後の区間を追加しました"
        return ids
    }
}

/// 生成メディアの画面部品の差し替え口(テストではプロバイダと確認画面を偽物にする)。
struct GenMediaUI {
    var makeImageProvider: () throws -> GenerativeMediaProvider = { try ImageGenerationSettings.load().makeProvider() }
    var makeVideoProvider: () throws -> GenerativeMediaProvider = { try VideoGenerationSettings.load().makeProvider() }
    var makeAudioProvider: () throws -> GenerativeMediaProvider = { try AudioGenerationSettings.load().makeProvider() }
    var confirmSend: (_ destination: String, _ summary: String) -> Bool = { d, s in
        MainActor.assumeIsolated { AIDialogs.confirmSend(destination: d, prompt: s) }
    }
}

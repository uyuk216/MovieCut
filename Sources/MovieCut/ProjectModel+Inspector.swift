import Foundation
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import MovieCutCore

/// プロパティ欄の表示の種類。
enum InspectorMode: Equatable {
    case clip(String)
    /// A6: 複数のクリップを選んでいる(個数)。
    case multi(Int)
    case character(String)
    case none
}

/// プロパティ欄(M4b)とキャラクター編集。メニュー(M5)からもそのまま呼べるよう、UI に依存しない形で model に置く。
extension ProjectModel {
    // MARK: 選択

    /// クリップが選ばれていればクリップ → キャラが選ばれていればキャラ → 何もなければヒント。
    var inspectorMode: InspectorMode {
        if selectedClipIDs.count > 1 { return .multi(selectedClipIDs.count) }
        if let c = selectedClip { return .clip(c.id) }
        if characterPanelActive, let id = effectiveSelectedCharId { return .character(id) }
        return .none
    }

    /// 左の一覧でキャラを選ぶ。クリップの選択は外し、プロパティ欄はキャラの設定になる。
    func selectCharacter(_ id: String) {
        guard project.characters.contains(where: { $0.id == id }) else { return }
        flushCoalesced()
        selectedClipId = nil
        selectedCharId = id
        characterPanelActive = true
    }

    func clip(_ id: String) -> Clip? { project.allClips.first { $0.id == id } }
    func character(_ id: String) -> Character? { project.characters.first { $0.id == id } }

    /// 選択中の(またはその id の)クリップを書き換える `Project` を作る。
    private func projectChangingClip(_ id: String, _ change: (inout Clip) -> Void) -> Project? {
        guard let loc = ClipEditing.locate(id, in: project) else { return nil }
        var p = project
        change(&p.tracks[loc.track].clips[loc.index])
        return p
    }

    private func projectChangingCharacter(_ id: String, _ change: (inout Character) -> Void) -> Project? {
        guard let i = project.characters.firstIndex(where: { $0.id == id }) else { return nil }
        var p = project
        change(&p.characters[i])
        return p
    }

    // MARK: クリップの項目(1 回の編集 / ドラッグ中 / まとめ)

    /// 1 回の編集として書き換える(変わらなければ何も登録しない)。`clipId` 省略で選択中のクリップ。
    /// クリップの注記を書く(整形は `Clip.cleanNote`。空にすると消す)。変わらなければ Undo に積まない。
    func setClipNote(_ raw: String, clipId: String? = nil) {
        let note = Clip.cleanNote(raw)
        setClipProperty(\.note, to: note, name: note == nil ? "注記を消す" : "注記を編集", clipId: clipId)
    }

    func setClipProperty(_ change: (inout Clip) -> Void, name: String, clipId: String? = nil) {
        guard let id = clipId ?? selectedClipId, let p = projectChangingClip(id, change) else { return }
        flushCoalesced()
        edit(name) { $0 = p }
    }

    func setClipProperty<V>(_ keyPath: WritableKeyPath<Clip, V>, to value: V, name: String, clipId: String? = nil) {
        setClipProperty({ $0[keyPath: keyPath] = value }, name: name, clipId: clipId)
    }

    /// 数値の項目(丸めてから書く)。
    func setClipField(_ field: ClipField, _ value: Double, clipId: String? = nil) {
        setClipProperty({ field.apply(value, to: &$0) }, name: field.undoName, clipId: clipId)
    }

    func setClipStart(_ v: Double, clipId: String? = nil) { setClipField(.start, v, clipId: clipId) }
    func setClipDuration(_ v: Double, clipId: String? = nil) { setClipField(.duration, v, clipId: clipId) }

    /// スライダーなど、つまみを動かしている間の編集。ドラッグ(`beginGesture` 〜 `commitGesture`)の最中なら Undo に積まず、
    /// そうでなければ(キーボードで動かしたときなど)1 回の編集にする。
    func liveClipProperty(_ change: (inout Clip) -> Void, name: String, clipId: String? = nil) {
        guard let id = clipId ?? selectedClipId, let p = projectChangingClip(id, change) else { return }
        if gestureBase != nil { updateGesture(p) } else { edit(name) { $0 = p } }
    }

    func liveClipField(_ field: ClipField, _ value: Double, clipId: String? = nil) {
        liveClipProperty({ field.apply(value, to: &$0) }, name: field.undoName, clipId: clipId)
    }

    /// ステッパー・色・文字入力など「いつ終わるか分からない」連続編集。最初の変更でジェスチャを始め、
    /// 一定時間(または `flushCoalesced`)で 1 回の Undo にまとめる。
    func coalescedEdit(_ name: String, _ change: (inout Project) -> Void) {
        if gestureBase == nil { beginGesture() }
        var p = project
        change(&p)
        updateGesture(p)
        coalesceName = name
        coalesceTask?.cancel()
        coalesceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            self?.flushCoalesced()
        }
    }

    func coalescedClipProperty(_ change: (inout Clip) -> Void, name: String, clipId: String? = nil) {
        guard let id = clipId ?? selectedClipId else { return }
        coalescedEdit(name) { p in
            if let loc = ClipEditing.locate(id, in: p) { change(&p.tracks[loc.track].clips[loc.index]) }
        }
    }

    func coalescedClipField(_ field: ClipField, _ value: Double, clipId: String? = nil) {
        coalescedClipProperty({ field.apply(value, to: &$0) }, name: field.undoName, clipId: clipId)
    }

    /// まとめている連続編集があれば、いま確定する(入力欄を離れたとき・別の編集の前・選択が変わったとき)。
    func flushCoalesced() {
        coalesceTask?.cancel()
        coalesceTask = nil
        if let n = coalesceName, gestureBase != nil { commitGesture(n) }
        coalesceName = nil
    }

    // MARK: ボイス(セリフ・キャラを変えたら音声を作り直す)

    /// 編集と音声の作り直しを 1 回の Undo にする。失敗したら何も変えず、警告を出して false を返す。
    @discardableResult
    func resynthesizeVoice(clipId: String, name: String, message: String = "音声を作り直しています…", _ change: (inout Clip) -> Void) async -> Bool {
        guard !isLocked, let before = clip(clipId), before.type == .voice else { return false }
        flushCoalesced()
        var trial = project
        guard let loc = ClipEditing.locate(clipId, in: trial) else { return false }
        change(&trial.tracks[loc.track].clips[loc.index])
        var c = trial.tracks[loc.track].clips[loc.index]
        // キャラが見つからなければ作り直さず、編集だけ反映する(renderer.js regenerateVoice と同じ)
        guard trial.characters.contains(where: { $0.id == (c.charId ?? "") }) else {
            edit(name) { $0 = trial }
            return true
        }
        playback.pause()
        busyMessage = message
        defer { busyMessage = nil }
        do {
            try await ScriptTimeline.regenerateVoice(clip: &c, project: trial, provider: voiceProviderFactory(trial))
        } catch {
            errorTitle = "音声を作れませんでした"
            errorMessage = error.localizedDescription
            return false
        }
        let result = c
        edit(name) { p in
            if let l = ClipEditing.locate(clipId, in: p) { p.tracks[l.track].clips[l.index] = result }
        }
        statusText = ""
        return true
    }

    /// セリフの文字を変える(確定したとき)。音声も作り直す。変わっていなければ何もしない。
    @discardableResult
    func setVoiceText(_ text: String, clipId: String? = nil) async -> Bool {
        guard let id = clipId ?? selectedClipId, let c = clip(id), c.type == .voice, (c.text ?? "") != text else { return false }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errorTitle = "セリフを入れてください"
            errorMessage = "セリフが空のままでは音声を作れません。"
            return false
        }
        return await resynthesizeVoice(clipId: id, name: "セリフの変更") { $0.text = text }
    }

    /// 話すキャラを変える。音声も作り直す。
    @discardableResult
    func setVoiceCharacter(_ charId: String, clipId: String? = nil) async -> Bool {
        guard let id = clipId ?? selectedClipId, let c = clip(id), c.type == .voice, c.charId != charId else { return false }
        return await resynthesizeVoice(clipId: id, name: "話すキャラの変更") { $0.charId = charId }
    }

    /// いまの設定のまま音声を作り直す。
    @discardableResult
    func regenerateVoice(clipId: String) async -> Bool {
        await resynthesizeVoice(clipId: clipId, name: "音声の作り直し") { _ in }
    }

    /// そのキャラの全セリフの音声を作り直す。全体で 1 回の Undo。1 つでも失敗したら何も変えない。作り直した数を返す。
    @discardableResult
    func regenerateAllVoices(charId: String) async -> Int {
        guard !isLocked, character(charId) != nil else { return 0 }
        let ids = CharacterEditing.voiceClips(of: charId, in: project).map(\.id)
        guard !ids.isEmpty else { return 0 }
        flushCoalesced()
        playback.pause()
        busyMessage = "音声を作っています 0/\(ids.count)"
        defer { busyMessage = nil }
        let work = project
        let provider = ProgressVoiceProvider(inner: voiceProviderFactory(work), total: ids.count) { [weak self] msg in
            Task { @MainActor in self?.busyMessage = msg }
        }
        var results: [String: Clip] = [:]
        do {
            for id in ids {
                guard var c = ClipEditing.locate(id, in: work).map({ work.tracks[$0.track].clips[$0.index] }) else { continue }
                try await ScriptTimeline.regenerateVoice(clip: &c, project: work, provider: provider)
                results[id] = c
            }
        } catch {
            errorTitle = "音声を作れませんでした"
            errorMessage = error.localizedDescription
            return 0
        }
        edit("全セリフの作り直し") { p in
            for (id, c) in results {
                if let l = ClipEditing.locate(id, in: p) { p.tracks[l.track].clips[l.index] = c }
            }
        }
        statusText = "\(results.count) 個のセリフの音声を作り直しました"
        return results.count
    }

    // MARK: キャラクター

    func setCharacterProperty(_ change: (inout Character) -> Void, name: String, charId: String? = nil) {
        guard let id = charId ?? effectiveSelectedCharId, let p = projectChangingCharacter(id, change) else { return }
        flushCoalesced()
        edit(name) { $0 = p }
    }

    func setCharacterField(_ field: CharacterField, _ value: Double, charId: String? = nil) {
        setCharacterProperty({ field.apply(value, to: &$0) }, name: field.undoName, charId: charId)
    }

    func coalescedCharacterProperty(_ change: (inout Character) -> Void, name: String, charId: String? = nil) {
        guard let id = charId ?? effectiveSelectedCharId else { return }
        coalescedEdit(name) { p in
            if let i = p.characters.firstIndex(where: { $0.id == id }) { change(&p.characters[i]) }
        }
    }

    func coalescedCharacterField(_ field: CharacterField, _ value: Double, charId: String? = nil) {
        coalescedCharacterProperty({ field.apply(value, to: &$0) }, name: field.undoName, charId: charId)
    }

    /// 音声エンジンの切り替え(速さの単位の換算と、足りない項目の補いつき)。
    func characterEngineChanged(charId: String? = nil, to engine: String) {
        setCharacterProperty({ CharacterEditing.switchEngine(&$0, to: engine) }, name: "音声エンジンの変更", charId: charId)
    }

    /// 立ち絵の画像を設定する(url が nil なら外す)。
    func setPortrait(charId: String, closed: Bool, url: URL?) {
        setCharacterProperty({ c in
            if closed { c.imgClosed = url?.path } else { c.imgOpen = url?.path }
        }, name: closed ? "立ち絵(口閉じ)の変更" : "立ち絵(口開き)の変更", charId: charId)
    }

    /// 「立ち絵」の画像を選ぶパネル。
    func choosePortrait(charId: String, closed: Bool) {
        guard !isLocked else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = ["png", "jpg", "jpeg", "gif", "webp"].compactMap { UTType(filenameExtension: $0) }
        panel.title = closed ? "立ち絵(口閉じ)を選ぶ" : "立ち絵(口開き)を選ぶ"
        let run: (NSApplication.ModalResponse) -> Void = { [weak self] resp in
            guard resp == .OK, let url = panel.url else { return }
            Task { @MainActor in self?.setPortrait(charId: charId, closed: closed, url: url) }
        }
        if let w = window { panel.beginSheetModal(for: w, completionHandler: run) } else { panel.begin(completionHandler: run) }
    }

    /// まばたき(目を閉じた画像)を設定する(url が nil なら外す)。
    func setBlinkImage(charId: String, url: URL?) {
        setCharacterProperty({ $0.imgBlink = url?.path }, name: url == nil ? "まばたき画像を外す" : "まばたき画像の変更", charId: charId)
    }

    /// バウンス(話し中の上下の揺れ)の切り替え。オフは項目を消す(既定と同じ形で保存する)。
    func setBounce(charId: String, _ on: Bool) {
        setCharacterProperty({ $0.bounce = on ? true : nil }, name: "バウンスの切り替え", charId: charId)
    }

    /// 表情の名前として使えるか。前後の空白を除いた名前で判定する(タグ `[名前]` の中に `[` `]` は入れられない)。
    static func expressionKey(_ name: String) -> String? {
        let key = name.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !key.contains("["), !key.contains("]") else { return nil }
        return key
    }

    /// 表情の画像を設定する(同名があれば差し替え)。url が nil なら表情を消す。名前が使えないときは何もしない。
    func setExpressionImage(charId: String, name: String, url: URL?) {
        guard let key = Self.expressionKey(name) else { return }
        setCharacterProperty({ c in
            var d = c.expressions ?? [:]
            if let u = url { d[key] = u.path } else { d.removeValue(forKey: key) }
            c.expressions = d.isEmpty ? nil : d
        }, name: url == nil ? "表情の削除" : "表情の画像の変更", charId: charId)
    }

    /// 表情を新しく追加する。名前は画像のファイル名(拡張子を除く)から作り、重複するときは数字を足す。
    func addExpression(charId: String, url: URL) {
        guard let ch = character(charId) else { return }
        let base = Self.expressionKey(url.deletingPathExtension().lastPathComponent) ?? "表情"
        var name = base, n = 2
        let taken = Set((ch.expressions ?? [:]).keys)
        while taken.contains(name) { name = "\(base)\(n)"; n += 1 }
        setCharacterProperty({ c in
            var d = c.expressions ?? [:]
            d[name] = url.path
            c.expressions = d.isEmpty ? nil : d
        }, name: "表情の追加", charId: charId)
    }

    /// 表情の名前を変える。空・使えない名前・既にある名前・同じ名前のときは何もしない。
    func renameExpression(charId: String, from old: String, to new: String) {
        guard let key = Self.expressionKey(new), key != old,
              let ch = character(charId), let img = ch.expressions?[old], ch.expressions?[key] == nil else { return }
        setCharacterProperty({ c in
            var d = c.expressions ?? [:]
            d.removeValue(forKey: old)
            d[key] = img
            c.expressions = d.isEmpty ? nil : d
        }, name: "表情の名前の変更", charId: charId)
    }

    /// 画像を 1 つ選んで渡す(キャラの立ち絵と同じ種類のパネル)。
    func chooseImage(title: String, _ apply: @escaping (URL) -> Void) {
        guard !isLocked else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = ["png", "jpg", "jpeg", "gif", "webp"].compactMap { UTType(filenameExtension: $0) }
        panel.title = title
        let run: (NSApplication.ModalResponse) -> Void = { resp in
            guard resp == .OK, let url = panel.url else { return }
            Task { @MainActor in apply(url) }
        }
        if let w = window { panel.beginSheetModal(for: w, completionHandler: run) } else { panel.begin(completionHandler: run) }
    }

    /// 「このキャラを消す」の確認を出す。最後の 1 人なら理由を出して何もしない。
    func requestDeleteCharacter(_ id: String) {
        guard !isLocked, character(id) != nil else { return }
        if project.characters.count <= 1 {
            errorTitle = "このキャラは消せません"
            errorMessage = "最後の1人は消せません(台本からの音声作成に必要です)。"
            return
        }
        pendingDeleteCharId = id
    }

    /// 確認の文言。
    func deleteConfirmation(for id: String) -> (title: String, message: String)? {
        guard let ch = character(id) else { return nil }
        let n = CharacterEditing.voiceClips(of: id, in: project).count
        return ("\(ch.name) を消しますか？", n > 0 ? "このキャラのセリフ \(n) 個もタイムラインから消えます。" : "このキャラを一覧から消します。")
    }

    /// キャラを消す。そのキャラのボイスクリップも消し、再生を止め、選択を整える。全体で 1 回の Undo。最後の 1 人は消せない(false)。
    @discardableResult
    func deleteCharacter(_ id: String) -> Bool {
        guard !isLocked, let r = CharacterEditing.delete(charId: id, in: project) else { return false }
        flushCoalesced()
        playback.pause()
        let removed = Set(r.removedClipIds)
        edit("キャラクターの削除") { $0 = r.project }
        if let c = selectedClipId, removed.contains(c) { selectedClipId = nil }
        selectedCharId = project.characters.first?.id
        pendingDeleteCharId = nil
        statusText = ""
        return true
    }

    /// 「試しに読み上げる」: 「<名前>です。よろしくお願いします。」をそのキャラの設定で作って鳴らす。作った WAV を返す。
    @discardableResult
    func testSpeak(charId: String) async -> URL? {
        guard !isLocked, let ch = character(charId) else { return nil }
        playback.pause()
        busyMessage = "試し読み上げ用の音声を作っています…"
        defer { busyMessage = nil }
        do {
            let provider = voiceProviderFactory(project)
            let r = try await provider.synthesize(character: ch, text: "\(ch.name)です。よろしくお願いします。", in: FileManager.default.temporaryDirectory)
            noteFallbackIfUsed(provider)
            if let hook = playTestAudio {
                try hook(r.url)
            } else {
                let player = try AVAudioPlayer(contentsOf: r.url)
                testPlayer?.stop()
                testPlayer = player
                player.play()
            }
            return r.url
        } catch {
            errorTitle = "読み上げられませんでした"
            errorMessage = error.localizedDescription
            return nil
        }
    }
}

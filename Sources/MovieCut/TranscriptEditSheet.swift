import SwiftUI
import MovieCutCore

/// クリップ ▸ 文字起こしで編集…: 音声を文字にして文の一覧を出す。使い方は 4 つ:
/// - 取り除く(従来): チェックを外した文を取り除く(全部チェック = 何も変えない)。
/// - 単語を取り除く: 単語の時刻がある文では、単語 1 件ずつ選んで取り除ける(区間は詰まる)。
///   単語の時刻が無い素材では単語単位は使えず、その旨を明示する(文単位まで)。
/// - Paper Edit: 行を押した順に組み立て列へ入れ、選んだ文の区間だけを並べたクリップ列を
///   元のレイヤーの末尾または新しいシーンへ配置する(元クリップは変えない)。
///   組み立て列はドラッグとボタン(上へ/下へ/先頭へ/末尾へ)で並べ替えられる。
/// - 単語で組み立てる: Paper Edit の単語版。単語を押した順に組み立て列へ入れ、単語の
///   区間だけを並べたクリップ列を配置する。並べ替えの作法は文の組み立てと同じ。
/// - 台本と連動: 台本(文の一覧)とタイムラインを双方向につなぐ。台本で文を削除・並べ替えるとタイムラインのクリップが
///   取り除かれ・並び直り、タイムライン側の分割・削除・移動は台本の状態(対応済み / 一部のみ / 対応なし)に追随する。
///   速度変更・逆再生・速度ランプのクリップは対象外。計算は Core の `TranscriptScripting`、Undo は操作 1 回につき 1 回。
/// 閉じると認識は止まる(`.task` のキャンセル)。
struct TranscriptEditSheet: View {
    @ObservedObject var model: ProjectModel
    @State private var found: [TranscriptSentence]?
    @State private var kept: Set<Int> = []
    @State private var failure: String?
    @State private var ripple = true
    // Paper Edit 用の状態(取り除く側の状態とは混ぜない)
    @State private var mode: Mode = .remove
    @State private var paperOrder: [Int] = []
    @State private var paperDestination: PaperDestination = .timeline
    @State private var paperSceneName = "Paper Edit"
    // 単語単位用の状態(文の状態とは混ぜない)。チェックした単語が取り除く対象。
    @State private var wordSelection: Set<TranscriptWordEdit.Selection> = []
    // 単語の組み立て用の状態(文の組み立て列とは混ぜない)。押した順がそのまま並びになる。
    @State private var wordPaperOrder: [TranscriptWordEdit.Selection] = []
    // 台本と連動用の状態。シートを開いた時点のクリップの素材(最初の文を削除してクリップが消えても台本を引ける)
    @State private var scriptSrc: String?
    @State private var retextingId: String?
    @State private var retextDraft = ""

    enum Mode { case remove, word, paper, wordPaper, script }
    enum PaperDestination { case timeline, scene }

    private var clipId: String? { model.transcriptEditClipId }
    private var clipStart: Double { clipId.flatMap { model.clip($0)?.start } ?? 0 }
    private var removedCount: Int { (found?.count ?? 0) - kept.count }
    private var hasAnyWordTiming: Bool { found?.contains { $0.hasWordTiming } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.t("文字起こしで編集")).font(.headline)
            Picker("", selection: $mode) {
                Text(L10n.t("文を取り除く")).tag(Mode.remove)
                Text(L10n.t("単語を取り除く")).tag(Mode.word)
                Text(L10n.t("選んだ文で組み立てる")).tag(Mode.paper)
                Text(L10n.t("単語で組み立てる")).tag(Mode.wordPaper)
                Text(L10n.t("台本と連動")).tag(Mode.script)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Group {
                if mode == .script {
                    scriptPane
                } else if let f = found {
                    if f.isEmpty {
                        Text(L10n.t("文は見つかりませんでした。"))
                    } else {
                        if mode == .remove {
                            Text(String(format: L10n.t("%d 文あります。残す文にチェックを入れたまま、外した文は取り除かれます。"), f.count))
                        } else if mode == .word {
                            if hasAnyWordTiming {
                                Text(L10n.t("取り除く単語にチェックを入れます"))
                            } else {
                                Text(L10n.t("この素材は単語単位の時刻が無いため、単語単位では編集できません(文単位までです)"))
                            }
                        } else if mode == .paper {
                            Text(L10n.t("行を押すと組み立てに追加されます。同じ行をもう一度押すと繰り返し追加されます。"))
                        } else {
                            if hasAnyWordTiming {
                                Text(L10n.t("単語を押すと組み立てに追加されます。同じ単語をもう一度押すと繰り返し追加されます。"))
                            } else {
                                Text(L10n.t("この素材は単語単位の時刻が無いため、単語単位では編集できません(文単位までです)"))
                            }
                        }
                        ScrollView {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(Array(f.enumerated()), id: \.offset) { i, s in
                                    if mode == .remove {
                                        Toggle(isOn: Binding(get: { kept.contains(i) }, set: { on in
                                            if on { kept.insert(i) } else { kept.remove(i) }
                                        })) {
                                            Text("\(String(format: "%.2f", clipStart + s.start)) 秒  \(s.text)")
                                                .monospacedDigit()
                                        }
                                        .toggleStyle(.checkbox)
                                    } else if mode == .word {
                                        wordRows(sentenceIndex: i, sentence: s)
                                    } else if mode == .wordPaper {
                                        wordPaperRows(sentenceIndex: i, sentence: s)
                                    } else {
                                        Button { paperOrder.append(i) } label: {
                                            HStack {
                                                Text("\(String(format: "%.2f", clipStart + s.start)) 秒  \(s.text)")
                                                    .monospacedDigit()
                                                Spacer()
                                                if let badge = paperBadge(for: i) {
                                                    Text(badge).foregroundStyle(.secondary)
                                                }
                                            }
                                            .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                        .frame(maxHeight: 260)
                        if mode == .paper {
                            paperOrderList(f)
                        } else if mode == .wordPaper {
                            wordPaperOrderList(f)
                        }
                    }
                } else if let e = failure {
                    Text(e).foregroundStyle(.red)
                } else {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text(L10n.t("音声を文字にしています…")) }
                }
            }
            .font(.callout)
            if mode == .remove || mode == .word || mode == .script {
                Toggle(L10n.t("後ろを詰める"), isOn: $ripple).toggleStyle(.checkbox)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Picker(L10n.t("配置先"), selection: $paperDestination) {
                        Text(L10n.t("タイムラインに追加")).tag(PaperDestination.timeline)
                        Text(L10n.t("新しいシーンとして作成")).tag(PaperDestination.scene)
                    }
                    .pickerStyle(.segmented)
                    if paperDestination == .scene {
                        HStack {
                            Text(L10n.t("シーン名"))
                            TextField(L10n.t("シーン名"), text: $paperSceneName)
                        }
                    } else {
                        Text(L10n.t("元のレイヤーの末尾に足します")).foregroundStyle(.secondary).font(.callout)
                    }
                }
            }
            HStack {
                Spacer()
                Button(mode == .script ? L10n.t("閉じる") : L10n.t("キャンセル")) { model.showTranscriptEditSheet = false }
                    .keyboardShortcut(.cancelAction)
                if mode == .script {
                    EmptyView()   // 台本と連動は操作のたびに反映される(確定ボタンは無い)
                } else if mode == .remove {
                    Button(removedCount > 0 ? String(format: L10n.t("%d 文を取り除く"), removedCount) : L10n.t("取り除く")) { commit() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(found == nil || removedCount <= 0)
                } else if mode == .word {
                    Button(wordSelection.isEmpty ? L10n.t("単語を取り除く") : String(format: L10n.t("%d 単語を取り除く"), wordSelection.count)) { commitWord() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(found == nil || wordSelection.isEmpty)
                } else if mode == .paper {
                    Button(paperOrder.isEmpty ? L10n.t("組み立てる") : String(format: L10n.t("%d 文で組み立てる"), paperOrder.count)) { commitPaper() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(found == nil || paperOrder.isEmpty || (paperDestination == .scene && paperSceneName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                } else {
                    Button(wordPaperOrder.isEmpty ? L10n.t("組み立てる") : String(format: L10n.t("%d 単語で組み立てる"), wordPaperOrder.count)) { commitWordPaper() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(found == nil || wordPaperOrder.isEmpty || (paperDestination == .scene && paperSceneName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                }
            }
        }
        .padding(20)
        .frame(width: 520)
        .task { await scan() }
        .onAppear { scriptSrc = clipId.flatMap { model.clip($0)?.src } }
    }

    // MARK: 台本と連動

    private var currentScript: TranscriptScript? {
        scriptSrc.flatMap { TranscriptScripting.script(forSrc: $0, in: model.project) }
    }

    /// 台本と連動モード: 台本があれば行の一覧(状態・削除・並べ替え・戻す・打ち直し)、無ければ連動の開始。
    /// 行は `model.project` から毎回再計算するので、タイムライン側の操作や Undo もそのまま映る。
    @ViewBuilder
    private var scriptPane: some View {
        if let sc = currentScript {
            let rows = TranscriptScripting.rows(of: sc, in: model.project)
            Text(L10n.t("台本の削除・並べ替えはタイムラインに反映されます。タイムラインの変更も台本に映ります。"))
            Text(L10n.t("速度変更・逆再生・速度ランプのクリップは対象外です。文字の打ち直しは台本の文字だけが変わります(音声は変わりません)。"))
                .foregroundStyle(.secondary).font(.caption)
            List {
                ForEach(rows, id: \.sentence.id) { row in scriptRow(row, scriptId: sc.id) }
                    .onMove { from, to in model.reorderScriptSentences(scriptId: sc.id, fromOffsets: from, toOffset: to) }
            }
            .listStyle(.plain)
            .frame(height: 260)
            HStack {
                Spacer()
                Button(L10n.t("連動をやめる")) { model.unlinkTranscriptScript(scriptId: sc.id) }
            }
        } else if let f = found, !f.isEmpty {
            Text(L10n.t("クリップを文の頭で切り分けて、台本と連動させます(長さと位置は変わりません)。速度変更・逆再生・速度ランプのクリップは対象外です。"))
            Button(String(format: L10n.t("%d 文で連動を始める"), f.count)) {
                if let id = clipId, model.linkTranscriptScript(clipId: id, sentences: f) { scriptSrc = model.clip(id)?.src ?? scriptSrc }
            }
            .buttonStyle(.borderedProminent)
        } else if let e = failure {
            Text(e).foregroundStyle(.red)
        } else if found == nil {
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text(L10n.t("音声を文字にしています…")) }
        } else {
            Text(L10n.t("文は見つかりませんでした。"))
        }
    }

    @ViewBuilder
    private func scriptRow(_ row: TranscriptScripting.Row, scriptId: String) -> some View {
        let sid = row.sentence.id
        HStack {
            if retextingId == sid {
                TextField("", text: $retextDraft, onCommit: {
                    model.retextScriptSentence(scriptId: scriptId, sentenceId: sid, text: retextDraft)
                    retextingId = nil
                })
                Button(L10n.t("確定")) {
                    model.retextScriptSentence(scriptId: scriptId, sentenceId: sid, text: retextDraft)
                    retextingId = nil
                }
                Button(L10n.t("やめる")) { retextingId = nil }
            } else {
                Text(row.sentence.text)
                    .lineLimit(1)
                    .foregroundStyle(row.coverage == .unlinked ? .secondary : .primary)
                    .strikethrough(row.coverage == .unlinked)
                Spacer()
                Text(scriptBadge(row.coverage)).font(.caption).foregroundStyle(row.coverage == .linked ? Color.secondary : Color.orange)
                Button(L10n.t("打ち直し")) { retextDraft = row.sentence.text; retextingId = sid }
                if row.coverage == .unlinked {
                    Button(L10n.t("戻す")) { model.restoreScriptSentence(scriptId: scriptId, sentenceId: sid) }
                } else {
                    Button(L10n.t("削除")) { model.deleteScriptSentence(scriptId: scriptId, sentenceId: sid, ripple: ripple) }
                }
            }
        }
    }

    private func scriptBadge(_ c: TranscriptScripting.Coverage) -> String {
        switch c {
        case .linked: return L10n.t("対応済み")
        case .partial: return L10n.t("一部のみ")
        case .unlinked: return L10n.t("対応なし")
        }
    }

    /// 単語モードの行: 単語の時刻がある文は単語ごとのチェック、無い文はその旨の注記つきで文だけ出す。
    @ViewBuilder
    private func wordRows(sentenceIndex i: Int, sentence s: TranscriptSentence) -> some View {
        if s.hasWordTiming {
            ForEach(Array(s.words.enumerated()), id: \.offset) { wi, w in
                Toggle(isOn: Binding(
                    get: { wordSelection.contains(TranscriptWordEdit.Selection(sentence: i, word: wi)) },
                    set: { on in
                        let sel = TranscriptWordEdit.Selection(sentence: i, word: wi)
                        if on { wordSelection.insert(sel) } else { wordSelection.remove(sel) }
                    }
                )) {
                    Text("\(String(format: "%.2f", clipStart + w.start)) 秒  \(w.text)")
                        .monospacedDigit()
                }
                .toggleStyle(.checkbox)
            }
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(String(format: "%.2f", clipStart + s.start)) 秒  \(s.text)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text(L10n.t("単語単位の時刻がありません")).foregroundStyle(.secondary).font(.caption)
            }
        }
    }

    /// 単語の組み立てモードの行: 単語の時刻がある文は単語ごとのボタン(押すと組み立て列へ追加)、
    /// 無い文はその旨の注記つきで文だけ出す(単語を取り除くモードと同じ明示)。
    @ViewBuilder
    private func wordPaperRows(sentenceIndex i: Int, sentence s: TranscriptSentence) -> some View {
        if s.hasWordTiming {
            ForEach(Array(s.words.enumerated()), id: \.offset) { wi, w in
                Button { wordPaperOrder.append(TranscriptWordEdit.Selection(sentence: i, word: wi)) } label: {
                    HStack {
                        Text("\(String(format: "%.2f", clipStart + w.start)) 秒  \(w.text)")
                            .monospacedDigit()
                        Spacer()
                        if let badge = wordPaperBadge(for: TranscriptWordEdit.Selection(sentence: i, word: wi)) {
                            Text(badge).foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(String(format: "%.2f", clipStart + s.start)) 秒  \(s.text)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text(L10n.t("単語単位の時刻がありません")).foregroundStyle(.secondary).font(.caption)
            }
        }
    }

    /// 単語の組み立て: その単語が組み立て列の何番目に入っているか(例: "#1, #3")。入っていなければ nil。
    private func wordPaperBadge(for sel: TranscriptWordEdit.Selection) -> String? {
        let positions = wordPaperOrder.enumerated().filter { $0.element == sel }.map { "#\($0.offset + 1)" }
        return positions.isEmpty ? nil : positions.joined(separator: ", ")
    }

    /// Paper Edit: その行が組み立て列の何番目に入っているか(例: "#1, #3")。入っていなければ nil。
    private func paperBadge(for index: Int) -> String? {
        let positions = paperOrder.enumerated().filter { $0.element == index }.map { "#\($0.offset + 1)" }
        return positions.isEmpty ? nil : positions.joined(separator: ", ")
    }

    /// Paper Edit: 組み立て列(並び順)の確認と並べ替え・取り消し。
    /// 並べ替えはドラッグ(`onMove`)とボタン(先頭へ/上へ/下へ/末尾へ)の両方。計算は Core の `PaperEdit`。
    @ViewBuilder
    private func paperOrderList(_ f: [TranscriptSentence]) -> some View {
        if paperOrder.isEmpty {
            Text(L10n.t("組み立ての並びはまだ空です")).foregroundStyle(.secondary)
        } else {
            Text(L10n.t("組み立ての並び"))
            Text(L10n.t("ドラッグでも並べ替えられます")).foregroundStyle(.secondary).font(.caption)
            List {
                ForEach(Array(paperOrder.enumerated()), id: \.offset) { pos, idx in
                    HStack {
                        Text("\(pos + 1). \(f[idx].text)")
                            .lineLimit(1)
                        Spacer()
                        Button(L10n.t("先頭へ移動")) { paperOrder = PaperEdit.movingEntryToEdge(paperOrder, at: pos, toEnd: false) }
                            .disabled(pos == 0)
                        Button(L10n.t("上へ")) { paperOrder = PaperEdit.movingEntry(paperOrder, at: pos, by: -1) }
                            .disabled(pos == 0)
                        Button(L10n.t("下へ")) { paperOrder = PaperEdit.movingEntry(paperOrder, at: pos, by: 1) }
                            .disabled(pos == paperOrder.count - 1)
                        Button(L10n.t("末尾へ移動")) { paperOrder = PaperEdit.movingEntryToEdge(paperOrder, at: pos, toEnd: true) }
                            .disabled(pos == paperOrder.count - 1)
                        Button(L10n.t("外す")) { paperOrder.remove(at: pos) }
                    }
                }
                .onMove { from, to in
                    paperOrder = PaperEdit.reordered(paperOrder, fromOffsets: from, toOffset: to)
                }
            }
            .listStyle(.plain)
            .frame(height: 110)
        }
    }

    /// 単語の組み立て: 組み立て列(単語の並び順)の確認と並べ替え・取り消し。
    /// 文の組み立て列と同じ作法(ドラッグとボタンの両方。計算は Core の `TranscriptWordEdit`)。
    @ViewBuilder
    private func wordPaperOrderList(_ f: [TranscriptSentence]) -> some View {
        if wordPaperOrder.isEmpty {
            Text(L10n.t("組み立ての並びはまだ空です")).foregroundStyle(.secondary)
        } else {
            Text(L10n.t("組み立ての並び"))
            Text(L10n.t("ドラッグでも並べ替えられます")).foregroundStyle(.secondary).font(.caption)
            List {
                ForEach(Array(wordPaperOrder.enumerated()), id: \.offset) { pos, sel in
                    HStack {
                        Text("\(pos + 1). \(f[sel.sentence].words[sel.word].text)")
                            .lineLimit(1)
                        Spacer()
                        Button(L10n.t("先頭へ移動")) { wordPaperOrder = TranscriptWordEdit.movingWordEntryToEdge(wordPaperOrder, at: pos, toEnd: false) }
                            .disabled(pos == 0)
                        Button(L10n.t("上へ")) { wordPaperOrder = TranscriptWordEdit.movingWordEntry(wordPaperOrder, at: pos, by: -1) }
                            .disabled(pos == 0)
                        Button(L10n.t("下へ")) { wordPaperOrder = TranscriptWordEdit.movingWordEntry(wordPaperOrder, at: pos, by: 1) }
                            .disabled(pos == wordPaperOrder.count - 1)
                        Button(L10n.t("末尾へ移動")) { wordPaperOrder = TranscriptWordEdit.movingWordEntryToEdge(wordPaperOrder, at: pos, toEnd: true) }
                            .disabled(pos == wordPaperOrder.count - 1)
                        Button(L10n.t("外す")) { wordPaperOrder.remove(at: pos) }
                    }
                }
                .onMove { from, to in
                    wordPaperOrder = TranscriptWordEdit.reorderedWords(wordPaperOrder, fromOffsets: from, toOffset: to)
                }
            }
            .listStyle(.plain)
            .frame(height: 110)
        }
    }

    private func scan() async {
        do {
            let r = try await model.scanTranscriptSentences()
            found = r
            kept = Set(r.indices)
        } catch is CancellationError {
            // 閉じたときは何もしない
        } catch {
            failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func commit() {
        guard let id = clipId, let f = found else { return }
        let removed = f.indices.filter { !kept.contains($0) }.map { f[$0] }
        if model.cutTranscriptSentences(clipId: id, removed: removed, ripple: ripple) { model.showTranscriptEditSheet = false }
    }

    private func commitWord() {
        guard let id = clipId, let f = found, !wordSelection.isEmpty else { return }
        if model.cutTranscriptWords(clipId: id, sentences: f, selections: wordSelection, ripple: ripple) {
            model.showTranscriptEditSheet = false
        }
    }

    private func commitPaper() {
        guard let id = clipId, let f = found, !paperOrder.isEmpty else { return }
        let destination: PaperEdit.Destination
        switch paperDestination {
        case .timeline:
            guard let track = ClipEditing.locate(id, in: model.project)?.track else { return }
            destination = .appendToTrack(track)
        case .scene:
            destination = .newScene(name: paperSceneName)
        }
        if model.assemblePaperEdit(clipId: id, sentences: f, order: paperOrder, destination: destination) {
            model.showTranscriptEditSheet = false
        }
    }

    private func commitWordPaper() {
        guard let id = clipId, let f = found, !wordPaperOrder.isEmpty else { return }
        let destination: PaperEdit.Destination
        switch paperDestination {
        case .timeline:
            guard let track = ClipEditing.locate(id, in: model.project)?.track else { return }
            destination = .appendToTrack(track)
        case .scene:
            destination = .newScene(name: paperSceneName)
        }
        if model.assemblePaperEditWords(clipId: id, sentences: f, order: wordPaperOrder, destination: destination) {
            model.showTranscriptEditSheet = false
        }
    }
}

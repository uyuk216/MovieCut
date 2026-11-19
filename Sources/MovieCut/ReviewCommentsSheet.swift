import SwiftUI
import MovieCutCore

/// レビューコメント一覧シート(移動 ▸ レビューコメント一覧…)。
/// 追加(再生位置)・本文の編集(確定で 1 回の Undo)・解決済みの切り替え・位置への移動・削除と、
/// 交換ファイル(JSON / CSV)の書き出し・読み込みができる。作法は注記一覧シートに合わせる。
struct ReviewCommentsSheet: View {
    @ObservedObject var model: ProjectModel
    @State private var author: String = ""
    @State private var newBody: String = ""
    @State private var openOnly = false

    private var all: [ReviewComment] { model.project.reviewComments }
    private var shown: [ReviewComment] { openOnly ? all.filter { !$0.resolved } : all }
    private var openCount: Int { all.filter { !$0.resolved }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.t("レビューコメント")).font(.title3.bold())
                Spacer()
                Text("\(all.count) 件").foregroundStyle(.secondary).monospacedDigit()
            }
            HStack(spacing: 8) {
                TextField(L10n.t("作成者名"), text: $author).textFieldStyle(.roundedBorder).frame(width: 140)
                TextField(L10n.t("コメント"), text: $newBody).textFieldStyle(.roundedBorder)
                    .onSubmit { add() }
                Button(L10n.t("追加")) { add() }.disabled(newBody.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            HStack(spacing: 8) {
                Text("\(L10n.t("再生位置")): \(Chapters.timecode(model.currentTime))")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                if !all.isEmpty {
                    Text("\(L10n.t("未解決")) \(openCount) 件").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    Toggle(L10n.t("未解決のみ表示"), isOn: $openOnly).toggleStyle(.checkbox).font(.caption)
                }
            }
            if all.isEmpty {
                InspectorGuideCard(symbol: "text.bubble", heading: "レビューコメントはありません", message: "再生位置にコメントを追加すると、ここに出ます。")
                    .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                List {
                    ForEach(shown) { c in
                        ReviewCommentRow(model: model, comment: c)
                    }
                }
                .frame(minHeight: 200)
            }
            HStack {
                Button(L10n.t("レビューコメントを書き出す…")) { model.chooseAndExportReviewComments() }
                    .disabled(all.isEmpty)
                Button(L10n.t("レビューコメントを読み込む…")) { model.chooseAndImportReviewComments() }
                Spacer()
                Button(L10n.t("閉じる")) { model.showReviewCommentsSheet = false }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 640)
        .onAppear { author = model.reviewCommentAuthor }
    }

    private func add() {
        guard model.addReviewCommentAtPlayhead(body: newBody, author: author) != nil else { return }
        newBody = ""
    }
}

private struct ReviewCommentRow: View {
    @ObservedObject var model: ProjectModel
    let comment: ReviewComment
    @State private var draft: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Button(Chapters.timecode(comment.time)) { model.jumpToReviewComment(id: comment.id) }
                .buttonStyle(.link)
                .help(L10n.t("位置へ移動"))
            TextField("", text: $draft).textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { commit() }
                .onChange(of: focused) { _, now in if !now { commit() } }
            if !comment.author.isEmpty {
                Text(comment.author).font(.caption).foregroundStyle(.secondary)
            }
            Button(comment.resolved ? L10n.t("解決済み") : L10n.t("未解決")) {
                model.toggleReviewCommentResolved(id: comment.id)
            }
            .foregroundStyle(comment.resolved ? .green : .secondary)
            Button(L10n.t("削除"), role: .destructive) { model.deleteReviewComment(id: comment.id) }
        }
        .onAppear { draft = comment.body }
        .onChange(of: comment.body) { _, v in if !focused { draft = v } }
    }

    /// 本文の確定(Enter かフォーカスを離したとき。モデルの編集 1 回 = Undo 1 回)。
    private func commit() {
        guard draft != comment.body else { return }
        if !model.updateReviewCommentBody(id: comment.id, to: draft) {
            draft = comment.body   // 空など、受け付けなかったときは元の本文に戻す
        }
    }
}

import SwiftUI
import MovieCutCore

/// レビューコメント一覧シート(移動 ▸ レビューコメント一覧…)。
/// 追加(再生位置)・本文の編集(確定で 1 回の Undo)・解決済みの切り替え・位置への移動・削除ができる。
struct ReviewCommentsSheet: View {
    @ObservedObject var model: ProjectModel
    @State private var author: String = ""
    @State private var newBody: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.t("レビューコメント")).font(.headline)
            HStack(spacing: 8) {
                TextField(L10n.t("作成者名"), text: $author).textFieldStyle(.roundedBorder).frame(width: 140)
                TextField(L10n.t("コメント"), text: $newBody).textFieldStyle(.roundedBorder)
                    .onSubmit { add() }
                Button(L10n.t("追加")) { add() }.disabled(newBody.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text(Chapters.timecode(model.currentTime)).font(.caption).foregroundStyle(.secondary)
            if model.project.reviewComments.isEmpty {
                Text(L10n.t("レビューコメントはありません")).foregroundStyle(.secondary)
            } else {
                List {
                    ForEach(model.project.reviewComments) { c in
                        ReviewCommentRow(model: model, comment: c)
                    }
                }
                .frame(minHeight: 180)
            }
            HStack {
                Spacer()
                Button(L10n.t("閉じる")) { model.showReviewCommentsSheet = false }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(width: 560)
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

    var body: some View {
        HStack(spacing: 8) {
            Button(Chapters.timecode(comment.time)) { model.jumpToReviewComment(id: comment.id) }
                .buttonStyle(.link)
                .help(L10n.t("位置へ移動"))
            TextField("", text: $draft).textFieldStyle(.roundedBorder)
                .onSubmit { model.updateReviewCommentBody(id: comment.id, to: draft) }
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
        .onChange(of: comment.body) { _, v in draft = v }
    }
}

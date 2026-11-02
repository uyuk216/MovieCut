import SwiftUI

/// インスペクタの「注記」欄。書き出しには出ない作業用のメモ。Return かフォーカスを離したときに 1 回の編集として書く(200 字まで)。
struct ClipNoteField: View {
    @ObservedObject var model: ProjectModel
    let clipId: String
    let note: String
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("作業メモ(書き出しには出ません)", text: $text, axis: .vertical)
            .lineLimit(1...3)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12))
            .focused($focused)
            .accessibilityIdentifier("clip-note-field")
            .onSubmit { commit() }
            .onChange(of: focused) { _, now in if !now { commit() } }
            .onAppear { text = note }
            .onChange(of: note) { _, v in if !focused { text = v } }
    }

    private func commit() {
        model.setClipNote(text, clipId: clipId)
        text = model.clip(clipId)?.note ?? ""
    }
}

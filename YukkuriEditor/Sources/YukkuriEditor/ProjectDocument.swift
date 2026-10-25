import SwiftUI
import UniformTypeIdentifiers
import YukkuriCore

extension UTType {
    /// .ymproj(JSON)。Info.plist の UTExportedTypeDeclarations と同じ識別子。
    static let ymproj = UTType(exportedAs: "jp.local.yukkuri-editor.project", conformingTo: .json)
}

/// .ymproj のドキュメント。開く/保存/別名/最近/未保存マークは DocumentGroup(NSDocument)が受け持つ。
/// 中身は ProjectModel が持つ(1 ドキュメントに 1 つ)。
final class ProjectDocument: ReferenceFileDocument {
    typealias Snapshot = Data

    static var readableContentTypes: [UTType] { [.ymproj] }
    static var writableContentTypes: [UTType] { [.ymproj] }

    let model: ProjectModel

    init() {
        model = onMain { ProjectModel(project: .new()) }
    }

    required init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let p = try Project.decode(from: data)
        model = onMain { ProjectModel(project: p) }
    }

    func snapshot(contentType: UTType) throws -> Data {
        try onMain { try model.project.encoded() }
    }

    func fileWrapper(snapshot: Data, configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: snapshot)
    }
}

/// どのスレッドから呼ばれても主スレッドで実行する(ファイルの読み込みは主スレッド以外で呼ばれる)。
func onMain<T>(_ body: @MainActor () throws -> T) rethrows -> T {
    if Thread.isMainThread { return try MainActor.assumeIsolated(body) }
    return try DispatchQueue.main.sync { try MainActor.assumeIsolated(body) }
}

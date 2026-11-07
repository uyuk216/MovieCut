import SwiftUI
import AppKit
import MovieCutCore

/// バナーに出す内容(足りない物だけ)。
struct DependencyBannerContent: Equatable {
    struct Link: Equatable { var title: String; var url: String }
    var messages: [String]
    var links: [Link]

    /// 何も欠けていなければ nil。
    static func make(from s: DependencyStatus) -> DependencyBannerContent? {
        var messages: [String] = []
        var links: [Link] = []
        if !s.voicevoxInstalled && !s.voicevoxRunning {
            messages.append("VOICEVOX が見つかりません。キャラ2などの声を使うには、VOICEVOX をインストールしてください。")
            links.append(Link(title: "VOICEVOX を入手", url: DependencyStatus.voicevoxURL))
        }
        if !s.aquestalkPlayerInstalled {
            messages.append("AquesTalkPlayer が見つかりません。ゆっくり音声は macOS の「Kyoko」で代用します。")
            links.append(Link(title: "AquesTalkPlayer を入手", url: DependencyStatus.aquestalkURL))
        }
        return messages.isEmpty ? nil : DependencyBannerContent(messages: messages, links: links)
    }
}

/// 起動時の依存チェックの結果を持つ(アプリ全体で 1 つ)。閉じたら、この起動中は二度と出さない。
@MainActor
final class DependencyNoticeCenter: ObservableObject {
    @Published private(set) var content: DependencyBannerContent?
    private(set) var dismissedThisSession = false
    private(set) var checkCount = 0
    var checker: (Project) async -> DependencyStatus

    init(checker: @escaping (Project) async -> DependencyStatus) { self.checker = checker }

    func refresh(project: Project) async {
        guard !dismissedThisSession else { return }
        let status = await checker(project)
        guard !dismissedThisSession else { return }
        checkCount += 1
        content = DependencyBannerContent.make(from: status)
    }

    func dismiss() {
        dismissedThisSession = true
        content = nil
    }

    /// 検証用: `MC_DEBUG_DEPS=missing`(両方無い)/ `missing-voicevox` / `missing-aquestalk` のとき、チェックの代わりに固定の結果を返す。
    static func debugChecker() -> ((Project) async -> DependencyStatus)? {
        switch ProcessInfo.processInfo.environment["MC_DEBUG_DEPS"] {
        case "missing": return { _ in DependencyStatus(voicevoxInstalled: false, voicevoxRunning: false, aquestalkPlayerInstalled: false) }
        case "missing-voicevox": return { _ in DependencyStatus(voicevoxInstalled: false, voicevoxRunning: false, aquestalkPlayerInstalled: true) }
        case "missing-aquestalk": return { _ in DependencyStatus(voicevoxInstalled: true, voicevoxRunning: false, aquestalkPlayerInstalled: false) }
        default: return nil
        }
    }
}

/// ウィンドウの一番上に出す、閉じられるバナー。
struct DependencyBannerBar: View {
    @ObservedObject var center: DependencyNoticeCenter

    var body: some View {
        if let c = center.content {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(c.messages, id: \.self) { Text($0).font(.system(size: 12)) }
                }
                Spacer(minLength: 12)
                ForEach(c.links, id: \.url) { l in
                    Button(l.title) { if let u = URL(string: l.url) { NSWorkspace.shared.open(u) } }
                        .controlSize(.small)
                }
                Button { center.dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("閉じる(この起動中は、もう出しません)")
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(Color.yellow.opacity(0.18), ignoresSafeAreaEdges: [])
            .overlay(alignment: .bottom) { Divider() }
        }
    }
}

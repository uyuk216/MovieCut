import Foundation

/// 起動時の依存チェック(ffmpeg は不要)。
public struct DependencyStatus: Equatable {
    public static let voicevoxURL = "https://voicevox.hiroshiba.jp/"
    public static let aquestalkURL = "https://www.a-quest.com/products/aquestalkplayer.html"

    public var voicevoxInstalled: Bool
    public var voicevoxRunning: Bool
    public var aquestalkPlayerInstalled: Bool

    public init(voicevoxInstalled: Bool, voicevoxRunning: Bool, aquestalkPlayerInstalled: Bool) {
        self.voicevoxInstalled = voicevoxInstalled
        self.voicevoxRunning = voicevoxRunning
        self.aquestalkPlayerInstalled = aquestalkPlayerInstalled
    }

    /// 案内文(足りないものだけ)。
    public var notice: [String] {
        var n: [String] = []
        if !voicevoxInstalled && !voicevoxRunning {
            n.append("VOICEVOX が見つかりません。キャラ2などの声を使うには VOICEVOX をインストールしてください: \(Self.voicevoxURL)")
        }
        if !aquestalkPlayerInstalled {
            n.append("AquesTalkPlayer が見つかりません。ゆっくり音声は macOS の「Kyoko」で代用します。本物のゆっくり音声を使うには AquesTalkPlayer をインストールしてください: \(Self.aquestalkURL)")
        }
        return n
    }

    public static func check(project: Project, voicevoxBinary: String = VoicevoxEngine.defaultBinary, aquestalkPath: String? = nil) async -> DependencyStatus {
        let fm = FileManager.default
        return DependencyStatus(
            voicevoxInstalled: fm.fileExists(atPath: voicevoxBinary),
            voicevoxRunning: await VoicevoxEngine.isAlive(baseURL: project.voicevoxUrl),
            aquestalkPlayerInstalled: AquesTalkSynthesizer(cache: .standard, playerPath: aquestalkPath).playerInstalled)
    }
}

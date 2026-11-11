import Foundation

extension Character {
    /// 声がまだ選ばれていないか(VOICEVOX は話者が nil、AquesTalk は声が nil)。
    /// 合成は未設定でも従来どおり既定の声で鳴る。これは「選んでね」という案内を出すための判定だけ。
    public var hasVoiceChosen: Bool {
        engine == "voicevox" ? speaker != nil : voice != nil
    }
}

/// 最初の一歩の案内(ウェルカム画面・空のプレビューに出す短い手順)。
public enum QuickStart {
    public static let title = "はじめかた"
    public static let steps: [String] = [
        "①キャラクターの声を選ぶ",
        "②台本を書く",
        "③「音声を作る」を押す",
        "④書き出す ⌘E",
    ]
}

/// 「おすすめ音声設定」の取得結果(通信は注入できる)。
public enum VoicePresetFetchOutcome: Equatable {
    case loaded([VoicePreset])
    case empty
    case failed(String)

    public static let networkFailureMessage = "ネットから取得できませんでした。接続を確認するか、「ファイルから読み込み…」で設定ファイルを選んでください。"

    public static func run(_ loader: () async throws -> VoicePresetCatalog) async -> VoicePresetFetchOutcome {
        do {
            let c = try await loader()
            return c.presets.isEmpty ? .empty : .loaded(c.presets)
        } catch let e as VoicePresetCatalog.Failure {
            return .failed(e.localizedDescription)
        } catch {
            return .failed(networkFailureMessage)
        }
    }
}

/// キャラクター一覧の行に出す 2 行目(エンジン・話者)。声が未選択なら「声 未設定」。
public enum CharacterRowSubtitle {
    public static let unsetVoice = "声 未設定"
    public static func text(for c: Character, speakerName: String?) -> String {
        guard c.hasVoiceChosen else { return unsetVoice }
        if c.engine == "voicevox" { return speakerName ?? "VOICEVOX 話者 \(c.speaker ?? 3)" }
        return "ゆっくり " + (c.voice ?? "")
    }
}

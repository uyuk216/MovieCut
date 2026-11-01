import Foundation

/// スタンプ(絵文字)。大きい文字クリップ 1 つとして置く(保存の形は文字クリップと同じ。新しい項目は増えない)。
/// 位置・大きさ・回転・不透明度はキーフレームで動かせる。
public enum StampCatalog {
    /// 組み込みの 24 種: 絵文字と、メニューに出す名前。
    public static let items: [(emoji: String, title: String)] = [
        ("😀", "笑顔"), ("😂", "爆笑"), ("🥰", "うっとり"), ("😎", "かっこいい"), ("🤔", "考え中"), ("😭", "泣き"),
        ("😡", "怒り"), ("👍", "いいね"), ("👏", "拍手"), ("🙏", "お願い"), ("🎉", "お祝い"), ("🔥", "熱い"),
        ("⭐", "星"), ("💯", "百点"), ("✨", "キラキラ"), ("👀", "注目"), ("💡", "ひらめき"), ("✅", "できた"),
        ("🌸", "桜"), ("🐱", "ねこ"), ("🐶", "いぬ"), ("🍣", "寿司"), ("🎵", "音符"), ("🚀", "ロケット"),
    ]
    /// スタンプの大きさ(文字の大きさ・px)と既定の長さ(秒)。
    public static let fontSize = 200.0
    public static let defaultDuration = 3.0

    /// 絵文字として描けるか(組み込みの 24 種だけ)。
    public static func isStamp(_ text: String) -> Bool { items.contains { $0.emoji == text } }
}

extension ClipEditing {
    /// スタンプの文字クリップを作る(再生位置から 3 秒、画面の中央)。
    public static func makeStampClip(_ emoji: String, at t: Double) -> Clip {
        var c = Clip()
        c.type = .text
        c.start = t
        c.duration = StampCatalog.defaultDuration
        c.text = emoji
        c.fontSize = StampCatalog.fontSize
        c.x = 0.5; c.y = 0.5
        return c
    }
}

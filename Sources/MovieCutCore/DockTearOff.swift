import Foundation

// MARK: - パネルの切り離し(Chrome のタブの引き剥がし)の状態機械

/// ドッキングのパネルのタブを掴んで、書類のウインドウの外へ引き出すまでの流れを決める純粋な状態機械。
/// 画面・ウインドウは持たない(AppKit 側が、マウスの位置と押下の状態を渡し、返された命令を実行する)。
///
/// 流れ:
/// - 掴む(`press`)。ドッキング中のパネルなら `docked = true`。
/// - ドラッグ中(`drag`): ドッキング中のパネルが書類のウインドウの外に出たら `tearOff`(切り離す)。
///   以後、切り離したウインドウはカーソルに合わせて動く(`follow`)。
/// - 離す(`release`): 書類のウインドウの上で離したら、ドッキングへ戻す(`redock`。端の帯なら端へ)。
///   外で離したら、切り離したまま(`none`)。
/// - ウインドウを閉じた・「ウインドウに戻す」を押した(`windowClosed` / `restore`): ドッキングへ戻す(`redock`)。
public struct DockTearOff: Equatable {
    public enum Phase: Equatable {
        /// 何も掴んでいない。
        case idle
        /// 掴んでいる(まだ切り離していない)。`docked` は掴んだときにドッキング中だったか。
        case pressed(DockPanel, docked: Bool)
        /// 切り離して、ウインドウとして動いている。
        case floating(DockPanel)
    }

    /// AppKit に頼む動き。`none` は何もしない。
    public enum Command: Equatable {
        case none
        /// ドッキングから切り離す(`DockLayout.detach`。戻し先を記録する)。ウインドウは、今のカーソルの位置に出す。
        case tearOff(DockPanel)
        /// 切り離したウインドウを、カーソルに合わせて動かす。
        case follow(DockPanel)
        /// ドッキングへ戻す。`outer` が入っていれば、ドック全体のその端へ(`DockLayout.redock`)。
        case redock(DockPanel, outer: DockEdge?)
    }

    public private(set) var phase: Phase = .idle

    public init() {}

    /// 掴んだ。
    public mutating func press(_ panel: DockPanel, docked: Bool) {
        phase = .pressed(panel, docked: docked)
    }

    /// ドラッグ中の位置。`overMainWindow` は、カーソルが書類のウインドウの上にあるか。
    public mutating func drag(overMainWindow: Bool) -> Command {
        switch phase {
        case .idle:
            return .none
        case .pressed(let p, let docked):
            // ドッキング中のタブを、書類のウインドウの外へ出したら切り離す
            if docked, !overMainWindow {
                phase = .floating(p)
                return .tearOff(p)
            }
            return .none
        case .floating(let p):
            return .follow(p)
        }
    }

    /// 離した。`overMainWindow` は、書類のウインドウの上で離したか。`outer` は、その位置が端の帯なら、その端。
    public mutating func release(overMainWindow: Bool, outer: DockEdge?) -> Command {
        defer { phase = .idle }
        switch phase {
        case .floating(let p):
            return overMainWindow ? .redock(p, outer: outer) : .none
        case .idle, .pressed:
            return .none
        }
    }

    /// 切り離したウインドウが閉じられた: ドッキングへ戻す(切り離し中のものだけ状態を変える)。
    public mutating func windowClosed(_ panel: DockPanel) -> Command {
        if phase == .floating(panel) { phase = .idle }
        return .redock(panel, outer: nil)
    }

    /// 「ウインドウに戻す」ボタン: ドッキングへ戻す。
    public mutating func restore(_ panel: DockPanel) -> Command {
        if phase == .floating(panel) { phase = .idle }
        return .redock(panel, outer: nil)
    }
}

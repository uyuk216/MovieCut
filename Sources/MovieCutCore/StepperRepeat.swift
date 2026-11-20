import Foundation

// 数値ステッパーの長押し連続操作の「発火計画」。UI もタイマーも持たない純粋な状態機械。
//
// 仕様(ユーザー要望):
// - 押した瞬間に 1 回発火する(短押し = 1 回だけ)。
// - 押し続けると `initialDelay`(目安 0.4 秒)経ってから連続発火が始まる。
// - 連続中は `repeatInterval` ごとに発火する。
// - 離したら即停止し、それ以降は発火しない。
//
// 使い方は、押下側(実タイマーの薄いアダプタ)が単調増加する時刻(秒)を渡して
// `pressBegan` / `poll(at:)` / `pressEnded` を呼ぶだけ。時刻の出どころ
// (systemUptime など)は呼び出し側の責任で、この型は時計を読まないので
// 任意の時刻列を与えて単体テストできる。

/// ステッパーを押す向き。
public enum StepperDirection: Equatable, Sendable {
    case increment
    case decrement
}

/// 長押し連続発火の状態機械。値型で、時刻はすべて引数で受け取る。
public struct StepperRepeatScheduler: Equatable, Sendable {
    /// 押してから連続発火が始まるまでの待ち時間(秒)。
    public var initialDelay: Double
    /// 連続発火の間隔(秒)。
    public var repeatInterval: Double

    /// 仕様の目安: 遅延 0.4 秒。
    public static let defaultInitialDelay: Double = 0.4
    /// 連続間隔。NumField の onStep は大半が coalesced(0.7 秒窓で Undo を 1 回に
    /// まとめる)経由なので、この間隔で連打しても Undo は膨らまない。
    public static let defaultRepeatInterval: Double = 0.05

    /// いま押されている向き。押されていなければ nil。
    public private(set) var direction: StepperDirection?
    /// 押されているかどうか。
    public var isPressed: Bool { direction != nil }
    /// この押下で発火した回数(押した瞬間の 1 回を含む)。押されていなければ 0。
    public private(set) var firedCount: Int = 0

    private var pressedAt: Double = 0
    private var nextRepeatAt: Double = 0

    public init(initialDelay: Double = StepperRepeatScheduler.defaultInitialDelay,
                repeatInterval: Double = StepperRepeatScheduler.defaultRepeatInterval) {
        // 0 以下・非有限の指定は発火が暴走するので、既定値に丸める。
        self.initialDelay = (initialDelay.isFinite && initialDelay > 0) ? initialDelay : Self.defaultInitialDelay
        self.repeatInterval = (repeatInterval.isFinite && repeatInterval > 0) ? repeatInterval : Self.defaultRepeatInterval
    }

    /// 押し始め。押した瞬間の 1 回ぶんとして、常に「いま発火すべき」を返す。
    /// すでに押されている最中に呼ばれたら(向きの切り替えなど)、そこから数え直す。
    @discardableResult
    public mutating func pressBegan(_ direction: StepperDirection, at time: Double) -> Bool {
        self.direction = direction
        pressedAt = time
        nextRepeatAt = time + initialDelay
        firedCount = 1
        return true
    }

    /// 時刻 `time` の時点で連続発火すべきなら true を返し、次の発火時刻を進める。
    /// 押されていない、または遅延が明けていなければ false。
    /// タイマーが遅れて複数間隔ぶん過ぎていても、1 回の poll では 1 回だけ発火し、
    /// 次回は現在時刻から間隔を置く(遅れを取り戻す連射はしない)。
    @discardableResult
    public mutating func poll(at time: Double) -> Bool {
        guard direction != nil else { return false }
        // 時刻の加算誤差で境界の tick を取りこぼさないよう、ごく小さい許容を持たせる。
        guard time >= nextRepeatAt - 1e-9 else { return false }
        firedCount += 1
        nextRepeatAt += repeatInterval
        if nextRepeatAt <= time { nextRepeatAt = time + repeatInterval }
        return true
    }

    /// 離した。以後は `poll` が常に false になる。
    public mutating func pressEnded() {
        direction = nil
        firedCount = 0
    }

    /// 次に発火しうる時刻(押されていないときは nil)。実タイマー側が
    /// スリープ量の目安に使えるが、使わなくてもよい。
    public var nextFireTime: Double? {
        direction == nil ? nil : nextRepeatAt
    }

    /// 押下からの経過で見た、次回発火までの残り(デバッグ・テスト用)。
    public func timeUntilNextFire(at time: Double) -> Double? {
        guard direction != nil else { return nil }
        return max(0, nextRepeatAt - time)
    }
}

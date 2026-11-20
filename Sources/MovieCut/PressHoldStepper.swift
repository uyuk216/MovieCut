import SwiftUI
import AppKit
import MovieCutCore

// MARK: - 長押し連続ステッパー(共通部品)
//
// SwiftUI の Stepper の代わりに NumField などで使う、上下ボタンの組。
// 見た目は従来の Stepper に揃えた小さな上下ボタンで、操作は:
// - 短押し(クリック): 1 回だけステップする。
// - 長押し: 押した瞬間に 1 回、0.4 秒押し続けたら連続ステップが始まり、
//   0.05 秒間隔で繰り返す。離したら即止まる。
// - キーボード: この部品にフォーカスがあるとき ↑ / ↓ で 1 回ステップする
//   (キーのリピートは OS 側が繰り返しイベントを送る)。VoiceOver の
//   調整(インクリメント/デクリメント)操作にも応じる。
//
// 発火のタイミング判定は MovieCutCore の StepperRepeatScheduler(純粋な状態機械)に任せ、
// ここは実タイマー(Task のスリープで 10ms ごとに poll する)との薄い接続だけを行う。
// 値のクランプ・ステップ幅・Undo の扱いは呼び出し側(onIncrement/onDecrement の先)が
// 従来どおり担う。この部品は「何回発火するか」だけを決める。

/// 長押しの駆動役。タイマーが古い値で発火し続けないよう、最新の
/// onIncrement/onDecrement を View の body から差し替えて保持する。
@MainActor
private final class PressHoldStepperDriver: ObservableObject {
    @Published private(set) var pressedDirection: StepperDirection?

    /// View の描画のたびに最新のクロージャへ差し替える(値・ステップ幅は描画時点のものを使う)。
    var onIncrement: () -> Void = {}
    var onDecrement: () -> Void = {}

    private var scheduler = StepperRepeatScheduler()
    private var tickTask: Task<Void, Never>?

    /// 押し始め。すでに同じ向きを押している最中の重複呼び出し(ドラッグの連続通知)は無視する。
    func begin(_ direction: StepperDirection) {
        if scheduler.isPressed, scheduler.direction == direction { return }
        if scheduler.pressBegan(direction, at: Self.now()) { fire(direction) }
        pressedDirection = direction
        tickTask?.cancel()
        tickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000)   // 10ms ごとに poll
                guard let self, self.scheduler.isPressed, let d = self.scheduler.direction else { return }
                if self.scheduler.poll(at: Self.now()) { self.fire(d) }
            }
        }
    }

    /// 離した(または部品が消えた・無効になった)。即停止する。
    func end() {
        scheduler.pressEnded()
        pressedDirection = nil
        tickTask?.cancel()
        tickTask = nil
    }

    private func fire(_ direction: StepperDirection) {
        switch direction {
        case .increment: onIncrement()
        case .decrement: onDecrement()
        }
    }

    private static func now() -> Double { ProcessInfo.processInfo.systemUptime }
}

/// 上下ボタンの組。`Stepper("", onIncrement:onDecrement:)` と同じ役割。
struct PressHoldStepper: View {
    let onIncrement: () -> Void
    let onDecrement: () -> Void

    @StateObject private var driver = PressHoldStepperDriver()
    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var focused: Bool

    var body: some View {
        // タイマーが保持するクロージャを、常に最新の値・ステップ幅のものに保つ。
        driver.onIncrement = onIncrement
        driver.onDecrement = onDecrement
        return VStack(spacing: 0) {
            half(.increment, symbol: "chevron.up")
            Rectangle().fill(MCDesign.Color.divider).frame(height: 1)
            half(.decrement, symbol: "chevron.down")
        }
        .frame(width: 20, height: 28)
        .background(MCDesign.Color.control, in: RoundedRectangle(cornerRadius: MCDesign.Radius.chip))
        .clipShape(RoundedRectangle(cornerRadius: MCDesign.Radius.chip))
        .overlay {
            RoundedRectangle(cornerRadius: MCDesign.Radius.chip)
                .stroke(focused ? Color.accentColor : MCDesign.Color.divider, lineWidth: focused ? 1.5 : 1)
        }
        .opacity(isEnabled ? 1 : 0.5)
        .focusable()
        .focused($focused)
        .onKeyPress(.upArrow) { guard isEnabled else { return .ignored }; onIncrement(); return .handled }
        .onKeyPress(.downArrow) { guard isEnabled else { return .ignored }; onDecrement(); return .handled }
        .accessibilityElement(children: .ignore)
        .accessibilityAdjustableAction { direction in
            guard isEnabled else { return }
            switch direction {
            case .increment: onIncrement()
            case .decrement: onDecrement()
            @unknown default: break
            }
        }
        .onChange(of: isEnabled) { _, now in if !now { driver.end() } }
        .onDisappear { driver.end() }
    }

    private func half(_ direction: StepperDirection, symbol: String) -> some View {
        let isPressed = driver.pressedDirection == direction && isEnabled
        return Image(systemName: symbol)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(Color.primary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(isPressed ? Color.primary.opacity(0.18) : Color.clear)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in if isEnabled { driver.begin(direction) } }
                    .onEnded { _ in driver.end() }
            )
    }
}

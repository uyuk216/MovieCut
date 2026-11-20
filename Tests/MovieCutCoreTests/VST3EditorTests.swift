import XCTest
@testable import MovieCutCore

/// VST3 純正 GUI の土台(R5 キュー3)の検証。実プラグイン・実ウィンドウは使わず、
/// 呼び出し順を記録するフェイクで「セッション契約・巻き戻し・エディタ無しの区別・コールバック」を固定する。
/// 実プラグインでの表示目視は未実施(docs の 6.7 / 7 節参照)。
final class VST3EditorTests: XCTestCase {

    final class FakeEditorBackend: VST3BridgeBackend {
        private(set) var calls: [String] = []
        /// 失敗を差し込む段階: "open" "create" "callback" "createView" "getSize" "setSize"
        var failAt: String?
        var createViewStatus: VST3BridgeStatus = .ok
        var viewSize = VST3EditorSize(width: 320, height: 200)
        /// setEditorSize で丸める先(nil なら受け取った値そのまま)
        var roundTo: VST3EditorSize?
        private(set) var registeredCallback: ((VST3EditorSize) -> Bool)?

        func handshake() -> (status: VST3BridgeStatus, version: Int32?) { calls.append("handshake"); return (.ok, VST3Bridge.protocolVersion) }
        func openBundle(path: String) -> VST3BridgeStatus { calls.append("open"); return failAt == "open" ? .notFound : .ok }
        func classInfos() -> (status: VST3BridgeStatus, infos: [VST3BridgeClassInfo]) { (.ok, []) }
        func createProcessor(cid: String?) -> VST3BridgeStatus { calls.append("create"); return failAt == "create" ? .internalError : .ok }
        func setupProcessing(_ setup: VST3ProcessSetup, layout: VST3BusLayout) -> VST3BridgeStatus { .ok }
        func setActive(_ active: Bool) -> VST3BridgeStatus { .ok }
        func processBlock(inputLeft: UnsafePointer<Float>, inputRight: UnsafePointer<Float>,
                          outputLeft: UnsafeMutablePointer<Float>, outputRight: UnsafeMutablePointer<Float>,
                          frames: Int, changes: [VST3ParameterChangePoint]) -> (status: VST3BridgeStatus, latency: Int?) { (.ok, nil) }
        func parameterInfos() -> (status: VST3BridgeStatus, infos: [VST3ParameterDescriptor]) { (.ok, []) }
        func getParameterNormalized(id: UInt32) -> (status: VST3BridgeStatus, value: Double?) { (.ok, nil) }
        func setParameterNormalized(id: UInt32, value: Double) -> VST3BridgeStatus { .ok }
        func latencyAndTail() -> (latency: Int, tail: Int)? { nil }
        func getState() -> (status: VST3BridgeStatus, data: Data?) { (.ok, nil) }
        func setState(_ data: Data) -> VST3BridgeStatus { .ok }
        func dispose() { calls.append("dispose") }

        func createEditorView(parentHandle: UInt64) -> (status: VST3BridgeStatus, viewHandle: UInt64?) {
            calls.append("createView(\(parentHandle))")
            if failAt == "createView" { return (.internalError, nil) }
            return createViewStatus == .ok ? (.ok, 0x1234) : (createViewStatus, nil)
        }
        func getEditorSize() -> (status: VST3BridgeStatus, size: VST3EditorSize?) {
            calls.append("getSize")
            return failAt == "getSize" ? (.internalError, nil) : (.ok, viewSize)
        }
        func setEditorSize(_ size: VST3EditorSize) -> VST3BridgeStatus {
            calls.append("setSize(\(size.width)x\(size.height))")
            if failAt == "setSize" { return .internalError }
            viewSize = roundTo ?? size
            return .ok
        }
        func destroyEditorView() -> VST3BridgeStatus { calls.append("destroyView"); return .ok }
        func setEditorResizeCallback(_ callback: ((VST3EditorSize) -> Bool)?) -> VST3BridgeStatus {
            calls.append(callback == nil ? "callback(nil)" : "callback")
            if failAt == "callback" { return .internalError }
            registeredCallback = callback
            return .ok
        }
    }

    private func makeSession(_ fake: FakeEditorBackend) -> VST3EditorSession {
        VST3EditorSession(backend: fake, bundlePath: "/tmp/Fake.vst3")
    }

    // MARK: 順序

    func testOpenAndCloseOrder() {
        let fake = FakeEditorBackend()
        let s = makeSession(fake)
        XCTAssertEqual(s.open(parentHandle: 42), .success(VST3EditorSize(width: 320, height: 200)))
        XCTAssertEqual(fake.calls, ["handshake", "open", "create", "callback", "createView(42)", "getSize"])
        XCTAssertEqual(s.state, .viewCreated)
        XCTAssertEqual(s.viewHandle, 0x1234)
        XCTAssertEqual(s.currentSize, VST3EditorSize(width: 320, height: 200))
        s.close()
        XCTAssertEqual(Array(fake.calls.suffix(2)), ["destroyView", "dispose"])
        XCTAssertEqual(s.state, .closed)
        XCTAssertNil(s.viewHandle); XCTAssertNil(s.currentSize)
        let count = fake.calls.count
        s.close()
        XCTAssertEqual(fake.calls.count, count, "二重 close は何も呼ばない")
    }

    func testOpenTwiceIsWrongStateWithoutBackendCalls() {
        let fake = FakeEditorBackend()
        let s = makeSession(fake)
        s.open(parentHandle: 1)
        let count = fake.calls.count
        XCTAssertEqual(s.open(parentHandle: 1), .failure(.wrongState))
        XCTAssertEqual(fake.calls.count, count)
        XCTAssertEqual(s.state, .viewCreated, "二重 open は既存のビューを壊さない")
    }

    // MARK: サイズ操作

    func testResizeForbiddenBeforeViewAndForInvalidSize() {
        let fake = FakeEditorBackend()
        let s = makeSession(fake)
        XCTAssertEqual(s.resize(to: VST3EditorSize(width: 100, height: 100)), .failure(.wrongState))
        XCTAssertTrue(fake.calls.isEmpty, "open 前はバックエンドを呼ばない")
        s.open(parentHandle: 1)
        let count = fake.calls.count
        XCTAssertEqual(s.resize(to: VST3EditorSize(width: 0, height: 100)), .failure(.invalidSize))
        XCTAssertEqual(s.resize(to: VST3EditorSize(width: 100, height: -1)), .failure(.invalidSize))
        XCTAssertEqual(fake.calls.count, count)
        // view 生成前(createView 失敗後)も wrongState
        let fake2 = FakeEditorBackend(); fake2.failAt = "createView"
        let s2 = makeSession(fake2)
        s2.open(parentHandle: 1)
        let c2 = fake2.calls.count
        XCTAssertEqual(s2.resize(to: VST3EditorSize(width: 100, height: 100)), .failure(.wrongState))
        XCTAssertEqual(fake2.calls.count, c2)
    }

    func testResizeRoundTripAdoptsPluginRoundedSize() {
        let fake = FakeEditorBackend()
        fake.roundTo = VST3EditorSize(width: 500, height: 300)
        let s = makeSession(fake)
        s.open(parentHandle: 1)
        let result = s.resize(to: VST3EditorSize(width: 497, height: 301))
        XCTAssertEqual(result, .success(VST3EditorSize(width: 500, height: 300)))
        XCTAssertEqual(Array(fake.calls.suffix(2)), ["setSize(497x301)", "getSize"], "setSize の後に getSize で再取得する")
        XCTAssertEqual(s.currentSize, VST3EditorSize(width: 500, height: 300))
    }

    // MARK: 巻き戻し

    func testCreateViewFailureRollsBackToDispose() {
        let fake = FakeEditorBackend(); fake.failAt = "createView"
        let s = makeSession(fake)
        XCTAssertEqual(s.open(parentHandle: 1), .failure(.bridgeFailure(.internalError)))
        XCTAssertEqual(Array(fake.calls.suffix(2)), ["createView(1)", "dispose"])
        XCTAssertFalse(fake.calls.contains("destroyView"), "view が無いので destroy は呼ばない")
        XCTAssertEqual(s.state, .closed)
        XCTAssertEqual(s.lastError, .bridgeFailure(.internalError))
    }

    func testGetSizeFailureDestroysViewThenDisposes() {
        let fake = FakeEditorBackend(); fake.failAt = "getSize"
        let s = makeSession(fake)
        XCTAssertEqual(s.open(parentHandle: 1), .failure(.bridgeFailure(.internalError)))
        XCTAssertEqual(Array(fake.calls.suffix(3)), ["getSize", "destroyView", "dispose"])
        XCTAssertEqual(s.state, .closed)
        XCTAssertNil(s.viewHandle)
    }

    func testEarlyFailuresDisposeOnlyWhatWasOpened() {
        let f1 = FakeEditorBackend(); f1.failAt = "open"
        XCTAssertEqual(makeSession(f1).open(parentHandle: 1), .failure(.bridgeFailure(.notFound)))
        XCTAssertFalse(f1.calls.contains("dispose"))
        let f2 = FakeEditorBackend(); f2.failAt = "create"
        XCTAssertEqual(makeSession(f2).open(parentHandle: 1), .failure(.bridgeFailure(.internalError)))
        XCTAssertEqual(f2.calls.last, "dispose")
        let f3 = FakeEditorBackend(); f3.failAt = "callback"
        XCTAssertEqual(makeSession(f3).open(parentHandle: 1), .failure(.bridgeFailure(.internalError)))
        XCTAssertEqual(f3.calls.last, "dispose")
    }

    // MARK: エディタ無しの区別

    func testNoEditorIsDistinctFromBridgeFailure() {
        let fake = FakeEditorBackend(); fake.createViewStatus = .noEditor
        let s = makeSession(fake)
        let result = s.open(parentHandle: 1)
        XCTAssertEqual(result, .failure(.noEditor))
        XCTAssertNotEqual(result, .failure(.bridgeFailure(.noEditor)))
        XCTAssertEqual(s.lastError, .noEditor)
        XCTAssertEqual(fake.calls.last, "dispose", "エディタ無しでも開いた分は畳む")
        XCTAssertEqual(s.state, .closed)
    }

    // MARK: プラグインからのリサイズ要求

    func testPluginResizeRequestIsRejectedWithoutHandler() {
        let fake = FakeEditorBackend()
        let s = makeSession(fake)
        s.open(parentHandle: 1)
        XCTAssertEqual(fake.registeredCallback?(VST3EditorSize(width: 640, height: 480)), false)
        XCTAssertEqual(s.currentSize, VST3EditorSize(width: 320, height: 200))
    }

    func testPluginResizeRequestPropagatesHandlerResult() {
        let fake = FakeEditorBackend()
        let s = makeSession(fake)
        s.open(parentHandle: 1)
        var accept = false
        var seen: [VST3EditorSize] = []
        s.onResizeRequested = { seen.append($0); return accept }
        XCTAssertEqual(fake.registeredCallback?(VST3EditorSize(width: 640, height: 480)), false)
        XCTAssertEqual(s.currentSize, VST3EditorSize(width: 320, height: 200), "拒否したら currentSize は変えない")
        accept = true
        XCTAssertEqual(fake.registeredCallback?(VST3EditorSize(width: 800, height: 600)), true)
        XCTAssertEqual(s.currentSize, VST3EditorSize(width: 800, height: 600))
        XCTAssertEqual(seen.count, 2)
    }

    func testDeinitClosesOpenSession() {
        let fake = FakeEditorBackend()
        var s: VST3EditorSession? = makeSession(fake)
        s?.open(parentHandle: 1)
        s = nil
        XCTAssertEqual(Array(fake.calls.suffix(2)), ["destroyView", "dispose"])
    }

    // MARK: ABI 固定・既定実装

    func testEditorABIConstants() {
        XCTAssertEqual(VST3BridgeOpcode.createEditorView.rawValue, 10)
        XCTAssertEqual(VST3BridgeOpcode.getEditorSize.rawValue, 11)
        XCTAssertEqual(VST3BridgeOpcode.setEditorSize.rawValue, 12)
        XCTAssertEqual(VST3BridgeOpcode.destroyEditorView.rawValue, 13)
        XCTAssertEqual(VST3BridgeOpcode.setEditorResizeCallback.rawValue, 14)
        XCTAssertEqual(VST3BridgeStatus.noEditor.rawValue, 7)
        XCTAssertTrue(VST3BridgeStatus.noEditor.shouldBypass)
        XCTAssertEqual(VST3CABI.editorSizeSize, 8)
        XCTAssertEqual(VST3CABI.editorSizeWidthOffset, 0)
        XCTAssertEqual(VST3CABI.editorSizeHeightOffset, 4)
    }

    func testEditorSessionStateRules() {
        XCTAssertFalse(VST3BridgeSession.allows(.createEditorView, in: .opened))
        XCTAssertTrue(VST3BridgeSession.allows(.createEditorView, in: .created))
        XCTAssertTrue(VST3BridgeSession.allows(.setEditorSize, in: .active))
        XCTAssertFalse(VST3BridgeSession.allows(.destroyEditorView, in: .closed))
        XCTAssertTrue(VST3BridgeSession.allows(.destroyEditorView, in: .opened))
        XCTAssertEqual(VST3BridgeSession.stateAfter(.getEditorSize, in: .configured), .configured)
    }

    func testDefaultImplementationsAreNotImplemented() {
        let b = UnavailableVST3BridgeBackend()
        XCTAssertEqual(b.createEditorView(parentHandle: 1).status, .notImplemented)
        XCTAssertEqual(b.getEditorSize().status, .notImplemented)
        XCTAssertEqual(b.setEditorSize(VST3EditorSize(width: 1, height: 1)), .notImplemented)
        XCTAssertEqual(b.destroyEditorView(), .notImplemented)
        XCTAssertEqual(b.setEditorResizeCallback(nil), .notImplemented)
        XCTAssertFalse(VST3EditorSize(width: 0, height: 5).isValid)
        XCTAssertTrue(VST3EditorSize(width: 1, height: 5).isValid)
    }

    func testEditorAvailabilityNoteIsHonest() {
        let a = VST3HostAvailability.processingNotImplemented
        XCTAssertTrue(a.hasEditorFoundation)
        XCTAssertFalse(a.editorDisplayVerified)
        XCTAssertTrue(a.editorUserFacingNote.contains("土台"))
        XCTAssertTrue(a.editorUserFacingNote.contains("未実施"))
    }
}

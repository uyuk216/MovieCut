import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - C ABI レイアウト(W6-1: docs/vst3-bridge/MovieCutVST3Bridge.h と対応)
//
// Swift 構造体をそのまま C 構造体として渡さない(レイアウト保証が無いため)。
// 代わりにバイトバッファへ決め打ちのオフセットで読み書きする。オフセットの正は
// C++ 側の static_assert(MovieCutVST3Bridge.cpp)が固定し、ここの定数と一致させる。

public enum VST3CABI {
    public static let setupSize = 32
    public static let setupSampleRateOffset = 8
    public static let setupMaxSamplesOffset = 16
    public static let setupInputSpeakersOffset = 20
    public static let setupOutputSpeakersOffset = 24

    public static let parameterInfoSize = 56
    public static let parameterInfoIDOffset = 0
    public static let parameterInfoTitleOffset = 8
    public static let parameterInfoShortTitleOffset = 16
    public static let parameterInfoUnitsOffset = 24
    public static let parameterInfoStepCountOffset = 32
    public static let parameterInfoDefaultOffset = 40
    public static let parameterInfoFlagsOffset = 48

    public static let parameterChangeSize = 16
    public static let parameterChangeIDOffset = 0
    public static let parameterChangeSampleOffsetOffset = 4
    public static let parameterChangeValueOffset = 8

    public static let processRequestSize = 48
    public static let processRequestNumSamplesOffset = 0
    public static let processRequestInputsOffset = 8
    public static let processRequestOutputsOffset = 16
    public static let processRequestChangesOffset = 24
    public static let processRequestChangeCountOffset = 32
    public static let processRequestLatencyOffset = 40

    public static let classInfoSize = 72
    public static let classInfoCategoryOffset = 0
    public static let classInfoNameOffset = 8
    public static let classInfoVendorOffset = 16
    public static let classInfoVersionOffset = 24
    public static let classInfoCIDHexOffset = 32

    /// MCVST3EditorSize(R5 キュー3)。
    public static let editorSizeSize = 8
    public static let editorSizeWidthOffset = 0
    public static let editorSizeHeightOffset = 4

    /// スピーカー配置 → C ABI の `MCVST3SpeakerArrangement` 値(チャンネル数で表す)。
    public static func speakerValue(_ arrangement: VST3SpeakerArrangement) -> Int32 {
        Int32(arrangement.channelCount)
    }
    /// 処理モード → C ABI の processingMode(0=realtime, 1=prefetch, 2=offline)。
    public static func processingModeValue(_ mode: VST3ProcessingMode) -> Int32 {
        switch mode { case .realtime: return 0; case .prefetch: return 1; case .offline: return 2 }
    }
}

// MARK: - ブリッジライブラリの探索とロード

/// C++ ブリッジ共有ライブラリの実行時ロード。アプリ本体にはリンクしない:
/// 見つかってハンドシェイクが通ったときだけ VST3 の実処理が有効になり、
/// それ以外は従来どおりバイパスになる(安全境界はここで守る)。
public enum VST3BridgeRuntime {
    #if os(Linux)
    public static let libraryFileName = "libMovieCutVST3Bridge.so"
    #else
    public static let libraryFileName = "libMovieCutVST3Bridge.dylib"
    #endif
    /// 明示指定用の環境変数名。
    public static let environmentKey = "MOVIECUT_VST3_BRIDGE_LIBRARY"

    /// 探索候補(先に見つかったものを使う)。純粋関数としてテスト可能にしておく。
    public static func candidatePaths(environment: [String: String],
                                      frameworksPath: String?,
                                      executableDirectory: String?) -> [String] {
        var out: [String] = []
        if let explicit = environment[environmentKey], !explicit.isEmpty { out.append(explicit) }
        if let frameworksPath, !frameworksPath.isEmpty {
            out.append((frameworksPath as NSString).appendingPathComponent(libraryFileName))
        }
        if let executableDirectory, !executableDirectory.isEmpty {
            out.append((executableDirectory as NSString).appendingPathComponent(libraryFileName))
        }
        // 注: 名前だけの候補(dlopen の標準探索任せ)は入れない。意図しない場所のライブラリを読み込まないため。
        // 注: /usr/local/lib のような共有の置き場は候補に入れない。開発機に置いた
        // ブリッジが、テスト実行時の到達状態まで変えてしまうのを防ぐため。
        // 開発時に使いたい場合は環境変数で明示指定する。
        return out
    }

    /// このプロセスで使うライブラリ(探索は 1 回だけ。結果はキャッシュする)。
    public static let shared: VST3BridgeLibrary? = loadFirstAvailable()

    /// ブリッジが使えるか(ライブラリがあり、版数が一致したか)。
    public static var isAvailable: Bool { shared != nil }

    private static func loadFirstAvailable() -> VST3BridgeLibrary? {
        let env = ProcessInfo.processInfo.environment
        let frameworks = Bundle.main.privateFrameworksPath
        let exeDir = Bundle.main.executablePath.map { ($0 as NSString).deletingLastPathComponent }
        for path in candidatePaths(environment: env, frameworksPath: frameworks, executableDirectory: exeDir) {
            if let lib = VST3BridgeLibrary(loadFrom: path) { return lib }
        }
        return nil
    }
}

/// ロード済みブリッジライブラリと関数ポインタ一式。
public final class VST3BridgeLibrary {
    public let path: String
    /// ハンドシェイクで確認したプロトコル版数。
    public let protocolVersion: Int32
    private let handle: UnsafeMutableRawPointer

    typealias StatusFn1 = @convention(c) (UnsafeMutableRawPointer?) -> Int32
    typealias HandshakeFn = @convention(c) (UnsafeMutablePointer<Int32>) -> Int32
    typealias OpenFn = @convention(c) (UnsafePointer<CChar>, UnsafeMutablePointer<UnsafeMutableRawPointer?>) -> Int32
    typealias CreateFn = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Int32
    typealias SetupFn = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt8>) -> Int32
    typealias SetActiveFn = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Int32
    typealias ProcessFn = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt8>) -> Int32
    typealias CountFn = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<Int32>) -> Int32
    typealias InfoFn = @convention(c) (UnsafeMutableRawPointer?, Int32, UnsafeMutablePointer<UInt8>) -> Int32
    typealias GetParamFn = @convention(c) (UnsafeMutableRawPointer?, UInt32, UnsafeMutablePointer<Double>) -> Int32
    typealias SetParamFn = @convention(c) (UnsafeMutableRawPointer?, UInt32, Double) -> Int32
    typealias GetStateFn = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<UInt8>?, UnsafeMutablePointer<Int32>) -> Int32
    typealias SetStateFn = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt8>, Int32) -> Int32
    typealias DisposeFn = @convention(c) (UnsafeMutableRawPointer?) -> Void
    /// リサイズ要求コールバックの C 型(1 = 受理, 0 = 拒否)。
    public typealias EditorResizeCallbackC = @convention(c) (UnsafeMutableRawPointer?, Int32, Int32) -> Int32
    typealias CreateEditorFn = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int32
    typealias EditorSizeFn = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Int32
    typealias DestroyEditorFn = @convention(c) (UnsafeMutableRawPointer?) -> Int32
    typealias SetEditorCallbackFn = @convention(c) (UnsafeMutableRawPointer?, EditorResizeCallbackC?, UnsafeMutableRawPointer?) -> Int32

    let handshakeFn: HandshakeFn
    let openFn: OpenFn
    let createFn: CreateFn
    let setupFn: SetupFn
    let setActiveFn: SetActiveFn
    let processFn: ProcessFn
    let paramCountFn: CountFn
    let paramInfoFn: InfoFn
    let classCountFn: CountFn
    let classInfoFn: InfoFn
    let getParamFn: GetParamFn
    let setParamFn: SetParamFn
    let latencyFn: CountFn
    let tailFn: CountFn
    let getStateFn: GetStateFn
    let setStateFn: SetStateFn
    let disposeFn: DisposeFn
    // エディタ系は任意(旧ブリッジとの互換): 見つからなければ nil で、エディタ操作だけ .notImplemented。
    let createEditorFn: CreateEditorFn?
    let getEditorSizeFn: EditorSizeFn?
    let setEditorSizeFn: EditorSizeFn?
    let destroyEditorFn: DestroyEditorFn?
    let setEditorCallbackFn: SetEditorCallbackFn?

    init?(loadFrom path: String) {
        guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else { return nil }
        func sym<T>(_ name: String, as type: T.Type) -> T? {
            guard let p = dlsym(handle, name) else { return nil }
            return unsafeBitCast(p, to: T.self)
        }
        guard let handshake = sym("mcvst3_handshake", as: HandshakeFn.self),
              let open = sym("mcvst3_open_bundle", as: OpenFn.self),
              let create = sym("mcvst3_create_processor", as: CreateFn.self),
              let setup = sym("mcvst3_setup_processing", as: SetupFn.self),
              let setActive = sym("mcvst3_set_active", as: SetActiveFn.self),
              let process = sym("mcvst3_process_block", as: ProcessFn.self),
              let paramCount = sym("mcvst3_get_parameter_count", as: CountFn.self),
              let paramInfo = sym("mcvst3_get_parameter_info", as: InfoFn.self),
              let classCount = sym("mcvst3_get_class_count", as: CountFn.self),
              let classInfo = sym("mcvst3_get_class_info", as: InfoFn.self),
              let getParam = sym("mcvst3_get_parameter_normalized", as: GetParamFn.self),
              let setParam = sym("mcvst3_set_parameter_normalized", as: SetParamFn.self),
              let latency = sym("mcvst3_get_latency_samples", as: CountFn.self),
              let tail = sym("mcvst3_get_tail_samples", as: CountFn.self),
              let getState = sym("mcvst3_get_state", as: GetStateFn.self),
              let setState = sym("mcvst3_set_state", as: SetStateFn.self),
              let dispose = sym("mcvst3_dispose", as: DisposeFn.self)
        else { dlclose(handle); return nil }
        var version: Int32 = 0
        guard handshake(&version) == VST3BridgeStatus.ok.rawValue, version == VST3Bridge.protocolVersion else {
            dlclose(handle); return nil
        }
        self.path = path
        self.handle = handle
        self.protocolVersion = version
        self.handshakeFn = handshake; self.openFn = open; self.createFn = create
        self.setupFn = setup; self.setActiveFn = setActive; self.processFn = process
        self.paramCountFn = paramCount; self.paramInfoFn = paramInfo
        self.classCountFn = classCount; self.classInfoFn = classInfo
        self.getParamFn = getParam; self.setParamFn = setParam
        self.latencyFn = latency; self.tailFn = tail
        self.getStateFn = getState; self.setStateFn = setState; self.disposeFn = dispose
        self.createEditorFn = sym("mcvst3_create_editor_view", as: CreateEditorFn.self)
        self.getEditorSizeFn = sym("mcvst3_get_editor_size", as: EditorSizeFn.self)
        self.setEditorSizeFn = sym("mcvst3_set_editor_size", as: EditorSizeFn.self)
        self.destroyEditorFn = sym("mcvst3_destroy_editor_view", as: DestroyEditorFn.self)
        self.setEditorCallbackFn = sym("mcvst3_set_editor_resize_callback", as: SetEditorCallbackFn.self)
    }
}

// MARK: - バイトバッファの読み書き(レイアウトは VST3CABI が正)

private func store<T>(_ base: UnsafeMutableRawPointer, _ offset: Int, _ value: T) {
    base.storeBytes(of: value, toByteOffset: offset, as: T.self)
}
private func loadInt32(_ base: UnsafeRawPointer, _ offset: Int) -> Int32 {
    base.load(fromByteOffset: offset, as: Int32.self)
}
private func loadUInt32(_ base: UnsafeRawPointer, _ offset: Int) -> UInt32 {
    base.load(fromByteOffset: offset, as: UInt32.self)
}
private func loadDouble(_ base: UnsafeRawPointer, _ offset: Int) -> Double {
    base.load(fromByteOffset: offset, as: Double.self)
}
private func loadCString(_ base: UnsafeRawPointer, _ offset: Int) -> String? {
    let addr = base.load(fromByteOffset: offset, as: Int.self)
    guard addr != 0, let p = UnsafePointer<CChar>(bitPattern: addr) else { return nil }
    return String(cString: p)
}
private func status(_ raw: Int32) -> VST3BridgeStatus { VST3BridgeStatus(rawValue: raw) ?? .internalError }

/// リサイズ要求の C コールバック(ファイルスコープ。context はバックエンドの unretained ポインタ)。
/// クロージャが無ければ拒否(0)。
private let editorResizeTrampoline: VST3BridgeLibrary.EditorResizeCallbackC = { context, width, height in
    guard let context else { return 0 }
    let backend = Unmanaged<VST3NativeBridgeBackend>.fromOpaque(context).takeUnretainedValue()
    guard let handler = backend.editorResizeHandler else { return 0 }
    return handler(VST3EditorSize(width: width, height: height)) ? 1 : 0
}

// MARK: - ネイティブバックエンド

/// dlopen した C++ ブリッジを直接呼ぶバックエンド。
/// ライブラリが無い環境では `init?` が nil を返し、呼び出し側はバイパスに落とす。
public final class VST3NativeBridgeBackend: VST3BridgeBackend {
    private let library: VST3BridgeLibrary
    private var instance: UnsafeMutableRawPointer?
    /// プラグイン→ホストのリサイズ要求クロージャ(C コールバックから参照される)。
    fileprivate var editorResizeHandler: ((VST3EditorSize) -> Bool)?

    public init?() {
        guard let lib = VST3BridgeRuntime.shared else { return nil }
        self.library = lib
    }

    public func handshake() -> (status: VST3BridgeStatus, version: Int32?) {
        var v: Int32 = 0
        let s = status(library.handshakeFn(&v))
        return (s, s == .ok ? v : nil)
    }

    public func openBundle(path: String) -> VST3BridgeStatus {
        guard instance == nil else { return .wrongState }
        var out: UnsafeMutableRawPointer?
        let s = path.withCString { status(library.openFn($0, &out)) }
        if s == .ok { instance = out }
        return s
    }

    public func classInfos() -> (status: VST3BridgeStatus, infos: [VST3BridgeClassInfo]) {
        guard let instance else { return (.wrongState, []) }
        var count: Int32 = 0
        let cs = status(library.classCountFn(instance, &count))
        guard cs == .ok else { return (cs, []) }
        var infos: [VST3BridgeClassInfo] = []
        for i in 0..<count {
            var buf = [UInt8](repeating: 0, count: VST3CABI.classInfoSize)
            let s = buf.withUnsafeMutableBytes { raw in status(library.classInfoFn(instance, i, raw.baseAddress!.assumingMemoryBound(to: UInt8.self))) }
            guard s == .ok else { return (s, infos) }
            let parsed: VST3BridgeClassInfo? = buf.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return nil }
                // cidHex は固定バッファ(ポインタではない)
                var cidBytes: [UInt8] = []
                for k in 0..<(VST3CABI.classInfoSize - VST3CABI.classInfoCIDHexOffset) {
                    let b = base.load(fromByteOffset: VST3CABI.classInfoCIDHexOffset + k, as: UInt8.self)
                    if b == 0 { break }
                    cidBytes.append(b)
                }
                return VST3BridgeClassInfo(category: loadCString(base, VST3CABI.classInfoCategoryOffset) ?? "",
                                           name: loadCString(base, VST3CABI.classInfoNameOffset) ?? "",
                                           vendor: loadCString(base, VST3CABI.classInfoVendorOffset),
                                           version: loadCString(base, VST3CABI.classInfoVersionOffset),
                                           cidHex: String(decoding: cidBytes, as: UTF8.self))
            }
            if let parsed { infos.append(parsed) }
        }
        return (.ok, infos)
    }

    public func createProcessor(cid: String?) -> VST3BridgeStatus {
        guard let instance else { return .wrongState }
        if let cid, !cid.isEmpty {
            return cid.withCString { status(library.createFn(instance, $0)) }
        }
        return status(library.createFn(instance, nil))
    }

    public func setupProcessing(_ setup: VST3ProcessSetup, layout: VST3BusLayout) -> VST3BridgeStatus {
        guard let instance else { return .wrongState }
        var buf = [UInt8](repeating: 0, count: VST3CABI.setupSize)
        return buf.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return .internalError }
            store(base, 0, VST3CABI.processingModeValue(setup.mode))
            store(base, VST3CABI.setupSampleRateOffset, setup.sampleRate)
            store(base, VST3CABI.setupMaxSamplesOffset, Int32(setup.maxSamplesPerBlock))
            store(base, VST3CABI.setupInputSpeakersOffset, VST3CABI.speakerValue(layout.input))
            store(base, VST3CABI.setupOutputSpeakersOffset, VST3CABI.speakerValue(layout.output))
            return status(library.setupFn(instance, base.assumingMemoryBound(to: UInt8.self)))
        }
    }

    public func setActive(_ active: Bool) -> VST3BridgeStatus {
        guard let instance else { return .wrongState }
        return status(library.setActiveFn(instance, active ? 1 : 0))
    }

    public func processBlock(inputLeft: UnsafePointer<Float>, inputRight: UnsafePointer<Float>,
                             outputLeft: UnsafeMutablePointer<Float>, outputRight: UnsafeMutablePointer<Float>,
                             frames: Int, changes: [VST3ParameterChangePoint]) -> (status: VST3BridgeStatus, latency: Int?) {
        guard let instance else { return (.wrongState, nil) }
        var inPtrs: [UnsafeMutablePointer<Float>?] = [UnsafeMutablePointer(mutating: inputLeft), UnsafeMutablePointer(mutating: inputRight)]
        var outPtrs: [UnsafeMutablePointer<Float>?] = [outputLeft, outputRight]
        var changeBuf = [UInt8](repeating: 0, count: VST3CABI.parameterChangeSize * changes.count)
        for (i, ch) in changes.enumerated() {
            changeBuf.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress else { return }
                let off = i * VST3CABI.parameterChangeSize
                store(base, off + VST3CABI.parameterChangeIDOffset, ch.parameterID)
                store(base, off + VST3CABI.parameterChangeSampleOffsetOffset, Int32(ch.sampleOffset))
                store(base, off + VST3CABI.parameterChangeValueOffset, ch.normalizedValue)
            }
        }
        let latencyPtr = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        latencyPtr.initialize(to: -1)
        defer { latencyPtr.deinitialize(count: 1); latencyPtr.deallocate() }
        let result: Int32 = inPtrs.withUnsafeMutableBufferPointer { inBuf in
            outPtrs.withUnsafeMutableBufferPointer { outBuf in
                changeBuf.withUnsafeMutableBytes { changeRaw in
                    var req = [UInt8](repeating: 0, count: VST3CABI.processRequestSize)
                    return req.withUnsafeMutableBytes { raw -> Int32 in
                        guard let base = raw.baseAddress else { return VST3BridgeStatus.internalError.rawValue }
                        store(base, VST3CABI.processRequestNumSamplesOffset, Int32(frames))
                        store(base, VST3CABI.processRequestInputsOffset, UnsafeMutableRawPointer(inBuf.baseAddress!))
                        store(base, VST3CABI.processRequestOutputsOffset, UnsafeMutableRawPointer(outBuf.baseAddress!))
                        if let cb = changeRaw.baseAddress, !changes.isEmpty {
                            store(base, VST3CABI.processRequestChangesOffset, UnsafeMutableRawPointer(mutating: cb))
                        }
                        store(base, VST3CABI.processRequestChangeCountOffset, Int32(changes.count))
                        store(base, VST3CABI.processRequestLatencyOffset, UnsafeMutableRawPointer(latencyPtr))
                        return library.processFn(instance, base.assumingMemoryBound(to: UInt8.self))
                    }
                }
            }
        }
        let s = status(result)
        let latency = latencyPtr.pointee
        return (s, s == .ok && latency >= 0 ? Int(latency) : nil)
    }

    public func parameterInfos() -> (status: VST3BridgeStatus, infos: [VST3ParameterDescriptor]) {
        guard let instance else { return (.wrongState, []) }
        var count: Int32 = 0
        let cs = status(library.paramCountFn(instance, &count))
        guard cs == .ok else { return (cs, []) }
        var out: [VST3ParameterDescriptor] = []
        for i in 0..<count {
            var buf = [UInt8](repeating: 0, count: VST3CABI.parameterInfoSize)
            let s = buf.withUnsafeMutableBytes { raw in status(library.paramInfoFn(instance, i, raw.baseAddress!.assumingMemoryBound(to: UInt8.self))) }
            guard s == .ok else { return (s, out) }
            let parsed: VST3ParameterDescriptor? = buf.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return nil }
                return VST3ParameterDescriptor(id: loadUInt32(base, VST3CABI.parameterInfoIDOffset),
                                               title: loadCString(base, VST3CABI.parameterInfoTitleOffset) ?? "",
                                               shortTitle: loadCString(base, VST3CABI.parameterInfoShortTitleOffset),
                                               units: loadCString(base, VST3CABI.parameterInfoUnitsOffset),
                                               stepCount: Int(loadInt32(base, VST3CABI.parameterInfoStepCountOffset)),
                                               defaultNormalizedValue: loadDouble(base, VST3CABI.parameterInfoDefaultOffset),
                                               flags: VST3ParameterDescriptor.Flags(rawValue: Int(loadInt32(base, VST3CABI.parameterInfoFlagsOffset))))
            }
            if let parsed { out.append(parsed) }
        }
        return (.ok, out)
    }

    public func getParameterNormalized(id: UInt32) -> (status: VST3BridgeStatus, value: Double?) {
        guard let instance else { return (.wrongState, nil) }
        var v: Double = 0
        let s = status(library.getParamFn(instance, id, &v))
        return (s, s == .ok ? v : nil)
    }

    public func setParameterNormalized(id: UInt32, value: Double) -> VST3BridgeStatus {
        guard let instance else { return .wrongState }
        return status(library.setParamFn(instance, id, value))
    }

    public func latencyAndTail() -> (latency: Int, tail: Int)? {
        guard let instance else { return nil }
        var latency: Int32 = 0, tail: Int32 = 0
        guard status(library.latencyFn(instance, &latency)) == .ok,
              status(library.tailFn(instance, &tail)) == .ok else { return nil }
        return (Int(latency), Int(tail))
    }

    public func getState() -> (status: VST3BridgeStatus, data: Data?) {
        guard let instance else { return (.wrongState, nil) }
        var length: Int32 = 0
        // 2 段階: まず長さを取り(バッファ不足は resultFalse + 必要長)、次に本体を取る
        let query = status(library.getStateFn(instance, nil, &length))
        guard query == .resultFalse, length > 0 else { return (query == .ok ? .ok : query, nil) }
        var buf = [UInt8](repeating: 0, count: Int(length))
        let s = buf.withUnsafeMutableBytes { raw in status(library.getStateFn(instance, raw.baseAddress!.assumingMemoryBound(to: UInt8.self), &length)) }
        guard s == .ok else { return (s, nil) }
        return (.ok, Data(buf.prefix(Int(length))))
    }

    public func setState(_ data: Data) -> VST3BridgeStatus {
        guard let instance else { return .wrongState }
        return data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return .invalidArgument }
            return status(library.setStateFn(instance, base.assumingMemoryBound(to: UInt8.self), Int32(data.count)))
        }
    }

    public func dispose() {
        // 解放後にコールバックが呼ばれないよう、先に C 側の登録を外す
        detachEditorCallback()
        if let instance { library.disposeFn(instance) }
        instance = nil
    }

    // MARK: エディタ(R5 キュー3)

    /// UInt64 ↔ ポインタ(0 は nil)。
    private func pointer(from handle: UInt64) -> UnsafeMutableRawPointer? {
        handle == 0 ? nil : UnsafeMutableRawPointer(bitPattern: UInt(handle))
    }

    /// C 側のコールバック登録を解除し、Swift 側のクロージャも手放す。
    private func detachEditorCallback() {
        if let instance, let fn = library.setEditorCallbackFn { _ = fn(instance, nil, nil) }
        editorResizeHandler = nil
    }

    public func createEditorView(parentHandle: UInt64) -> (status: VST3BridgeStatus, viewHandle: UInt64?) {
        guard let instance else { return (.wrongState, nil) }
        guard let fn = library.createEditorFn else { return (.notImplemented, nil) }
        guard let parent = pointer(from: parentHandle) else { return (.invalidArgument, nil) }
        var out: UnsafeMutableRawPointer?
        let s = status(fn(instance, parent, &out))
        guard s == .ok else { return (s, nil) }
        return (.ok, out.map { UInt64(UInt(bitPattern: $0)) })
    }

    public func getEditorSize() -> (status: VST3BridgeStatus, size: VST3EditorSize?) {
        guard let instance else { return (.wrongState, nil) }
        guard let fn = library.getEditorSizeFn else { return (.notImplemented, nil) }
        var buf = [UInt8](repeating: 0, count: VST3CABI.editorSizeSize)
        let s = buf.withUnsafeMutableBytes { raw in status(fn(instance, raw.baseAddress)) }
        guard s == .ok else { return (s, nil) }
        let size = buf.withUnsafeBytes { raw -> VST3EditorSize in
            let base = raw.baseAddress!
            return VST3EditorSize(width: loadInt32(base, VST3CABI.editorSizeWidthOffset),
                                  height: loadInt32(base, VST3CABI.editorSizeHeightOffset))
        }
        return (.ok, size)
    }

    public func setEditorSize(_ size: VST3EditorSize) -> VST3BridgeStatus {
        guard let instance else { return .wrongState }
        guard let fn = library.setEditorSizeFn else { return .notImplemented }
        var buf = [UInt8](repeating: 0, count: VST3CABI.editorSizeSize)
        return buf.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return .internalError }
            store(base, VST3CABI.editorSizeWidthOffset, size.width)
            store(base, VST3CABI.editorSizeHeightOffset, size.height)
            return status(fn(instance, base))
        }
    }

    public func destroyEditorView() -> VST3BridgeStatus {
        guard let instance else { return .wrongState }
        // C 側の view を畳む前にコールバックを外す(畳み中の resizeView がホストへ戻らないように)
        detachEditorCallback()
        guard let fn = library.destroyEditorFn else { return .notImplemented }
        return status(fn(instance))
    }

    public func setEditorResizeCallback(_ callback: ((VST3EditorSize) -> Bool)?) -> VST3BridgeStatus {
        guard let instance else { return .wrongState }
        guard let fn = library.setEditorCallbackFn else { return .notImplemented }
        if let callback {
            editorResizeHandler = callback
            let ctx = Unmanaged.passUnretained(self).toOpaque()
            let s = status(fn(instance, editorResizeTrampoline, ctx))
            if s != .ok { editorResizeHandler = nil }
            return s
        }
        let s = status(fn(instance, nil, nil))
        editorResizeHandler = nil
        return s
    }
}

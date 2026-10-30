// moviecut-fanhelper: Movie Cut が書き出し中にファンを最大にするための、小さな特権ヘルパー(root の LaunchDaemon)。
//
// SMC(AppleSMC)を読み書きする部分は、ユーザー自身のツール fanctl(/Users/USER/開発/ツール/Macアプリ/ファン制御)の実装をそのまま使っている。
// fanctl との違い:
//   - 127.0.0.1:1201 で待ち受ける(ユーザーの fanctl の :1200 とぶつからない)。設定ファイル・履歴・カーブ・Web 画面は持たない
//   - 見張り(watchdog): ファンが手動の間に heartbeat(または最大の再要求)が 15 秒途切れたら、全ファンを自動に戻す
//   - 終了(SIGTERM / SIGINT)・起動時にも必ず自動に戻す。100 ℃ を超えたらヘルパー自身も自動に戻す
//   - Origin ヘッダのある要求(ブラウザからの要求)と、Host が 127.0.0.1 / localhost 以外の要求は拒否する
//   - --simulate: SMC に触らずメモリ上の疑似ファンで動く(見張りと HTTP の確認用。root 不要)
//
// 使い方: moviecut-fanhelper serve [--port 1201] [--simulate] [--watchdog-seconds 15]
//         moviecut-fanhelper status | auto
import Foundation
import IOKit
import Network

private struct FanctlError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private func fourCC(_ text: String) -> UInt32 {
    let bytes = Array(text.utf8.prefix(4))
    return bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
}

private func fourCCString(_ value: UInt32) -> String {
    let bytes: [UInt8] = [
        UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff),
        UInt8((value >> 8) & 0xff), UInt8(value & 0xff)
    ]
    return String(bytes: bytes, encoding: .ascii) ?? "????"
}

// AppleSMC's user-client structure is an 80-byte ABI. Padding is explicit so
// the layout does not depend on how Swift lays out nested value types.
private struct SMCKeyData {
    var key: UInt32 = 0
    var versionMajor: UInt8 = 0
    var versionMinor: UInt8 = 0
    var versionBuild: UInt8 = 0
    var versionReserved: UInt8 = 0
    var versionRelease: UInt16 = 0
    var versionPadding: UInt16 = 0
    var powerVersion: UInt16 = 0
    var powerLength: UInt16 = 0
    var cpuPowerLimit: UInt32 = 0
    var gpuPowerLimit: UInt32 = 0
    var memoryPowerLimit: UInt32 = 0
    var infoDataSize: UInt32 = 0
    var infoDataType: UInt32 = 0
    var infoAttributes: UInt8 = 0
    var infoPadding0: UInt8 = 0
    var infoPadding1: UInt8 = 0
    var infoPadding2: UInt8 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var commandPadding: UInt8 = 0
    var data32: UInt32 = 0
    var payload0: UInt64 = 0
    var payload1: UInt64 = 0
    var payload2: UInt64 = 0
    var payload3: UInt64 = 0
}

private struct SMCKeyInfo {
    let size: Int
    let type: UInt32
    let attributes: UInt8
    var typeName: String { fourCCString(type) }

    var diagnostic: String {
        "dataType=\(typeName) (0x\(String(format: "%08x", type))), size=\(size) bytes"
    }
}

private struct SMCWritePayload {
    let info: SMCKeyInfo
    let bytes: [UInt8]

    var byteDescription: String {
        bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
    }
}

private struct SMCValue {
    let key: String
    let info: SMCKeyInfo
    let bytes: [UInt8]

    var number: Double? {
        let raw = bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        switch info.typeName {
        case "flt ":
            guard bytes.count == 4 else { return nil }
            let beBits = UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
            let leBits = UInt32(bytes[3]) << 24 | UInt32(bytes[2]) << 16 | UInt32(bytes[1]) << 8 | UInt32(bytes[0])
            let candidates = [Double(Float(bitPattern: leBits)), Double(Float(bitPattern: beBits))]
                .filter { $0.isFinite }
            guard let first = candidates.first else { return nil }
            // Apple Silicon's SMC flt payloads are commonly native little-endian;
            // byte-reversed interpretations are usually subnormal values.
            return candidates.max(by: { abs($0) < abs($1) }) ?? first
        case "sp78":
            guard bytes.count >= 2 else { return nil }
            let signed = Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
            return Double(signed) / 256.0
        case "fpe2":
            guard bytes.count >= 2 else { return nil }
            let value = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
            return Double(value) / 4.0
        case "ui8 ": return bytes.first.map(Double.init)
        case "si8 ": return bytes.first.map { Double(Int8(bitPattern: $0)) }
        case "ui16": return bytes.count >= 2 ? Double(UInt16(raw & 0xffff)) : nil
        case "si16": return bytes.count >= 2 ? Double(Int16(bitPattern: UInt16(raw & 0xffff))) : nil
        case "ui32": return bytes.count >= 4 ? Double(UInt32(raw & 0xffff_ffff)) : nil
        case "si32": return bytes.count >= 4 ? Double(Int32(bitPattern: UInt32(raw & 0xffff_ffff))) : nil
        default: return nil
        }
    }
}

private final class SMCClient {
    private var connection: io_connect_t = 0
    private var indexedKeys: [String]?
    private var fanModeKeys: [Int: String] = [:]

    init() {
        precondition(MemoryLayout<SMCKeyData>.size == 80, "Unexpected AppleSMC structure size")
        precondition(MemoryLayout<SMCKeyData>.offset(of: \.infoDataSize) == 28)
        precondition(MemoryLayout<SMCKeyData>.offset(of: \.result) == 40)
        precondition(MemoryLayout<SMCKeyData>.offset(of: \.data32) == 44)
        precondition(MemoryLayout<SMCKeyData>.offset(of: \.payload0) == 48)
    }

    deinit {
        if connection != 0 { IOServiceClose(connection) }
    }

    private func ensureConnection() throws {
        guard connection == 0 else { return }
        let matching = IOServiceMatching("AppleSMC")
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != IO_OBJECT_NULL else {
            throw FanctlError("AppleSMC サービスが見つかりません。対応する Mac と macOS で実行してください。")
        }
        var opened: io_connect_t = 0
        let result = IOServiceOpen(service, mach_task_self_, 0, &opened)
        IOObjectRelease(service)
        guard result == KERN_SUCCESS else {
            let code = String(format: "0x%08x", UInt32(bitPattern: result))
            let hint = result == kIOReturnNotPermitted ? " (kIOReturnNotPermitted。root 権限の LaunchDaemon で実行してください)" : ""
            throw FanctlError("AppleSMC の接続に失敗しました: IOServiceOpen \(code)\(hint)")
        }
        connection = opened
    }

    private func request(key: String, command: UInt8) -> SMCKeyData {
        var value = SMCKeyData()
        value.key = fourCC(key)
        value.data8 = command
        return value
    }

    private func call(_ inputValue: inout SMCKeyData) throws -> SMCKeyData {
        try ensureConnection()
        var input = inputValue
        var output = SMCKeyData()
        var outputSize = MemoryLayout<SMCKeyData>.size
        let result = withUnsafePointer(to: &input) { inputPointer in
            withUnsafeMutablePointer(to: &output) { outputPointer in
                IOConnectCallStructMethod(
                    connection,
                    2,
                    UnsafeRawPointer(inputPointer),
                    MemoryLayout<SMCKeyData>.size,
                    UnsafeMutableRawPointer(outputPointer),
                    &outputSize
                )
            }
        }
        guard result == KERN_SUCCESS else {
            let code = String(format: "0x%08x", UInt32(bitPattern: result))
            let hint = result == kIOReturnNotPermitted ? " (kIOReturnNotPermitted)" : ""
            throw FanctlError("AppleSMC 呼び出しに失敗しました: \(code)\(hint)")
        }
        guard outputSize == MemoryLayout<SMCKeyData>.size else {
            throw FanctlError("AppleSMC が予期しない応答サイズ \(outputSize) bytes を返しました。")
        }
        guard output.result == 0 else {
            throw FanctlError("SMC コマンドが失敗しました (result=0x\(String(format: "%02x", output.result)), key=\(fourCCString(input.key)))")
        }
        return output
    }

    private func keyInfo(_ key: String) throws -> SMCKeyInfo {
        var input = request(key: key, command: 9)
        let output = try call(&input)
        let size = Int(output.infoDataSize)
        let info = SMCKeyInfo(size: size, type: output.infoDataType, attributes: output.infoAttributes)
        guard size > 0 && size <= 32 else {
            throw FanctlError("SMC キー \(key) のデータサイズは扱えません (\(info.diagnostic), writeBytes=<unavailable>)。")
        }
        return info
    }

    private func bytes(of value: inout SMCKeyData, count: Int) -> [UInt8] {
        withUnsafeBytes(of: &value) { buffer in
            guard count > 0 && count <= 32 else { return [] }
            return Array(buffer[48..<(48 + count)])
        }
    }

    func read(_ key: String) throws -> SMCValue {
        let info = try keyInfo(key)
        var input = request(key: key, command: 5)
        input.infoDataSize = UInt32(info.size)
        input.infoDataType = info.type
        let output = try call(&input)
        var copy = output
        return SMCValue(key: key, info: info, bytes: bytes(of: &copy, count: info.size))
    }

    func keyExists(_ key: String) -> Bool {
        (try? keyInfo(key)) != nil
    }

    private func orderedBytes(_ value: UInt64, size: Int) throws -> [UInt8] {
        guard size >= 1 && size <= 8 else { throw FanctlError("書き込みサイズ (size) bytes は扱えません。") }
        return (0..<size).map { shift in UInt8((value >> (UInt64(size - shift - 1) * 8)) & 0xff) }
    }

    private func write(_ key: String, info: SMCKeyInfo, bytes data: [UInt8]) throws {
        guard data.count == info.size else {
            throw FanctlError("SMC キー \(key) は \(info.size) bytes を要求しますが、\(data.count) bytes を指定しました。")
        }
        var input = request(key: key, command: 6)
        input.infoDataSize = UInt32(info.size)
        input.infoDataType = info.type
        withUnsafeMutableBytes(of: &input) { buffer in
            for (offset, byte) in data.enumerated() { buffer[48 + offset] = byte }
        }
        _ = try call(&input)
    }

    private func write(_ key: String, bytes data: [UInt8]) throws {
        let info = try keyInfo(key)
        try write(key, info: info, bytes: data)
    }

    private func writeInteger(_ key: String, value: UInt64) throws {
        let info = try keyInfo(key)
        try write(key, bytes: orderedBytes(value, size: info.size))
    }

    func setFtst(_ value: UInt64) throws {
        try writeInteger("Ftst", value: value)
        guard let readBack = try read("Ftst").number, readBack == Double(value) else {
            throw FanctlError("Ftst=\(value) を読み戻せませんでした。")
        }
    }

    private func rpmWritePayload(_ key: String, rpm: Double) throws -> SMCWritePayload {
        // Read the key's actual dataType and size before encoding. The same info
        // is then used for the SMC write header so the payload cannot disagree
        // with a separately re-read type.
        let info = try keyInfo(key)
        guard rpm.isFinite, rpm >= 0 else {
            throw FanctlError("RPM 書込みを準備できません (key=\(key), \(info.diagnostic), writeBytes=<none>; RPM 値が有限の非負数ではありません)。")
        }
        let data: [UInt8]
        switch info.typeName {
        case "flt ":
            guard info.size == 4 else {
                throw FanctlError("RPM 書込みを準備できません (key=\(key), \(info.diagnostic), writeBytes=<none>)。")
            }
            let bits = Float(rpm).bitPattern
            // Apple Silicon exposes fan targets as little-endian IEEE-754 flt.
            data = [UInt8(bits & 0xff), UInt8((bits >> 8) & 0xff), UInt8((bits >> 16) & 0xff), UInt8((bits >> 24) & 0xff)]
        case "fpe2":
            guard info.size == 2 else {
                throw FanctlError("RPM 書込みを準備できません (key=\(key), \(info.diagnostic), writeBytes=<none>; fpe2 は2 bytesが必要です)。")
            }
            let raw = UInt16(max(0, min(Double(UInt16.max), rpm * 4)).rounded())
            data = [UInt8(raw >> 8), UInt8(raw & 0xff)]
        case "ui8 ", "ui16", "ui32", "si8 ", "si16", "si32":
            let expectedSize: Int
            let maximum: Double
            switch info.typeName {
            case "ui8 ": expectedSize = 1; maximum = Double(UInt8.max)
            case "si8 ": expectedSize = 1; maximum = Double(Int8.max)
            case "ui16": expectedSize = 2; maximum = Double(UInt16.max)
            case "si16": expectedSize = 2; maximum = Double(Int16.max)
            case "ui32": expectedSize = 4; maximum = Double(UInt32.max)
            default: expectedSize = 4; maximum = Double(Int32.max)
            }
            guard info.size == expectedSize, rpm.isFinite, rpm >= 0, rpm <= maximum else {
                throw FanctlError("RPM 書込みを準備できません (key=\(key), \(info.diagnostic), writeBytes=<none>; 値またはサイズが \(info.typeName) の範囲外です)。")
            }
            let raw = UInt64(rpm.rounded())
            // Signed two's-complement and unsigned integers have the same
            // big-endian representation for nonnegative values.
            data = try orderedBytes(raw, size: info.size)
        default:
            throw FanctlError("RPM 書込みを準備できません (key=\(key), \(info.diagnostic), writeBytes=<none>; この型は未対応です)。")
        }
        return SMCWritePayload(info: info, bytes: data)
    }

    private func writeRPM(_ key: String, payload: SMCWritePayload) throws {
        do {
            try write(key, info: payload.info, bytes: payload.bytes)
        } catch {
            throw FanctlError("RPM 書込み失敗 (key=\(key), \(payload.info.diagnostic), writeBytes=[\(payload.byteDescription)]): \(error.localizedDescription)")
        }
    }

    private func readUInt(_ key: String) throws -> UInt64 {
        let value = try read(key)
        guard let number = value.number, number.isFinite, number >= 0, number <= 20_000 else {
            throw FanctlError("SMC キー (key) (\(value.info.typeName)) を数値として読めません。")
        }
        return UInt64(number.rounded())
    }

    func readFans() throws -> [FanReading] {
        let count = Int(try readUInt("FNum"))
        guard count > 0 && count <= 32 else {
            throw FanctlError("FNum が不正です: \(count)")
        }
        return try (0..<count).map { index in try readFan(index) }
    }

    private func readFan(_ index: Int) throws -> FanReading {
        let prefix = "F\(index)"
        func rpm(_ suffix: String) throws -> Double {
            let key = prefix + suffix
            guard let value = try read(key).number, value.isFinite, value >= 0, value <= 50_000 else {
                throw FanctlError("SMC キー \(key) の RPM 値が不正です。")
            }
            return value
        }
        let actual = try rpm("Ac")
        let minimum = try rpm("Mn")
        let maximum = try rpm("Mx")
        let target = try rpm("Tg")
        guard maximum >= minimum else { throw FanctlError("ファン \(index) の最小/最大 RPM が逆転しています。") }
        let modeKey = fanModeKey(index)
        guard let modeKey else { throw FanctlError("ファン \(index) のモードキー F\(index)Md / F\(index)md がありません。") }
        let modeNumber = try read(modeKey).number
        guard let modeNumber, modeNumber.isFinite, modeNumber >= 0, modeNumber <= 255 else {
            throw FanctlError("ファン \(index) のモード値を読み取れません。")
        }
        let rawMode = Int(modeNumber)
        let mode: String
        switch rawMode {
        case 0: mode = "auto"
        case 1: mode = "manual"
        case 3: mode = "system"
        default: mode = "unknown"
        }
        return FanReading(index: index, actualRPM: actual, minimumRPM: minimum, maximumRPM: maximum,
                          targetRPM: target, mode: mode, rawMode: rawMode, modeKey: modeKey)
    }

    private func fanModeKey(_ index: Int) -> String? {
        if let cached = fanModeKeys[index] { return cached }
        let upper = "F\(index)Md"
        let lower = "F\(index)md"
        if keyExists(upper) { fanModeKeys[index] = upper; return upper }
        if keyExists(lower) { fanModeKeys[index] = lower; return lower }
        return nil
    }

    func setAuto(_ index: Int) throws {
        guard let fan = try readFans().first(where: { $0.index == index }), let key = fan.modeKey else {
            throw FanctlError("ファン \(index) のモードキー F\(index)Md / F\(index)md がありません。")
        }
        if fan.mode == "auto" { return }
        if fan.mode == "system" { return }
        try writeInteger(key, value: 0)
        let readBack = try read(key).number
        guard readBack == 0 || readBack == 3 else {
            throw FanctlError("ファン \(index) を自動モードにできませんでした (mode=\(readBack.map(String.init(describing:)) ?? "?")).")
        }
    }

    func setAllAuto() throws {
        let fans = try readFans()
        var failures: [String] = []
        for fan in fans where !isNonManualMode(fan.mode) {
            do { try setAuto(fan.index) }
            catch { failures.append("fan \(fan.index): \(error.localizedDescription)") }
        }
        if !failures.isEmpty { throw FanctlError("自動モードへ戻せませんでした: \(failures.joined(separator: "; "))") }
        let finalFans = try readFans()
        let unsafeModes = finalFans.filter { !isNonManualMode($0.mode) }
        guard unsafeModes.isEmpty else {
            throw FanctlError("自動復帰後も手動/不明モードのファンがあります: \(unsafeModes.map { "fan \($0.index)=\($0.mode)" }.joined(separator: ", "))")
        }
        if keyExists("Ftst") { try setFtst(0) }
    }

    func setManual(_ fan: FanReading, rpm: Double) throws {
        guard let minimum = fan.minimumRPM, let maximum = fan.maximumRPM, minimum.isFinite, maximum.isFinite, maximum >= minimum else {
            throw FanctlError("ファン \(fan.index) の Mn/Mx を読み取れず、安全な RPM 範囲を確認できません。")
        }
        guard let modeKey = fan.modeKey ?? fanModeKey(fan.index) else {
            throw FanctlError("ファン \(fan.index) のモードキーが見つかりません。")
        }
        let clamped = min(max(rpm, minimum), maximum)
        do {
            if isAppleSilicon && keyExists("Ftst") {
                try setFtst(1)
                guard let startingMode = try read(modeKey).number else {
                    throw FanctlError("ファン \(fan.index) のモードを Ftst 解放後に読み取れません。")
                }
                if startingMode != 1 {
                    let deadline = DispatchTime.now().uptimeNanoseconds + 6_000_000_000
                    var enteredAuto = startingMode == 0
                    var lastObservedMode = startingMode
                    while !enteredAuto && DispatchTime.now().uptimeNanoseconds < deadline {
                        Thread.sleep(forTimeInterval: 0.1)
                        guard let mode = try read(modeKey).number else { continue }
                        lastObservedMode = mode
                        enteredAuto = mode == 0
                    }
                    guard enteredAuto else {
                        throw FanctlError("Ftst=1 後 6 秒以内にファン \(fan.index) が自動モードへ移行しませんでした (mode=\(lastObservedMode))。")
                    }
                }
            }
            try writeInteger(modeKey, value: 1)
            let targetKey = "F\(fan.index)Tg"
            let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
            let payload = try rpmWritePayload(targetKey, rpm: clamped)
            var lastMode: Double?
            var lastTarget: Double?
            var lastReadInfo: SMCKeyInfo?
            var lastPollError: String?
            var wroteTarget = false
            var succeeded = false

            while DispatchTime.now().uptimeNanoseconds < deadline {
                do {
                    guard let mode = try read(modeKey).number, mode.isFinite else {
                        throw FanctlError("ファン \(fan.index) のモードを読み取れません。")
                    }
                    lastMode = mode
                    if mode != 1 {
                        try writeInteger(modeKey, value: 1)
                    }

                    guard DispatchTime.now().uptimeNanoseconds < deadline else { break }
                    wroteTarget = true
                    try writeRPM(targetKey, payload: payload)

                    let targetValue = try read(targetKey)
                    lastReadInfo = targetValue.info
                    lastTarget = targetValue.number

                    guard let modeAfterWrite = try read(modeKey).number, modeAfterWrite.isFinite else {
                        throw FanctlError("ファン \(fan.index) の書込み後モードを読み取れません。")
                    }
                    lastMode = modeAfterWrite
                    if modeAfterWrite != 1 {
                        try writeInteger(modeKey, value: 1)
                    } else if let readBackTarget = targetValue.number,
                              readBackTarget.isFinite,
                              abs(readBackTarget - clamped) < max(2, clamped * 0.03) {
                        succeeded = true
                        break
                    }
                } catch {
                    lastPollError = error.localizedDescription
                }

                let now = DispatchTime.now().uptimeNanoseconds
                guard now < deadline else { break }
                let remaining = deadline - now
                Thread.sleep(forTimeInterval: Double(min(remaining, 250_000_000)) / 1_000_000_000)
            }

            guard succeeded else {
                let modeDescription = lastMode.map(String.init(describing:)) ?? "?"
                let targetDescription = lastTarget.map(String.init(describing:)) ?? "?"
                let writtenBytes = wroteTarget ? "[\(payload.byteDescription)]" : "<not-written>"
                let readInfoDescription = lastReadInfo.map { "; readBack \($0.diagnostic)" } ?? ""
                let pollErrorDescription = lastPollError.map { "; lastError=\($0)" } ?? ""
                throw FanctlError("ファン \(fan.index) の手動 RPM を読み戻せませんでした (mode=\(modeDescription), target=\(targetDescription), requested=\(Int(clamped)); key=\(targetKey), \(payload.info.diagnostic), writeBytes=\(writtenBytes)\(readInfoDescription)\(pollErrorDescription))。")
            }
        } catch {
            let reason = error.localizedDescription
            var resetError: String?
            do {
                try setAuto(fan.index)
                let remainingFans = try readFans()
                if remainingFans.allSatisfy({ isNonManualMode($0.mode) }), keyExists("Ftst") {
                    try setFtst(0)
                }
            } catch { resetError = error.localizedDescription }
            if let resetError {
                throw FanctlError("ファン \(fan.index) の手動設定に失敗しました: \(reason)。自動復帰にも失敗しました: \(resetError)")
            }
            throw FanctlError("ファン \(fan.index) の手動設定に失敗しました: \(reason)。自動モードへ戻しました。")
        }
    }

    func readSensors() throws -> [TemperatureSensor] {
        let keys = try allKeys()
        var sensors: [TemperatureSensor] = []
        for key in keys where key.hasPrefix("T") {
            guard let value = try? read(key), value.info.typeName == "flt " || value.info.typeName == "sp78",
                  let number = value.number, number >= 0, number <= 130, number.isFinite else { continue }
            sensors.append(TemperatureSensor(key: key, name: sensorName(key), celsius: number, type: value.info.typeName))
        }
        return sensors.sorted { $0.key < $1.key }
    }

    private func allKeys() throws -> [String] {
        if let indexedKeys { return indexedKeys }
        let count = Int(try readUInt("#KEY"))
        guard count > 0 && count < 20_000 else { throw FanctlError("#KEY の値が不正です: \(count)") }
        var keys: [String] = []
        keys.reserveCapacity(count)
        for index in 0..<count {
            var input = request(key: "\0\0\0\0", command: 8)
            input.data32 = UInt32(index)
            let output = try call(&input)
            let name = fourCCString(output.key)
            guard name.utf8.count == 4 else { throw FanctlError("SMC キー index \(index) の名前を解釈できません。") }
            keys.append(name)
        }
        indexedKeys = keys
        return keys
    }

    private var isAppleSilicon: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }
}

private struct FanReading {
    let index: Int
    let actualRPM: Double?
    let minimumRPM: Double?
    let maximumRPM: Double?
    let targetRPM: Double?
    let mode: String
    let rawMode: Int?
    let modeKey: String?

    var json: [String: Any] {
        var result: [String: Any] = ["index": index, "mode": mode]
        if let actualRPM { result["actualRPM"] = actualRPM }
        if let minimumRPM { result["minimumRPM"] = minimumRPM }
        if let maximumRPM { result["maximumRPM"] = maximumRPM }
        if let targetRPM { result["targetRPM"] = targetRPM }
        if let rawMode { result["rawMode"] = rawMode }
        if let modeKey { result["modeKey"] = modeKey }
        return result
    }
}

private struct TemperatureSensor {
    let key: String
    let name: String
    let celsius: Double
    let type: String
    var json: [String: Any] { ["key": key, "name": name, "celsius": celsius, "type": type] }
}

private func sensorName(_ key: String) -> String {
    let names: [String: String] = [
        "TC0P": "CPU 近接", "TC0E": "CPU コア", "TC0F": "CPU 温度",
        "TCGC": "CPU/GPU 周辺", "TCGD": "GPU ダイ", "TG0P": "GPU 近接",
        "TG0D": "GPU ダイ", "TCPU": "CPU 温度", "TGPU": "GPU 温度",
        "TB0T": "バッテリー", "TH0x": "筐体", "Ts0P": "パームレスト"
    ]
    return names[key] ?? key
}

private func isNonManualMode(_ mode: String) -> Bool {
    mode == "auto" || mode == "system"
}

// ===================== ここから Movie Cut ファンヘルパー本体 =====================

private protocol FanHardware: AnyObject {
    func readFans() throws -> [FanReading]
    func readSensors() throws -> [TemperatureSensor]
    func setManual(_ fan: FanReading, rpm: Double) throws
    func setAllAuto() throws
}

extension SMCClient: FanHardware {}

/// --simulate 用。SMC に一切触れない。
private final class SimulatedHardware: FanHardware {
    private let lock = NSLock()
    private var manual = false
    private var target = 2500.0
    var temperature: Double
    init(temperature: Double) { self.temperature = temperature }
    func readFans() throws -> [FanReading] {
        lock.lock(); defer { lock.unlock() }
        return [FanReading(index: 0, actualRPM: target, minimumRPM: 2317, maximumRPM: 6550, targetRPM: target,
                           mode: manual ? "manual" : "auto", rawMode: manual ? 1 : 0, modeKey: "F0md")]
    }
    func readSensors() throws -> [TemperatureSensor] {
        [TemperatureSensor(key: "Tp01", name: "Tp01", celsius: temperature, type: "flt ")]
    }
    func setManual(_ fan: FanReading, rpm: Double) throws { lock.lock(); manual = true; target = rpm; lock.unlock() }
    func setAllAuto() throws { lock.lock(); manual = false; target = 2500; lock.unlock() }
}

private let coreSensorPrefixes = ["Tp", "Te", "Tg", "Ts", "TC", "TG"]
private let hardTemperatureLimit = 100.0

private final class HelperController {
    private let lock = NSRecursiveLock()
    private let hardware: FanHardware
    private let watchdogSeconds: TimeInterval
    private var manual = false
    private var lastBeat = Date()
    private var sensors: [TemperatureSensor] = []
    private var tick = 0
    private var timer: DispatchSourceTimer?
    private var shuttingDown = false
    let simulated: Bool

    init(hardware: FanHardware, watchdogSeconds: TimeInterval, simulated: Bool) {
        self.hardware = hardware; self.watchdogSeconds = watchdogSeconds; self.simulated = simulated
    }

    /// 起動時: 前の実行(クラッシュなど)が手動のまま残していても、まず自動に戻す。
    func start() {
        lock.lock(); defer { lock.unlock() }
        do { try hardware.setAllAuto() } catch { NSLog("[moviecut-fanhelper] startup auto reset failed: %@", error.localizedDescription) }
        sensors = (try? hardware.readSensors()) ?? []
        let source = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "moviecut.fanhelper.watchdog"))
        source.schedule(deadline: .now() + 1, repeating: .seconds(1), leeway: .milliseconds(100))
        source.setEventHandler { [weak self] in self?.watchdogTick() }
        timer = source
        source.resume()
    }

    private var hottestCore: Double? {
        sensors.filter { s in coreSensorPrefixes.contains { s.key.hasPrefix($0) } }.map(\.celsius).max()
    }

    private func watchdogTick() {
        lock.lock(); defer { lock.unlock() }
        guard !shuttingDown else { return }
        tick += 1
        if tick % 2 == 0, let s = try? hardware.readSensors() { sensors = s }
        guard manual else { return }
        if Date().timeIntervalSince(lastBeat) > watchdogSeconds {
            NSLog("[moviecut-fanhelper] watchdog: no heartbeat for %.0fs; returning fans to automatic", watchdogSeconds)
            releaseToAuto()
        } else if let t = hottestCore, t >= hardTemperatureLimit {
            NSLog("[moviecut-fanhelper] %.1f C >= %.0f C; returning fans to automatic", t, hardTemperatureLimit)
            releaseToAuto()
        }
    }

    @discardableResult
    private func releaseToAuto() -> Bool {
        do { try hardware.setAllAuto(); manual = false; return true }
        catch { NSLog("[moviecut-fanhelper] auto reset failed (will retry): %@", error.localizedDescription); return false }
    }

    func status() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        var obj: [String: Any] = ["ok": true, "helper": "moviecut-fanhelper", "simulated": simulated,
                                  "watchdogSeconds": watchdogSeconds, "manualRequested": manual]
        do { obj["fans"] = try hardware.readFans().map { $0.json }; obj["available"] = true }
        catch { obj["fans"] = [[String: Any]](); obj["available"] = false; obj["error"] = error.localizedDescription }
        obj["sensors"] = sensors.map { $0.json }
        return obj
    }

    func heartbeat() -> [String: Any] {
        lock.lock()
        if manual { lastBeat = Date() }
        lock.unlock()
        return status()
    }

    func setAll(_ body: [String: Any]) throws {
        lock.lock(); defer { lock.unlock() }
        guard !shuttingDown else { throw FanctlError("ヘルパーは停止中です。") }
        let mode = (body["mode"] as? String ?? "auto").lowercased()
        switch mode {
        case "auto":
            try hardware.setAllAuto()
            manual = false
        case "fixedpercent", "percent", "fixedrpm", "rpm":
            if let t = hottestCore, t >= hardTemperatureLimit { throw FanctlError("温度が高すぎるため(\(Int(t)) ℃)ファンを手動にしません。") }
            let fans = try hardware.readFans()
            guard !fans.isEmpty else { throw FanctlError("ファンがありません。") }
            do {
                for fan in fans {
                    guard let minimum = fan.minimumRPM, let maximum = fan.maximumRPM else { throw FanctlError("ファン \(fan.index) の最小/最大 RPM を読めません。") }
                    let desired: Double
                    if mode.contains("percent") {
                        guard let p = (body["percent"] as? NSNumber)?.doubleValue, p.isFinite else { throw FanctlError("percent を数値で指定してください。") }
                        desired = minimum + (maximum - minimum) * min(100, max(0, p)) / 100
                    } else {
                        guard let r = (body["rpm"] as? NSNumber)?.doubleValue, r.isFinite else { throw FanctlError("rpm を数値で指定してください。") }
                        desired = r
                    }
                    try hardware.setManual(fan, rpm: min(maximum, max(minimum, desired)))
                }
            } catch {
                _ = releaseToAuto()          // 一部だけ手動のまま残さない
                throw error
            }
            manual = true
            lastBeat = Date()
        default:
            throw FanctlError("未対応のモードです: \(mode)")
        }
    }

    @discardableResult
    func shutdown() -> Bool {
        lock.lock(); defer { lock.unlock() }
        shuttingDown = true
        timer?.cancel(); timer = nil
        for attempt in 1...3 {
            if releaseToAuto() { return true }
            if attempt < 3 { Thread.sleep(forTimeInterval: 0.25 * Double(attempt)) }
        }
        return false
    }
}

private struct HTTPRequest {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data
}

private final class HelperServer {
    private let controller: HelperController
    private let listener: NWListener
    private let queue = DispatchQueue(label: "moviecut.fanhelper.http")

    init(controller: HelperController, port: UInt16) throws {
        self.controller = controller
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host("127.0.0.1"), port: NWEndpoint.Port(rawValue: port)!)
        listener = try NWListener(using: parameters)
    }

    func start() {
        listener.stateUpdateHandler = { [controller] state in
            if case .failed(let error) = state {
                NSLog("[moviecut-fanhelper] listener failed; returning fans to automatic: %@", error.localizedDescription)
                _ = controller.shutdown()
                exit(EXIT_FAILURE)
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            connection.start(queue: self.queue)
            self.receive(connection, accumulated: Data())
        }
        listener.start(queue: queue)
    }

    func stop() { listener.cancel() }

    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var full = accumulated
            if let data { full.append(data) }
            if let request = self.parse(full) {
                self.send(self.handle(request), on: connection)
            } else if full.count > 200_000 {
                self.send(self.json(413, ["ok": false, "error": "request is too large"]), on: connection)
            } else if complete || error != nil {
                connection.cancel()
            } else {
                self.receive(connection, accumulated: full)
            }
        }
    }

    private func parse(_ data: Data) -> HTTPRequest? {
        guard let marker = data.range(of: Data([13, 10, 13, 10])) else { return nil }
        let lines = String(decoding: data[..<marker.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let first = lines.first?.split(separator: " ") ?? []
        guard first.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if let i = line.firstIndex(of: ":") {
                headers[line[..<i].lowercased()] = line[line.index(after: i)...].trimmingCharacters(in: .whitespaces)
            }
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let body = data[marker.upperBound...]
        guard body.count >= length else { return nil }
        let path = String(first[1]).components(separatedBy: "?")[0]
        return HTTPRequest(method: String(first[0]).uppercased(), path: path, headers: headers, body: Data(body.prefix(length)))
    }

    private func handle(_ request: HTTPRequest) -> (Int, Data) {
        // ブラウザ(Origin 付き)と DNS リバインディング(Host が違う)を拒否する。ネイティブのクライアントは Origin を付けない。
        if request.headers["origin"] != nil { return json(403, ["ok": false, "error": "Origin header is not allowed"]) }
        let host = (request.headers["host"] ?? "").components(separatedBy: ":")[0].lowercased()
        if !host.isEmpty && host != "127.0.0.1" && host != "localhost" { return json(403, ["ok": false, "error": "Host is not allowed"]) }
        switch (request.method, request.path) {
        case ("GET", "/api/status"):
            return json(200, controller.status())
        case ("POST", "/api/heartbeat"):
            return json(200, controller.heartbeat())
        case ("POST", "/api/all"):
            do {
                let body = (try JSONSerialization.jsonObject(with: request.body.isEmpty ? Data("{}".utf8) : request.body)) as? [String: Any] ?? [:]
                try controller.setAll(body)
                return json(200, ["ok": true])
            } catch {
                return json(error.localizedDescription.contains("SMC") ? 503 : 400, ["ok": false, "error": error.localizedDescription])
            }
        default:
            return json(404, ["ok": false, "error": "not found"])
        }
    }

    private func json(_ status: Int, _ object: [String: Any]) -> (Int, Data) {
        (status, (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed])) ?? Data("{}".utf8))
    }

    private func send(_ response: (Int, Data), on connection: NWConnection) {
        let reason = [200: "OK", 400: "Bad Request", 403: "Forbidden", 404: "Not Found", 413: "Payload Too Large", 503: "Service Unavailable"][response.0] ?? "Error"
        var text = "HTTP/1.1 \(response.0) \(reason)\r\nContent-Type: application/json; charset=utf-8\r\n"
        text += "Content-Length: \(response.1.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n"
        var data = Data(text.utf8)
        data.append(response.1)
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }
}

private final class SignalManager {
    private var sources: [DispatchSourceSignal] = []
    func install(_ handler: @escaping () -> Void) {
        for value in [SIGINT, SIGTERM] {
            signal(value, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: value, queue: .main)
            source.setEventHandler(handler: handler)
            source.resume()
            sources.append(source)
        }
    }
}

private func optionValue(_ option: String, in args: [String]) -> String? {
    guard let i = args.firstIndex(of: option), i + 1 < args.count else { return nil }
    return args[i + 1]
}

private let helperUsage = """
使い方:
  moviecut-fanhelper serve [--port 1201] [--simulate] [--sim-temp 50] [--watchdog-seconds 15]
  moviecut-fanhelper status      (root で実行: ファンの状態を表示)
  moviecut-fanhelper auto        (root で実行: 全ファンを自動に戻す)
"""

do {
    let args = Array(CommandLine.arguments.dropFirst())
    guard let command = args.first else { print(helperUsage); exit(EXIT_FAILURE) }
    let simulate = args.contains("--simulate")
    let hardware: FanHardware = simulate
        ? SimulatedHardware(temperature: optionValue("--sim-temp", in: args).flatMap(Double.init) ?? 50)
        : SMCClient()
    switch command {
    case "serve":
        var port: UInt16 = 1201
        if let p = optionValue("--port", in: args) {
            guard let parsed = UInt16(p), parsed > 0 else { throw FanctlError("port は 1〜65535 の整数で指定してください。") }
            port = parsed
        }
        let watchdog = optionValue("--watchdog-seconds", in: args).flatMap(Double.init) ?? 15
        guard watchdog >= 1 else { throw FanctlError("--watchdog-seconds は 1 以上にしてください。") }
        let controller = HelperController(hardware: hardware, watchdogSeconds: watchdog, simulated: simulate)
        let server = try HelperServer(controller: controller, port: port)
        let signals = SignalManager()
        signals.install {
            server.stop()
            let restored = controller.shutdown()
            NSLog(restored ? "[moviecut-fanhelper] stopped; all fans returned to automatic mode" : "[moviecut-fanhelper] stopped, but automatic reset could not be confirmed")
            exit(restored ? EXIT_SUCCESS : EXIT_FAILURE)
        }
        controller.start()
        server.start()
        print("moviecut-fanhelper listening at http://127.0.0.1:\(port)/ (watchdog \(Int(watchdog))s\(simulate ? ", simulated" : ""))")
        fflush(stdout)
        dispatchMain()
    case "status":
        for fan in try hardware.readFans() {
            print("Fan \(fan.index): actual \(fan.actualRPM.map { String(Int($0)) } ?? "?") RPM, target \(fan.targetRPM.map { String(Int($0)) } ?? "?"), mode \(fan.mode)")
        }
    case "auto":
        try hardware.setAllAuto()
        print("全ファンを自動モードにしました。")
    default:
        print(helperUsage); exit(EXIT_FAILURE)
    }
} catch {
    fputs("moviecut-fanhelper: \(error.localizedDescription)\n", stderr)
    exit(EXIT_FAILURE)
}

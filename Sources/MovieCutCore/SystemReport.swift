import Foundation

/// システムレポート(診断情報)。クラッシュ・問題・改善要望のときに利用者が書き出して、
/// Discord の DM などで自分で送るためのもの。サーバへの自動送信はしない。
/// 中身は「環境と設定の要約」「直近のクラッシュレポート」「(任意で)プロジェクトファイル」だけ。
/// ホームディレクトリのパスやプロジェクトの中身そのものは、要約(system-report.txt)には含めない。

/// レポートに書く環境情報。テストでは値を差し替えられる。
public struct SystemReportEnvironment: Equatable, Sendable {
    public var appName: String
    public var appVersion: String
    public var appBuild: String
    public var bundleIdentifier: String
    public var edition: String
    public var osVersion: String
    public var machineModel: String
    public var cpuBrand: String
    public var physicalMemoryBytes: UInt64
    public var architecture: String
    public var generatedAt: Date

    public init(appName: String, appVersion: String, appBuild: String, bundleIdentifier: String,
                edition: String, osVersion: String, machineModel: String, cpuBrand: String,
                physicalMemoryBytes: UInt64, architecture: String, generatedAt: Date) {
        self.appName = appName
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.bundleIdentifier = bundleIdentifier
        self.edition = edition
        self.osVersion = osVersion
        self.machineModel = machineModel
        self.cpuBrand = cpuBrand
        self.physicalMemoryBytes = physicalMemoryBytes
        self.architecture = architecture
        self.generatedAt = generatedAt
    }

    /// 動いている環境から集める。アプリの版数まわりは Info.plist 由来の値を呼び出し側が渡す。
    public static func current(appName: String, appVersion: String, appBuild: String,
                               bundleIdentifier: String, edition: String,
                               generatedAt: Date = Date()) -> SystemReportEnvironment {
        let pi = ProcessInfo.processInfo
        return SystemReportEnvironment(
            appName: appName, appVersion: appVersion, appBuild: appBuild,
            bundleIdentifier: bundleIdentifier, edition: edition,
            osVersion: pi.operatingSystemVersionString,
            machineModel: sysctlString("hw.model") ?? "不明",
            cpuBrand: sysctlString("machdep.cpu.brand_string") ?? "不明",
            physicalMemoryBytes: pi.physicalMemory,
            architecture: architectureName,
            generatedAt: generatedAt)
    }

    private static var architectureName: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "不明"
        #endif
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }
}

/// 設定の要約の 1 行。呼び出し側が、個人情報を含まない項目だけを選んで渡す。
public struct SystemReportSetting: Equatable, Sendable {
    public var key: String
    public var value: String
    public init(key: String, value: String) { self.key = key; self.value = value }
}

/// レポート生成の条件。テストでは置き場や上限を差し替えられる。
public struct SystemReportOptions: Sendable {
    /// クラッシュレポートの置き場(通常は ~/Library/Logs/DiagnosticReports)。
    public var diagnosticReportsDirectory: URL
    /// 同梱するクラッシュレポートの最大件数(新しい順)。
    public var maxCrashReports: Int
    /// クラッシュレポート 1 件の最大バイト数(超えたら先頭だけを収録する)。
    public var maxCrashReportBytes: Int
    /// 同梱するプロジェクトファイル(ファイルでもパッケージでもよい)。nil なら同梱しない。
    public var projectFileURL: URL?
    /// 設定の要約。
    public var settings: [SystemReportSetting]

    public init(diagnosticReportsDirectory: URL = SystemReportOptions.systemDiagnosticReportsDirectory,
                maxCrashReports: Int = 5,
                maxCrashReportBytes: Int = 512 * 1024,
                projectFileURL: URL? = nil,
                settings: [SystemReportSetting] = []) {
        self.diagnosticReportsDirectory = diagnosticReportsDirectory
        self.maxCrashReports = maxCrashReports
        self.maxCrashReportBytes = maxCrashReportBytes
        self.projectFileURL = projectFileURL
        self.settings = settings
    }

    /// macOS 標準の診断レポート置き場。
    public static var systemDiagnosticReportsDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/DiagnosticReports", isDirectory: true)
    }
}

/// システムレポートの組み立てと zip 化。
public enum SystemReportBuilder {
    public struct CrashReport: Equatable {
        public var fileName: String
        public var modifiedAt: Date
        public var data: Data
        /// 上限を超えたため先頭だけに切り詰めた。
        public var truncated: Bool

        public init(fileName: String, modifiedAt: Date, data: Data, truncated: Bool) {
            self.fileName = fileName
            self.modifiedAt = modifiedAt
            self.data = data
            self.truncated = truncated
        }
    }

    public enum Failure: Error, LocalizedError {
        case zipFailed(String)
        public var errorDescription: String? {
            switch self {
            case .zipFailed(let detail):
                return "zip の作成に失敗しました。\(detail)"
            }
        }
    }

    /// このアプリのクラッシュレポートかどうか(ファイル名で判断する)。
    public static func isAppCrashReport(fileName: String) -> Bool {
        let lower = fileName.lowercased()
        guard lower.hasSuffix(".ips") || lower.hasSuffix(".crash") else { return false }
        return lower.contains("moviecut") || lower.contains("movie cut")
    }

    /// 診断レポート置き場から、このアプリのクラッシュレポートを新しい順に集める。
    public static func collectCrashReports(directory: URL, limit: Int = 5, maxBytes: Int = 512 * 1024,
                                           fileManager: FileManager = .default) -> [CrashReport] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return [] }
        var found: [(name: String, url: URL, modified: Date)] = []
        for name in names where isAppCrashReport(fileName: name) {
            let url = directory.appendingPathComponent(name)
            guard let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  vals.isRegularFile == true else { continue }
            found.append((name, url, vals.contentModificationDate ?? .distantPast))
        }
        found.sort { $0.modified > $1.modified }
        return found.prefix(limit).compactMap { item in
            guard let data = try? Data(contentsOf: item.url) else { return nil }
            if data.count > maxBytes {
                return CrashReport(fileName: item.name, modifiedAt: item.modified,
                                   data: Data(data.prefix(maxBytes)), truncated: true)
            }
            return CrashReport(fileName: item.name, modifiedAt: item.modified, data: data, truncated: false)
        }
    }

    /// レポート本文(system-report.txt の中身)。
    public static func summaryText(environment e: SystemReportEnvironment,
                                   settings: [SystemReportSetting],
                                   crashReports: [CrashReport],
                                   projectFileName: String?) -> String {
        var lines: [String] = []
        lines.append("Movie Cut システムレポート")
        lines.append("生成日時: \(ISO8601DateFormatter().string(from: e.generatedAt))")
        lines.append("")
        lines.append("■ アプリ")
        lines.append("名前: \(e.appName)")
        lines.append("バージョン: \(e.appVersion) (ビルド \(e.appBuild))")
        lines.append("バンドル ID: \(e.bundleIdentifier)")
        lines.append("版: \(e.edition)")
        lines.append("")
        lines.append("■ 環境")
        lines.append("OS: \(e.osVersion)")
        lines.append("機種: \(e.machineModel)")
        lines.append("CPU: \(e.cpuBrand)")
        lines.append("メモリ: \(ByteCountFormatter.string(fromByteCount: Int64(e.physicalMemoryBytes), countStyle: .memory))")
        lines.append("アーキテクチャ: \(e.architecture)")
        if !settings.isEmpty {
            lines.append("")
            lines.append("■ 設定の要約")
            for s in settings { lines.append("\(s.key): \(s.value)") }
        }
        lines.append("")
        lines.append("■ 同梱ファイル")
        lines.append("system-report.txt — このファイル")
        if crashReports.isEmpty {
            lines.append("クラッシュレポート — 直近のものはありませんでした")
        } else {
            for c in crashReports {
                let size = ByteCountFormatter.string(fromByteCount: Int64(c.data.count), countStyle: .file)
                lines.append("crash-reports/\(c.fileName) — \(size)\(c.truncated ? "(先頭だけを収録)" : "")")
            }
        }
        if let p = projectFileName {
            lines.append("project/\(p) — 利用者が同梱を選んだプロジェクトファイル")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// staging フォルダへ中身を書く。戻り値は置いたファイルの相対パス一覧。
    @discardableResult
    public static func writeStaging(environment: SystemReportEnvironment, options: SystemReportOptions,
                                    to staging: URL, fileManager: FileManager = .default) throws -> [String] {
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        let crashes = collectCrashReports(directory: options.diagnosticReportsDirectory,
                                          limit: options.maxCrashReports,
                                          maxBytes: options.maxCrashReportBytes,
                                          fileManager: fileManager)
        var placed: [String] = ["system-report.txt"]
        var projectName: String? = nil
        if let src = options.projectFileURL {
            let dir = staging.appendingPathComponent("project", isDirectory: true)
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            try fileManager.copyItem(at: src, to: dir.appendingPathComponent(src.lastPathComponent))
            projectName = src.lastPathComponent
            placed.append("project/\(src.lastPathComponent)")
        }
        if !crashes.isEmpty {
            let dir = staging.appendingPathComponent("crash-reports", isDirectory: true)
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            for c in crashes {
                try c.data.write(to: dir.appendingPathComponent(c.fileName))
                placed.append("crash-reports/\(c.fileName)")
            }
        }
        let text = summaryText(environment: environment, settings: options.settings,
                               crashReports: crashes, projectFileName: projectName)
        try Data(text.utf8).write(to: staging.appendingPathComponent("system-report.txt"))
        return placed
    }

    /// staging の中身を zip にする(release.sh と同じ ditto の流儀。中身がルートに並ぶ形)。
    public static func makeZip(staging: URL, destination: URL, fileManager: FileManager = .default) throws {
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", staging.path, destination.path]
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw Failure.zipFailed(detail.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// 一時フォルダに staging を作って zip 化し、一時フォルダを片付ける。
    public static func generate(environment: SystemReportEnvironment, options: SystemReportOptions,
                                destination: URL, fileManager: FileManager = .default) throws {
        let staging = fileManager.temporaryDirectory
            .appendingPathComponent("MovieCutSystemReport-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: staging) }
        try writeStaging(environment: environment, options: options, to: staging, fileManager: fileManager)
        try makeZip(staging: staging, destination: destination, fileManager: fileManager)
    }
}

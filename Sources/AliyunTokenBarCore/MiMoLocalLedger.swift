import Foundation

// MARK: - 小米 MiMo 本地用量账本(零凭据兜底)
//
// 动机:控制台 Cookie 是 MiMo 用量的**唯一官方来源**,但它会过期、续期也可能失败。
// 而本机跑 MiMo 的 CLI 会把逐条用量写进自己的库里(实测 2026-09-25):
//
//   ~/.local/share/mimocode/mimocode.db   message.data = {providerID:"xiaomi",
//                                                          tokens:{input,output,reasoning,
//                                                                  cache:{read,write}}, cost}
//   ~/.local/share/opencode/opencode.db   同形(opencode 系同源 schema)
//
// 这条链路**零凭据、零网络、永不过期**,适合做"控制台拿不到时的下限估算 + 趋势"。
//
// ⚠️ 口径诚实(2026-09-25 修正):本地账本与控制台数字**不是同一个量,不能互相界定**:
//   • 单位不同:控制台 `used`/`limit` 的量纲是 **Credits**(由 /tokenPlan/list 确证,
//     standard = 110 亿 Credits = 11,000,000,000),而这里统计的是**原始 token**
//     (控制台套餐页文案:1 token = 2 Credits);
//   • 覆盖面不同:这里只覆盖本机 mimocode/opencode 产生的消耗,网页/其他客户端/其他机器看不到
//     (实测控制台月用量约 10 亿 token 量级,本机 4 天仅 52 万 token,差约 2000 倍);
//   • 本地 `total` 不含 cache(实测 cache.read 可达 input 的 7 倍),口径也自成一系。
// 结论:它是"本机 CLI 活动量 + 趋势"指标,**不是**套餐余量的上界或下界,绝不冒充官方百分比。

/// 一行本地用量(已从 SQL 抽出的裸数值)。
public struct MiMoLocalUsageRow: Equatable, Sendable {
    public let timestampMs: Int64
    public let input: Int
    public let output: Int
    public let reasoning: Int
    public let cacheRead: Int
    public let cacheWrite: Int

    public init(timestampMs: Int64, input: Int, output: Int,
                reasoning: Int, cacheRead: Int, cacheWrite: Int) {
        self.timestampMs = timestampMs
        self.input = input
        self.output = output
        self.reasoning = reasoning
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }
}

/// 本地账本快照(落盘 JSON)。
public struct MiMoLocalUsage: Codable, Equatable, Sendable {
    public struct Day: Codable, Equatable, Sendable {
        public let date: String          // yyyy-MM-dd(本地时区)
        public let input: Int
        public let output: Int
        public let reasoning: Int
        public let cacheRead: Int
        public let cacheWrite: Int

        public init(date: String, input: Int, output: Int, reasoning: Int,
                    cacheRead: Int, cacheWrite: Int) {
            self.date = date
            self.input = input
            self.output = output
            self.reasoning = reasoning
            self.cacheRead = cacheRead
            self.cacheWrite = cacheWrite
        }

        /// 计费口径总量(不含 cache;cache 单独展示,避免口径混淆)。
        public var total: Int { input + output + reasoning }
    }

    public var schemaVersion: Int
    public var updatedAt: Date
    /// 按日期升序
    public var days: [Day]

    public init(schemaVersion: Int, updatedAt: Date, days: [Day]) {
        self.schemaVersion = schemaVersion
        self.updatedAt = updatedAt
        self.days = days
    }
}

public enum MiMoLocalLedger {
    /// 官方 provider id(mimocode 的 xiaomi auth 插件与 opencode 的 xiaomi provider 都用它)。
    public static let providerID = "xiaomi"

    /// 采集 SQL。`json_extract` 依赖 SQLite JSON1(macOS 系统 sqlite3 自带)。
    public static func querySQL(sinceMs: Int64) -> String {
        """
        SELECT time_created,
               json_extract(data,'$.tokens.input'),
               json_extract(data,'$.tokens.output'),
               json_extract(data,'$.tokens.reasoning'),
               json_extract(data,'$.tokens.cache.read'),
               json_extract(data,'$.tokens.cache.write')
        FROM message
        WHERE json_extract(data,'$.providerID')='\(providerID)'
          AND time_created >= \(sinceMs)
        """
    }

    /// sqlite3 `-separator '|'` 输出 → 行。畸形行(字段数不足 / 时间戳非数字 / 负值)一律跳过。
    public static func parseRows(_ output: String) -> [MiMoLocalUsageRow] {
        output.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let parts = line.split(separator: "|", omittingEmptySubsequences: false)
            guard parts.count >= 6, let ts = Int64(parts[0].trimmingCharacters(in: .whitespaces)) else {
                return nil
            }
            let nums = parts[1...5].map { field -> Int in
                let raw = field.trimmingCharacters(in: .whitespaces)
                // SQL NULL / 空串 → 0(该字段缺失不应丢弃整行)
                guard let v = Int(raw), v > 0 else { return 0 }
                return v
            }
            return MiMoLocalUsageRow(timestampMs: ts, input: nums[0], output: nums[1],
                                     reasoning: nums[2], cacheRead: nums[3], cacheWrite: nums[4])
        }
    }

    /// 行 → 按天聚合(升序)。分日按传入时区,便于跨时区断言。
    public static func aggregate(_ rows: [MiMoLocalUsageRow],
                                 timeZone: TimeZone = .current) -> [MiMoLocalUsage.Day] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone

        var byDay: [String: MiMoLocalUsage.Day] = [:]
        for row in rows {
            let key = formatter.string(from: Date(timeIntervalSince1970: Double(row.timestampMs) / 1000))
            let existing = byDay[key] ?? MiMoLocalUsage.Day(
                date: key, input: 0, output: 0, reasoning: 0, cacheRead: 0, cacheWrite: 0)
            byDay[key] = MiMoLocalUsage.Day(
                date: key,
                input: existing.input + row.input,
                output: existing.output + row.output,
                reasoning: existing.reasoning + row.reasoning,
                cacheRead: existing.cacheRead + row.cacheRead,
                cacheWrite: existing.cacheWrite + row.cacheWrite)
        }
        return byDay.values.sorted { $0.date < $1.date }
    }

    /// 窗口内合计(不含 cache)。
    public static func totalTokens(in usage: MiMoLocalUsage) -> Int {
        usage.days.reduce(0) { $0 + $1.total }
    }

    /// 指定日期(按传入时区)的合计(不含 cache)。
    public static func todayTokens(in usage: MiMoLocalUsage, now: Date,
                                   timeZone: TimeZone = .current) -> Int {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        let key = formatter.string(from: now)
        return usage.days.first { $0.date == key }?.total ?? 0
    }
}

// MARK: - 落盘(与 DeepSeekDailyStore 同形:IO + 锁,纯逻辑在上方)

public final class MiMoLocalUsageStore: @unchecked Sendable {
    private let url: URL
    private let fileLock = NSLock()
    private var cache: MiMoLocalUsage?

    public static func defaultURL() -> URL {
        let fm = FileManager.default
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        return dir.appendingPathComponent("AliyunTokenBar/mimo-local.json", isDirectory: false)
    }

    public init(url: URL = MiMoLocalUsageStore.defaultURL()) { self.url = url }

    public func load() -> MiMoLocalUsage? {
        fileLock.lock()
        defer { fileLock.unlock() }
        if let cache { return cache }
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(MiMoLocalUsage.self, from: data),
              decoded.schemaVersion == 1 else { return nil }
        cache = decoded
        return cache
    }

    /// 写失败只记日志(下次采集重试,不阻塞展示)。
    public func save(_ usage: MiMoLocalUsage) {
        fileLock.lock()
        defer { fileLock.unlock() }
        cache = usage
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(usage).write(to: url, options: .atomic)
        } catch {
            AppLog.warning("MiMo 本地账本写入失败(不影响展示): \(error.localizedDescription)", category: .mimo)
        }
    }
}

// MARK: - 上次成功快照(控制台不可用时仍可展示,跨重启保留)

/// 最近一次**控制台成功拉取**的快照。与本地账本互补:
/// 本地账本给"本机 CLI 下限",快照给"上次已知的官方口径 + 时间"。
public struct MiMoLastUsage: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var capturedAt: Date
    public var usage: MiMoUsageService.MiMoUsage

    public init(schemaVersion: Int, capturedAt: Date, usage: MiMoUsageService.MiMoUsage) {
        self.schemaVersion = schemaVersion
        self.capturedAt = capturedAt
        self.usage = usage
    }
}

public final class MiMoLastUsageStore: @unchecked Sendable {
    private let url: URL
    private let fileLock = NSLock()
    private var cache: MiMoLastUsage?

    public static func defaultURL() -> URL {
        let fm = FileManager.default
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        return dir.appendingPathComponent("AliyunTokenBar/mimo-last.json", isDirectory: false)
    }

    public init(url: URL = MiMoLastUsageStore.defaultURL()) { self.url = url }

    public func load() -> MiMoLastUsage? {
        fileLock.lock()
        defer { fileLock.unlock() }
        if let cache { return cache }
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(MiMoLastUsage.self, from: data),
              decoded.schemaVersion == 1 else { return nil }
        cache = decoded
        return cache
    }

    public func save(_ snapshot: MiMoLastUsage) {
        fileLock.lock()
        defer { fileLock.unlock() }
        cache = snapshot
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
        } catch {
            AppLog.warning("MiMo 快照写入失败(不影响展示): \(error.localizedDescription)", category: .mimo)
        }
    }
}

// MARK: - 采集(读本机 CLI 库)

public enum MiMoLocalUsageCollector {
    /// 已知客户端库路径(缺失即跳过,不报错)。
    public static func candidateDBPaths(home: String = NSHomeDirectory()) -> [String] {
        [
            "\(home)/.local/share/mimocode/mimocode.db",
            "\(home)/.local/share/opencode/opencode.db",
        ]
    }

    /// 采集最近 `sinceDays` 天并落盘。返回合并后的账本;无可用库/无数据返回 nil。
    /// ⚠️ 只读打开(`-readonly`),避免与正在运行的 CLI 争写锁。
    @discardableResult
    public static func collect(sinceDays: Int = 30, home: String = NSHomeDirectory(),
                               store: MiMoLocalUsageStore = MiMoLocalUsageStore(),
                               now: Date = Date()) -> MiMoLocalUsage? {
        let sinceMs = Int64((now.timeIntervalSince1970 - Double(sinceDays) * 86_400) * 1000)
        var rows: [MiMoLocalUsageRow] = []
        var usedPaths: [String] = []
        for path in candidateDBPaths(home: home) where FileManager.default.fileExists(atPath: path) {
            guard let output = runSQLite(path: path, sinceMs: sinceMs) else { continue }
            let parsed = MiMoLocalLedger.parseRows(output)
            guard !parsed.isEmpty else { continue }
            rows.append(contentsOf: parsed)
            usedPaths.append(path)
        }
        guard !rows.isEmpty else { return nil }
        let usage = MiMoLocalUsage(schemaVersion: 1, updatedAt: now,
                                   days: MiMoLocalLedger.aggregate(rows))
        store.save(usage)
        AppLog.debug("MiMo 本地账本采集:\(usedPaths.count) 个库,\(rows.count) 条,"
                     + "近 \(sinceDays) 天合计 \(MiMoLocalLedger.totalTokens(in: usage)) tok", category: .mimo)
        return usage
    }

    /// 调系统 sqlite3 只读查询。失败返回 nil(采集是尽力而为的兜底路径)。
    static func runSQLite(path: String, sinceMs: Int64) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-readonly", "-noheader", "-separator", "|", path,
                             MiMoLocalLedger.querySQL(sinceMs: sinceMs)]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            AppLog.debug("MiMo 本地账本:sqlite3 启动失败 \(error.localizedDescription)", category: .mimo)
            return nil
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            AppLog.debug("MiMo 本地账本:sqlite3 退出码 \(process.terminationStatus)(库可能被占用)", category: .mimo)
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

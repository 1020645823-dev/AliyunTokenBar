import Foundation

// MARK: - 用量快照(时序持久化)

/// 单次刷新落盘的用量快照(所有窗口聚合成一条)。
/// nil 字段表示该 Provider 当时未配置/拉取失败——历史不应因部分缺失而丢弃整条。
public struct UsageSnapshot: Codable, Equatable {
    public let timestamp: Date
    public let aliyunFiveHour: Int?
    public let aliyunOneWeek: Int?
    public let opencodeRolling: Int?
    public let opencodeWeekly: Int?
    public let opencodeMonthly: Int?
    public let kimiFiveHour: Int?
    public let kimiWeekly: Int?
    public let kimiMonthly: Int?

    public init(timestamp: Date,
                aliyunFiveHour: Int?, aliyunOneWeek: Int?,
                opencodeRolling: Int?, opencodeWeekly: Int?, opencodeMonthly: Int?,
                kimiFiveHour: Int? = nil, kimiWeekly: Int? = nil, kimiMonthly: Int? = nil) {
        self.timestamp = timestamp
        self.aliyunFiveHour = aliyunFiveHour
        self.aliyunOneWeek = aliyunOneWeek
        self.opencodeRolling = opencodeRolling
        self.opencodeWeekly = opencodeWeekly
        self.opencodeMonthly = opencodeMonthly
        self.kimiFiveHour = kimiFiveHour
        self.kimiWeekly = kimiWeekly
        self.kimiMonthly = kimiMonthly
    }
}

/// 历史存储:纯 JSON 落盘(不引入 SwiftData/CoreData,免依赖升级)。
/// 写:append 一条,自动按「同窗口序列最多 N 条」淘汰旧值(环形缓冲语义);
/// 读:返回最近 max 条,供 sparkline / 趋势预测使用。
///
/// 时钟/文件 IO 经协议注入:逻辑(淘汰/截断/预测)可纯内存单测。
public protocol HistoryClock {
    func now() -> Date
}
public struct SystemHistoryClock: HistoryClock {
    public init() {}
    public func now() -> Date { Date() }
}

public protocol HistoryStorageBackend {
    func read() -> [UsageSnapshot]
    func write(_ snapshots: [UsageSnapshot])
    /// 读-改-写互斥段(跨进程)。默认 no-op;文件后端用 flock 实现。
    /// append 的「读全量 → 追加 → 写全量」必须整体持锁,否则双实例交错写会丢快照。
    func withExclusiveLock<T>(_ body: () throws -> T) rethrows -> T
}

public extension HistoryStorageBackend {
    func withExclusiveLock<T>(_ body: () throws -> T) rethrows -> T {
        try body()
    }
}

public final class FileHistoryBackend: HistoryStorageBackend {
    private let url: URL
    public init(url: URL) { self.url = url }

    public func read() -> [UsageSnapshot] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return Self.decode(data)
    }

    /// 兼容解码(P1-D9):JSONL v1(首行 schemaVersion 注释,一行一条快照)优先;
    /// 旧版 JSON 数组(v0)透明读取,下一次 write 自动迁移为 v1。
    public static func decode(_ data: Data) -> [UsageSnapshot] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("[") {
            // v0:JSON 数组
            return (try? dec.decode([UsageSnapshot].self, from: data)) ?? []
        }
        // v1:JSONL,容忍个别损坏行(单行坏不影响整体)
        var out: [UsageSnapshot] = []
        for line in text.split(separator: "\n") {
            let lineStr = String(line).trimmingCharacters(in: .whitespaces)
            guard !lineStr.isEmpty, !lineStr.hasPrefix("//") else { continue }
            if let snap = try? dec.decode(UsageSnapshot.self, from: Data(lineStr.utf8)) {
                out.append(snap)
            }
        }
        return out
    }

    public func write(_ snapshots: [UsageSnapshot]) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            AppLog.error("history 目录创建失败: \(error.localizedDescription)", category: .history)
            return
        }
        // v1 JSONL:首行版本注释,后续每行一条快照——自描述、可增量迁移、单行损坏不影响整体
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        var lines = ["// CodingTokenBar history v1 (JSONL: one snapshot per line)"]
        for s in snapshots {
            if let d = try? enc.encode(s), let line = String(data: d, encoding: .utf8) {
                lines.append(line)
            }
        }
        let out = lines.joined(separator: "\n") + "\n"
        do {
            try out.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            AppLog.error("history 写入失败: \(error.localizedDescription)", category: .history)
        }
    }

    /// flock 互斥:单实例保护之外的跨进程双保险(dev 裸二进制无 bundle id 也可双开)。
    public func withExclusiveLock<T>(_ body: () throws -> T) rethrows -> T {
        let fd = open(url.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else {
            // 打不开文件(极端环境):退化为无锁执行,读改写仍走 atomic
            return try body()
        }
        flock(fd, LOCK_EX)
        defer {
            flock(fd, LOCK_UN)
            close(fd)
        }
        return try body()
    }
}
public final class InMemoryHistoryBackend: HistoryStorageBackend {
    public private(set) var data: [UsageSnapshot]
    public init(_ initial: [UsageSnapshot] = []) { self.data = initial }
    public func read() -> [UsageSnapshot] { data }
    public func write(_ snapshots: [UsageSnapshot]) { data = snapshots }
}

/// 历史仓库。默认保留 7 天、每个 Provider-窗口序列最多 1000 条(约 7 天 × 10 分钟间隔)。
public final class HistoryStore {
    public static let defaultMaxAgeDays = 7
    public static let defaultMaxPerSeries = 1000

    public let backend: HistoryStorageBackend
    public let clock: HistoryClock
    public let maxAgeDays: Int
    public let maxPerSeries: Int

    public init(backend: HistoryStorageBackend, clock: HistoryClock = SystemHistoryClock(),
                maxAgeDays: Int = defaultMaxAgeDays, maxPerSeries: Int = defaultMaxPerSeries) {
        self.backend = backend
        self.clock = clock
        self.maxAgeDays = maxAgeDays
        self.maxPerSeries = maxPerSeries
    }

    /// App Support 子目录下的默认存储路径。
    public static func defaultURL() -> URL {
        let fm = FileManager.default
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        return dir.appendingPathComponent("AliyunTokenBar/history.json", isDirectory: false)
    }

    /// 追加一条快照,并执行淘汰(超期 + 超量)。
    /// 读-改-写全程持互斥锁(文件后端为 flock),双实例/并发下不丢快照。
    public func append(_ snapshot: UsageSnapshot) {
        backend.withExclusiveLock {
            var all = backend.read()
            all.append(snapshot)
            let cutoff = clock.now().addingTimeInterval(-Double(maxAgeDays) * 86_400)
            all.removeAll { $0.timestamp < cutoff }
            if all.count > maxPerSeries {
                all.removeFirst(all.count - maxPerSeries)
            }
            backend.write(all)
        }
    }

    /// 读取最近 max 条(按时间升序),供 sparkline。
    public func recent(_ max: Int) -> [UsageSnapshot] {
        let all = backend.read().sorted { $0.timestamp < $1.timestamp }
        guard all.count > max else { return all }
        return Array(all.suffix(max))
    }

    /// 读取指定时间窗内的快照(升序)。
    public func within(lastHours: Int) -> [UsageSnapshot] {
        let cutoff = clock.now().addingTimeInterval(-Double(lastHours) * 3600)
        return backend.read().filter { $0.timestamp >= cutoff }
            .sorted { $0.timestamp < $1.timestamp }
    }

    // MARK: - 纯函数:序列提取 + 线性预测

    /// 从快照序列提取某窗口的百分比序列(保留 nil,长度 = 输入长度)。
    public static func series(_ snapshots: [UsageSnapshot], provider: String, window: String) -> [Int?] {
        snapshots.map { snap -> Int? in
            switch (provider, window) {
            case ("aliyun", "5h"): return snap.aliyunFiveHour
            case ("aliyun", "7d"): return snap.aliyunOneWeek
            case ("opencode", "rolling"): return snap.opencodeRolling
            case ("opencode", "weekly"): return snap.opencodeWeekly
            case ("opencode", "monthly"): return snap.opencodeMonthly
            case ("kimi", "5h"): return snap.kimiFiveHour
            case ("kimi", "weekly"): return snap.kimiWeekly
            case ("kimi", "monthly"): return snap.kimiMonthly
            default: return nil
            }
        }
    }

    /// 基于近 N 条有效点线性外推「距达 100% 还需多少分钟」。
    /// 用两点间斜率(百分比/小时)推算;数据不足或斜率非正返回 nil。
    /// 结果仅粗略估算(滚动窗口非固定周期),UI 应标注「估算」。
    public static func estimateMinutesToLimit(snapshots: [UsageSnapshot]) -> Int? {
        // 取最近 ≤12 条且非空、且时间严格递增的有效点
        let pts: [(t: Date, pct: Int)] = snapshots.suffix(12).compactMap { snap in
            // 默认按阿里云 7d(最长窗口)估算;调用方按窗口传对应序列更准
            guard let pct = snap.aliyunOneWeek else { return nil }
            return (snap.timestamp, pct)
        }
        guard pts.count >= 2 else { return nil }
        let first = pts.first!, last = pts.last!
        let hours = last.t.timeIntervalSince(first.t) / 3600
        guard hours > 0 else { return nil }
        let deltaPct = Double(last.pct - first.pct)
        guard deltaPct > 0 else { return nil }                 // 速率非正:不会达限
        let remainingPct = Double(100 - last.pct)
        guard remainingPct > 0 else { return 0 }               // 已达/超限 → 0
        return Int((remainingPct / (deltaPct / hours)) * 60)
    }
}

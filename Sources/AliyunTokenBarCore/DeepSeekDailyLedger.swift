import Foundation

// MARK: - DeepSeek 当日费用账本(余额差快照法)
//
// 官方 API 只有余额、没有用量明细。「当日使用费用(0点→now)」用余额差计算:
//   当日费用 = 当日基线余额 − 当前余额
// 基线 = 今日 0 点后第一次成功拉到的余额(应用每天 0 点前后都会刷新,基线≈0点余额)。
// 当天未抓到今日快照时(应用今天刚启动),用最近一天的最后余额作基线并标记 estimated。
// 充值/赠金到账会让余额上涨,费用可能为负 → 记录时把基线重设为新余额(费用归零重计)。
//
// 落盘:~/Library/Application Support/AliyunTokenBar/deepseek-daily.json
// {"schemaVersion":1,"entries":[{"date":"2026-08-13","firstBalance":110,"firstAt":...,"lastBalance":108.5,"lastAt":...}]}
// 只保留最近 32 天;写入走临时文件 + 原子替换,双实例并发以文件锁互斥。

public struct DeepSeekDailyEntry: Codable, Equatable {
    /// 本地时区日期键 "yyyy-MM-dd"(同一天多条刷新只更新同一 entry)
    public var date: String
    /// 当日基线余额(0点后首拉;充值后重设)
    public var firstBalance: Double
    /// 基线采样时间(epoch 秒)
    public var firstAt: TimeInterval
    /// 当日最后一次拉到的余额
    public var lastBalance: Double
    /// 最后采样时间(epoch 秒)
    public var lastAt: TimeInterval

    public init(date: String, firstBalance: Double, firstAt: TimeInterval,
                lastBalance: Double, lastAt: TimeInterval) {
        self.date = date
        self.firstBalance = firstBalance
        self.firstAt = firstAt
        self.lastBalance = lastBalance
        self.lastAt = lastAt
    }
}

/// 当日费用结果。
public struct DeepSeekDailyCost: Equatable {
    /// 当日费用(元,恒 ≥0)
    public let cost: Double
    /// 基线是否估算(基线来自往日余额而非今日快照)
    public let estimated: Bool
    /// 基线采样时间(展示"自 HH:mm 起累计"用;无历史时为 nil)
    public let baselineAt: Date?

    public init(cost: Double, estimated: Bool, baselineAt: Date?) {
        self.cost = cost
        self.estimated = estimated
        self.baselineAt = baselineAt
    }
}

/// 纯函数账本逻辑(时间/日历可注入,Verify 全量覆盖)。
public enum DeepSeekDailyLedger {
    public static let maxDays = 32

    /// Date → 本地日期键 "yyyy-MM-dd"。
    public static func dateKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// 把一次余额采样并入账本(纯函数):
    /// - 今日已有 entry:更新 last;若余额上涨超过 0.001(充值)→ 重设基线(费用归零重计);
    /// - 今日无 entry:追加新 entry(基线 = 首拉余额);
    /// - 淘汰 32 天前的 entry。
    public static func record(entries: [DeepSeekDailyEntry], balance: Double, at: Date,
                              calendar: Calendar = .current) -> [DeepSeekDailyEntry] {
        let key = dateKey(at, calendar: calendar)
        var out = entries
        if let idx = out.firstIndex(where: { $0.date == key }) {
            var e = out[idx]
            // 充值检测:余额显著上涨 → 基线前移,当日费用从新基线重新累计
            if balance > e.firstBalance + 0.001 {
                e.firstBalance = balance
                e.firstAt = at.timeIntervalSince1970
            }
            e.lastBalance = balance
            e.lastAt = at.timeIntervalSince1970
            out[idx] = e
        } else {
            out.append(DeepSeekDailyEntry(date: key,
                                          firstBalance: balance, firstAt: at.timeIntervalSince1970,
                                          lastBalance: balance, lastAt: at.timeIntervalSince1970))
        }
        out.sort { $0.date < $1.date }
        if out.count > maxDays {
            out.removeFirst(out.count - maxDays)
        }
        return out
    }

    /// 计算当日费用(纯函数):
    /// - 有今日 entry → 今日基线 − 当前余额(精确);
    /// - 无今日 entry 但有往日 entry → 最近一天最后余额 − 当前余额,estimated = true;
    /// - 完全无历史 → 0,estimated = true(首拉即基线,费用从此刻起累计)。
    public static func computeCost(entries: [DeepSeekDailyEntry], currentBalance: Double, at: Date,
                                   calendar: Calendar = .current) -> DeepSeekDailyCost {
        let key = dateKey(at, calendar: calendar)
        if let today = entries.first(where: { $0.date == key }) {
            return DeepSeekDailyCost(
                cost: max(0, today.firstBalance - currentBalance),
                estimated: false,
                baselineAt: Date(timeIntervalSince1970: today.firstAt))
        }
        if let prev = entries.last {
            return DeepSeekDailyCost(
                cost: max(0, prev.lastBalance - currentBalance),
                estimated: true,
                baselineAt: Date(timeIntervalSince1970: prev.lastAt))
        }
        return DeepSeekDailyCost(cost: 0, estimated: true, baselineAt: nil)
    }
}

/// 文件落盘实现(纯逻辑在 DeepSeekDailyLedger;这里只做 IO + 锁)。
public final class DeepSeekDailyStore {
    private let url: URL
    private let fileLock: NSLock
    /// 内存缓存,避免每次刷新都读文件(单进程单实例足够;文件为跨重启持久化)
    private var cache: [DeepSeekDailyEntry]?

    public static func defaultURL() -> URL {
        let fm = FileManager.default
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        return dir.appendingPathComponent("AliyunTokenBar/deepseek-daily.json", isDirectory: false)
    }

    public init(url: URL = DeepSeekDailyStore.defaultURL()) {
        self.url = url
        self.fileLock = NSLock()
    }

    public func load() -> [DeepSeekDailyEntry] {
        fileLock.lock()
        defer { fileLock.unlock() }
        if let cache { return cache }
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONDecoder().decode(FileDTO.self, from: data) else {
            cache = []
            return cache ?? []
        }
        cache = root.entries
        return cache ?? []
    }

    /// 记录一次余额采样并返回当日费用。写失败只记日志(下次刷新重试,不阻塞展示)。
    public func record(balance: Double, at: Date) -> DeepSeekDailyCost {
        fileLock.lock()
        defer { fileLock.unlock() }
        var entries = cache ?? []
        entries = DeepSeekDailyLedger.record(entries: entries, balance: balance, at: at)
        cache = entries
        let dto = FileDTO(schemaVersion: 1, entries: entries)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(dto)
            try data.write(to: url, options: .atomic)
        } catch {
            AppLog.warning("DeepSeek 当日账本写入失败(不影响展示): \(error.localizedDescription)", category: .deepseek)
        }
        return DeepSeekDailyLedger.computeCost(entries: entries, currentBalance: balance, at: at)
    }

    private struct FileDTO: Codable {
        var schemaVersion: Int
        var entries: [DeepSeekDailyEntry]
    }
}

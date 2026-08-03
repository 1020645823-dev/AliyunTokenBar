import Foundation

// MARK: - Kimi Code 用量模型(与官方 API 响应结构对齐)

/// Kimi Code 单个用量窗口。
/// 对齐官方语义:limits[0](duration=300) = 5小时窗口,usage = 滚动周窗口,totalQuota = 月度总额。
public struct KimiWindow: Equatable {
    public let used: Int          // 已用 tokens
    public let limit: Int         // 限额 tokens
    public let resetTimeMs: Int64? // 重置时间(ms epoch);API 有时不返回

    public init(used: Int, limit: Int, resetTimeMs: Int64?) {
        self.used = used
        self.limit = limit
        self.resetTimeMs = resetTimeMs
    }

    /// 剩余
    public var remaining: Int { max(0, limit - used) }

    /// 0–100 浮点百分比(2 位小数精度,钳制 0...100)
    public var pct: Double {
        guard limit > 0 else { return 0 }
        let pct = (Double(used) / Double(limit) * 100 * 100).rounded() / 100
        return min(max(pct, 0), 100)
    }

    /// 整数百分比(阈值/通知用)
    public var pctInt: Int { Int(pct.rounded()) }

    /// 完整重置时间:"2026-08-04 14:36:22"(本地时区)
    public var resetTimeDisplay: String {
        guard let resetTimeMs else { return "未知" }
        let reset = Date(timeIntervalSince1970: TimeInterval(resetTimeMs) / 1000)
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return fmt.string(from: reset)
    }

    /// 滑动窗口(5h)重置提示:空窗时 API 返回**上一窗口的过去时间戳**,
    /// 按 timeUntilReset 会误显"即将重置";过去时间戳返回 nil 隐藏倒计时
    /// (2026-08-03 活体验证:remaining==limit 且 resetTime 在过去)。
    /// 窗口内有用量时时间戳在未来,正常显示。仅用于 5h 卡;
    /// weekly/monthly 是固定边界,始终显示 timeUntilReset。
    public var slidingResetText: String? {
        guard let resetTimeMs,
              Date(timeIntervalSince1970: TimeInterval(resetTimeMs) / 1000) > Date() else { return nil }
        return timeUntilReset
    }

    /// "X小时Y分钟后重置" / "X天后重置" / "即将重置" / "未知"
    public var timeUntilReset: String {
        guard let resetTimeMs else { return "未知" }
        let reset = Date(timeIntervalSince1970: TimeInterval(resetTimeMs) / 1000)
        let now = Date()
        if reset <= now { return "即将重置" }
        let comps = Calendar.current.dateComponents([.day, .hour, .minute], from: now, to: reset)
        if let day = comps.day, day > 0 {
            return "\(day)天\(comps.hour ?? 0)小时后重置"
        }
        if let hour = comps.hour, hour > 0 {
            return "\(hour)小时\(comps.minute ?? 0)分钟后重置"
        }
        if let minute = comps.minute, minute > 0 {
            return "\(minute)分钟后重置"
        }
        return "即将重置"
    }
}

/// Kimi 网页订阅共享额度。Work/Kimi 与 Code 共用同一账户池,比例都以该池为分母。
public struct KimiSubscriptionBalance: Equatable {
    /// 账户共享池总使用比例(0...1)。
    public let totalUsedRatio: Double
    /// Code 在共享池中的使用比例(0...1);服务端未返回时为 nil。
    public let codeUsedRatio: Double?
    /// 订阅池重置/到期时间(ms epoch)。
    public let expireTimeMs: Int64?

    public init(totalUsedRatio: Double, codeUsedRatio: Double?, expireTimeMs: Int64?) {
        self.totalUsedRatio = Self.clamp(totalUsedRatio)
        self.codeUsedRatio = codeUsedRatio.map(Self.clamp)
        self.expireTimeMs = expireTimeMs
    }

    /// 账户共享池总使用百分比。
    public var totalUsedPercent: Double { roundedPercent(totalUsedRatio) }

    /// Code 占共享池的百分比;没有服务端分项时为 nil。
    public var codeUsedPercent: Double? {
        guard let codeUsedRatio else { return nil }
        return roundedPercent(min(codeUsedRatio, totalUsedRatio))
    }

    /// Work/Kimi 占共享池的百分比;没有 Code 分项时为 nil。
    public var workUsedPercent: Double? {
        guard let codeUsedRatio else { return nil }
        return roundedPercent(max(0, totalUsedRatio - min(codeUsedRatio, totalUsedRatio)))
    }

    /// 共享池剩余百分比。
    public var remainingPercent: Double {
        roundedPercent(1 - totalUsedRatio)
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

    private func roundedPercent(_ ratio: Double) -> Double {
        (ratio * 100 * 100).rounded() / 100
    }
}

/// Kimi Code 套餐用量(5h / 周 / 月度总额 + 加油包)。
public struct KimiQuota: Equatable {
    /// 5 小时窗口(limits[0],duration=300)
    public let fiveHour: KimiWindow
    /// 滚动周窗口(usage 字段)
    public let weekly: KimiWindow
    /// 月度总额度(totalQuota 字段;API 未返回时为 nil)
    public let monthly: KimiWindow?
    /// 网页订阅共享池(Work/Kimi + Code);未登录网页控制台时为 nil。
    public let subscriptionBalance: KimiSubscriptionBalance?
    /// 加油包(未开通/未启用时为 nil)
    public let booster: KimiBooster?
    /// 会员等级(LEVEL_* 枚举,如 "LEVEL_ADVANCED")
    public let membershipLevel: String?
    /// 订阅到期时间(ms epoch,web 控制台 GetSubscriptionStats 提供;月度卡片"重置"时间)
    public let subscriptionExpireMs: Int64?

    public init(fiveHour: KimiWindow, weekly: KimiWindow, monthly: KimiWindow?,
                booster: KimiBooster?, membershipLevel: String?,
                subscriptionExpireMs: Int64? = nil,
                subscriptionBalance: KimiSubscriptionBalance? = nil) {
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.monthly = monthly
        self.subscriptionBalance = subscriptionBalance
        self.booster = booster
        self.membershipLevel = membershipLevel
        self.subscriptionExpireMs = subscriptionExpireMs
    }

    /// 月度卡片重置时间:优先订阅到期时间,否则走 monthly 窗口自身。
    public var monthlyResetDisplay: String? {
        if let ms = subscriptionExpireMs {
            let reset = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
            return fmt.string(from: reset)
        }
        return monthly?.resetTimeDisplay
    }
}

/// Kimi 加油包余额(官方后台已开通才展示)。
public struct KimiBooster: Equatable {
    public let enabled: Bool
    /// 余额(元);接口未返回真实余额时为 0
    public let balanceYuan: Double
    /// 本月消费(元)
    public let monthlyUsedYuan: Double
    /// 月度消费上限(元);0 = 无限制
    public let monthlyLimitYuan: Double

    public init(enabled: Bool, balanceYuan: Double, monthlyUsedYuan: Double, monthlyLimitYuan: Double) {
        self.enabled = enabled
        self.balanceYuan = balanceYuan
        self.monthlyUsedYuan = monthlyUsedYuan
        self.monthlyLimitYuan = monthlyLimitYuan
    }
}
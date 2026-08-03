import Foundation

public struct UsageDetail: Equatable {
    public let percentageRaw: Double
    public let resetTimeMs: Int64

    public init(percentageRaw: Double, resetTimeMs: Int64) {
        self.percentageRaw = percentageRaw
        self.resetTimeMs = resetTimeMs
    }

    /// 0–100 浮点百分比(2 位小数精度,钳制到 0...100)。对齐官方控制台显示精度。
    public var percentage: Double {
        let pct = (percentageRaw * 100 * 100).rounded() / 100  // 保留 2 位小数
        return min(max(pct, 0), 100)
    }

    /// 整数百分比(用于阈值判定/通知,向下兼容)
    public var percentageInt: Int {
        Int(percentage.rounded())
    }

    /// 完整重置时间字符串:"2026-08-03 05:19:00" 格式,对齐官方控制台。
    /// nil = 服务端未给重置时间(如空窗),调用方应隐藏重置行而非显示"未知"。
    public var resetTimeDisplay: String? {
        guard resetTimeMs > 0 else { return nil }
        let reset = Date(timeIntervalSince1970: TimeInterval(resetTimeMs) / 1000)
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return fmt.string(from: reset)
    }

    /// "X小时Y分钟后重置" / "X天后重置" / "即将重置" / "未知"(相对时间,菜单栏等紧凑场景用)
    public var timeUntilReset: String {
        guard resetTimeMs > 0 else { return "未知" }
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

public struct SubscriptionDetail: Equatable {
    public let specCode: String
    public let status: String
    public let remainingDays: Int
    public let startTimeMs: Int64?
    public let endTimeMs: Int64?
    public let autoRenewFlag: Bool

    public init(specCode: String, status: String, remainingDays: Int,
                startTimeMs: Int64?, endTimeMs: Int64?, autoRenewFlag: Bool) {
        self.specCode = specCode; self.status = status; self.remainingDays = remainingDays
        self.startTimeMs = startTimeMs; self.endTimeMs = endTimeMs; self.autoRenewFlag = autoRenewFlag
    }

    public var specDisplay: String { specCode.capitalized }
    public var statusDisplay: String { status == "VALID" ? "生效中" : status }
}

public struct AddonSummary: Equatable {
    public let remainingCredits: Double
    public let totalCredits: Double
    public let activeCount: Int
    public init(remainingCredits: Double, totalCredits: Double, activeCount: Int) {
        self.remainingCredits = remainingCredits; self.totalCredits = totalCredits; self.activeCount = activeCount
    }
}

/// 一次 usage 响应同时包含 5 小时和 7 天两个窗口。
public struct UsageWindows: Equatable {
    public let fiveHour: UsageDetail
    public let oneWeek: UsageDetail
    public init(fiveHour: UsageDetail, oneWeek: UsageDetail) {
        self.fiveHour = fiveHour; self.oneWeek = oneWeek
    }
}

public struct TokenPlanQuota: Equatable {
    public let usage: UsageWindows
    public let subscription: SubscriptionDetail?
    public let addon: AddonSummary?
    public init(usage: UsageWindows,
                subscription: SubscriptionDetail?, addon: AddonSummary?) {
        self.usage = usage
        self.subscription = subscription; self.addon = addon
    }
}

public enum AuthState: Equatable {
    case unknown
    case ok
    case blNotInstalled
    case notLoggedIn      // bl 装了,但控制台未登录
    case expired          // 登录过但 token 失效
}

public enum UsageError: Error, Equatable {
    case authExpired
    case network(String)
    case parse
    case invalidResponse
    case unknown(String)
}

// MARK: - OpenCode Go 用量(rolling/weekly/monthly 三窗口,与阿里云 5h/7d 结构相似)

/// OpenCode Go 单个用量窗口(rolling≈5h / weekly≈7d / monthly)
public struct OpenCodeWindow: Equatable {
    public let pct: Int               // 已用百分比 0-100
    public let resetInSec: Int64      // 距重置秒数
    public init(pct: Int, resetInSec: Int64) { self.pct = pct; self.resetInSec = resetInSec }

    /// OpenCode Go 滚动窗口时长(秒,官方 5 小时)。
    public static let rollingWindowSec: Int64 = 5 * 3600

    /// 滚动窗口重置提示:空窗时服务端恒返完整窗口时长(resetInSec=18000),
    /// 倒计时没有意义,返回 nil 让面板隐藏,避免"永远 5 小时后重置"的误解
    /// (2026-08-03 用户反馈)。窗口内有用量时 resetInSec < 完整时长,正常显示。
    /// 仅用于 rolling 卡;weekly/monthly 是固定边界,始终显示 timeUntilReset。
    public var rollingResetText: String? {
        guard resetInSec > 0, resetInSec < Self.rollingWindowSec else { return nil }
        return timeUntilReset
    }

    /// "X小时Y分钟后重置" 等
    public var timeUntilReset: String {
        guard resetInSec > 0 else { return "未知" }
        let hrs = resetInSec / 3600
        let mins = (resetInSec % 3600) / 60
        let days = hrs / 24
        if days > 0 { return "\(days)天\(hrs % 24)小时后重置" }
        if hrs > 0 { return "\(hrs)小时\(mins)分钟后重置" }
        if mins > 0 { return "\(mins)分钟后重置" }
        return "即将重置"
    }
}

/// OpenCode Go 套餐用量(三窗口)
public struct OpenCodeQuota: Equatable {
    public let rolling: OpenCodeWindow    // 滚动窗口(≈5h)
    public let weekly: OpenCodeWindow     // 每周
    public let monthly: OpenCodeWindow    // 每月
    public init(rolling: OpenCodeWindow, weekly: OpenCodeWindow, monthly: OpenCodeWindow) {
        self.rolling = rolling; self.weekly = weekly; self.monthly = monthly
    }
}

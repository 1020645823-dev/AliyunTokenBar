import Foundation

public struct UsageDetail: Equatable {
    public let percentageRaw: Double
    public let resetTimeMs: Int64

    public init(percentageRaw: Double, resetTimeMs: Int64) {
        self.percentageRaw = percentageRaw
        self.resetTimeMs = resetTimeMs
    }

    /// 0–100 整数百分比(从 0.x 浮点四舍五入,钳制到 0...100)
    public var percentage: Int {
        let pct = Int((percentageRaw * 100).rounded())
        return min(max(pct, 0), 100)
    }

    /// "X小时Y分钟后重置" / "X天后重置" / "即将重置" / "未知"
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

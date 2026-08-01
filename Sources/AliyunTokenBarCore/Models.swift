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

public struct TokenPlanQuota: Equatable {
    public let fiveHour: UsageDetail
    public let oneWeek: UsageDetail
    public let subscription: SubscriptionDetail?
    public let addon: AddonSummary?
    public init(fiveHour: UsageDetail, oneWeek: UsageDetail,
                subscription: SubscriptionDetail?, addon: AddonSummary?) {
        self.fiveHour = fiveHour; self.oneWeek = oneWeek
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
    case unknown(String)
}

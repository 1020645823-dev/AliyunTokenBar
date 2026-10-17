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

// MARK: - 多账户(2026-10-04:用户有多个 Kimi 订阅账户)

/// 一个已登录的 Kimi 账户。账户身份 = www.kimi.com 网页控制台登录态
/// (web JWT 按 id 分槽存 Keychain;Keychain 槽位命名见 KimiUsageService)。
/// 首账户固定 id="main"——沿用 v1.0.16 起的本机凭证(KimiCodeBar/Kimi CLI 文件
/// + `kimi-web-token` Keychain 槽),零迁移;其余账户为独立网页登录。
public struct KimiAccount: Codable, Equatable, Identifiable {
    public let id: String
    public var label: String
    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

/// 单账户用量快照(模型层聚合后按账户展示/告警)。
public struct KimiAccountSnapshot: Equatable, Identifiable {
    public let id: String
    public let label: String
    public let quota: KimiQuota
    public init(id: String, label: String, quota: KimiQuota) {
        self.id = id
        self.label = label
        self.quota = quota
    }
}

extension KimiQuota {
    /// 多账户聚合(纯函数,Verify 断言覆盖):
    /// - 5h/周/月是**计数**窗口:used/limit 跨账户求和(每个订阅是独立池,总量口径最直观),
    ///   重置取最早;
    /// - 订阅共享池只有比率没有绝对值:取 totalUsedRatio 最大(风险最紧的那个);
    /// - 加油包是钱:余额/本月消费求和,月度上限求和;
    /// - membershipLevel / subscriptionExpireMs 取首个非空 / 最早。
    public static func aggregate(_ quotas: [KimiQuota]) -> KimiQuota? {
        guard !quotas.isEmpty else { return nil }
        guard quotas.count > 1 else { return quotas[0] }

        func sumWindow(_ keyPath: (KimiQuota) -> KimiWindow?) -> KimiWindow? {
            let wins = quotas.compactMap(keyPath)
            guard !wins.isEmpty else { return nil }
            let used = wins.map(\.used).reduce(0, +)
            let limit = wins.map(\.limit).reduce(0, +)
            let reset = wins.compactMap(\.resetTimeMs).min()
            return KimiWindow(used: used, limit: limit, resetTimeMs: reset)
        }

        let balances = quotas.compactMap(\.subscriptionBalance)
        var balance: KimiSubscriptionBalance?
        if !balances.isEmpty {
            let worst = balances.max(by: { $0.totalUsedRatio < $1.totalUsedRatio })!
            balance = KimiSubscriptionBalance(totalUsedRatio: worst.totalUsedRatio,
                                              codeUsedRatio: worst.codeUsedRatio,
                                              expireTimeMs: worst.expireTimeMs)
        }

        let boosters = quotas.compactMap(\.booster).filter(\.enabled)
        var booster: KimiBooster?
        if !boosters.isEmpty {
            let balanceYuan = boosters.map(\.balanceYuan).reduce(0, +)
            let monthlyUsedYuan = boosters.map(\.monthlyUsedYuan).reduce(0, +)
            let monthlyLimitYuan = boosters.map(\.monthlyLimitYuan).reduce(0, +)
            booster = KimiBooster(enabled: true, balanceYuan: balanceYuan,
                                  monthlyUsedYuan: monthlyUsedYuan, monthlyLimitYuan: monthlyLimitYuan)
        }

        let level = quotas.compactMap(\.membershipLevel).first { !$0.isEmpty }
        let expire = quotas.compactMap(\.subscriptionExpireMs).min()
        return KimiQuota(fiveHour: sumWindow(\.fiveHour) ?? quotas[0].fiveHour,
                         weekly: sumWindow(\.weekly) ?? quotas[0].weekly,
                         monthly: sumWindow(\.monthly),
                         booster: booster,
                         membershipLevel: level,
                         subscriptionExpireMs: expire,
                         subscriptionBalance: balance)
    }
}
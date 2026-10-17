import Foundation

// MARK: - 阶跃星辰 StepFun Step Plan 用量模型
//
// 对应 platform.stepfun.com 控制台的 Dashboard RPC
// `QueryStepPlanRateLimit`(私有端点,官方文档未收录;端点/字段形状对齐
// codex-switcher v0.7.19 的生产实现,snake/camel 双键名均收)。
//
// Step Plan 现行计费 = Credit 月池(2026-09 官方文档:额度以 Credit 按月发放,
// 月末清零,1M Credit = ¥1;月池用尽可加购「加油包」,加油包各自 30 天到期):
//
//   plan_credit_rate_limit.credit_buckets[]
//     credit_total / credit_residual / type / next_reset_at|expire_at
//     type 含 "TOPUP" 或 =="2" → 加油包;其余 → 订阅月池
//
// 兼容两种旧形状(解析层「来什么归一化什么」):
//   ① plan_credit_rate_limit.subscription_credit_left_rate / topup_credit_left_rate(纯百分比)
//   ② 根级 five_hour_usage_left_rate / weekly_usage_left_rate(旧 5h+周双限额)
//
// ⚠️ 所有 *_rate 字段是**剩余**百分比(left rate,0-1 小数或 0-100 均可能);
// 本 App 统一口径 = 已用百分比,解析层负责 100-left 反推。
// ⚠️ 计数单位是 Credit 不是 token,量级巨大(亿级)——展示用 M(百万)或换算 ¥。

/// 单个 Credit 桶(订阅月池或加油包)。
public struct StepFunCreditBucket: Equatable {
    /// 桶内 Credit 总量(纯百分比兜底形状无计数,为 0)
    public let total: Double
    /// 桶内剩余 Credit
    public let residual: Double
    /// 已用百分比 0-100(由 residual/total 或剩余 rate 反推)
    public let usedPct: Double
    /// 重置/到期时间(epoch 毫秒;缺失为 nil,UI 不显示倒计时)
    public let resetTimeMs: Int64?

    public init(total: Double, residual: Double, usedPct: Double, resetTimeMs: Int64?) {
        self.total = total
        self.residual = residual
        self.usedPct = usedPct
        self.resetTimeMs = resetTimeMs
    }

    public var usedCredits: Double { max(0, total - residual) }
    public var usedPctInt: Int { Int(usedPct.rounded()) }
}

/// 旧计费的纯百分比窗口(5h / 7d)。
public struct StepFunRateWindow: Equatable {
    /// 已用百分比 0-100
    public let usedPct: Double
    /// 重置时间(epoch 毫秒)
    public let resetTimeMs: Int64?

    public init(usedPct: Double, resetTimeMs: Int64?) {
        self.usedPct = usedPct
        self.resetTimeMs = resetTimeMs
    }

    public var usedPctInt: Int { Int(usedPct.rounded()) }

    /// 重置倒计时文案(MiniMaxWindow.resetText 同款;过去时间/缺失 → nil)。
    public static func resetText(fromMs ms: Int64?) -> String? {
        guard let ms else { return nil }
        let delta = Date(timeIntervalSince1970: TimeInterval(ms) / 1000).timeIntervalSinceNow
        guard delta > 0 else { return nil }
        let mins = Int(delta) / 60
        let hrs = mins / 60
        let days = hrs / 24
        if days > 0 { return "\(days)天\(hrs % 24)小时后重置" }
        if hrs > 0 { return "\(hrs)小时\(mins % 60)分钟后重置" }
        if mins > 0 { return "\(mins)分钟后重置" }
        return "即将重置"
    }
}

/// Step Plan 用量快照。任一月池/加油包/旧窗口可用即视为成功。
public struct StepFunQuota: Equatable {
    /// 订阅月池(当月 Credit 池)
    public let subscription: StepFunCreditBucket?
    /// 加油包(多包时聚合:total/residual 求和,到期取最早)
    public let topup: StepFunCreditBucket?
    /// 旧计费 5 小时窗口
    public let fiveHour: StepFunRateWindow?
    /// 旧计费周窗口
    public let weekly: StepFunRateWindow?

    public init(subscription: StepFunCreditBucket?, topup: StepFunCreditBucket?,
                fiveHour: StepFunRateWindow?, weekly: StepFunRateWindow?) {
        self.subscription = subscription
        self.topup = topup
        self.fiveHour = fiveHour
        self.weekly = weekly
    }

    /// 菜单栏/摘要主窗口:新计费=订阅月池;旧计费=5h;再退=周;最后退=加油包。
    public var primaryPct: Int? {
        subscription?.usedPctInt ?? fiveHour?.usedPctInt ?? weekly?.usedPctInt ?? topup?.usedPctInt
    }

    /// 主窗口标签(展示层 tooltip 用)。
    public var primaryLabel: String {
        if subscription != nil { return "月池" }
        if fiveHour != nil { return "5小时" }
        if weekly != nil { return "周" }
        return "加油包"
    }

    /// 菜单栏次窗口:新计费=加油包;旧计费=周;单桶订阅无次窗口(nil → 单值列)。
    public var secondaryPct: Int? {
        if subscription != nil || topup != nil { return topup?.usedPctInt }
        if fiveHour != nil { return weekly?.usedPctInt }
        return nil
    }

    /// 次窗口标签。
    public var secondaryLabel: String? {
        if subscription != nil || topup != nil { return topup != nil ? "加油包" : nil }
        if fiveHour != nil { return weekly != nil ? "周" : nil }
        return nil
    }

    /// 副标题(面板 hero 下文案)。
    public var billingDisplay: String {
        if subscription != nil || topup != nil { return "Credit 月池" }
        if fiveHour != nil || weekly != nil { return "5小时 + 周" }
        return "Step Plan"
    }
}

// MARK: - 多账户(2026-10-02:用户有多个 Step Plan 订阅账户)

/// 一个已登录的阶跃账户身份(持久化到 UserDefaults;id 同时是会话仓库标识)。
/// 首个账户固定 id="main"(沿用 v1.0.60 起的默认 WKWebsiteDataStore,零迁移);
/// 其余账户用 UUID + 独立命名仓库。
public struct StepFunAccount: Codable, Equatable, Identifiable {
    public let id: String
    public var label: String
    /// 账户身份(oasis_id,登录时从 Oasis-Token cookie 的 JWT 解析;nil=尚未识别)。
    /// 同一 oasis_id 的多个会话 = 同一个阶跃账户:登录时阻止重复添加,聚合时只计一次。
    public var oasisID: String?
    /// 账户手机号尾4位(登录时经账户中心 GetAccountBinding 识别;nil=尚未识别)。
    /// JWT 里没有手机号(oasis_id 只是内部 id),必须走账户中心 RPC 单独取。
    public var phoneTail: String?

    public init(id: String, label: String, oasisID: String? = nil, phoneTail: String? = nil) {
        self.id = id
        self.label = label
        self.oasisID = oasisID
        self.phoneTail = phoneTail
    }

    /// 展示用身份后缀(如 "#3403");无 oasis_id 返回 nil。
    public var identitySuffix: String? {
        guard let oasisID, oasisID.count >= 4 else { return nil }
        return "#" + oasisID.suffix(4)
    }

    /// 面板/设置行内的身份展示:**优先手机号尾号**(如 "****5678",对用户有
    /// 意义、多账户一眼区分);拿不到才回落 oasis_id 尾4位("#8016")。
    public var identityDisplay: String? {
        if let phoneTail, phoneTail.count == 4 { return "****" + phoneTail }
        return identitySuffix
    }
}

/// 单账户的用量快照(模型层聚合后按账户展示/告警)。
public struct StepFunAccountSnapshot: Equatable, Identifiable {
    public let id: String
    public let label: String
    public let quota: StepFunQuota
    /// 本次快照的拉取时刻(nil = 旧版本构造的兼容值)
    public var fetchedAt: Date?
    /// 是否为旧数据(本轮刷新失败,保留上轮成功值展示)
    public var isStale: Bool

    public init(id: String, label: String, quota: StepFunQuota,
                fetchedAt: Date? = nil, isStale: Bool = false) {
        self.id = id
        self.label = label
        self.quota = quota
        self.fetchedAt = fetchedAt
        self.isStale = isStale
    }

    /// 一轮刷新的快照合并(纯函数,Verify 断言覆盖):
    /// 按账户列表顺序输出——本轮成功的账户用新快照(标 fetchedAt=now);本轮失败
    /// 但有 last-good 的账户保留旧值并标 `isStale`(统计不跳动、行不消失);
    /// 两者皆无的账户不输出(无数据可展示,由错误行/加载态兜底)。
    public static func merge(accounts: [StepFunAccount],
                             fresh: [String: StepFunAccountSnapshot],
                             previous: [String: StepFunAccountSnapshot],
                             now: Date) -> [StepFunAccountSnapshot] {
        accounts.compactMap { account in
            if let f = fresh[account.id] { return f }
            if let p = previous[account.id] {
                return StepFunAccountSnapshot(id: p.id, label: account.label, quota: p.quota,
                                              fetchedAt: p.fetchedAt, isStale: true)
            }
            return nil
        }
    }
}

extension StepFunQuota {
    /// 多账户聚合(纯函数,Verify 断言覆盖):
    /// - 月池/加油包:跨账户**求和**后算比例(每个订阅是独立月池,总量口径最直观),
    ///   重置时间取最早(最先到期的那个);纯百分比兜底形状(无计数)退化为取 max。
    /// - 旧 5h/周窗口:取 max(告警保守口径;月池计费下通常为 nil)。
    public static func aggregate(_ quotas: [StepFunQuota]) -> StepFunQuota? {
        guard !quotas.isEmpty else { return nil }
        guard quotas.count > 1 else { return quotas[0] }

        func bucket(_ keyPath: (StepFunQuota) -> StepFunCreditBucket?) -> StepFunCreditBucket? {
            let buckets = quotas.compactMap(keyPath)
            guard !buckets.isEmpty else { return nil }
            let counting = buckets.filter { $0.total > 0 }
            if !counting.isEmpty {
                let total = counting.map(\.total).reduce(0, +)
                let residual = counting.map(\.residual).reduce(0, +)
                let pct = StepFunUsageService.bucketUsedPct(total: total, residual: residual) ?? 0
                let resets = buckets.compactMap(\.resetTimeMs)
                return StepFunCreditBucket(total: total, residual: residual, usedPct: pct,
                                           resetTimeMs: resets.min())
            }
            // 全是纯百分比兜底形状:取已用最大(最紧的那个)
            let worst = buckets.max(by: { $0.usedPct < $1.usedPct })!
            return StepFunCreditBucket(total: 0, residual: 0, usedPct: worst.usedPct,
                                       resetTimeMs: worst.resetTimeMs)
        }

        func rateMax(_ keyPath: (StepFunQuota) -> StepFunRateWindow?) -> StepFunRateWindow? {
            let windows = quotas.compactMap(keyPath)
            guard let worst = windows.max(by: { $0.usedPct < $1.usedPct }) else { return nil }
            return worst
        }

        return StepFunQuota(subscription: bucket(\.subscription),
                             topup: bucket(\.topup),
                             fiveHour: rateMax(\.fiveHour),
                             weekly: rateMax(\.weekly))
    }
}

// MARK: - 月池预测已泛化
//
// Credit 月池"发放一次、月末清零",真正的问题是"按当前速度能不能撑到清零"。
// 该外推从 v1.0.65 起泛化为 UsageForecast(月池/窗口/余额三种形态,所有订阅卡
// 共用);StepFunForecast 仅为兼容旧调用点的 typealias,见 UsageForecast.swift。

// MARK: - Credit 展示格式(纯函数,Verify 断言覆盖)

public enum StepFunCreditFormat {
    /// Credit 数量 → 紧凑 M(百万)展示:"240M"、"1.2B"(>1000M 用 B);
    /// <1M 显示 "0.9M"。Credit 量级巨大(亿级),菜单栏不使用此格式(只有百分比)。
    public static func compact(_ credits: Double) -> String {
        guard credits.isFinite, credits > 0 else { return "0" }
        let m = credits / 1_000_000
        if m >= 1000 {
            return String(format: "%.2fB", m / 1000)
        }
        if m >= 100 {
            return String(format: "%.0fM", m)
        }
        return String(format: "%.1fM", m)
    }

    /// Credit 数量 → ¥ 等值(官方换算 1M Credit = ¥1)。
    public static func cny(_ credits: Double) -> String {
        String(format: "¥%.2f", credits / 1_000_000)
    }
}

import Foundation

// MARK: - MiniMax Coding Plan(Token Plan)用量模型
//
// 对应 coding_plan/token_plan remains 接口的 model_remains[]:
// 每个模型条目含「当前计费窗口」(general 为 5h 滚动,video 为日)与「周窗口」。
//
// ⚠️ 字段语义(2026-08-18 真实订阅实测修正):
// `*_remaining_percent` 是**剩余**百分比(0-100),优先采用、不依赖计数口径。
// 计数有两种历史口径:2026-04 社区实现(minimax-status/CodexBar)把
// `*_usage_count` 当**剩余**;2026-08 实测(M2.7 全新订阅:total=3, usage_count=0,
// remaining_percent=100)证明当前字面语义 usage_count=**已用**。percent 存在时
// 按百分比反推计数,规避口径分歧;percent 缺失时按字面语义(已用)。

/// 单个用量窗口(当前计费窗口或周窗口)。
public struct MiniMaxWindow: Equatable {
    /// 已用百分比 0-100
    public let pct: Double
    /// 已用次数
    public let used: Int
    /// 总次数
    public let total: Int
    /// 剩余次数(接口的 usage_count 原值)
    public let remaining: Int
    /// 下次重置时间(epoch ms);缺失时不显示倒计时
    public let resetTimeMs: Int64?

    public init(pct: Double, used: Int, total: Int, remaining: Int, resetTimeMs: Int64?) {
        self.pct = pct
        self.used = used
        self.total = total
        self.remaining = remaining
        self.resetTimeMs = resetTimeMs
    }

    public var pctInt: Int { Int(pct.rounded()) }

    /// "已用 x/y 次";total ≤ 0(不限量/无数据)返回 nil。
    public var usageText: String? {
        total > 0 ? "\(used)/\(total) 次" : nil
    }

    /// "X小时Y分钟后重置"(文案与 ZhipuWindow/KimiWindow 一致);无重置时间返回 nil。
    public var timeUntilReset: String? {
        Self.resetText(fromMs: resetTimeMs)
    }

    /// 重置倒计时文案(过去时间/缺失返回 nil,UI 隐藏倒计时)。
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

/// 单个模型的窗口组(model_remains[] 一条;如 "general" 总额度、"video" 视频次数)。
public struct MiniMaxModelQuota: Equatable {
    public let name: String
    public let interval: MiniMaxWindow?
    public let weekly: MiniMaxWindow?

    public init(name: String, interval: MiniMaxWindow?, weekly: MiniMaxWindow?) {
        self.name = name
        self.interval = interval
        self.weekly = weekly
    }
}

/// MiniMax Coding Plan 用量快照。
public struct MiniMaxQuota: Equatable {
    /// 套餐名(current_subscribe_title / plan_name 等首个非空;缺失为 nil)
    public let planName: String?
    /// 积分余额(points_balance 等变体;按量付费赠送积分;缺失为 nil)
    public let pointsBalance: Double?
    /// 主模型名(优先 "general" 总额度条目,否则首条;缺失为 nil)
    public let modelName: String?
    /// 当前计费窗口(通常 5h 滚动;纯百分比窗口 total=0 也有效)
    public let interval: MiniMaxWindow?
    /// 周窗口(纯百分比窗口 total=0 也有效)
    public let weekly: MiniMaxWindow?
    /// 其余模型条目(video 等专项次数;主条目不在内)
    public let models: [MiniMaxModelQuota]

    public init(planName: String?, pointsBalance: Double?, modelName: String?,
                interval: MiniMaxWindow?, weekly: MiniMaxWindow?,
                models: [MiniMaxModelQuota] = []) {
        self.planName = planName
        self.pointsBalance = pointsBalance
        self.modelName = modelName
        self.interval = interval
        self.weekly = weekly
        self.models = models
    }
}

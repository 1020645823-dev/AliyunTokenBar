import Foundation

// MARK: - 智谱 GLM Coding Plan 用量模型
//
// 对应 open.bigmodel.cn 的 /api/monitor/usage/quota/limit 响应:
// data.limits[] 含 2 条 TOKENS_LIMIT(5 小时 + 周,按窗口时长区分)
// 与 1 条 TIME_LIMIT(MCP 通道月度按次配额);data.level 为套餐档位("lite"/"pro"/"max")。

/// 单个 token 用量窗口(5h 或周)。percentage 由服务端直接给出,无需本地换算。
public struct ZhipuWindow: Equatable {
    public let pct: Double
    /// 下次重置时间(epoch ms);缺失时不显示倒计时。
    public let resetTimeMs: Int64?

    public init(pct: Double, resetTimeMs: Int64?) {
        self.pct = pct
        self.resetTimeMs = resetTimeMs
    }

    public var pctInt: Int { Int(pct.rounded()) }

    /// "X小时Y分钟后重置"(风格与 KimiWindow.timeUntilReset 一致);无重置时间返回 nil。
    public var timeUntilReset: String? {
        Self.resetText(fromMs: resetTimeMs)
    }

    /// 重置倒计时文案(共享:ZhipuWindow 与 ZhipuMCPQuota 复用)。
    /// 过去时间/缺失返回 nil(UI 隐藏倒计时)。
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

/// MCP 通道月度配额(TIME_LIMIT,按次计,如 search-prime/web-reader/zread 共享 4000 次/月)。
public struct ZhipuMCPQuota: Equatable {
    public struct Detail: Equatable {
        public let modelCode: String
        public let usage: Int
        public init(modelCode: String, usage: Int) {
            self.modelCode = modelCode
            self.usage = usage
        }
    }

    /// 月度总次数(如 4000);信息不全时为 nil。
    public let usage: Int?
    /// 已用次数。
    public let currentValue: Int?
    public let remaining: Int?
    public let percentage: Double
    public let resetTimeMs: Int64?
    public let details: [Detail]

    public init(usage: Int?, currentValue: Int?, remaining: Int?,
                percentage: Double, resetTimeMs: Int64?, details: [Detail]) {
        self.usage = usage
        self.currentValue = currentValue
        self.remaining = remaining
        self.percentage = percentage
        self.resetTimeMs = resetTimeMs
        self.details = details
    }

    /// "5/4000 次";usage/currentValue 缺失时返回 nil(UI 退化为只显示百分比)。
    public var usageText: String? {
        guard let usage, let currentValue, usage > 0 else { return nil }
        return "\(currentValue)/\(usage) 次"
    }

    /// 月度重置倒计时(与 ZhipuWindow 同文案)。
    public var timeUntilReset: String? {
        ZhipuWindow.resetText(fromMs: resetTimeMs)
    }
}

/// 智谱 Coding Plan 用量快照。
public struct ZhipuQuota: Equatable {
    public let fiveHour: ZhipuWindow?
    public let weekly: ZhipuWindow?
    public let mcp: ZhipuMCPQuota?
    /// 套餐档位原始值("lite"/"pro"/"max";区域间字段名不稳,展示层做宽容映射)。
    public let level: String?

    public init(fiveHour: ZhipuWindow?, weekly: ZhipuWindow?, mcp: ZhipuMCPQuota?, level: String?) {
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.mcp = mcp
        self.level = level
    }
}

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

// MARK: - 多账户(2026-10-04:用户有多个智谱 Coding Plan 订阅账户)

/// 一个已配置的智谱账户(Keychain 按 id 分槽存 Key;持久化到 UserDefaults)。
/// 首账户固定 id="main"——沿用 v1.0.35 起的 `zhipu-api-key` Keychain 槽位(零迁移),
/// 且只有 main 账户享受「opencode 配置自动发现」的兜底(其余账户只认手动 Key)。
public struct ZhipuAccount: Codable, Equatable, Identifiable {
    public let id: String
    public var label: String
    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

/// 单账户用量快照(模型层聚合后按账户展示/告警)。
public struct ZhipuAccountSnapshot: Equatable, Identifiable {
    public let id: String
    public let label: String
    public let quota: ZhipuQuota
    public init(id: String, label: String, quota: ZhipuQuota) {
        self.id = id
        self.label = label
        self.quota = quota
    }
}

extension ZhipuQuota {
    /// 多账户聚合(纯函数,Verify 断言覆盖):
    /// - 5h/周窗口是**百分比**:取 max(风险保守口径——最紧的账户决定会不会被限流);
    /// - MCP 月度**按次**配额:各账户独立计数,usage/currentValue/remaining 求和后重算百分比,
    ///   details 按 modelCode 归并求和,重置取最早;
    /// - level 取首个非空(展示用,不影响数据)。
    public static func aggregate(_ quotas: [ZhipuQuota]) -> ZhipuQuota? {
        guard !quotas.isEmpty else { return nil }
        guard quotas.count > 1 else { return quotas[0] }

        func maxWindow(_ keyPath: (ZhipuQuota) -> ZhipuWindow?) -> ZhipuWindow? {
            quotas.compactMap(keyPath).max(by: { $0.pct < $1.pct })
        }

        let mcps = quotas.compactMap(\.mcp)
        var mcp: ZhipuMCPQuota?
        if !mcps.isEmpty {
            let usage = mcps.compactMap(\.usage).reduce(0, +)
            let currentValue = mcps.compactMap(\.currentValue).reduce(0, +)
            let remaining = mcps.compactMap(\.remaining).reduce(0, +)
            let pct: Double = usage > 0 ? min(100, Double(currentValue) / Double(usage) * 100) : 0
            var details: [String: Int] = [:]
            for m in mcps {
                for d in m.details { details[d.modelCode, default: 0] += d.usage }
            }
            let resetTimeMs = mcps.compactMap(\.resetTimeMs).min()
            mcp = ZhipuMCPQuota(usage: usage, currentValue: currentValue, remaining: remaining,
                                percentage: pct, resetTimeMs: resetTimeMs,
                                details: details.map { ZhipuMCPQuota.Detail(modelCode: $0.key, usage: $0.value) })
        }
        let level = quotas.compactMap(\.level).first { !$0.isEmpty }
        return ZhipuQuota(fiveHour: maxWindow(\.fiveHour), weekly: maxWindow(\.weekly),
                          mcp: mcp, level: level)
    }
}

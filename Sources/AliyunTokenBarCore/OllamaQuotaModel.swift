import Foundation

// MARK: - Ollama Cloud 用量模型
//
// 对应 ollama.com 的 GET /api/usage?range=30d(未公开文档,但维护者在
// ollama/ollama#17451 公开指引该端点)。
//
// ⚠️ 2026-10-09 结构变更(实测):旧的 `limits.{monthly,session,weekly}.usage`
// (0-1 小数)整个消失,换成**按天用量报表**:
//
//   range/granularity/from/until  报表参数(day 粒度;range ∈ 24h/7d/30d)
//   totals.request_count          周期内请求总数
//   totals.usage_usd              周期内消费(美元,绝对金额)
//   buckets[]                     每日一行(from/until/request_count/usage_usd/
//                                 input_tokens/cached_input_tokens/output_tokens,
//                                 当日桶带 partial:true)
//
// 新响应**不含任何额度/限额字段**:月度额度上限由套餐档位推导
// (free=? / pro=$60 / max=$300 / team=$1000,取 ollama.com/pricing),
// 档位走远程 POST /api/me(带 API Key,返回 {"Plan":"max"})或本机 daemon。
// 已用比例 = 近 30 天消费 ÷ 月度额度 —— 滚动窗口口径,非订阅计费周期。

/// 月度额度窗口(展示层兼容:菜单栏/历史/通知/卡片环都按"窗口"消费)。
///
/// `usage` 为**近 30 天消费美元额**;`pct` = 消费 ÷ 套餐月度额度(0-100)。
/// 套餐未知(档位探测失败)时无额度可除 → 整个窗口为 nil,由 UI 走
/// 绝对金额 hero 形态(参考 MiMo 余额卡)。
public struct OllamaWindow: Equatable {
    /// 近 30 天消费(美元,服务端原始值)。
    public let rawUsage: Double
    /// 归一化已用百分比 0-100。
    public let pct: Double
    /// 兼容字段:新接口不再返回每模型请求数,恒为空。
    public let models: [OllamaModelUsage]

    public init(rawUsage: Double, pct: Double, models: [OllamaModelUsage]) {
        self.rawUsage = rawUsage
        self.pct = pct
        self.models = models
    }

    public var pctInt: Int { Int(pct.rounded()) }
}

/// 窗口内单模型请求数(旧接口 `limits.*.models[]`;新接口已无此数据,恒空)。
public struct OllamaModelUsage: Equatable {
    public let name: String
    public let requestCount: Int

    public init(name: String, requestCount: Int) {
        self.name = name
        self.requestCount = requestCount
    }
}

/// Ollama Cloud 用量快照(近 30 天滚动报表)。
public struct OllamaQuota: Equatable {
    /// 近 30 天消费(美元,totals.usage_usd)。
    public let spentUSD30d: Double
    /// 近 30 天请求总数(totals.request_count)。
    public let requests30d: Int
    /// 近 7 天消费(美元,由日桶尾部 7 个汇总;桶不足 7 个时为全部之和)。
    public let spentUSD7d: Double
    /// 每日消费桶(美元,时间升序,末桶可能为当日部分)。
    public let dailyUSD: [Double]
    /// 套餐月度额度(美元);档位探测失败为 nil。
    public let capUSD: Double?
    /// 套餐档位("free"/"pro"/"max"/"team");探测失败为 nil。
    public let plan: String?

    public init(spentUSD30d: Double, requests30d: Int, spentUSD7d: Double,
                dailyUSD: [Double], capUSD: Double?, plan: String?) {
        self.spentUSD30d = spentUSD30d
        self.requests30d = requests30d
        self.spentUSD7d = spentUSD7d
        self.dailyUSD = dailyUSD
        self.capUSD = capUSD
        self.plan = plan
    }

    /// 近 30 天消费占月度额度比例(0-100);无档位(无额度)时为 nil。
    public var usagePct: Double? {
        guard let cap = capUSD, cap > 0 else { return nil }
        return OllamaPlan.usagePct(spentUSD: spentUSD30d, capUSD: cap)
    }

    /// 月度窗口(有额度才存在);菜单栏主行/hero/历史/告警都走它。
    public var monthly: OllamaWindow? {
        guard let pct = usagePct else { return nil }
        return OllamaWindow(rawUsage: spentUSD30d, pct: pct, models: [])
    }

    /// 主窗口:新接口只有月度(滚动 30 天)一个口径。
    public var primary: OllamaWindow? { monthly }

    /// 次窗口:新接口无周窗口,恒 nil(菜单栏走单值列形态)。
    public var secondary: OllamaWindow? { nil }

    /// 主窗口标签(展示层 tooltip 用)。
    public var primaryLabel: String { "30天" }

    /// 日均消费(美元/天,按 30 天窗口)。
    public var dailyAvgUSD: Double { spentUSD30d / 30 }

    /// 套餐档位展示名;nil → 不显示徽标。
    public var planDisplay: String? {
        guard let plan, !plan.trimmed.isEmpty else { return nil }
        switch plan.lowercased() {
        case "free": return "Free"
        case "pro": return "Pro"
        case "max": return "Max"
        case "team": return "Team"
        case "enterprise": return "Enterprise"
        default: return plan.uppercased().prefix(10).description
        }
    }
}

// MARK: - 美元格式化(与 DeepSeekMoneyFormat 同范式,币种 $)

public enum OllamaMoney {
    /// 完整格式:恒两位小数("$167.51" / "$0.00")。
    public static func full(_ v: Double) -> String {
        "$" + String(format: "%.2f", max(0, v))
    }
}

// MARK: - 套餐档位与百分比归一化(纯函数,Verify 断言覆盖)

public enum OllamaPlan {
    /// 各档位月度含赠额度(美元),取自 ollama.com/pricing(2026-09-12)。
    /// Free 档"starter usage"未公布美元数字 → nil(无法按美元换算)。
    public static func monthlyCapUSD(plan: String?) -> Double? {
        switch plan?.trimmed.lowercased() {
        case "pro": return 60
        case "max": return 300
        case "team": return 1000
        default: return nil
        }
    }

    /// 近 30 天消费(美元)÷ 月度额度 → 已用百分比 0-100。
    ///
    /// 新接口回报的是**绝对美元**(2026-10-09 实测),不再是 0-1 小数;
    /// 无额度(档位未知)返回 nil,由 UI 展示绝对金额而非编造百分比。
    /// 超支(消费 > 额度)钳到 100:宁显示满也不显示 130%。
    public static func usagePct(spentUSD: Double, capUSD: Double) -> Double? {
        guard capUSD > 0, spentUSD.isFinite else { return nil }
        return min(max(spentUSD, 0) / capUSD * 100, 100)
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

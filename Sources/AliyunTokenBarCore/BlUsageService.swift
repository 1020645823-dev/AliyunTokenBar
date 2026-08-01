import Foundation

/// 数据层:shell out 调 bl console call,解析三层嵌套 JSON。
/// 唯一掌握 RPC 契约的文件,改动需配合同步更新 Verify fixture。
public final class BlUsageService {
    // 三个控制台私有 RPC(2026-08-01 Playwright 抓包 + bl 验证)
    public static let usageAPI = "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/usage"
    public static let subscriptionAPI = "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/subscription"
    public static let addonAPI = "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/addon/summary"

    // MARK: - Parsing (pure functions, fully tested)

    /// 解析 usage 响应。JSON 三层嵌套:data.DataV2.data.data.<字段>
    public static func parseUsage(_ data: Data) throws -> UsageWindows {
        let p = try extractInnerPayload(data)
        return UsageWindows(
            fiveHour: UsageDetail(
                percentageRaw: try p.value("per5HourPercentage", as: Double.self),
                resetTimeMs: try p.value("per5HourResetTime", as: Int64.self)
            ),
            oneWeek: UsageDetail(
                percentageRaw: try p.value("per1WeekPercentage", as: Double.self),
                resetTimeMs: try p.value("per1WeekResetTime", as: Int64.self)
            )
        )
    }

    public static func parseSubscription(_ data: Data) throws -> SubscriptionDetail {
        let p = try extractInnerPayload(data)
        return SubscriptionDetail(
            specCode: try p.value("specCode", as: String.self),
            status: try p.value("status", as: String.self),
            remainingDays: try p.value("remainingDays", as: Int.self),
            startTimeMs: try? p.value("startTime", as: Int64.self),
            endTimeMs: try? p.value("endTime", as: Int64.self),
            autoRenewFlag: (try? p.value("autoRenewFlag", as: Bool.self)) ?? false
        )
    }

    public static func parseAddon(_ data: Data) throws -> AddonSummary {
        let p = try extractInnerPayload(data)
        return AddonSummary(
            remainingCredits: (try? p.value("remainingCredits", as: Double.self)) ?? 0,
            totalCredits: (try? p.value("totalCredits", as: Double.self)) ?? 0,
            activeCount: (try? p.value("activeCount", as: Int.self)) ?? 0
        )
    }

    /// 从 bl 的输出判断是否 token 过期(返回 .authExpired)或其他错误。
    public static func classifyError(_ data: Data, httpOk: Bool) -> UsageError {
        if let s = String(data: data, encoding: .utf8),
           s.contains("not logged in") || s.contains("has expired") {
            return .authExpired
        }
        return .network(String(data: data, encoding: .utf8) ?? "unknown error")
    }

    /// 抽取三层嵌套的最内层 data: data.DataV2.data.data
    private static func extractInnerPayload(_ data: Data) throws -> [String: Any] {
        struct ParseErr: Error {}
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let d1 = root["data"] as? [String: Any],
              let d2 = d1["DataV2"] as? [String: Any],
              let d3 = d2["data"] as? [String: Any],
              let inner = d3["data"] as? [String: Any] else {
            throw ParseErr()
        }
        return inner
    }
}

// MARK: - [String:Any] 类型安全取值辅助
private struct BlValueMismatch: Error {}

private extension Dictionary where Key == String, Value == Any {
    func value<T>(_ key: String, as type: T.Type) throws -> T {
        guard let v = self[key] as? T else { throw BlValueMismatch() }
        return v
    }
}

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
    /// 宽容解析:窗口为空(如 5h 内零用量)时服务端可能返回 null/缺失字段,
    /// 官方控制台该状态显示 0%;这里同样按 0 处理,避免严格解析把整次更新
    /// 打成 .parse 失败、UI 静默保留几小时前的旧值(2026-08-03 事故根因)。
    public static func parseUsage(_ data: Data) throws -> UsageWindows {
        let p = try extractInnerPayload(data)
        return UsageWindows(
            fiveHour: UsageDetail(
                percentageRaw: p.optionalDouble("per5HourPercentage") ?? 0,
                resetTimeMs: p.optionalInt64("per5HourResetTime") ?? 0
            ),
            oneWeek: UsageDetail(
                percentageRaw: p.optionalDouble("per1WeekPercentage") ?? 0,
                resetTimeMs: p.optionalInt64("per1WeekResetTime") ?? 0
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
    public static func classifyError(_ data: Data) -> UsageError {
        let text = String(data: data, encoding: .utf8) ?? ""
        let lower = text.lowercased()
        if lower.contains("not logged in") || lower.contains("has expired") ||
            lower.contains("notlogined") || lower.contains("session is not logged") {
            return .authExpired
        }
        return .network(text.isEmpty ? "unknown error" : text)
    }

    /// 兼容 Verify/旧调用方的签名。
    public static func classifyError(_ data: Data, httpOk: Bool) -> UsageError {
        classifyError(data)
    }

    // MARK: - Execution (shell out to bl)

    /// 调一个 RPC,返回 stdout 的 Data。environment 只用于临时 token profile。
    /// 经 ProcessRunner 执行:30s 超时(挂死降级为单次失败,不再永久锁死刷新)。
    public static func callRPC(_ api: String, environment: [String: String]? = nil) async throws -> Data {
        guard let blPath = BlExecutable.resolve() else {
            throw UsageError.unknown("未找到 bl CLI(检查 PATH 或安装位置)")
        }
        var env = environment ?? BlExecutable.enrichedEnvironment()
        env["NO_COLOR"] = "1"
        let result = await ProcessRunner.runAsync(
            executable: URL(fileURLWithPath: blPath),
            arguments: ["console", "call",
                        "--api", api, "--data", "{}", "--output", "json"],
            environment: env,
            timeout: 30
        )
        if result.timedOut {
            AppLog.error("bl console call 超时(30s): \(api)", category: .bl)
            throw UsageError.unknown("bl 调用超时,请稍后重试")
        }
        guard result.exitCode == 0 else {
            throw classifyError(Data(result.combinedOutput.utf8))
        }
        return Data(result.stdout.utf8)
    }

    /// 一次拉取完整套餐数据(3 个 RPC 并发)。usage 是必须项,sub/addon 缺失则 nil。
    public static func fetchQuota(environment: [String: String]? = nil) async -> Result<TokenPlanQuota, UsageError> {
        async let usageRes = (try? await callRPC(usageAPI, environment: environment)).flatMap { try? parseUsage($0) }
        async let subRes = (try? await callRPC(subscriptionAPI, environment: environment)).flatMap { try? parseSubscription($0) }
        async let addonRes = (try? await callRPC(addonAPI, environment: environment)).flatMap { try? parseAddon($0) }

        let usage = await usageRes
        let sub = await subRes
        let addon = await addonRes

        guard let usage else {
            // usage 失败:重新触发以捕获精确错误类型
            do { _ = try await callRPC(usageAPI, environment: environment) }
            catch let e as UsageError { return .failure(e) }
            catch { return .failure(.unknown(error.localizedDescription)) }
            // 重试成功但首次并发失败:usage 仍不可用,返回明确错误而非误报 parse 失败
            return .failure(.unknown("usage 数据暂不可用,请稍后重试"))
        }
        return .success(TokenPlanQuota(usage: usage, subscription: sub, addon: addon))
    }

    /// 只拉 usage(1 个 RPC)。辅助数据(subscription/addon)变化慢,由调用方按低频单独拉,
    /// 避免每轮刷新都 spawn 3 个 node 进程。失败时语义同 fetchQuota。
    public static func fetchUsageOnly(environment: [String: String]? = nil) async -> Result<UsageWindows, UsageError> {
        do {
            let data = try await callRPC(usageAPI, environment: environment)
            if let w = try? parseUsage(data) { return .success(w) }
            return .failure(.parse)
        } catch let e as UsageError {
            return .failure(e)
        } catch {
            return .failure(.unknown(error.localizedDescription))
        }
    }

    /// 只拉辅助数据(subscription + addon,2 个 RPC 并发)。
    /// 这两项一天内基本不变(套餐状态/加购包余额),适合 24h 低频拉取。
    public static func fetchAuxOnly(environment: [String: String]? = nil) async -> (subscription: SubscriptionDetail?, addon: AddonSummary?) {
        async let subRes = (try? await callRPC(subscriptionAPI, environment: environment)).flatMap { try? parseSubscription($0) }
        async let addonRes = (try? await callRPC(addonAPI, environment: environment)).flatMap { try? parseAddon($0) }
        return (await subRes, await addonRes)
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

    /// 数值字段宽容取值:缺失/null/非数字 → nil;JSON 数字(Int/Double)经 NSNumber 统一转换。
    func optionalDouble(_ key: String) -> Double? {
        (self[key] as? NSNumber)?.doubleValue
    }

    func optionalInt64(_ key: String) -> Int64? {
        (self[key] as? NSNumber)?.int64Value
    }
}

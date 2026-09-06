import Foundation

/// 数据层:shell out 调 bl console call,解析三层嵌套 JSON。
/// 唯一掌握 RPC 契约的文件,改动需配合同步更新 Verify fixture。
public final class BlUsageService {
    // 三个控制台私有 RPC(2026-08-01 Playwright 抓包 + bl 验证)
    public static let usageAPI = "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/usage"
    public static let subscriptionAPI = "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/subscription"
    public static let addonAPI = "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/addon/summary"

    // MARK: - DTO(P2-A1:三层嵌套 data.DataV2.data.data,宽容 Codable 解码)
    //
    // 语义与旧 [String:Any] 解析完全一致(Verify fixture 全量回归):
    // - usage 窗口字段缺失/null → 按 0(官方控制台同款,避免整次更新 .parse)
    // - subscription 三必填字段缺失 → throw(等价旧 value(as:) 的 BlValueMismatch)
    // - addon 全可选 → 缺失按 0

    // 嵌套层级(与旧 [String:Any] 完全一致):
    // root.data → .DataV2 → .data → .data(字段)
    private struct Envelope: Decodable {
        struct Level1: Decodable {
            struct Level2: Decodable {
                struct Level3: Decodable {
                    struct Payload: Decodable {
                        var per5HourPercentage: Double?
                        var per5HourResetTime: Int64?
                        var per1WeekPercentage: Double?
                        var per1WeekResetTime: Int64?
                        var specCode: String?
                        var status: String?
                        var remainingDays: Int64?
                        var startTime: Int64?
                        var endTime: Int64?
                        var autoRenewFlag: Bool?
                        var remainingCredits: Double?
                        var totalCredits: Double?
                        var activeCount: Int64?

                        enum CodingKeys: String, CodingKey {
                            case per5HourPercentage, per5HourResetTime
                            case per1WeekPercentage, per1WeekResetTime
                            case specCode, status, remainingDays
                            case startTime, endTime, autoRenewFlag
                            case remainingCredits, totalCredits, activeCount
                        }

                        // 手写解码:property wrapper 合成对缺失键会抛 keyNotFound,
                        // 这里逐字段 decodeIfPresent(缺失/null → nil;类型异常经宽容包装器 → nil)
                        init(from decoder: Decoder) throws {
                            let c = try decoder.container(keyedBy: CodingKeys.self)
                            per5HourPercentage = try c.decodeIfPresent(FlexibleDouble.self, forKey: .per5HourPercentage)?.wrappedValue
                            per5HourResetTime = try c.decodeIfPresent(FlexibleInt64.self, forKey: .per5HourResetTime)?.wrappedValue
                            per1WeekPercentage = try c.decodeIfPresent(FlexibleDouble.self, forKey: .per1WeekPercentage)?.wrappedValue
                            per1WeekResetTime = try c.decodeIfPresent(FlexibleInt64.self, forKey: .per1WeekResetTime)?.wrappedValue
                            specCode = try c.decodeIfPresent(String.self, forKey: .specCode)
                            status = try c.decodeIfPresent(String.self, forKey: .status)
                            remainingDays = try c.decodeIfPresent(FlexibleInt64.self, forKey: .remainingDays)?.wrappedValue
                            startTime = try c.decodeIfPresent(FlexibleInt64.self, forKey: .startTime)?.wrappedValue
                            endTime = try c.decodeIfPresent(FlexibleInt64.self, forKey: .endTime)?.wrappedValue
                            autoRenewFlag = try c.decodeIfPresent(FlexibleBool.self, forKey: .autoRenewFlag)?.wrappedValue
                            remainingCredits = try c.decodeIfPresent(FlexibleDouble.self, forKey: .remainingCredits)?.wrappedValue
                            totalCredits = try c.decodeIfPresent(FlexibleDouble.self, forKey: .totalCredits)?.wrappedValue
                            activeCount = try c.decodeIfPresent(FlexibleInt64.self, forKey: .activeCount)?.wrappedValue
                        }
                    }
                    var data: Payload?
                }
                var data: Level3?
            }
            var DataV2: Level2?
        }
        var data: Level1?
    }

    private struct BlEnvelopeError: Error {}

    private static func decodePayload(_ data: Data) throws -> Envelope.Level1.Level2.Level3.Payload {
        let env = try JSONDecoder().decode(Envelope.self, from: data)
        guard let payload = env.data?.DataV2?.data?.data else { throw BlEnvelopeError() }
        return payload
    }

    /// 解析 usage 响应。宽容解析:
    /// - 5h 两个字段均缺失/null → fiveHour == nil(2026-08-15 官方限时取消 5h 窗口后的
    ///   常态;也可能是窗口存在但零用量的旧空窗形态,两种对展示语义等价:隐藏 5h 统计);
    ///   任一字段存在 → 窗口有效,缺失侧按 0(零用量正常显示,不隐藏)。
    /// - 7d 字段缺失/null → 按 0(官方控制台同款,避免整次更新 .parse;
    ///   2026-08-03 事故根因)。
    public static func parseUsage(_ data: Data) throws -> UsageWindows {
        let p = try decodePayload(data)
        let fiveHour: UsageDetail? = (p.per5HourPercentage != nil || p.per5HourResetTime != nil)
            ? UsageDetail(percentageRaw: p.per5HourPercentage ?? 0,
                          resetTimeMs: p.per5HourResetTime ?? 0)
            : nil
        return UsageWindows(
            fiveHour: fiveHour,
            oneWeek: UsageDetail(
                percentageRaw: p.per1WeekPercentage ?? 0,
                resetTimeMs: p.per1WeekResetTime ?? 0
            )
        )
    }

    public static func parseSubscription(_ data: Data) throws -> SubscriptionDetail {
        let p = try decodePayload(data)
        guard let specCode = p.specCode, let status = p.status,
              let remainingDays = p.remainingDays else { throw BlEnvelopeError() }
        return SubscriptionDetail(
            specCode: specCode,
            status: status,
            remainingDays: Int(remainingDays),
            startTimeMs: p.startTime,
            endTimeMs: p.endTime,
            autoRenewFlag: p.autoRenewFlag ?? false
        )
    }

    public static func parseAddon(_ data: Data) throws -> AddonSummary {
        let p = try decodePayload(data)
        return AddonSummary(
            remainingCredits: p.remainingCredits ?? 0,
            totalCredits: p.totalCredits ?? 0,
            activeCount: Int(p.activeCount ?? 0)
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

}

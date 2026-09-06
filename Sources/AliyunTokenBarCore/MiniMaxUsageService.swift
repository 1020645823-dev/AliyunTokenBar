import Foundation

// MARK: - MiniMax Coding Plan 用量服务
//
// 数据源(Token Plan / Coding Plan 剩余额度,官方未在文档中心公开,端点对齐
// CodexBar MiniMaxUsageFetcher + minimax-status 两个生产实现):
//   GET https://api.minimaxi.com/v1/token_plan/remains                  国内(优先)
//   GET https://api.minimax.io/v1/token_plan/remains                    国际
//   GET https://www.minimaxi.com/v1/api/openplatform/coding_plan/remains 旧 web 端点
//   Authorization: Bearer <coding plan API key>
//   → base_resp.status_code(0=成功,1004=未登录)+ data.model_remains[]
//
// 三个 host 依次尝试:同一 key 只在其购买区域有效;全部失败时若任一 host
// 报鉴权错误则归为 authExpired(面板引导换 key),否则透传最后错误。
//
// ⚠️ 字段语义:model_remains 里的 `current_interval_usage_count` 等名义 usage
// 字段实际是**剩余**次数,`*_remaining_percent` 是剩余百分比(见 MiniMaxQuotaModel)。
public enum MiniMaxUsageService {
    /// 尝试顺序:国内 → 国际 → 旧 web 端点
    public static let remainsURLs: [URL] = [
        URL(string: "https://api.minimaxi.com/v1/token_plan/remains")!,
        URL(string: "https://api.minimax.io/v1/token_plan/remains")!,
        URL(string: "https://www.minimaxi.com/v1/api/openplatform/coding_plan/remains")!,
    ]

    public enum MiniMaxError: Error, Equatable {
        case authExpired
        /// Key 有效但账号当前无生效中的 Coding Plan 订阅(业务码 2062)
        case noSubscription
        case network(String)
        case parse
        case invalidResponse(String)
        case unknown(String)
    }

    // MARK: - 拉取

    public static func fetchQuota(apiKey: String) async -> Result<MiniMaxQuota, MiniMaxError> {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return .failure(.authExpired) }
        var sawAuthFailure = false
        var lastError = MiniMaxError.unknown("无可用端点")
        for url in remainsURLs {
            switch await fetchOnce(url: url, apiKey: key) {
            case .success(let quota):
                return .success(quota)
            case .failure(let e):
                lastError = e
                if e == .authExpired { sawAuthFailure = true }
            }
        }
        return .failure(sawAuthFailure ? .authExpired : lastError)
    }

    private static func fetchOnce(url: URL, apiKey: String) async -> Result<MiniMaxQuota, MiniMaxError> {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(.invalidResponse("非 HTTP 响应"))
            }
            switch http.statusCode {
            case 200:
                if let envelopeError = envelopeError(in: data) {
                    return .failure(envelopeError)
                }
                guard let quota = parseQuota(from: data) else {
                    return .failure(.parse)
                }
                return .success(quota)
            case 401, 403:
                return .failure(.authExpired)
            default:
                return .failure(.unknown("HTTP \(http.statusCode)"))
            }
        } catch {
            return .failure(.network(error.localizedDescription))
        }
    }

    /// 业务包络错误:base_resp.status_code ≠ 0(顶层或 data 内,两处都查)。
    /// 1004 / 消息含 cookie/login/登录 → authExpired;其余 → invalidResponse。
    public static func envelopeError(in data: Data) -> MiniMaxError? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let dataObj = obj["data"] as? [String: Any]
        let base = (obj["base_resp"] as? [String: Any]) ?? (dataObj?["base_resp"] as? [String: Any])
        guard let base else { return nil }
        let rawStatus = base["status_code"]
        let status = (rawStatus as? Int) ?? (rawStatus as? String).flatMap(Int.init)
        guard let status, status != 0 else { return nil }
        let msg = (base["status_msg"] as? String) ?? ""
        let lower = msg.lowercased()
        if status == 1004 || lower.contains("cookie") || lower.contains("login")
            || lower.contains("log in") || msg.contains("登录") {
            return .authExpired
        }
        // 实测(mmx 官方 CLI 同报):status=2062 no active token plan subscription
        if status == 2062 || lower.contains("no active token plan subscription") {
            return .noSubscription
        }
        return .invalidResponse("status=\(status) \(msg)".trimmingCharacters(in: .whitespaces))
    }

    // MARK: - 解析(纯函数,fixture 测试覆盖)

    /// epoch 秒/毫秒 → 统一 epoch 毫秒;非法(≤0/太小)返回 nil。(Verify 断言覆盖)
    public static func epochMs(_ v: Int64?) -> Int64? {
        guard let v, v > 0 else { return nil }
        if v > 1_000_000_000_000 { return v }
        if v > 1_000_000_000 { return v * 1000 }
        return nil
    }

    /// 重置时间:优先窗口 end_time(epoch);缺失时按 remains_time(毫秒/秒自适应)
    /// 从 now 起推算。(Verify 断言覆盖)
    public static func resetTimeMs(endTime: Int64?, remainsTime: Int64?, now: Date) -> Int64? {
        if let end = epochMs(endTime) { return end }
        guard let remains = remainsTime, remains > 0 else { return nil }
        let seconds = remains > 1_000_000 ? Double(remains) / 1000 : Double(remains)
        return Int64((now.timeIntervalSince1970 + seconds) * 1000)
    }

    /// 窗口已用百分比:优先 remaining_percent(0-100)反推;缺失按计数(字面语义:
    /// usage_count=已用)计算。
    static func usedPct(total: Int, used: Int, remainingPercent: Double?) -> Double {
        if let rp = remainingPercent {
            return max(0, min(100, 100 - rp))
        }
        guard total > 0 else { return 0 }
        return max(0, min(100, Double(used) / Double(total) * 100))
    }

    /// 计数口径解析(见 MiniMaxQuotaModel 头注释):percent 存在时按百分比反推
    /// 剩余数,规避 usage_count 的历史口径分歧;缺失时按字面语义(已用)。
    static func counts(total: Int, usageCount: Int, remainingPercent: Double?) -> (used: Int, remaining: Int) {
        guard total > 0 else { return (0, 0) }
        if let rp = remainingPercent {
            let remaining = Int((Double(total) * max(0, min(100, rp)) / 100).rounded())
            return (max(0, total - remaining), remaining)
        }
        let used = max(0, min(total, usageCount))
        return (used, total - used)
    }

    public static func parseQuota(from data: Data) -> MiniMaxQuota? {
        // CN api 端点:model_remains 直接挂根(2026-08-18 实测);
        // 旧 web 端点包在 data 里。两个形态都收(对齐 CodexBar 双形态处理)。
        struct Envelope: Decodable {
            let data: Payload

            enum CodingKeys: String, CodingKey { case data }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                if c.contains(.data) {
                    data = try c.decode(Payload.self, forKey: .data)
                } else {
                    data = try Payload(from: decoder)
                }
            }
        }
        struct Payload: Decodable {
            var currentSubscribeTitle: String?
            var planName: String?
            var comboTitle: String?
            var currentPlanTitle: String?
            var modelRemains: [ModelRemain]?
            // 积分余额字段名不稳,多个变体都收
            var pointsBalance: FlexibleDouble?

            enum CodingKeys: String, CodingKey {
                case currentSubscribeTitle = "current_subscribe_title"
                case planName = "plan_name"
                case comboTitle = "combo_title"
                case currentPlanTitle = "current_plan_title"
                case modelRemains = "model_remains"
                case pointsBalance = "points_balance"
                case pointBalance = "point_balance"
                case creditsBalance = "credits_balance"
                case creditBalance = "credit_balance"
                case balance
            }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                currentSubscribeTitle = try c.decodeIfPresent(String.self, forKey: .currentSubscribeTitle)
                planName = try c.decodeIfPresent(String.self, forKey: .planName)
                comboTitle = try c.decodeIfPresent(String.self, forKey: .comboTitle)
                currentPlanTitle = try c.decodeIfPresent(String.self, forKey: .currentPlanTitle)
                modelRemains = try c.decodeIfPresent([ModelRemain].self, forKey: .modelRemains)
                pointsBalance = (try? c.decodeIfPresent(FlexibleDouble.self, forKey: .pointsBalance))
                    ?? (try? c.decodeIfPresent(FlexibleDouble.self, forKey: .pointBalance))
                    ?? (try? c.decodeIfPresent(FlexibleDouble.self, forKey: .creditsBalance))
                    ?? (try? c.decodeIfPresent(FlexibleDouble.self, forKey: .creditBalance))
                    ?? (try? c.decodeIfPresent(FlexibleDouble.self, forKey: .balance))
            }
        }
        struct ModelRemain: Decodable {
            var modelName: String?
            var intervalTotal: FlexibleInt64?
            var intervalRemaining: FlexibleInt64?
            var intervalRemainingPercent: FlexibleDouble?
            var startTime: FlexibleInt64?
            var endTime: FlexibleInt64?
            var remainsTime: FlexibleInt64?
            var weeklyTotal: FlexibleInt64?
            var weeklyRemaining: FlexibleInt64?
            var weeklyRemainingPercent: FlexibleDouble?
            var weeklyEndTime: FlexibleInt64?
            var weeklyRemainsTime: FlexibleInt64?

            enum CodingKeys: String, CodingKey {
                case modelName = "model_name"
                case intervalTotal = "current_interval_total_count"
                case intervalRemaining = "current_interval_usage_count"
                case intervalRemainingPercent = "current_interval_remaining_percent"
                case startTime = "start_time"
                case endTime = "end_time"
                case remainsTime = "remains_time"
                case weeklyTotal = "current_weekly_total_count"
                case weeklyRemaining = "current_weekly_usage_count"
                case weeklyRemainingPercent = "current_weekly_remaining_percent"
                case weeklyEndTime = "weekly_end_time"
                case weeklyRemainsTime = "weekly_remains_time"
            }
        }

        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              let models = envelope.data.modelRemains,
              let first = models.first else { return nil }
        let payload = envelope.data
        let now = Date()

        func window(total: Int, usageCount: Int, remainingPercent: Double?,
                    endTime: Int64?, remainsTime: Int64?) -> MiniMaxWindow? {
            // 纯百分比窗口(total=0,如 general 无限次套餐)只看 remaining_percent;
            // 两种信息都没有才算窗口缺失。
            guard total > 0 || remainingPercent != nil else { return nil }
            let counts = counts(total: total, usageCount: usageCount, remainingPercent: remainingPercent)
            return MiniMaxWindow(pct: usedPct(total: total, used: counts.used,
                                              remainingPercent: remainingPercent),
                                 used: counts.used, total: total, remaining: counts.remaining,
                                 resetTimeMs: resetTimeMs(endTime: endTime,
                                                          remainsTime: remainsTime, now: now))
        }

        func modelQuota(_ m: ModelRemain) -> MiniMaxModelQuota {
            MiniMaxModelQuota(
                name: m.modelName ?? "",
                interval: window(total: Int(m.intervalTotal?.wrappedValue ?? 0),
                                 usageCount: Int(m.intervalRemaining?.wrappedValue ?? 0),
                                 remainingPercent: m.intervalRemainingPercent?.wrappedValue,
                                 endTime: m.endTime?.wrappedValue,
                                 remainsTime: m.remainsTime?.wrappedValue),
                weekly: window(total: Int(m.weeklyTotal?.wrappedValue ?? 0),
                               usageCount: Int(m.weeklyRemaining?.wrappedValue ?? 0),
                               remainingPercent: m.weeklyRemainingPercent?.wrappedValue,
                               endTime: m.weeklyEndTime?.wrappedValue,
                               remainsTime: m.weeklyRemainsTime?.wrappedValue))
        }

        // 主条目:优先 "general"(套餐总额度);没有时退回首条。
        let primaryIndex = models.firstIndex { ($0.modelName ?? "").lowercased() == "general" } ?? 0
        let primary = models[primaryIndex]
        let primaryQuota = modelQuota(primary)
        let others = models.enumerated()
            .filter { $0.offset != primaryIndex }
            .map { modelQuota($0.element) }

        let planName = [payload.currentSubscribeTitle, payload.planName,
                        payload.comboTitle, payload.currentPlanTitle]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }

        return MiniMaxQuota(planName: planName,
                            pointsBalance: payload.pointsBalance?.wrappedValue,
                            modelName: primary.modelName,
                            interval: primaryQuota.interval,
                            weekly: primaryQuota.weekly,
                            models: others)
    }
}

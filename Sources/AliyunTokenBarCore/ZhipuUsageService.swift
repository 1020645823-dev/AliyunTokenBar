import Foundation

/// 数据层:智谱 GLM Coding Plan 用量(open.bigmodel.cn monitor API)。
///
/// 端点与解析对齐两个生产实现:智谱官方插件(zai-org/zai-coding-plugins 的
/// query-usage.mjs)与 CodexBar(ZaiUsageStats.swift):
///   GET https://open.bigmodel.cn/api/monitor/usage/quota/limit
///   Authorization: Bearer <coding-plan API key>
///   → data.limits[](TOKENS_LIMIT×N + TIME_LIMIT)+ data.level
///
/// 凭证(优先级):Keychain(设置页粘贴,见 TokenPlanModel.zhipuAPIKey)
/// → 自动发现 opencode 配置(~/.config/opencode/opencode.json 的
///   provider.zhipuai-coding-plan.options.apiKey,Kimi 范式:每次现读,不复制存储)。
///
/// 团队版需 Bigmodel-Organization/Bigmodel-Project 请求头,当前仅支持个人版。
public enum ZhipuUsageService {
    static let quotaURL = URL(string: "https://open.bigmodel.cn/api/monitor/usage/quota/limit")!

    /// opencode 全局配置路径(自动发现 Coding Plan key)。
    public static let opencodeConfigURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/opencode/opencode.json")

    public enum ZhipuError: Error, Equatable {
        case authExpired
        case network(String)
        case parse
        case invalidResponse(String)
        case unknown(String)
    }

    // MARK: - 凭证发现

    /// 自动发现的 key 与时间(5s TTL:配置文件变化后免重启生效,同时避免每次
    /// SwiftUI 渲染都重读解析整个 opencode.json)。
    private static var cachedKey: String?
    private static var cachedKeyAt: Date = .distantPast
    private static let cacheTTL: TimeInterval = 5

    /// 从 opencode 配置发现 Coding Plan API key;未配置返回 nil。
    public static func discoveredAPIKey() -> String? {
        // 多线程读静态缓存足够安全(同值幂等);不做精细同步。
        if Date().timeIntervalSince(cachedKeyAt) < cacheTTL {
            return cachedKey
        }
        let key = readOpencodeKey()
        cachedKey = key
        cachedKeyAt = Date()
        return key
    }

    private static func readOpencodeKey() -> String? {
        guard let data = try? Data(contentsOf: opencodeConfigURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let providers = obj["provider"] as? [String: Any] else { return nil }
        for id in ["zhipuai-coding-plan", "glm_coding", "zhipuai"] {
            if let options = (providers[id] as? [String: Any])?["options"] as? [String: Any],
               let key = options["apiKey"] as? String,
               !key.trimmingCharacters(in: .whitespaces).isEmpty {
                return key
            }
        }
        return nil
    }

    // MARK: - 拉取

    public static func fetchQuota(apiKey: String) async -> Result<ZhipuQuota, ZhipuError> {
        var request = URLRequest(url: quotaURL)
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
                // 业务错误走 HTTP 200 包络(如 code 1001 未带 Authorization)。
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

    /// 解析业务包络:success=false 时把 code/msg 归类(鉴权类 → authExpired)。
    public static func envelopeError(in data: Data) -> ZhipuError? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let success = obj["success"] as? Bool, !success else { return nil }
        let code = obj["code"] as? Int ?? -1
        let msg = obj["msg"] as? String ?? ""
        if code == 1001 || msg.contains("Authorization") || msg.contains("身份验证")
            || msg.contains("令牌") || msg.contains("API Key") {
            return .authExpired
        }
        return .invalidResponse("code=\(code) \(msg)")
    }

    // MARK: - 解析(纯函数,Verify 断言覆盖)

    /// limits 窗口时长(分钟)。unit 枚举对齐 CodexBar ZaiLimitUnit:
    /// 1=天, 3=小时, 5=分钟(TIME_LIMIT 月度配额复用此值,按 type 区分), 6=周。
    public static func windowMinutes(unit: Int, number: Int) -> Int? {
        guard number > 0 else { return nil }
        switch unit {
        case 1: return number * 24 * 60
        case 3: return number * 60
        case 5: return number
        case 6: return number * 7 * 24 * 60
        default: return nil
        }
    }

    public static func parseQuota(from data: Data) -> ZhipuQuota? {
        struct Envelope: Decodable {
            let code: Int?
            let success: Bool?
            let data: Payload?
        }
        struct Payload: Decodable {
            let limits: [Limit]?
            // CN 实测返回 level;z.ai 国际版见过 planName/plan 变体,一并收集。
            let level: String?
            let planName: String?
            let plan: String?
        }
        struct Limit: Decodable {
            let type: String?
            let unit: Int?
            let number: Int?
            let usage: Int?
            let currentValue: Int?
            let remaining: Int?
            let percentage: Double?
            let nextResetTime: Int64?
            let usageDetails: [Detail]?
        }
        struct Detail: Decodable {
            let modelCode: String?
            let usage: Int?
        }

        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.success == true, envelope.code == 200,
              let payload = envelope.data else { return nil }

        var tokenLimits: [(Limit, Int)] = []   // (limit, windowMinutes)
        var timeLimit: Limit?
        for limit in payload.limits ?? [] {
            guard let type = limit.type else { continue }
            let minutes = windowMinutes(unit: limit.unit ?? 0, number: limit.number ?? 0)
            if type == "TOKENS_LIMIT" {
                tokenLimits.append((limit, minutes ?? .max))
            } else if type == "TIME_LIMIT" {
                timeLimit = limit
            }
        }
        // 多条 TOKENS_LIMIT:最短窗口 = 5h,最长 = 周(CodexBar 同规则)。
        tokenLimits.sort { $0.1 < $1.1 }
        func window(_ limit: Limit) -> ZhipuWindow {
            ZhipuWindow(pct: limit.percentage ?? 0, resetTimeMs: limit.nextResetTime)
        }
        var fiveHour: ZhipuWindow?
        var weekly: ZhipuWindow?
        if tokenLimits.count >= 2 {
            fiveHour = window(tokenLimits.first!.0)
            weekly = window(tokenLimits.last!.0)
        } else if let only = tokenLimits.first {
            // 单条时按窗口时长归位(<24h 归 5h,否则归周)。
            if only.1 < 24 * 60 { fiveHour = window(only.0) } else { weekly = window(only.0) }
        }

        let mcp: ZhipuMCPQuota?
        if let t = timeLimit {
            mcp = ZhipuMCPQuota(
                usage: t.usage,
                currentValue: t.currentValue,
                remaining: t.remaining,
                percentage: t.percentage ?? 0,
                resetTimeMs: t.nextResetTime,
                details: (t.usageDetails ?? []).compactMap { d in
                    guard let code = d.modelCode, let usage = d.usage else { return nil }
                    return ZhipuMCPQuota.Detail(modelCode: code, usage: usage)
                })
        } else {
            mcp = nil
        }

        let level = [payload.level, payload.planName, payload.plan]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        return ZhipuQuota(fiveHour: fiveHour, weekly: weekly, mcp: mcp, level: level)
    }
}

import Foundation

/// 数据层:Ollama Cloud 用量(ollama.com 私有 JSON 端点)。
///
///   GET  https://ollama.com/api/usage?range=30d   Authorization: Bearer <API Key>
///   POST https://ollama.com/api/me                同一 Key → 套餐档位(Plan)
///   POST http://127.0.0.1:11434/api/me           本机 daemon,免凭据 → 档位兜底
///
/// ⚠️ 官方未收录进 OpenAPI 规格,但维护者 rick-github 在 ollama/ollama#17451
/// 公开指引 `curl -H "Authorization: $OLLAMA_API_KEY" https://ollama.com/api/usage`,
/// 属"未文档化但被默许"。
///
/// ⚠️ 2026-10-09 结构变更(实测):旧 `limits.{monthly,session,weekly}.usage`
/// (0-1 小数)已消失,改为按天用量报表(totals + buckets,美元消费);
/// `range` 仅接受 24h/7d/30d,`granularity` 参数会 400。新响应不含任何
/// 额度字段,月度额度由套餐档位推导(见 OllamaPlan.monthlyCapUSD)。
///
/// 认证:用户在 https://ollama.com/settings/keys 创建 API Key 后粘贴(不过期,可吊销)。
/// ⚠️ 本机 `~/.ollama/id_ed25519`(CLI 注册表凭据)会被云端端点 401 拒绝,不能复用;
/// 该私钥只用于本机 daemon 的 /api/me 签名。
public enum OllamaUsageService {
    /// 云端用量端点。range=30d:拿满 30 个日桶,才能与"月度额度"同口径对比
    /// (默认 7d 只覆盖一周,会把月度占比严重低估)。
    public static let usageURL = URL(string: "https://ollama.com/api/usage?range=30d")!
    /// 远程 whoami:与 usage 同一 Host、同一 Key,返回账户信息(含 Plan)。
    /// GET 会 405,必须 POST。
    public static let remoteMeURL = URL(string: "https://ollama.com/api/me")!
    /// 本机 daemon 的 whoami(daemon 用 id_ed25519 自行签名,调用方无需凭据)。
    /// 仅作档位兜底;daemon 未运行时静默降级(plan = nil)。
    public static let localMeURL = URL(string: "http://127.0.0.1:11434/api/me")!
    static let requestTimeout: TimeInterval = 20
    /// daemon 本地调用超时(未装 Ollama 时连接会被立即拒绝,给 3s 足够)。
    static let localTimeout: TimeInterval = 3

    public enum OllamaError: Error, Equatable {
        /// 401/403:API Key 无效或已吊销
        case authExpired
        /// 429:被限流(用量耗尽时 chat 侧也是 429,此处按限流归类)
        case rateLimited
        case network(String)
        case parse(String)
        case invalidResponse(String)
        case unknown(String)
    }

    // MARK: - 拉取

    /// 拉取用量 + 探测套餐档位。plan 失败不影响用量结果(可选增强)。
    public static func fetchQuota(apiKey: String) async -> Result<OllamaQuota, OllamaError> {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return .failure(.authExpired) }

        // 并行:云端用量(必需)+ 档位(远程优先,本机 daemon 兜底)
        async let usageTask = fetchUsageData(apiKey: key)
        async let planTask = fetchPlan(apiKey: key)

        let usageResult = await usageTask
        let plan = await planTask

        switch usageResult {
        case .failure(let e):
            return .failure(e)
        case .success(let data):
            guard let quota = parseQuota(from: data, plan: plan) else {
                return .failure(.parse("usage 响应无 totals(结构可能已变更)"))
            }
            return .success(quota)
        }
    }

    private static func fetchUsageData(apiKey: String) async -> Result<Data, OllamaError> {
        var request = URLRequest(url: usageURL)
        request.httpMethod = "GET"
        request.timeoutInterval = requestTimeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(.invalidResponse("非 HTTP 响应"))
            }
            if let classified = classifyHTTP(http.statusCode) {
                return .failure(classified)
            }
            return .success(data)
        } catch {
            return .failure(.network(error.localizedDescription))
        }
    }

    /// 套餐档位探测:远程 /api/me(权威,需 Key)→ 本机 daemon /api/me(免凭据兜底)。
    /// 两者都失败返回 nil —— 此时无月度额度,UI 走绝对金额形态。
    public static func fetchPlan(apiKey: String) async -> String? {
        if let remote = await fetchRemotePlan(apiKey: apiKey) { return remote }
        return await fetchLocalPlan()
    }

    /// 远程 whoami:POST /api/me + Bearer Key → {"Plan":"max", ...}。
    /// 只取档位,不记录 Email/ID 等账户信息(隐私红线)。
    public static func fetchRemotePlan(apiKey: String) async -> String? {
        var request = URLRequest(url: remoteMeURL)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        return decodePlan(from: data)
    }

    /// 本机 daemon 的 plan 探测:任何失败(未装/未启/未登录)都静默返回 nil。
    public static func fetchLocalPlan() async -> String? {
        var request = URLRequest(url: localMeURL)
        request.httpMethod = "POST"
        request.timeoutInterval = localTimeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        return decodePlan(from: data)
    }

    /// /api/me 响应 → 档位。远程返回 "Plan"、本机 daemon 返回 "plan",
    /// 两个 key 都试(纯函数,Verify 断言覆盖)。
    public static func decodePlan(from data: Data) -> String? {
        struct AnyKeys: CodingKey {
            let stringValue: String
            var intValue: Int? { nil }
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { return nil }
        }
        struct Me: Decodable {
            let plan: String?
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: AnyKeys.self)
                plan = (try? c.decode(String.self, forKey: AnyKeys(stringValue: "Plan")!))
                    ?? (try? c.decode(String.self, forKey: AnyKeys(stringValue: "plan")!))
            }
        }
        return (try? JSONDecoder().decode(Me.self, from: data))?.plan
    }

    /// HTTP 状态 → 错误分类(纯函数,Verify 断言覆盖)。
    /// 2xx → nil;401/403 → authExpired;429 → rateLimited;其余 unknown。
    public static func classifyHTTP(_ statusCode: Int) -> OllamaError? {
        switch statusCode {
        case 200...299: return nil
        case 401, 403: return .authExpired
        case 429: return .rateLimited
        default: return .unknown("HTTP \(statusCode)")
        }
    }

    // MARK: - 解析(纯函数,fixture 测试覆盖)

    /// /api/usage 响应(2026-10-09 新结构)→ 用量快照。
    /// 成功条件:totals.usage_usd 存在(消费额是核心字段,缺了就无法展示);
    /// 日桶缺失时按"无 7 天汇总"处理,不失败。plan 由调用方探测后注入。
    public static func parseQuota(from data: Data, plan: String? = nil) -> OllamaQuota? {
        struct Response: Decodable {
            let totals: Totals?
            let buckets: [Bucket]?
        }
        struct Totals: Decodable {
            var requestCount: FlexibleInt64?
            var usageUSD: FlexibleDouble?
            enum CodingKeys: String, CodingKey {
                case requestCount = "request_count"
                case usageUSD = "usage_usd"
            }
        }
        struct Bucket: Decodable {
            var usageUSD: FlexibleDouble?
            enum CodingKeys: String, CodingKey {
                case usageUSD = "usage_usd"
            }
        }

        guard let response = try? JSONDecoder().decode(Response.self, from: data),
              let spent = response.totals?.usageUSD?.wrappedValue else { return nil }

        let requests = Int(response.totals?.requestCount?.wrappedValue ?? 0)
        let daily = (response.buckets ?? []).compactMap { $0.usageUSD?.wrappedValue }
        // 近 7 天 = 日桶尾部 7 个(末桶可能是当日部分);桶不足则全部累加。
        let spent7d = daily.suffix(7).reduce(0, +)

        return OllamaQuota(spentUSD30d: spent,
                           requests30d: requests,
                           spentUSD7d: spent7d,
                           dailyUSD: daily,
                           capUSD: OllamaPlan.monthlyCapUSD(plan: plan),
                           plan: plan)
    }
}

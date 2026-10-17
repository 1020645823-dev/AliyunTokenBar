import Foundation

/// 数据层:阶跃星辰 StepFun Step Plan 用量(platform.stepfun.com 控制台 RPC)。
///
///   POST https://platform.stepfun.com/api/step.openapi.devcenter.Dashboard/QueryStepPlanRateLimit
///   Oasis-Token: <控制台登录态>        ← 不是 API Key!Step Plan API Key 只能调模型
///   Oasis-AppID: 10300 / Oasis-Platform: web / Origin/Referer: platform.stepfun.com
///   body {}
///
/// 端点与响应形状对齐 codex-switcher v0.7.19 的生产实现(官方未公开文档,
/// 2026-10-02 实测匿名探测:401 + {"code":"unauthenticated"})。响应三种形状
/// 依次尝试:credit_buckets(计数)→ 纯 rate 兜底 → 旧 5h/周窗口,见 StepFunQuotaModel。
///
/// ⚠️ `*_rate` 字段是剩余(left)百分比;本 App 口径统一为已用,解析层反推。
/// ⚠️ 时间戳秒/毫秒双形态(>20e9 视为毫秒)。
public enum StepFunUsageService {
    public static let rateLimitURL = URL(
        string: "https://platform.stepfun.com/api/step.openapi.devcenter.Dashboard/QueryStepPlanRateLimit")!
    static let requestTimeout: TimeInterval = 20

    public enum StepFunError: Error, Equatable {
        /// 401 / unauthenticated:控制台登录态缺失、非法或已过期 → 引导重新登录
        case authExpired
        /// permission_denied(如 "api key not permitted for this method"):
        /// 用户贴了 API Key/OAuth token 等错误类型的凭证,不是 Oasis-Token
        case tokenNotPermitted
        case network(String)
        /// 解析失败(附响应片段,便于定口径;不含敏感值)
        case parse(String)
        case invalidResponse(String)
        case unknown(String)
    }

    /// 账户中心「账号绑定」RPC——取账户绑定的手机号(2026-10-15 实勘):
    /// `POST /api/user/proto.api.user.v1.UserService/GetAccountBinding`,
    /// 头 `Oasis-appID: 10300`/`Oasis-Platform: web`,body `{}`。
    /// 与额度 RPC 不同域(account.stepfun.com 账户中心,platform 不代理 /api/user);
    /// CORS 预检放行 `oasis-token`/`oasis-webid` 头且 allow-origin:*——平台会话页
    /// 可**跨域**直接调用(token 走请求头,不需要 Cookie,无 CSP 拦截)。
    ///
    /// ⚠️ **鉴权组合实勘定论**(2026-10-15 curl 矩阵,一次成功):
    /// - `Oasis-Token` 与 `Oasis-Webid` **同取 platform.stepfun.com 域的同一对
    ///   cookie**:token 用 cookie 原值(SPA 持续轮换的那对,请求前即时读取保新鲜),
    ///   Webid 用该 cookie 里 device JWT 的 `device_id`(StepFunUsageService.deviceID);
    /// - 账户中心校验「token 的设备 == Webid 头」,错配即 `CODE_TOKEN_ILLEGAL`
    ///   "device is not matching"(缺 Webid 头同样报错);account 域的旧对设备不同,必败;
    /// - 两者就位 → 200。响应**服务端已掩码**:`mobile.number="186****6010"`
    ///   (只取尾4位,见 phoneTail(fromBindingJSON:))。
    public static let accountBindingURL = URL(
        string: "https://account.stepfun.com/api/user/proto.api.user.v1.UserService/GetAccountBinding")!

    /// 页面内拉取结果(会话通道三态,2026-10-09):
    /// - `json`:会话页在平台域且 fetch 返回了响应文本(可能含错误包络,由调用方分类);
    /// - `pageNotReady`:页面还在导航/加载(软状态,稍后自动重试,不计鉴权失败);
    /// - `sessionExpired`:页面被踢到登录域(account.stepfun.com)——会话已死。
    ///   ⚠️ 与 pageNotReady 混同会导致「永远加载中」:既不触发重载自愈,
    ///   也不给用户重登入口(会话失效时 SPA 会重定向到登录页)。
    public enum StepFunFetchOutcome: Equatable {
        case json(String)
        case pageNotReady
        case sessionExpired
    }

    // MARK: - 凭据归一化(纯函数,fixture 测试覆盖)

    /// 用户输入 → Oasis-Token 裸值。接受三种粘贴形态:
    /// 裸 token / `Oasis-Token=xxx` / 含它的整段 Cookie header(含 `Cookie:` 前缀)。
    /// 取值时剥外层引号;无法识别返回 nil。
    public static func normalizedToken(from raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        if let idx = lower.range(of: "cookie:") {
            text = String(text[idx.upperBound...])
        } else if let idx = lower.range(of: "oasis-token:") {
            text = String(text[idx.upperBound...])
        }
        if let line = text.split(separator: "\n", omittingEmptySubsequences: true).first {
            text = String(line)
        }
        text = text.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "'\"`\\"))
        for pair in text.split(separator: ";") {
            guard let eq = pair.firstIndex(of: "=") else { continue }
            let name = pair[..<eq].trimmingCharacters(in: .whitespaces)
            guard name.caseInsensitiveCompare("Oasis-Token") == .orderedSame else { continue }
            let value = pair[pair.index(after: eq)...]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            if !value.isEmpty { return value }
        }
        // 无 '=' 视为裸 token(值里含 '=' 的裸 token 也不会走到这里:无分号无等号才可能)
        if !text.isEmpty && !text.contains("=") {
            return text
        }
        return nil
    }

    // MARK: - 归一化纯函数(Verify 断言覆盖)

    /// 时间戳 → 统一 epoch 毫秒:>20e9 视为毫秒原样;>1e9 视为秒 ×1000;
    /// 其余(≤0/异常小)返回 nil。
    public static func epochMs(_ v: Int64?) -> Int64? {
        guard let v, v > 0 else { return nil }
        if v > 20_000_000_000 { return v }
        if v > 1_000_000_000 { return v * 1000 }
        return nil
    }

    /// 剩余 rate(left,0-1 小数或 0-100)→ 已用百分比 0-100。
    /// ≤1 按 0-1 小数(codex-switcher 口径);NaN/非有限 → nil。
    public static func leftRateToUsedPct(_ v: Double?) -> Double? {
        guard let v, v.isFinite else { return nil }
        let left = v <= 1 ? v * 100 : v
        return max(0, min(100, 100 - left))
    }

    /// 桶计数(total/residual)→ 已用百分比;total≤0 返回 nil。
    public static func bucketUsedPct(total: Double, residual: Double) -> Double? {
        guard total > 0, residual.isFinite else { return nil }
        let left = max(0, min(100, residual / total * 100))
        return 100 - left
    }

    /// 鉴权失败重试冷却(MiMo 同款保守档位:15/30/60/120 分钟封顶)。
    /// 登录态过期属于「用户不处理不会自愈」,按正常间隔轮询纯属无效请求。
    public static func authRetryCooldownSeconds(consecutiveFailures: Int) -> TimeInterval {
        let tiers: [TimeInterval] = [15 * 60, 30 * 60, 60 * 60, 120 * 60]
        guard consecutiveFailures > 0 else { return 0 }
        let idx = min(consecutiveFailures, tiers.count) - 1
        return tiers[idx]
    }

    // MARK: - 拉取

    /// 拉取 Step Plan 额度。
    /// - Parameters:
    ///   - webId: 平台 web_id(登录窗从 localStorage 抓取;SPA 同款 `Oasis-Webid` 请求头,可缺省)。
    ///   - onRotatedToken: 会话为**滚动轮换**凭据(access...refresh 对,服务端可在响应里
    ///     Set-Cookie 下发新对);捕获到新 Oasis-Token 时回调,调用方应持久化以便下次使用。
    public static func fetchQuota(consoleToken: String, webId: String? = nil,
                                  onRotatedToken: ((String) -> Void)? = nil) async -> Result<StepFunQuota, StepFunError> {
        let token = consoleToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return .failure(.authExpired) }
        var request = URLRequest(url: rateLimitURL)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(token, forHTTPHeaderField: "Oasis-Token")
        if let webId, !webId.isEmpty {
            request.setValue(webId, forHTTPHeaderField: "Oasis-Webid")
        }
        request.setValue("10300", forHTTPHeaderField: "Oasis-appID")
        request.setValue("web", forHTTPHeaderField: "Oasis-Platform")
        request.setValue("https://platform.stepfun.com", forHTTPHeaderField: "Origin")
        request.setValue("https://platform.stepfun.com/plan-subscribe", forHTTPHeaderField: "Referer")
        request.httpBody = Data("{}".utf8)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(.invalidResponse("非 HTTP 响应"))
            }
            if let rotated = rotatedToken(from: http), rotated != token {
                onRotatedToken?(rotated)
            }
            if let classified = classifyHTTP(statusCode: http.statusCode, data: data) {
                return .failure(classified)
            }
            guard let quota = parseQuota(from: data) else {
                return .failure(.parse("响应无可识别额度字段: \(snippet(data))"))
            }
            return .success(quota)
        } catch {
            return .failure(.network(error.localizedDescription))
        }
    }

    /// 响应 Set-Cookie → 新 Oasis-Token(滚动轮换)。
    /// ⚠️ 用 `HTTPCookie.cookies(withResponseHeaderFields:)` 解析,不能用
    /// `allHeaderFields` 字符串切分(重复 Set-Cookie 会被折叠,值内含逗号会错切)。
    public static func rotatedToken(from response: HTTPURLResponse) -> String? {
        guard let headers = response.allHeaderFields as? [String: String] else { return nil }
        let url = response.url ?? rateLimitURL
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: headers, for: url)
        guard let cookie = cookies.first(where: {
            $0.name.caseInsensitiveCompare("Oasis-Token") == .orderedSame
        }) else { return nil }
        let value = cookie.value.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        return value.isEmpty ? nil : value
    }

    /// Oasis-Token cookie 值 → oasis_id(账户身份,用于多账户去重)。
    /// cookie 值是「access...refresh」两段 JWT 拼接(实测可能以字面 "..." 分隔):
    /// 按 "." 切段,逐段试解 payload(header/signature 解不出 JSON 或没有
    /// oasis_id 字段,自然跳过);oasis_id 可能是数字或字符串。
    public static func oasisID(fromCookieValue raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "'\"` "))
        guard !text.isEmpty else { return nil }
        for segment in text.split(separator: ".", omittingEmptySubsequences: true) {
            guard segment.hasPrefix("eyJ") else { continue }
            var b64 = String(segment)
                .replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
            let pad = b64.count % 4
            if pad > 0 { b64 += String(repeating: "=", count: 4 - pad) }
            guard let data = Data(base64Encoded: b64),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let s = obj["oasis_id"] as? String, !s.isEmpty { return s }
            if let n = obj["oasis_id"] as? NSNumber { return n.stringValue }
        }
        return nil
    }

    /// Oasis-Token cookie 值 → 设备标识(device JWT 段的 `device_id`)。
    /// 账户中心 RPC 的 `Oasis-Webid` 头要用它(与 oasisID 同款逐段试解;
    /// 取不到返回 nil)。cookie 值是「access...refresh」两段 JWT 拼接。
    public static func deviceID(fromCookieValue raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "'\"` "))
        guard !text.isEmpty else { return nil }
        for segment in text.split(separator: ".", omittingEmptySubsequences: true) {
            guard segment.hasPrefix("eyJ") else { continue }
            var b64 = String(segment)
                .replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
            let pad = b64.count % 4
            if pad > 0 { b64 += String(repeating: "=", count: 4 - pad) }
            guard let data = Data(base64Encoded: b64),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let s = obj["device_id"] as? String, !s.isEmpty { return s }
        }
        return nil
    }

    /// GetAccountBinding 响应(Connect JSON)→ 手机号尾4位(纯函数,Verify 断言覆盖)。
    /// 形状:`{"binding":{"mobile":{"cc":"86","number":"186****6010"}}}`——
    /// **服务端返回的就是掩码号**(前3+****+后4;客户端打码是历史行为,两种都收):
    /// 剥非数字后 ≥7 位(11 位全号或 3+4 掩码)才取尾4。
    /// 未绑手机、错误包络、形状不符 → nil(展示层回落 oasis_id)。
    public static func phoneTail(fromBindingJSON raw: String) -> String? {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["code"] as? String == nil,               // 错误包络(unauthenticated 等)
              let binding = obj["binding"] as? [String: Any],
              let mobile = binding["mobile"] as? [String: Any] else { return nil }
        guard let number = (mobile["number"] as? String)
                ?? (mobile["number"] as? NSNumber)?.stringValue else { return nil }
        let digits = number.filter { $0.isNumber }
        guard digits.count >= 7 else { return nil }
        return String(digits.suffix(4))
    }

    /// HTTP 状态 + 业务包络 → 错误分类(纯函数,Verify 断言覆盖)。
    /// 成功(2xx 且包络无错)返回 nil。
    public static func classifyHTTP(statusCode: Int, data: Data) -> StepFunError? {        if let envelope = classifyEnvelope(data: data) {
            // 200 也可能带错误包络;401+unauthenticated 与非 401 的包络错误统一归包络语义
            return envelope
        }
        switch statusCode {
        case 200...299: return nil
        case 401, 403: return .authExpired
        default: return .unknown("HTTP \(statusCode)")
        }
    }

    /// JSON 业务包络:{"code":"unauthenticated","message":...}(2026-10-02 实测形状)。
    public static func classifyEnvelope(data: Data) -> StepFunError? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = obj["code"] as? String else { return nil }
        switch code {
        case "unauthenticated":
            // "token is missing" / "token is illegal" / 会话过期,均为「需重新登录」
            return .authExpired
        case "permission_denied":
            // 实测:贴 API Key/OAuth token 会被网关当 api key → "api key not permitted for this method"
            return .tokenNotPermitted
        default:
            let message = (obj["message"] as? String) ?? ""
            return .invalidResponse("code=\(code) \(message)".trimmingCharacters(in: .whitespaces))
        }
    }

    // MARK: - 解析(纯函数,fixture 测试覆盖)

    public static func parseQuota(from data: Data) -> StepFunQuota? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let pcl = field(obj, "plan_credit_rate_limit", "planCreditRateLimit")

        // ① credit_buckets(计数形状,现行主路径)
        var subscription: StepFunCreditBucket?
        var topupAggregated: StepFunCreditBucket?
        var topupTotal = 0.0, topupResidual = 0.0
        var sawTopup = false
        var topupReset: Int64?
        if let buckets = bucketsField(pcl) {
            for bucket in buckets {
                let total = number(bucket, "credit_total", "creditTotal") ?? 0
                let residual = number(bucket, "credit_residual", "creditResidual") ?? 0
                let reset = epochMs(int64(bucket, "next_reset_at", "nextResetAt")
                                        ?? int64(bucket, "expire_at", "expireAt"))
                guard let pct = bucketUsedPct(total: total, residual: residual) else { continue }
                let isTopup = isTopupBucket(bucket)
                if isTopup {
                    sawTopup = true
                    topupTotal += total
                    topupResidual += residual
                    if let reset, topupReset == nil || reset < topupReset! { topupReset = reset }
                } else if subscription == nil {
                    subscription = StepFunCreditBucket(total: total, residual: residual,
                                                       usedPct: pct, resetTimeMs: reset)
                }
            }
            if sawTopup {
                let pct = bucketUsedPct(total: topupTotal, residual: topupResidual) ?? 0
                topupAggregated = StepFunCreditBucket(total: topupTotal, residual: topupResidual,
                                                      usedPct: pct, resetTimeMs: topupReset)
            }
        }
        // ② 纯 rate 兜底形状(无 buckets 或 buckets 无计数时)
        if subscription == nil,
           let subRate = number(pcl, "subscription_credit_left_rate", "subscriptionCreditLeftRate"),
           let usedPct = leftRateToUsedPct(subRate) {
            let reset = epochMs(int64(pcl, "subscription_credit_reset_time", "subscriptionCreditResetTime"))
            subscription = StepFunCreditBucket(total: 0, residual: 0, usedPct: usedPct, resetTimeMs: reset)
            if topupAggregated == nil,
               let topRate = number(pcl, "topup_credit_left_rate", "topupCreditLeftRate"),
               let topPct = leftRateToUsedPct(topRate) {
                topupAggregated = StepFunCreditBucket(total: 0, residual: 0, usedPct: topPct, resetTimeMs: nil)
            }
        }
        // ③ 旧计费:根级 5h/周双窗口。**仅当没有任何 Credit 桶时才解析**——
        // 新计费(月池)响应里这些 proto3 遗留字段会以零值下发(实测 2026-10-02:
        // left_rate=0 且无重置时间),把「剩余 0」误读成「已用 100%」会凭空吓人。
        let hasCreditBuckets = subscription != nil || topupAggregated != nil
        let fiveHour: StepFunRateWindow?
        let weekly: StepFunRateWindow?
        if !hasCreditBuckets {
            if let r = leftRateToUsedPct(number(obj, "five_hour_usage_left_rate", "fiveHourUsageLeftRate")) {
                fiveHour = StepFunRateWindow(usedPct: r,
                                             resetTimeMs: epochMs(int64(obj, "five_hour_usage_reset_time", "fiveHourUsageResetTime")))
            } else {
                fiveHour = nil
            }
            if let r = leftRateToUsedPct(number(obj, "weekly_usage_left_rate", "weeklyUsageLeftRate")) {
                weekly = StepFunRateWindow(usedPct: r,
                                           resetTimeMs: epochMs(int64(obj, "weekly_usage_reset_time", "weeklyUsageResetTime")))
            } else {
                weekly = nil
            }
        } else {
            fiveHour = nil
            weekly = nil
        }

        guard subscription != nil || topupAggregated != nil || fiveHour != nil || weekly != nil else {
            return nil
        }
        return StepFunQuota(subscription: subscription, topup: topupAggregated,
                            fiveHour: fiveHour, weekly: weekly)
    }

    // MARK: - 取数辅助(宽容:snake/camel 双键名;数字/数字字符串)

    static func field(_ obj: [String: Any]?, _ snake: String, _ camel: String) -> [String: Any]? {
        guard let obj else { return nil }
        return (obj[snake] as? [String: Any]) ?? (obj[camel] as? [String: Any])
    }

    /// 数组字段(snake/camel 双键名)。
    static func bucketsField(_ obj: [String: Any]?) -> [[String: Any]]? {
        guard let obj else { return nil }
        return (obj["credit_buckets"] as? [[String: Any]]) ?? (obj["creditBuckets"] as? [[String: Any]])
    }

    static func number(_ obj: [String: Any]?, _ snake: String, _ camel: String) -> Double? {
        guard let obj else { return nil }
        for key in [snake, camel] {
            if let v = obj[key] as? Double { return v }
            if let v = obj[key] as? Int { return Double(v) }
            if let v = obj[key] as? NSNumber { return v.doubleValue }
            if let v = obj[key] as? String, let d = Double(v) { return d }
        }
        return nil
    }

    static func int64(_ obj: [String: Any]?, _ snake: String, _ camel: String) -> Int64? {
        guard let v = number(obj, snake, camel) else { return nil }
        guard v.isFinite else { return nil }
        return Int64(v.rounded())
    }

    /// 桶 type 判定:字符串含 "TOPUP"(如 CREDIT_BUCKET_TYPE_TOPUP)或字面 "2"/数字 2 → 加油包。
    static func isTopupBucket(_ bucket: [String: Any]) -> Bool {
        if let s = bucket["type"] as? String {
            return s.uppercased().contains("TOPUP") || s == "2"
        }
        if let i = bucket["type"] as? Int {
            return i == 2
        }
        return false
    }

    /// 响应片段(诊断用,截 120 字符)。
    static func snippet(_ data: Data) -> String {
        let s = String(data: data.prefix(120), encoding: .utf8) ?? "(非 UTF-8)"
        return s.replacingOccurrences(of: "\n", with: " ")
    }
}

import Foundation

// MARK: - 小米 MiMo 开放平台余额服务
//
// 数据源:platform.xiaomimimo.com Web 控制台私有 API(Cookie 认证,官方未公开文档):
//   GET https://platform.xiaomimimo.com/api/v1/balance           总余额(现金/赠送拆分)
//   GET https://platform.xiaomimimo.com/api/v1/tokenPlan/detail  套餐码/周期结束/是否过期
//   GET https://platform.xiaomimimo.com/api/v1/tokenPlan/usage   套餐月度 token 用量
//
// 端点/字段/错误码对齐 CodexBar(MiMoUsageFetcher.swift)与 cc-switch 社区实践;
// 官方未公开文档,响应结构可能随平台改版变化——解析层宽容 + Verify fixture 锁契约。
//
// 认证:浏览器登录 platform.xiaomimimo.com 后整段复制 `Cookie:` 请求头;
// 必需 cookie:api-platform_serviceToken + userId。会话过期(30x 登录重定向/401)
// 与凭据无效(403)分开归类,面板据此引导重登。
public enum MiMoUsageService {
    public static let apiBase = URL(string: "https://platform.xiaomimimo.com/api/v1")!
    static let requestTimeout: TimeInterval = 20

    public enum MiMoError: Error, Equatable {
        /// 粘贴内容缺少必需 cookie(api-platform_serviceToken / userId)
        case invalidCookie
        /// 会话过期(30x 登录重定向 / 401 / 业务 code 401),需重新登录复制
        case loginRequired
        /// 403:账号无权访问控制台 API
        case invalidCredentials
        case network(String)
        case parse(String)
        case unknown(String)
    }

    /// 账户余额。金额字段为字符串,宽容数值化(FlexibleDouble);币种如 "CNY"。
    public struct MiMoBalance: Equatable {
        /// 总余额(现金 + 赠送)
        public let balance: Double
        public let currency: String
        /// 现金(充值)余额
        public let cashBalance: Double?
        /// 赠送余额
        public let giftBalance: Double?

        public init(balance: Double, currency: String, cashBalance: Double?, giftBalance: Double?) {
            self.balance = balance
            self.currency = currency
            self.cashBalance = cashBalance
            self.giftBalance = giftBalance
        }
    }

    /// Token 套餐月度用量(未购套餐/接口不返回时为 nil)。
    public struct MiMoTokenPlan: Equatable {
        /// 套餐码(如 "standard");接口不给时为 nil
        public let planCode: String?
        /// 当前周期结束时间(UTC "yyyy-MM-dd HH:mm:ss");解析失败为 nil
        public let periodEnd: Date?
        public let expired: Bool
        public let used: Int
        public let limit: Int
        /// 已用百分比 0-100(服务端 percent 为 0-1 小数;缺失按 used/limit 计算)
        public let usedPct: Double

        public init(planCode: String?, periodEnd: Date?, expired: Bool,
                    used: Int, limit: Int, usedPct: Double) {
            self.planCode = planCode
            self.periodEnd = periodEnd
            self.expired = expired
            self.used = used
            self.limit = limit
            self.usedPct = usedPct
        }
    }

    /// 一次拉取的汇总快照(余额必有;套餐任一接口可用即有)。
    public struct MiMoUsage: Equatable {
        public let balance: MiMoBalance
        public let plan: MiMoTokenPlan?

        public init(balance: MiMoBalance, plan: MiMoTokenPlan?) {
            self.balance = balance
            self.plan = plan
        }
    }

    // MARK: - Cookie 规范化(纯函数,Verify 断言覆盖)

    /// 整段 Cookie 请求头 → 规范 Cookie 值。容忍 "Cookie:" 前缀与多余空白;
    /// 缺 api-platform_serviceToken 或 userId 返回 nil(引导用户重抄)。
    public static func normalizedCookie(from raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["Cookie:", "cookie:"] where value.hasPrefix(prefix) {
            value = String(value.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        guard !value.isEmpty else { return nil }
        let lower = value.lowercased()
        guard lower.contains("api-platform_servicetoken="), lower.contains("userid=") else {
            return nil
        }
        return value
    }

    // MARK: - 拉取

    /// 拉取余额 + 套餐用量。balance 为必需(失败即整体失败);
    /// tokenPlan/detail 与 tokenPlan/usage 为增强信息,失败静默降级(与 CodexBar 一致)。
    public static func fetchUsage(cookieHeader: String) async -> Result<MiMoUsage, MiMoError> {
        guard let cookie = normalizedCookie(from: cookieHeader) else {
            return .failure(.invalidCookie)
        }
        async let balanceTask = fetchAuthenticated(path: "balance", cookie: cookie)
        async let detailTask = fetchAuthenticated(path: "tokenPlan/detail", cookie: cookie)
        async let usageTask = fetchAuthenticated(path: "tokenPlan/usage", cookie: cookie)

        let balanceResult = await balanceTask
        let detailData = successData(await detailTask)
        let usageData = successData(await usageTask)

        switch balanceResult {
        case .failure(let e):
            return .failure(e)
        case .success(let data):
            guard let balance = parseBalance(from: data) else {
                return .failure(.parse("balance 响应无法解析"))
            }
            let detail = detailData.flatMap(parsePlanDetail(from:))
            let usage = usageData.flatMap(parsePlanUsage(from:))
            let plan: MiMoTokenPlan?
            if let detail, let usage {
                plan = MiMoTokenPlan(planCode: detail.planCode, periodEnd: detail.periodEnd,
                                     expired: detail.expired, used: usage.used,
                                     limit: usage.limit, usedPct: usage.usedPct)
            } else if let usage {
                plan = MiMoTokenPlan(planCode: nil, periodEnd: nil, expired: false,
                                     used: usage.used, limit: usage.limit, usedPct: usage.usedPct)
            } else if let detail {
                plan = MiMoTokenPlan(planCode: detail.planCode, periodEnd: detail.periodEnd,
                                     expired: detail.expired, used: 0, limit: 0, usedPct: 0)
            } else {
                plan = nil
            }
            return .success(MiMoUsage(balance: balance, plan: plan))
        }
    }

    private static func successData(_ result: Result<Data, MiMoError>) -> Data? {
        if case .success(let data) = result { return data }
        return nil
    }

    private static func fetchAuthenticated(path: String, cookie: String) async -> Result<Data, MiMoError> {
        var request = URLRequest(url: apiBase.appendingPathComponent(path))
        request.httpMethod = "GET"
        request.timeoutInterval = requestTimeout
        // 模拟浏览器控制台请求:不带这组头会被 WAF/登录拦截(对齐 CodexBar)
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("en-CN,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("https://platform.xiaomimimo.com", forHTTPHeaderField: "Origin")
        request.setValue("https://platform.xiaomimimo.com/#/console/balance", forHTTPHeaderField: "Referer")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(.unknown("非 HTTP 响应"))
            }
            if let classified = classifyHTTP(http.statusCode) {
                return .failure(classified)
            }
            return .success(data)
        } catch {
            return .failure(.network(error.localizedDescription))
        }
    }

    /// HTTP 状态 → 错误分类(纯函数,Verify 断言覆盖)。
    /// 2xx → nil;3xx(登录重定向)/401 → loginRequired;403 → invalidCredentials。
    public static func classifyHTTP(_ statusCode: Int) -> MiMoError? {
        switch statusCode {
        case 200...299: return nil
        case 300..<400, 401: return .loginRequired
        case 403: return .invalidCredentials
        default: return .unknown("HTTP \(statusCode)")
        }
    }

    /// 业务包络 code → 错误分类(纯函数)。0 → nil(成功);401 → loginRequired;
    /// 403 → invalidCredentials;其他非 0 → parse(附 code/message)。
    public static func classifyEnvelope(code: Int, message: String?) -> MiMoError? {
        switch code {
        case 0: return nil
        case 401: return .loginRequired
        case 403: return .invalidCredentials
        default: return .parse("code=\(code)\(message.map { " \($0)" } ?? "")")
        }
    }

    // MARK: - 解析(纯函数,fixture 测试覆盖)

    /// /balance 响应 → 余额。金额字符串/数字均可;currency 缺失视为解析失败。
    public static func parseBalance(from data: Data) -> MiMoBalance? {
        struct Envelope: Decodable {
            let code: Int?
            let data: Payload?
        }
        struct Payload: Decodable {
            var balance: FlexibleDouble?
            var currency: String?
            var cashBalance: FlexibleDouble?
            var giftBalance: FlexibleDouble?
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.code == 0, let payload = envelope.data else { return nil }
        guard let value = payload.balance?.wrappedValue,
              let currency = payload.currency?.trimmingCharacters(in: .whitespacesAndNewlines),
              !currency.isEmpty else { return nil }
        return MiMoBalance(balance: value, currency: currency,
                           cashBalance: payload.cashBalance?.wrappedValue,
                           giftBalance: payload.giftBalance?.wrappedValue)
    }

    /// /tokenPlan/detail 响应 → 套餐信息;code≠0/无 data/字段全缺 → nil(降级)。
    public static func parsePlanDetail(from data: Data) -> MiMoTokenPlan? {
        struct Envelope: Decodable {
            let code: Int?
            let data: Payload?
        }
        struct Payload: Decodable {
            var planCode: String?
            var currentPeriodEnd: String?
            var expired: FlexibleBool?
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.code == 0, let payload = envelope.data else { return nil }
        // 周期结束时间为 UTC(对齐 CodexBar:GMT formatter)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return MiMoTokenPlan(planCode: payload.planCode,
                             periodEnd: payload.currentPeriodEnd.flatMap(formatter.date(from:)),
                             expired: payload.expired?.wrappedValue ?? false,
                             used: 0, limit: 0, usedPct: 0)
    }

    /// /tokenPlan/usage 响应 → (used, limit, usedPct);取 monthUsage.items 首条。
    /// 服务端 percent 为 0-1 小数(CodexBar ×100 同规则);缺失时按 used/limit 计算。
    public static func parsePlanUsage(from data: Data) -> (used: Int, limit: Int, usedPct: Double)? {
        struct Envelope: Decodable {
            let code: Int?
            let data: Payload?
        }
        struct Payload: Decodable {
            var monthUsage: MonthUsage?
        }
        struct MonthUsage: Decodable {
            var percent: FlexibleDouble?
            var items: [Item]?
        }
        struct Item: Decodable {
            var name: String?
            var used: FlexibleInt64?
            var limit: FlexibleInt64?
            var percent: FlexibleDouble?
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.code == 0,
              let item = envelope.data?.monthUsage?.items?.first else { return nil }
        let used = Int(item.used?.wrappedValue ?? 0)
        let limit = Int(item.limit?.wrappedValue ?? 0)
        let pct: Double
        if let fraction = item.percent?.wrappedValue {
            pct = max(0, min(100, fraction * 100))
        } else if limit > 0 {
            pct = max(0, min(100, Double(used) / Double(limit) * 100))
        } else {
            pct = 0
        }
        return (used, limit, pct)
    }
}

// MARK: - 金额格式化(面板完整格式;币种跟随接口)

public enum MiMoMoneyFormat {
    /// 币种符号:CNY → ¥,USD → $;未知币种回退 ISO 代码前缀。
    public static func symbol(for currency: String) -> String {
        switch currency.uppercased() {
        case "CNY": return "¥"
        case "USD": return "$"
        default: return currency.uppercased() + " "
        }
    }

    /// 面板完整格式:恒两位小数("¥110.50")。
    public static func full(_ v: Double, currency: String) -> String {
        symbol(for: currency) + String(format: "%.2f", max(0, v))
    }

    /// 紧凑格式(档位规则与 DeepSeekMoneyFormat.compact 一致):
    /// <100 两位小数;<1万 整数;≥1万 "x.x万";≥1亿 "x.x亿"。
    public static func compact(_ v: Double, currency: String) -> String {
        let x = max(0, v)
        let s = symbol(for: currency)
        if x >= 100_000_000 { return s + String(format: "%.1f亿", x / 100_000_000) }
        if x >= 10_000 { return s + String(format: "%.1f万", x / 10_000) }
        if x >= 100 { return s + String(format: "%.0f", x) }
        return s + String(format: "%.2f", x)
    }
}

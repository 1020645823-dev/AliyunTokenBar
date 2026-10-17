import Foundation

// MARK: - 小米 MiMo 开放平台余额服务
//
// 数据源:platform.xiaomimimo.com Web 控制台私有 API(Cookie 认证,官方未公开文档):
//   GET https://platform.xiaomimimo.com/api/v1/balance           总余额(现金/赠送拆分)
//   GET https://platform.xiaomimimo.com/api/v1/tokenPlan/detail  套餐码/周期结束/是否过期
//   GET https://platform.xiaomimimo.com/api/v1/tokenPlan/usage   套餐月度用量(**Credits**)
//   GET https://platform.xiaomimimo.com/api/v1/tokenPlan/list    套餐目录(单位与额度权威来源)
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
    public struct MiMoBalance: Equatable, Codable, Sendable {
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

    /// ⚠️ **单位是 Credits,不是 tokens**(2026-09-25 由 `/tokenPlan/list` 确证:
    /// `standard` → `tokenQuotaCn = "110 亿 Credits"` = 11,000,000,000,与 API 返回的
    /// `limit` 完全吻合;lite=41 亿 / pro=380 亿 / max=820 亿)。
    /// API 的**字段名**叫 `*_token`、但**单位**是 Credits —— 字段命名不等于单位规格,
    /// 且响应里没有任何单位字段,必须对照套餐目录。
    /// 参考比值(控制台套餐页文案):1 token = 2 Credits。百分比不受单位影响。
    public static let planQuotaUnit = "Credits"

    /// Token 套餐月度用量(未购套餐/接口不返回时为 nil)。
    /// `used` / `limit` / `usedPct` 的量纲见 `planQuotaUnit`(**Credits**)。
    public struct MiMoTokenPlan: Equatable, Codable, Sendable {
        /// 套餐码(如 "standard");接口不给时为 nil
        public let planCode: String?
        /// 当前周期结束时间(UTC "yyyy-MM-dd HH:mm:ss");解析失败为 nil
        public let periodEnd: Date?
        /// 是否已过期。**三态**:接口未下发 → nil(未知,不得默认"未过期")
        public let expired: Bool?
        /// 已用量,单位见 `planQuotaUnit`(**Credits**)
        public let used: Int
        /// 套餐总量,单位见 `planQuotaUnit`(**Credits**)
        public let limit: Int
        /// 已用百分比 0-100(服务端 percent 为 0-1 小数;缺失按 used/limit 计算;与单位无关)
        public let usedPct: Double

        public init(planCode: String?, periodEnd: Date?, expired: Bool?,
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
    public struct MiMoUsage: Equatable, Codable, Sendable {
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
    /// tokenPlan/detail 与 tokenPlan/usage 为增强信息,**非鉴权类**失败静默降级(与 CodexBar 一致);
    /// **鉴权类**失败(会话过期 / 无权访问)必须整体暴露——否则面板会把"登录过期"
    /// 显示成"暂无用量数据",用户无从知道该重登。
    public static func fetchUsage(cookieHeader: String) async -> Result<MiMoUsage, MiMoError> {
        guard let cookie = normalizedCookie(from: cookieHeader) else {
            return .failure(.invalidCookie)
        }
        async let balanceTask = fetchAuthenticated(path: "balance", cookie: cookie)
        async let detailTask = fetchAuthenticated(path: "tokenPlan/detail", cookie: cookie)
        async let usageTask = fetchAuthenticated(path: "tokenPlan/usage", cookie: cookie)

        return combine(balance: await balanceTask, detail: await detailTask, usage: await usageTask)
    }

    /// 三端点结果归并(纯函数,Verify 覆盖):
    /// 1) balance 是必需项,它的错误(含网络/解析)优先暴露;
    /// 2) plan 端点的**鉴权类**错误必须整体暴露,不得被静默降级;
    /// 3) plan 端点的非鉴权失败(网络抖动 / 无套餐 404)静默降级为 plan=nil,余额照常展示。
    public static func combine(balance: Result<Data, MiMoError>,
                               detail: Result<Data, MiMoError>,
                               usage: Result<Data, MiMoError>) -> Result<MiMoUsage, MiMoError> {
        if case .failure(let e) = balance { return .failure(e) }
        if let e = authFailure(in: detail) ?? authFailure(in: usage) { return .failure(e) }

        guard let balanceData = successData(balance), let balance = parseBalance(from: balanceData) else {
            return .failure(.parse("balance 响应无法解析"))
        }
        let detailInfo = successData(detail).flatMap(parsePlanDetail(from:))
        let usageInfo = successData(usage).flatMap(parsePlanUsage(from:))
        let plan: MiMoTokenPlan?
        if let detailInfo, let usageInfo {
            plan = MiMoTokenPlan(planCode: detailInfo.planCode, periodEnd: detailInfo.periodEnd,
                                 expired: detailInfo.expired, used: usageInfo.used,
                                 limit: usageInfo.limit, usedPct: usageInfo.usedPct)
        } else if let usageInfo {
            plan = MiMoTokenPlan(planCode: nil, periodEnd: nil, expired: nil,
                                 used: usageInfo.used, limit: usageInfo.limit, usedPct: usageInfo.usedPct)
        } else if let detailInfo {
            plan = MiMoTokenPlan(planCode: detailInfo.planCode, periodEnd: detailInfo.periodEnd,
                                 expired: detailInfo.expired, used: 0, limit: 0, usedPct: 0)
        } else {
            plan = nil
        }
        return .success(MiMoUsage(balance: balance, plan: plan))
    }

    /// 只把"用户必须处理"的鉴权类错误视为致命;网络/解析失败仍走静默降级。
    private static func authFailure(in result: Result<Data, MiMoError>) -> MiMoError? {
        guard case .failure(let e) = result else { return nil }
        switch e {
        case .loginRequired, .invalidCredentials, .invalidCookie: return e
        case .network, .parse, .unknown: return nil
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
            // HTTP 2xx 但业务包络 code≠0(平台可用 200 + code:401 表达会话过期)
            if let envelope = envelopeError(from: data) {
                return .failure(envelope)
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

    /// 2xx 响应体的业务包络判定(纯函数)。平台可能以 **HTTP 200 + `{"code":401,…}`**
    /// 表达会话过期——只看 HTTP 状态会把它误判成解析失败。
    /// 无 `code` 字段视为通过(nil),保持宽容。
    public static func envelopeError(from data: Data) -> MiMoError? {
        struct Envelope: Decodable {
            let code: Int?
            let message: String?
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              let code = envelope.code else { return nil }
        return classifyEnvelope(code: code, message: envelope.message)
    }

    /// 鉴权失败后的重试冷却秒数(纯函数):15 → 30 → 60 分钟,第 4 次起 120 分钟封顶。
    ///
    /// ⚠️ 真机实测(2026-09-25):小米 SSO 对**密集自动尝试会软拒绝**——即使 `passToken` 有效,
    /// 连续请求也会退化成"跳登录页",静置后才恢复。所以这里必须足够保守:首档 5 分钟太短,
    /// 会一边被拒绝一边把软拒绝窗口续上,等于**自锁**。会话过期本就只能靠用户重登或静置恢复,
    /// 高频重试没有收益。
    /// (用户重登/保存新 Cookie 会经 `mimoJar.didSet` 立即清掉冷却,不会让用户干等。)
    public static func authRetryCooldownSeconds(consecutiveFailures n: Int) -> TimeInterval {
        guard n > 0 else { return 0 }
        let steps: [TimeInterval] = [900, 1800, 3600]
        return n <= steps.count ? steps[n - 1] : 7200
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
                             expired: payload.expired?.wrappedValue,
                             used: 0, limit: 0, usedPct: 0)
    }

    /// /tokenPlan/usage 响应 → (used, limit, usedPct),量纲为 **Credits**(见 `planQuotaUnit`)。
    /// 多 item 时选**主窗口**(见 `primaryItem`)。
    /// 服务端 percent 为 0-1 小数(CodexBar ×100 同规则);
    /// 取值优先级:item.percent → 外层 monthUsage.percent → used/limit。
    public static func parsePlanUsage(from data: Data) -> (used: Int, limit: Int, usedPct: Double)? {
        guard let envelope = try? JSONDecoder().decode(UsageEnvelope.self, from: data),
              envelope.code == 0,
              let month = envelope.data?.monthUsage,
              let items = month.items, !items.isEmpty,
              let item = primaryItem(items) else { return nil }
        let used = Int(item.used?.wrappedValue ?? 0)
        let limit = Int(item.limit?.wrappedValue ?? 0)
        let pct: Double
        if let fraction = item.percent?.wrappedValue ?? month.percent?.wrappedValue {
            pct = max(0, min(100, fraction * 100))
        } else if limit > 0 {
            pct = max(0, min(100, Double(used) / Double(limit) * 100))
        } else {
            pct = 0
        }
        return (used, limit, pct)
    }

    /// 多 item 归一:优先 `limit` 最大者,`limit` 全为 0 时退化为 `percent` 最大者。
    /// 服务端可能同时下发多个专项条目,原 `items.first` 口径武断(与 MiniMax 的
    /// general/video 多窗口同源问题)。
    static func primaryItem(_ items: [MiMoUsageItem]) -> MiMoUsageItem? {
        items.max { lhs, rhs in
            let l = (Int(lhs.limit?.wrappedValue ?? 0), lhs.percent?.wrappedValue ?? 0)
            let r = (Int(rhs.limit?.wrappedValue ?? 0), rhs.percent?.wrappedValue ?? 0)
            return l < r
        }
    }
}

// MARK: - /tokenPlan/usage 解码模型(file scope:供 primaryItem 复用)

private struct UsageEnvelope: Decodable {
    let code: Int?
    let data: Payload?
    struct Payload: Decodable { var monthUsage: MonthUsage? }
    struct MonthUsage: Decodable {
        var percent: FlexibleDouble?
        var items: [MiMoUsageItem]?
    }
}

struct MiMoUsageItem: Decodable {
    var name: String?
    var used: FlexibleInt64?
    var limit: FlexibleInt64?
    var percent: FlexibleDouble?
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
        symbol(for: currency) + compactDigits(v)
    }

    /// 菜单栏数字部分(compact 去币种符号;迷你表格金额列值域与百分比列统一 34pt,契约 ≤5 字符)。
    /// 档位与进位保护同 DeepSeekMoneyFormat.compactDigits。币种歧义由列图标+面板兜底(菜单栏金额列只有两列)。
    public static func compactDigits(_ v: Double) -> String {
        let x = max(0, v)
        if x >= 100_000_000 {
            let y = x / 100_000_000
            return y >= 10 ? String(format: "%.0f亿", y) : String(format: "%.1f亿", y)
        }
        if x >= 10_000 {
            let y = x / 10_000
            return y >= 100 ? String(format: "%.0f万", y) : String(format: "%.1f万", y)
        }
        if x >= 100 { return String(format: "%.0f", x) }
        let s = String(format: "%.2f", x)
        return s.count <= 5 ? s : String(format: "%.0f", x)
    }
}

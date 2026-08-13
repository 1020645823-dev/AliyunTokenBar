import Foundation

/// 数据层:Kimi Code 官方 REST API(api.kimi.com/coding/v1/usages)。
/// 凭证复用本机 KimiCodeBar / Kimi CLI 的 OAuth token(不复制存储,每次读文件)。
/// 对齐 KimiCodeBar 参考实现:usage=t周窗口,limits[0](duration=300)=5h,totalQuota=月度总额。
public enum KimiUsageService {
    // MARK: - 常量

    /// OAuth client_id(Kimi Code CLI 与 KimiCodeBar 共用)
    static let clientID = "17e5f671-d194-4dfb-9706-5516cb48c098"
    static let tokenURL = URL(string: "https://auth.kimi.com/api/oauth/token")!
    static let usageURL = URL(string: "https://api.kimi.com/coding/v1/usages")!

    // MARK: Web 控制台(月度总额度数据源)
    /// Web 控制台 API 需要独立的 web JWT(www.kimi.com 登录),与 coding OAuth token 不同。
    /// - 刷新:POST auth.kimi.com/api/account.gateway.v1.AuthService/RefreshToken
    /// - 用量:POST www.kimi.com/apiv2/kimi.gateway.billing.v1.BillingService/GetUsages
    /// - 订阅:POST www.kimi.com/apiv2/kimi.gateway.membership.v2.MembershipService/GetSubscriptionStats
    static let webRefreshURL = URL(string: "https://auth.kimi.com/api/account.gateway.v1.AuthService/RefreshToken")!
    static let webUsagesURL = URL(string: "https://www.kimi.com/apiv2/kimi.gateway.billing.v1.BillingService/GetUsages")!
    static let webStatsURL = URL(string: "https://www.kimi.com/apiv2/kimi.gateway.membership.v2.MembershipService/GetSubscriptionStats")!
    /// Keychain 中 web JWT 的 account 名(存 JSON 字符串)
    public static let webTokenAccount = "kimi-web-token"

    /// KimiCodeBar 凭证路径(优先,其自动刷新 access_token)
    static let kimiCodeBarCredentialsURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/KimiCodeBar/credentials.json")
    /// Kimi CLI 凭证路径(fallback)
    static let kimiCliCredentialsURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".kimi/credentials/kimi-code.json")

    // MARK: - Token

    /// 解析出的 OAuth token(kimi-code scope)。
    public struct KimiToken: Equatable {
        public let accessToken: String
        public let refreshToken: String
        /// 过期时间(epoch 秒)
        public let expiresAt: TimeInterval
        public init(accessToken: String, refreshToken: String, expiresAt: TimeInterval) {
            self.accessToken = accessToken
            self.refreshToken = refreshToken
            self.expiresAt = expiresAt
        }
        /// 是否未过期(留 5 分钟余量)
        public var isValid: Bool { expiresAt > Date().timeIntervalSince1970 + 300 }
    }

    /// 读本机 Kimi 凭证:优先 KimiCodeBar(自动刷新,更新鲜),其次 Kimi CLI。
    public static func loadToken() -> KimiToken? {
        if let t = readKimiCodeBarToken() { return t }
        return readKimiCliToken()
    }

    /// 凭证是否存在于本机(设置页状态显示用)。
    public static func tokenExists() -> Bool {
        FileManager.default.fileExists(atPath: kimiCodeBarCredentialsURL.path)
            || FileManager.default.fileExists(atPath: kimiCliCredentialsURL.path)
    }

    /// KimiCodeBar:credentials.json 的 accounts[0].credential.oauth._0
    private static func readKimiCodeBarToken() -> KimiToken? {
        guard let data = try? Data(contentsOf: kimiCodeBarCredentialsURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accounts = root["accounts"] as? [[String: Any]],
              let first = accounts.first,
              let cred = first["credential"] as? [String: Any],
              let oauth = cred["oauth"] as? [String: Any],
              let zero = oauth["_0"] as? [String: Any] else { return nil }
        return makeToken(from: zero)
    }

    /// Kimi CLI:~/.kimi/credentials/kimi-code.json(扁平结构)
    private static func readKimiCliToken() -> KimiToken? {
        guard let data = try? Data(contentsOf: kimiCliCredentialsURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return makeToken(from: root)
    }

    private static func makeToken(from dict: [String: Any]) -> KimiToken? {
        guard let access = dict["access_token"] as? String, !access.isEmpty,
              let refresh = dict["refresh_token"] as? String, !refresh.isEmpty else { return nil }
        let expires: TimeInterval
        if let raw = dict["expires_at"] as? Double {
            expires = raw
        } else if let raw = dict["expires_at"] as? Int {
            expires = TimeInterval(raw)
        } else {
            expires = 0  // 未知过期时间 → 视为需刷新
        }
        return KimiToken(accessToken: access, refreshToken: refresh, expiresAt: expires)
    }

    /// 用 refresh_token 换新 token,并写回原凭证文件(让 KimiCodeBar/CLI 也能用新 token)。
    /// 返回新 token;失败返回 nil。
    public static func refreshToken(_ refreshToken: String) async -> KimiToken? {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = "client_id=\(clientID)&grant_type=refresh_token&refresh_token=\(refreshToken)"
        request.httpBody = body.data(using: .utf8)
        request.timeoutInterval = 30

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let access = root["access_token"] as? String, !access.isEmpty,
                  let refresh = root["refresh_token"] as? String, !refresh.isEmpty else { return nil }
            let expires: TimeInterval
            if let e = root["expires_at"] as? Double {
                expires = e
            } else if let e = root["expires_at"] as? Int {
                expires = TimeInterval(e)
            } else if let e = root["expires_in"] as? Double {
                expires = Date().timeIntervalSince1970 + e
            } else if let e = root["expires_in"] as? Int {
                expires = Date().timeIntervalSince1970 + TimeInterval(e)
            } else {
                expires = 0
            }
            let token = KimiToken(accessToken: access, refreshToken: refresh, expiresAt: expires)
            persistToken(token)
            return token
        } catch {
            return nil
        }
    }

    /// 把刷新后的 token 写回原文件(优先写回 KimiCodeBar 的 credentials.json,其次是 Kimi CLI)。
    private static func persistToken(_ token: KimiToken) {
        if FileManager.default.fileExists(atPath: kimiCodeBarCredentialsURL.path) {
            writeKimiCodeBarToken(token)
        } else if FileManager.default.fileExists(atPath: kimiCliCredentialsURL.path) {
            writeKimiCliToken(token)
        }
    }

    private static func writeKimiCodeBarToken(_ token: KimiToken) {
        guard let data = try? Data(contentsOf: kimiCodeBarCredentialsURL),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var accounts = root["accounts"] as? [[String: Any]],
              accounts.count > 0,
              var cred = accounts[0]["credential"] as? [String: Any],
              var oauth = cred["oauth"] as? [String: Any],
              var zero = oauth["_0"] as? [String: Any] else { return }
        zero["access_token"] = token.accessToken
        zero["refresh_token"] = token.refreshToken
        zero["expires_at"] = token.expiresAt
        oauth["_0"] = zero
        cred["oauth"] = oauth
        accounts[0]["credential"] = cred
        root["accounts"] = accounts
        if let out = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) {
            atomicReplaceWrite(out, to: kimiCodeBarCredentialsURL)
        }
    }

    private static func writeKimiCliToken(_ token: KimiToken) {
        guard let data = try? Data(contentsOf: kimiCliCredentialsURL),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        root["access_token"] = token.accessToken
        root["refresh_token"] = token.refreshToken
        root["expires_at"] = token.expiresAt
        if let out = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) {
            atomicReplaceWrite(out, to: kimiCliCredentialsURL)
        }
    }

    /// P1-D5:外部凭据文件回写保护——先备份旧文件(.bak),再经临时文件原子替换。
    /// 与 KimiCodeBar/CLI 并发写时保证文件永不出现在写一半的状态;失败只记日志,
    /// 不影响本 App 自身的拉取(下一轮重新读旧 token 并再试刷新)。
    private static func atomicReplaceWrite(_ data: Data, to url: URL) {
        do {
            let dir = url.deletingLastPathComponent()
            let tmp = dir.appendingPathComponent(".(url.lastPathComponent).tmp-(UUID().uuidString)")
            try data.write(to: tmp, options: .atomic)
            let bak = dir.appendingPathComponent(url.lastPathComponent + ".bak")
            if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: bak)
                try? FileManager.default.copyItem(at: url, to: bak)
            }
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp, backupItemName: nil, options: [])
        } catch {
            AppLog.warning("Kimi 凭据回写失败(不影响本 App 拉取): (error.localizedDescription)", category: .kimi)
        }
    }

    // MARK: - Web 控制台 token(月度总额度数据源)

    /// Web 控制台 JWT(www.kimi.com 登录获取,与 coding OAuth token 不同)。
    public struct KimiWebToken: Equatable {
        public let accessToken: String
        public let refreshToken: String
        /// 过期时间(epoch 秒);未知为 0
        public let expiresAt: TimeInterval
        public init(accessToken: String, refreshToken: String, expiresAt: TimeInterval) {
            self.accessToken = accessToken
            self.refreshToken = refreshToken
            self.expiresAt = expiresAt
        }
        public var isValid: Bool { expiresAt > Date().timeIntervalSince1970 + 300 }
    }

    /// 从 Keychain 读 web JWT(JSON 字符串)。
    public static func loadWebToken() -> KimiWebToken? {
        guard let store = KeychainCredentialStore(service: "com.aliyuntokenbar").read(account: webTokenAccount),
              let data = store.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = root["accessToken"] as? String, !access.isEmpty,
              let refresh = root["refreshToken"] as? String, !refresh.isEmpty else { return nil }
        let expires = (root["expiresAt"] as? Double) ?? (root["expiresAt"] as? Int).map(TimeInterval.init) ?? 0
        return KimiWebToken(accessToken: access, refreshToken: refresh, expiresAt: expires)
    }

    /// 保存 web JWT 到 Keychain。
    public static func saveWebToken(_ token: KimiWebToken) {
        let dict: [String: Any] = [
            "accessToken": token.accessToken,
            "refreshToken": token.refreshToken,
            "expiresAt": token.expiresAt,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: dict) {
            KeychainCredentialStore(service: "com.aliyuntokenbar").write(String(data: data, encoding: .utf8) ?? "", account: webTokenAccount)
        }
    }

    /// 清除 web JWT(登出)。
    public static func clearWebToken() {
        KeychainCredentialStore(service: "com.aliyuntokenbar").delete(account: webTokenAccount)
    }

    /// 用 web refresh_token 换新 JWT(access_token 15 分钟过期,refresh_token 90 天)。
    /// 成功则写回 Keychain。
    public static func refreshWebToken(_ refreshToken: String) async -> KimiWebToken? {
        var request = URLRequest(url: webRefreshURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("web", forHTTPHeaderField: "x-msh-platform")
        request.setValue("2.0.0", forHTTPHeaderField: "x-msh-version")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["refresh_token": refreshToken])
        request.timeoutInterval = 30
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let access = root["accessToken"] as? String, !access.isEmpty,
                  let refresh = root["refreshToken"] as? String, !refresh.isEmpty else { return nil }
            // 响应无 expiresAt,按 15 分钟估算
            let expires = Date().timeIntervalSince1970 + 900
            let token = KimiWebToken(accessToken: access, refreshToken: refresh, expiresAt: expires)
            saveWebToken(token)
            return token
        } catch {
            return nil
        }
    }

    // MARK: - Web 控制台用量(月度总额度)

    /// 合并后的 Web 用量:5h / 周 / totalQuota + 订阅共享池 + 订阅到期时间。
    public struct KimiWebQuota: Equatable {
        public let fiveHour: KimiWindow
        public let weekly: KimiWindow
        public let monthly: KimiWindow?
        public let subscriptionExpireMs: Int64?
        public let subscriptionBalance: KimiSubscriptionBalance?
        public init(fiveHour: KimiWindow, weekly: KimiWindow, monthly: KimiWindow?,
                    subscriptionExpireMs: Int64?, subscriptionBalance: KimiSubscriptionBalance? = nil) {
            self.fiveHour = fiveHour
            self.weekly = weekly
            self.monthly = monthly
            self.subscriptionExpireMs = subscriptionExpireMs
            self.subscriptionBalance = subscriptionBalance
        }
    }

    /// 拉取 Web 控制台用量(需要 web JWT)。失败语义同 coding API。
    public static func fetchWebQuota() async -> Result<KimiWebQuota, UsageError> {
        guard let token = loadWebToken() else {
            return .failure(.unknown("未登录 Kimi 网页控制台"))
        }
        let useToken = token.isValid ? token : (await refreshWebToken(token.refreshToken) ?? token)
        let result = await fetchWebWithToken(useToken)
        switch result {
        case .success(let q):
            return .success(q)
        case .failure(let e):
            if e == .authExpired, let refreshed = await refreshWebToken(useToken.refreshToken) {
                return await fetchWebWithToken(refreshed)
            }
            return .failure(e)
        }
    }

    private static func fetchWebWithToken(_ token: KimiWebToken) async -> Result<KimiWebQuota, UsageError> {
        // 1) GetUsages → 5h / 周 / totalQuota(月度)
        var usageReq = URLRequest(url: webUsagesURL)
        usageReq.httpMethod = "POST"
        usageReq.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        usageReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        usageReq.setValue("web", forHTTPHeaderField: "x-msh-platform")
        usageReq.setValue("2.0.0", forHTTPHeaderField: "x-msh-version")
        usageReq.httpBody = try? JSONSerialization.data(withJSONObject: ["scope": ["FEATURE_CODING"]])
        usageReq.timeoutInterval = 30

        let parsed: KimiWebQuota
        do {
            let (data, response) = try await URLSession.shared.data(for: usageReq)
            guard let http = response as? HTTPURLResponse else { return .failure(.invalidResponse) }
            if http.statusCode == 401 { return .failure(.authExpired) }
            guard http.statusCode == 200, let q = parseWebUsages(data) else { return .failure(.parse) }
            parsed = q
        } catch {
            return .failure(.network(error.localizedDescription))
        }

        // 2) GetSubscriptionStats → 共享订阅池(Work/Kimi + Code)和重置时间
        var statsBalance: KimiSubscriptionBalance?
        var statsReq = URLRequest(url: webStatsURL)
        statsReq.httpMethod = "POST"
        statsReq.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        statsReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        statsReq.setValue("web", forHTTPHeaderField: "x-msh-platform")
        statsReq.setValue("2.0.0", forHTTPHeaderField: "x-msh-version")
        statsReq.httpBody = try? JSONSerialization.data(withJSONObject: [:])
        statsReq.timeoutInterval = 30
        if let (data, response) = try? await URLSession.shared.data(for: statsReq),
           let http = response as? HTTPURLResponse, http.statusCode == 200 {
            statsBalance = parseSubscriptionStats(data)
        }

        return .success(KimiWebQuota(fiveHour: parsed.fiveHour, weekly: parsed.weekly,
                                     monthly: parsed.monthly,
                                     subscriptionExpireMs: statsBalance?.expireTimeMs,
                                     subscriptionBalance: statsBalance))
    }

    /// 纯函数:解析 GetUsages 响应(usages[scope=FEATURE_CODING].detail=周,
    /// limits[0].duration=300=5h,totalQuota=兼容汇总字段)。
    public static func parseWebUsages(_ data: Data) -> KimiWebQuota? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let usages = root["usages"] as? [[String: Any]],
              let coding = usages.first(where: {
                  ($0["scope"] as? String)?.uppercased() == "FEATURE_CODING"
              }) else { return nil }
        let weekly = makeWindow(coding["detail"] as? [String: Any])
        var fiveHour = KimiWindow(used: 0, limit: 0, resetTimeMs: nil)
        if let limits = coding["limits"] as? [[String: Any]] {
            for limit in limits {
                if let window = limit["window"] as? [String: Any],
                   intValue(window["duration"]) == 300,
                   isMinuteUnit(window["timeUnit"]),
                   let detail = limit["detail"] as? [String: Any] {
                    fiveHour = makeWindow(detail)
                    break
                }
            }
        }
        var monthly: KimiWindow?
        if let tq = root["totalQuota"] as? [String: Any], !tq.isEmpty {
            monthly = makeWindow(tq)
        }
        return KimiWebQuota(fiveHour: fiveHour, weekly: weekly, monthly: monthly,
                            subscriptionExpireMs: nil)
    }

    /// 解析 GetSubscriptionStats.subscriptionBalance 的共享订阅池。
    public static func parseSubscriptionStats(_ data: Data) -> KimiSubscriptionBalance? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = root["subscriptionBalance"] as? [String: Any],
              let total = ratioValue(raw["amountUsedRatio"]) else { return nil }
        return KimiSubscriptionBalance(totalUsedRatio: total,
                                       codeUsedRatio: ratioValue(raw["kimiCodeUsedRatio"]),
                                       expireTimeMs: dateMs(raw["expireTime"]))
    }

    // MARK: - Fetch

    /// 拉取 Kimi Code 套餐用量。失败语义同 BlUsageService(authExpired/network/parse/invalidResponse/unknown)。
    /// 有 web 控制台登录时优先走 web API(含月度总额);否则用 coding API(5h/周)。
    public static func fetchQuota() async -> Result<KimiQuota, UsageError> {
        // 1) web 控制台登录存在 → 用它(含月度总额)
        if loadWebToken() != nil {
            let webResult = await fetchWebQuota()
            switch webResult {
            case .success(let wq):
                return .success(KimiQuota(
                    fiveHour: wq.fiveHour,
                    weekly: wq.weekly,
                    monthly: wq.monthly,
                    booster: nil,
                    membershipLevel: nil,
                    subscriptionExpireMs: wq.subscriptionExpireMs,
                    subscriptionBalance: wq.subscriptionBalance
                ))
            case .failure:
                // web 失败(网络/过期)→ 回退 coding API,月度缺失
                return await fetchCodingQuota()
            }
        }
        // 2) 无 web 登录 → coding API
        return await fetchCodingQuota()
    }

    /// 仅 coding API(5h/周,无月度)。
    private static func fetchCodingQuota() async -> Result<KimiQuota, UsageError> {
        guard let token = loadToken() else {
            return .failure(.unknown("未找到 Kimi 登录凭证(KimiCodeBar / Kimi CLI)"))
        }
        let useToken = token.isValid ? token : (await refreshToken(token.refreshToken) ?? token)
        let result = await fetchWithToken(useToken)
        switch result {
        case .success(let quota):
            return .success(quota)
        case .failure(let e):
            // 401 → 刷新后重试一次
            if e == .authExpired, let refreshed = await refreshToken(useToken.refreshToken) {
                return await fetchWithToken(refreshed)
            }
            return .failure(e)
        }
    }

    private static func fetchWithToken(_ token: KimiToken) async -> Result<KimiQuota, UsageError> {
        var request = URLRequest(url: usageURL)
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failure(.invalidResponse) }
            if http.statusCode == 401 { return .failure(.authExpired) }
            guard http.statusCode == 200 else {
                return .failure(.network("HTTP \(http.statusCode)"))
            }
            guard let quota = parse(data) else { return .failure(.parse) }
            return .success(quota)
        } catch {
            return .failure(.network(error.localizedDescription))
        }
    }

    // MARK: - Parse(纯函数,fixture 测试覆盖)

    /// 解析官方 usages 响应。
    /// 字段均为字符串形式(如 "58"),需宽松解析。
    /// - usage → 周窗口(滚动)
    /// - limits[0](window.duration == 300)→ 5 小时窗口
    /// - totalQuota → 月度总额(API 未返回时为空对象 {} → nil)
    /// - boosterWallet → 加油包(余额单位 1e-8 元)
    public static func parse(_ data: Data) -> KimiQuota? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        let usage = root["usage"] as? [String: Any]
        let weekly = makeWindow(usage)

        // 5h 窗口:limits 中 window.duration == 300
        var fiveHour = KimiWindow(used: 0, limit: 0, resetTimeMs: nil)
        if let limits = root["limits"] as? [[String: Any]] {
            for limit in limits {
                if let window = limit["window"] as? [String: Any],
                   intValue(window["duration"]) == 300,
                   isMinuteUnit(window["timeUnit"]),
                   let detail = limit["detail"] as? [String: Any] {
                    fiveHour = makeWindow(detail)
                    break
                }
            }
        }

        // 月度总额:totalQuota(空对象 → nil)
        var monthly: KimiWindow?
        if let tq = root["totalQuota"] as? [String: Any], !tq.isEmpty {
            monthly = makeWindow(tq)
        }

        // 加油包
        let booster = makeBooster(root["boosterWallet"] as? [String: Any])

        let membership = (root["user"] as? [String: Any])?["membership"] as? [String: Any]
        let level = membership?["level"] as? String

        return KimiQuota(fiveHour: fiveHour, weekly: weekly, monthly: monthly,
                         booster: booster, membershipLevel: level)
    }

    /// 从 detail/usage 字典构造窗口。字段为字符串或数字,宽松取值。
    private static func makeWindow(_ dict: [String: Any]?) -> KimiWindow {
        guard let dict, !dict.isEmpty else { return KimiWindow(used: 0, limit: 0, resetTimeMs: nil) }
        let limit = intValue(dict["limit"]) ?? 0
        let used: Int
        if let u = intValue(dict["used"]) {
            used = u
        } else if let remaining = intValue(dict["remaining"]), limit > 0 {
            used = max(0, limit - remaining)
        } else {
            used = 0
        }
        let resetMs = dateMs(dict["resetTime"])
        return KimiWindow(used: used, limit: limit, resetTimeMs: resetMs)
    }

    private static func makeBooster(_ dict: [String: Any]?) -> KimiBooster? {
        guard let dict, !dict.isEmpty else { return nil }
        let status = (dict["status"] as? String)?.uppercased() ?? ""
        let enabled = status == "STATUS_ACTIVE" || status == "STATUS_ENABLED"
        // 余额:balance.amountLeft,单位 1e-8 元(未返回时 0,不估算)
        var balanceYuan = 0.0
        if let balance = dict["balance"] as? [String: Any] {
            if let amountLeftStr = balance["amountLeft"] as? String, let v = Double(amountLeftStr) {
                balanceYuan = max(0, v / 100_000_000.0)
            } else if let amountLeftNum = balance["amountLeft"] as? Double {
                balanceYuan = max(0, amountLeftNum / 100_000_000.0)
            }
        }
        let monthlyUsedCents = intValue((dict["monthlyUsed"] as? [String: Any])?["priceInCents"]) ?? 0
        let monthlyLimitCents = intValue((dict["monthlyChargeLimit"] as? [String: Any])?["priceInCents"]) ?? 0
        return KimiBooster(enabled: enabled,
                           balanceYuan: balanceYuan,
                           monthlyUsedYuan: Double(monthlyUsedCents) / 100.0,
                           monthlyLimitYuan: Double(monthlyLimitCents) / 100.0)
    }

    // MARK: - 宽松取值辅助

    /// 字符串或数字 → Int
    private static func intValue(_ v: Any?) -> Int? {
        if let s = v as? String { return Int(s) }
        if let n = v as? Int { return n }
        if let n = v as? Double { return Int(n) }
        if let n = v as? NSNumber { return n.intValue }
        return nil
    }

    /// 字符串或数字 → 0...1 比例。
    private static func ratioValue(_ value: Any?) -> Double? {
        let raw: Double?
        if let s = value as? String { raw = Double(s) }
        else if let n = value as? Double { raw = n }
        else if let n = value as? Int { raw = Double(n) }
        else if let n = value as? NSNumber { raw = n.doubleValue }
        else { raw = nil }
        guard let raw else { return nil }
        return min(max(raw, 0), 1)
    }

    /// 5 小时窗口的时间单位兼容 protobuf 枚举和简化字符串。
    private static func isMinuteUnit(_ value: Any?) -> Bool {
        guard let raw = value as? String else { return true }
        let unit = raw.uppercased()
        return unit == "TIME_UNIT_MINUTE" || unit == "MINUTE"
    }

    /// ISO8601 字符串 → epoch 毫秒
    private static func dateMs(_ v: Any?) -> Int64? {
        guard let s = v as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = formatter.date(from: s) { return Int64(d.timeIntervalSince1970 * 1000) }
        // 无小数秒 fallback
        formatter.formatOptions = [.withInternetDateTime]
        if let d = formatter.date(from: s) { return Int64(d.timeIntervalSince1970 * 1000) }
        return nil
    }
}
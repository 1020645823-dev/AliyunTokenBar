import Foundation

// MARK: - 小米 MiMo 控制台会话:Cookie jar + 静默续期
//
// 背景(2026-09-25 实测):控制台私有 API 只有 Cookie 认证一条路,而 `api-platform_serviceToken`
// 是会过期的会话态(天级),过期后 401 响应体给出可续期的 `loginUrl`:
//
//   401 {"code":401,"loginUrl":"https://account.xiaomi.com/pass/serviceLogin
//         ?callback=https%3A%2F%2Fplatform.xiaomimimo.com%2Fsts%3Fsign%3D…%26followup%3D…&sid=api-platform"}
//     → 带 `passToken`(account.xiaomi.com,长寿命且滑动续期)GET serviceLogin
//     → 302 Location 落在 **platform.xiaomimimo.com/sts**(认证通过)或停在 account.xiaomi.com/fe/service/login(未通过)
//     → 平台 sts 下发 Set-Cookie: api-platform_serviceToken
//
// 因此 App 存的不再是"一段 Cookie 请求头",而是**两域 Cookie 的 jar**:
//   - platform 段:控制台 API 直接使用
//   - account 段:`passToken` 是自动续期的钥匙(只靠 platform 段就会退化成人工重抄)
//
// 兼容:旧版单键 `mimo-console-cookie` 仍可解析(无 account 段 → 不可续期,行为不劣化)。

/// 两域 Cookie jar。`platformHeader` / `accountHeader` 均为可直接塞进 `Cookie:` 头的 "k=v; k=v" 串。
public struct MiMoCookieJar: Equatable, Codable {
    /// platform.xiaomimimo.com 的 Cookie(控制台 API 认证)
    public var platformHeader: String
    /// account.xiaomi.com / .xiaomi.com 的 Cookie(续期用;含 passToken 才可自动续期)
    public var accountHeader: String

    public init(platformHeader: String, accountHeader: String) {
        self.platformHeader = platformHeader
        self.accountHeader = accountHeader
    }

    /// 能否自动续期:account 段必须有 passToken。
    public var canRenew: Bool {
        MiMoCookieJar.parseCookiePairs(accountHeader)["passToken"] != nil
    }

    /// 从旧版单段 Cookie 请求头迁移(无 account 段)。
    /// 必需 cookie 缺失返回 nil,与 `MiMoUsageService.normalizedCookie` 同规则。
    public static func legacy(_ rawHeader: String) -> MiMoCookieJar? {
        guard let normalized = MiMoUsageService.normalizedCookie(from: rawHeader) else { return nil }
        return MiMoCookieJar(platformHeader: normalized, accountHeader: "")
    }

    public func jsonString() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func decode(_ raw: String) -> MiMoCookieJar? {
        guard let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(MiMoCookieJar.self, from: data)
    }

    // MARK: Cookie 串 ↔ 字典(纯函数)

    /// "Cookie: a=1; b=\"2\"" → ["a":"1","b":"2"]。去前缀、去引号、忽略空段。
    public static func parseCookiePairs(_ header: String) -> [String: String] {
        var value = header
        for prefix in ["Cookie:", "cookie:"] where value.hasPrefix(prefix) {
            value = String(value.dropFirst(prefix.count))
        }
        var out: [String: String] = [:]
        for segment in value.split(separator: ";") {
            let pair = segment.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { continue }
            let name = pair[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            out[name] = unquote(pair[1].trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return out
    }

    /// 去掉 cookie 值外层成对的引号。
    ///
    /// ⚠️ **真机踩坑(2026-09-25)**:`HTTPCookie.value` 会**保留**外层引号,平台用来表达
    /// "清除"的 `api-platform_serviceToken=""` 于是变成两个引号字符的**非空**串 ——
    /// 若不剥离,续期会把空凭据当成"拿到新 token",表现为"续期报成功但立刻 401"。
    public static func unquote(_ raw: String) -> String {
        guard raw.count >= 2, raw.hasPrefix("\""), raw.hasSuffix("\"") else { return raw }
        return String(raw.dropFirst().dropLast())
    }

    /// 字典 → 稳定顺序的 Cookie 头串(按名排序,便于断言与缓存)。
    public static func header(from pairs: [String: String]) -> String {
        pairs.keys.sorted().map { "\($0)=\(pairs[$0] ?? "")" }.joined(separator: "; ")
    }

    /// 把 name→value 并入现有 Cookie 段。**空值不覆盖**(平台用 `name=""` + `Expires=1970`
    /// 表达"清除",若当成有效值写入就会把好凭据擦掉)。
    public static func merging(_ existing: String, with pairs: [String: String]) -> String {
        var merged = parseCookiePairs(existing)
        for (name, value) in pairs where !name.isEmpty && !value.isEmpty {
            merged[name] = value
        }
        return header(from: merged)
    }
}

// MARK: - 响应 Set-Cookie 归一(⚠️ URLSession 折叠陷阱)

/// 从响应里还原出的一个 cookie(name / value / domain)。
public struct MiMoResponseCookie: Equatable, Sendable {
    public let name: String
    public let value: String
    public let domain: String

    public init(name: String, value: String, domain: String) {
        self.name = name
        self.value = value
        self.domain = domain
    }

    /// 解析 URLSession 的响应头字典。
    ///
    /// ⚠️ **真机踩坑(2026-09-25)**:`HTTPURLResponse.allHeaderFields` 会把重复的
    /// `Set-Cookie` 折叠成**逗号分隔的单个值**,而 `Expires=Thu, 01-Jan-1970 …` 自身就含逗号
    /// ——手写 `split(",")` / 取首段必然解析错(原实现只解析了折叠串的第一段,恰好是平台的
    /// **空清除 cookie**,于是"续期成功"却拿到废凭据)。必须交给 Foundation 的 cookie 解析器;
    /// 并额外剥离外层引号,才能把 `""` 认成空值剔除。
    public static func parseHeaderFields(_ fields: [String: String], for url: URL) -> [MiMoResponseCookie] {
        var normalized: [String: String] = [:]
        for (key, value) in fields where key.lowercased() == "set-cookie" {
            normalized["Set-Cookie"] = normalized["Set-Cookie"].map { $0 + ", " + value } ?? value
        }
        guard !normalized.isEmpty else { return [] }
        return HTTPCookie.cookies(withResponseHeaderFields: normalized, for: url)
            .compactMap { cookie in
                let value = MiMoCookieJar.unquote(cookie.value)
                guard !value.isEmpty else { return nil }   // 空值 = 平台的"清除"语义,不参与回写
                return MiMoResponseCookie(name: cookie.name, value: value, domain: cookie.domain)
            }
    }
}

// MARK: - HTTP 传输(可注入,便于离线驱动整条续期链路)

/// 续期链路需要的响应要素(只取用得到的部分,避免为一个用例引入完整 URLSession 抽象)。
public struct MiMoHTTPResponse: Sendable {
    public let statusCode: Int
    public let location: String?
    /// 已归一化的响应 cookie(空值已剔除;见 `MiMoResponseCookie.parseHeaderFields`)
    public let setCookies: [MiMoResponseCookie]
    public let body: Data

    public init(statusCode: Int, location: String?, setCookies: [MiMoResponseCookie], body: Data) {
        self.statusCode = statusCode
        self.location = location
        self.setCookies = setCookies
        self.body = body
    }
}

public protocol MiMoTransport {
    func send(_ request: URLRequest) async -> Result<MiMoHTTPResponse, MiMoUsageService.MiMoError>
}

/// 默认传输:URLSession,**不自动跟随重定向**(续期链路要逐跳判域)。
public struct URLSessionMiMoTransport: MiMoTransport {
    public init() {}

    public func send(_ request: URLRequest) async -> Result<MiMoHTTPResponse, MiMoUsageService.MiMoError> {
        final class NoRedirect: NSObject, URLSessionTaskDelegate {
            func urlSession(_ session: URLSession, task: URLSessionTask,
                            willPerformHTTPRedirection response: HTTPURLResponse,
                            newRequest request: URLRequest,
                            completionHandler: @escaping (URLRequest?) -> Void) {
                completionHandler(nil)   // 停在当前跳,交给调用方判域
            }
        }
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(.unknown("非 HTTP 响应"))
            }
            var fields: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                if let key = key as? String { fields[key] = String(describing: value) }
            }
            let cookies = MiMoResponseCookie.parseHeaderFields(fields, for: http.url ?? request.url!)
            return .success(MiMoHTTPResponse(statusCode: http.statusCode,
                                             location: http.value(forHTTPHeaderField: "Location"),
                                             setCookies: cookies,
                                             body: data))
        } catch {
            return .failure(.network(error.localizedDescription))
        }
    }
}

// MARK: - 续期编排

public enum MiMoSessionRenewal {
    public static let platformBase = "https://platform.xiaomimimo.com"
    /// 认证通过后 Location 应落在平台域;仍停在账号域 = passToken 已失效。
    static let platformHost = "xiaomimimo.com"

    /// 用 jar 里的 `passToken` 静默换发新的 `api-platform_serviceToken`。
    /// - 成功:返回**回写后**的新 jar(含旋转过的 passToken / 新 serviceToken)。
    /// - 失败:`.loginRequired`(需人工重新登录)/ `.network` 等。
    public static func renew(jar: MiMoCookieJar,
                             transport: MiMoTransport = URLSessionMiMoTransport())
        async -> Result<MiMoCookieJar, MiMoUsageService.MiMoError> {
        guard jar.canRenew else { return .failure(.loginRequired) }

        // 1) 取一次新鲜的 loginUrl(platform 的 sign 是每次请求生成的,不能缓存)
        let probeResult = await transport.send(request(url: "\(platformBase)/api/v1/balance",
                                                       cookie: jar.platformHeader))
        let probe: MiMoHTTPResponse
        switch probeResult {
        case .failure(let e): return .failure(e)
        case .success(let r): probe = r
        }
        // 会话其实还有效 → 无需续期,原样返回
        if (200...299).contains(probe.statusCode), probe.location == nil { return .success(jar) }
        guard let loginUrl = loginURL(from: probe.body) else { return .failure(.loginRequired) }
        AppLog.debug("MiMo 会话续期:取得 loginUrl", category: .mimo)

        // 2) 带账号 Cookie(passToken)走 serviceLogin
        let loginResult = await transport.send(request(url: loginUrl, cookie: jar.accountHeader))
        let login: MiMoHTTPResponse
        switch loginResult {
        case .failure(let e): return .failure(e)
        case .success(let r): login = r
        }
        guard login.statusCode == 302, let location = login.location,
              let target = URL(string: location), let host = target.host else {
            return .failure(.loginRequired)
        }
        guard host.contains(platformHost) else {
            // 认证没通过:Location 停在 account.xiaomi.com/fe/service/login 等登录页
            AppLog.warning("MiMo 续期:passToken 未被接受(Location=\(host)),需重新登录", category: .mimo)
            return .failure(.loginRequired)
        }

        // 3) 平台 sts 回调下发新的 serviceToken(可能同时旋转 passToken)
        let callbackResult = await transport.send(
            request(url: location, cookie: "\(jar.platformHeader); \(jar.accountHeader)"))
        let callback: MiMoHTTPResponse
        switch callbackResult {
        case .failure(let e): return .failure(e)
        case .success(let r): callback = r
        }
        // 必须拿到**非空**的 serviceToken;空值是平台表达"未通过"的清除 cookie
        // (此处曾误判为成功:取到空值 → 换发的凭据仍 401)
        guard let newToken = callback.setCookies
            .last(where: { $0.name == "api-platform_serviceToken" && !$0.value.isEmpty })?.value else {
            AppLog.warning("MiMo 续期:回调未下发有效 api-platform_serviceToken", category: .mimo)
            return .failure(.loginRequired)
        }

        // 4) 回写:平台域与账号域分别合并(账号域 Set-Cookie 是滑动续期,必须落盘,
        //    否则用过一次的 passToken 轮换后旧值失效 → 下次续期失败)
        let platformPairs = Dictionary(
            callback.setCookies.filter { isPlatformDomain($0.domain) }.map { ($0.name, $0.value) },
            uniquingKeysWith: { _, new in new })
        let accountPairs = Dictionary(
            callback.setCookies.filter { isAccountDomain($0.domain) }.map { ($0.name, $0.value) },
            uniquingKeysWith: { _, new in new })
        let newJar = MiMoCookieJar(
            platformHeader: MiMoCookieJar.merging(jar.platformHeader, with: platformPairs),
            accountHeader: MiMoCookieJar.merging(jar.accountHeader, with: accountPairs))
        AppLog.info("MiMo 会话已自动续期(serviceToken 长度 \(newToken.count))", category: .mimo)
        return .success(newJar)
    }

    /// 从 401 响应体里取 loginUrl。
    static func loginURL(from body: Data) -> String? {
        struct Envelope: Decodable { let loginUrl: String? }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: body),
              let raw = envelope.loginUrl, URL(string: raw) != nil else { return nil }
        return raw
    }

    /// 平台域判定:`.xiaomimimo.com` / `platform.xiaomimimo.com` / `xiaomimimo.com`。
    /// 注意 `xiaomimimo.com` **不含**子串 `xiaomi.com`(中间是 `mimo.`),两域可安全区分。
    static func isPlatformDomain(_ domain: String) -> Bool {
        domain.lowercased().contains(platformHost)
    }

    /// 账号域判定:`.xiaomi.com` / `account.xiaomi.com`。
    static func isAccountDomain(_ domain: String) -> Bool {
        let lower = domain.lowercased()
        return lower.contains("xiaomi.com") && !lower.contains(platformHost)
    }

    /// 续期链路一律用平台 UA / Referer,与正常刷新同形,避免 WAF 差异。
    static func request(url: String, cookie: String) -> URLRequest {
        var request = URLRequest(url: URL(string: url) ?? URL(string: platformBase)!)
        request.httpMethod = "GET"
        request.timeoutInterval = MiMoUsageService.requestTimeout
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue(platformBase, forHTTPHeaderField: "Origin")
        request.setValue("\(platformBase)/#/console/balance", forHTTPHeaderField: "Referer")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent")
        return request
    }
}

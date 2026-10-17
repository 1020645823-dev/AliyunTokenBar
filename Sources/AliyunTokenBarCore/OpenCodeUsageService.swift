import Foundation

/// OpenCode Go 用量查询:console JSON API(2026-10-17 重写;原 SSR 抓取路线已废弃)。
///
/// 背景:opencode.ai 控制台从 SSR vanity 路由(`/workspace/{id}/go` + `auth` cookie)
/// 迁到 `/console` SPA + `__Host-console_session` 会话 cookie 后(2026-10-17 实测):
/// - 旧 vanity 路由(`/auth`、`/workspace/{id}/go`)对 console 会话一律 302 到
///   `/console/login`,SSR 正则抓取与"auth cookie 名假设"同时作废;
/// - 现行数据源 = console JSON API(同一会话 cookie):
///   * `GET /console/api/user/workspaces` → 账户下全部 workspace
///     (多 workspace 监控的基础,响应 `[{id,name,...}]`);
///   * `GET /console/api/go/status` + `x-org-id: <workspaceID>` → 该 workspace 的
///     Go 订阅三窗口用量(`access.meters.{fiveHour,week,month}` 各含
///     `limitMicroCents`/`usedMicroCents`/`resetsAt`)。
///
/// 鉴权:opencode.ai 网页登录的会话 cookie(整段 Cookie 头)。登录窗从 WKWebView
/// cookieStore 打包该域**全部** cookie——会话 cookie 名(实测 `__Host-console_session`)
/// 可能变化,不假设具体名字,由服务端自选。
public final class OpenCodeUsageService {
    private static let baseURL = "https://opencode.ai"
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"

    /// 规范化 cookie:允许传整段 Cookie 头("a=1; b=2")或纯值
    static func cookieHeader(_ cookie: String) -> String {
        cookie.contains("=") ? cookie : "auth=\(cookie)"
    }

    // MARK: - 用量(console go/status)

    /// 拉取某 workspace 的 Go 三窗口用量。
    /// - Parameters:
    ///   - cookie: 登录会话 cookie(整段 Cookie 头)
    ///   - workspaceID: wrk_xxx / org_xxx(同时作为 x-org-id 头)
    public static func fetchQuota(cookie: String, workspaceID: String) async -> Result<OpenCodeQuota, UsageError> {
        guard !workspaceID.isEmpty else { return .failure(.unknown("缺少 workspace ID(wrk_xxx/org_xxx)")) }
        guard !cookie.isEmpty else { return .failure(.unknown("缺少登录 cookie")) }
        guard let url = URL(string: "\(baseURL)/console/api/go/status") else {
            return .failure(.unknown("无效的 endpoint"))
        }

        var request = URLRequest(url: url)
        request.setValue(cookieHeader(cookie), forHTTPHeaderField: "Cookie")
        request.setValue(workspaceID, forHTTPHeaderField: "x-org-id")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failure(.invalidResponse) }
            switch http.statusCode {
            case 200:
                return parseGoStatus(data).map { .success($0) } ?? .failure(.parse)
            case 401, 403:
                return .failure(.authExpired)
            default:
                return .failure(.invalidResponse)
            }
        } catch {
            return .failure(.network(error.localizedDescription))
        }
    }

    /// 解析 go/status 响应(纯函数,Verify 覆盖;`now` 可注入保证断言确定性)。
    ///
    /// 形状:`{"access":{"meters":{"fiveHour":{"resetsAt":"2026-10-17T16:08:13.000Z",
    /// "limitMicroCents":"1200000000","usedMicroCents":"886219"},"week":{...},"month":{...}}}}`
    ///
    /// - 百分比 = used/limit×100 取整(对齐控制台的整数 "x% used" 显示);
    /// - `resetsAt` 缺省/为 null/已过去 → resetInSec=0(UI 隐藏倒计时);
    /// - `access`/`meters` 缺失(未订阅 Go)→ nil(调用方按"无用量数据"呈现)。
    public static func parseGoStatus(_ data: Data, now: Date = Date()) -> OpenCodeQuota? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = root["access"] as? [String: Any],
              let meters = access["meters"] as? [String: Any] else { return nil }

        func window(_ key: String) -> OpenCodeWindow? {
            guard let m = meters[key] as? [String: Any] else { return nil }
            let limit = (m["limitMicroCents"] as? String).flatMap(Int64.init)
                ?? (m["limitMicroCents"] as? Int).map(Int64.init) ?? 0
            let used = (m["usedMicroCents"] as? String).flatMap(Int64.init)
                ?? (m["usedMicroCents"] as? Int).map(Int64.init) ?? 0
            let pct: Int = limit > 0 ? Int((Double(used) / Double(limit) * 100).rounded()) : 0
            return OpenCodeWindow(pct: min(max(pct, 0), 100), resetInSec: resetInSec(from: m["resetsAt"], now: now))
        }

        guard let rolling = window("fiveHour"),
              let weekly = window("week"),
              let monthly = window("month") else { return nil }
        return OpenCodeQuota(rolling: rolling, weekly: weekly, monthly: monthly)
    }

    /// ISO8601(带/不带毫秒)时间戳 → 距重置秒数;过去/缺失/解析失败 → 0。
    private static func resetInSec(from value: Any?, now: Date) -> Int64 {
        guard let s = value as? String, !s.isEmpty else { return 0 }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        guard let date = fractional.date(from: s) ?? plain.date(from: s) else { return 0 }
        return max(0, Int64(date.timeIntervalSince(now)))
    }

    // MARK: - workspace 列表(2026-10-17:一个账户多个 workspace,各有独立订阅)

    /// console SPA 的 me 组端点返回的单个 workspace(逆自 console bundle;
    /// 额外字段 role/memberCount 等忽略)。
    public struct OpenCodeWorkspaceInfo: Codable, Equatable {
        public let id: String
        public let name: String
        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    /// 列出账户下全部 workspace(与配额抓取共用同一会话 cookie)。
    ///
    /// `GET /console/api/user/workspaces`(2026-10-17 逆自 console SPA bundle):
    /// 响应为 JSON 数组 `[{id, name, avatarUrl, role, memberCount, ...}]`,
    /// id 形如 wrk_xxx / org_xxx。
    ///
    /// 端点失效(401/改版/网络)→ 返回空数组,调用方回落到手动填写。
    public static func listWorkspaces(cookie: String) async -> [OpenCodeWorkspaceInfo] {
        guard !cookie.isEmpty,
              let url = URL(string: "\(baseURL)/console/api/user/workspaces") else { return [] }
        var request = URLRequest(url: url)
        request.setValue(cookieHeader(cookie), forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
            return parseWorkspaceList(data)
        } catch {
            return []
        }
    }

    /// 宽容解析 workspace 列表:直接数组,或 {workspaces:[...]}/{data:[...]} 包装。
    /// 纯函数(Verify 覆盖):坏 JSON/空数组 → 空;缺 name 用 id 兜底。
    public static func parseWorkspaceList(_ data: Data) -> [OpenCodeWorkspaceInfo] {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let array: [[String: Any]]
        if let direct = root as? [[String: Any]] {
            array = direct
        } else if let obj = root as? [String: Any],
                  let wrapped = (obj["workspaces"] as? [[String: Any]]) ?? (obj["data"] as? [[String: Any]]) {
            array = wrapped
        } else {
            return []
        }
        return array.compactMap { item in
            guard let id = item["id"] as? String, !id.isEmpty else { return nil }
            let name = (item["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id
            return OpenCodeWorkspaceInfo(id: id, name: name)
        }
    }
}

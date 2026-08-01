import Foundation

/// OpenCode Go 用量查询:带 auth cookie 请求页面,正则提取 SolidJS 注入的用量数据。
///
/// 原理(逆向自社区工具 brfid/quotactl 的 scraper_go.py):
/// OpenCode Go 无公开 API,但 workspace "Go" 页面是 SSR 的,用量百分比/reset 时间
/// 内联在 HTML 的 <script> 里,形如:
///   rollingUsage:$R[N]={status:"ok",resetInSec:12345,usagePercent:43}
/// 带 auth cookie 请求页面 + 正则提取即可。
///
/// 鉴权:浏览器 opencode.ai 的 `auth` cookie(用户手动提供,会过期)。
public final class OpenCodeUsageService {
    private static let baseURL = "https://opencode.ai"

    /// 三窗口在页面里的 JS 属性名
    private static let windowKeys: [(name: String, key: String)] = [
        ("rolling", "rollingUsage"),
        ("weekly", "weeklyUsage"),
        ("monthly", "monthlyUsage"),
    ]

    /// 抓取 OpenCode Go 用量。
    /// - Parameters:
    ///   - cookie: 浏览器 auth cookie 值(整个 Cookie 头,或仅 auth=xxx)
    ///   - workspaceID: wrk_xxx 工作区 ID(在 Go 页面 URL 里)
    public static func fetchQuota(cookie: String, workspaceID: String) async -> Result<OpenCodeQuota, UsageError> {
        guard !workspaceID.isEmpty else { return .failure(.unknown("缺少 workspace ID(wrk_xxx)")) }
        guard !cookie.isEmpty else { return .failure(.unknown("缺少 auth cookie")) }

        // 规范化 cookie:允许用户传 "auth=xxx" 或纯 "xxx"
        let cookieHeader = cookie.contains("=") ? cookie : "auth=\(cookie)"
        guard let url = URL(string: "\(baseURL)/workspace/\(workspaceID)/go") else {
            return .failure(.unknown("无效的 workspace ID"))
        }

        var request = URLRequest(url: url)
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failure(.invalidResponse) }

            // 登录态检查:重定向到 auth.opencode.ai 或页面无 wrk_ 内容
            let finalURL = http.url?.absoluteString ?? ""
            let html = String(data: data, encoding: .utf8) ?? ""
            if finalURL.contains("auth.opencode.ai") || !html.contains("wrk_") {
                return .failure(.authExpired)
            }
            return parse(html).map { .success($0) } ?? .failure(.parse)
        } catch {
            return .failure(.network(error.localizedDescription))
        }
    }

    /// 从页面 HTML 提取三窗口用量。
    /// 正则匹配 `rollingUsage:$R[N]={status:"ok",resetInSec:12345,usagePercent:43}`。
    public static func parse(_ html: String) -> OpenCodeQuota? {
        var rolling: OpenCodeWindow?
        var weekly: OpenCodeWindow?
        var monthly: OpenCodeWindow?

        for (name, key) in windowKeys {
            // 正则:捕获 status / resetInSec / usagePercent
            let pattern = "\(NSRegularExpression.escapedPattern(for: key)):\\$R\\[\\d+\\]=\\{status:\"([^\"]*)\",resetInSec:(\\d+),usagePercent:(\\d+)\\}"
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            let range = NSRange(html.startIndex..., in: html)
            guard let m = regex.firstMatch(in: html, range: range) else { return nil }

            let status = capture(m, at: 1, in: html)      // "ok"
            _ = status
            let resetInSec = Int64(capture(m, at: 2, in: html) ?? "0") ?? 0
            let pct = Int(capture(m, at: 3, in: html) ?? "0") ?? 0

            let window = OpenCodeWindow(pct: pct, resetInSec: resetInSec)
            switch name {
            case "rolling": rolling = window
            case "weekly": weekly = window
            case "monthly": monthly = window
            default: break
            }
        }

        guard let r = rolling, let w = weekly, let mth = monthly else { return nil }
        return OpenCodeQuota(rolling: r, weekly: w, monthly: mth)
    }

    private static func capture(_ match: NSTextCheckingResult, at idx: Int, in text: String) -> String? {
        guard let range = Range(match.range(at: idx), in: text) else { return nil }
        return String(text[range])
    }
}

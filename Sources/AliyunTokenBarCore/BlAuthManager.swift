import Foundation

/// 环境与鉴权检测:bl 是否安装、控制台是否已登录。
public final class BlAuthManager {
    /// 检测 bl 是否可用(PATH 或常见安装路径)。
    public static func isBlInstalled() -> Bool {
        BlExecutable.resolve() != nil
    }

    /// 解析 `bl auth status --output json` 判断控制台登录态。
    /// console.source == "config" 且 masked 非空 → .ok;否则 .notLoggedIn。
    public static func parseAuthStatus(_ data: Data) -> AuthState {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let console = root["console"] as? [String: Any],
              let source = console["source"] as? String,
              source == "config",
              let masked = console["masked"] as? String,
              !masked.isEmpty else {
            return .notLoggedIn
        }
        return .ok
    }

    /// 解析 bl profile 中是否存在 OpenAPI AK/SK（仅用于诊断/兼容旧版本）。
    public static func parseOpenAPIConfig(_ data: Data) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        let profile = (root["token-plan"] as? [String: Any]) ?? root
        guard let accessKeyID = profile["access_key_id"] as? String,
              let accessKeySecret = profile["access_key_secret"] as? String else { return false }
        return !accessKeyID.isEmpty && !accessKeySecret.isEmpty
    }

    /// 综合:bl 未装 → .blNotInstalled;装了但解析不出有效 console → .notLoggedIn;否则 .ok。
    /// 注意:.ok 只表示配置存在,实际是否过期要靠调用 RPC 才知道。
    public static func currentAuthState() async -> AuthState {
        guard let blPath = BlExecutable.resolve() else { return .blNotInstalled }
        let result = await ProcessRunner.runAsync(
            executable: URL(fileURLWithPath: blPath),
            arguments: ["auth", "status", "--output", "json"],
            environment: BlExecutable.enrichedEnvironment(),
            timeout: 10
        )
        guard !result.timedOut, result.exitCode == 0 else { return .notLoggedIn }
        return parseAuthStatus(Data(result.stdout.utf8))
    }

    // MARK: - OpenAPI token exchange

    /// 读取非敏感的 console 路由配置，避免丢失 delegated switch agent。
    public static func parseConsoleRouting(_ data: Data) -> BlConsoleProfile? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let region = root["console_region"] as? String,
              let site = root["console_site"] as? String else { return nil }
        let switchAgent: Int?
        if let value = root["console_switch_agent"] as? Int {
            switchAgent = value
        } else if let value = root["console_switch_agent"] as? NSNumber {
            switchAgent = value.intValue
        } else {
            switchAgent = nil
        }
        return BlConsoleProfile(accessToken: "", region: region, site: site, switchAgent: switchAgent)
    }

    private static func consoleRouting() async -> BlConsoleProfile? {
        guard let blPath = BlExecutable.resolve() else { return nil }
        let result = await ProcessRunner.runAsync(
            executable: URL(fileURLWithPath: blPath),
            arguments: ["config", "show", "--config", "token-plan", "--output", "json"],
            environment: BlExecutable.enrichedEnvironment(),
            timeout: 10
        )
        guard !result.timedOut, result.exitCode == 0 else { return nil }
        return parseConsoleRouting(Data(result.stdout.utf8))
    }

    /// 用 AK/SK 交换短期 token，并为 bl 创建一次性配置目录。
    /// 长期凭据不会写入 bl 配置，也不会出现在进程参数中。
    public static func makeEphemeralConfig(
        credential: AliyunOpenAPICredential
    ) async throws -> BlEphemeralConfig {
        let token = try await AliyunOpenAPIService.exchangeAccessToken(credential: credential)
        let route = await consoleRouting() ?? BlConsoleProfile(accessToken: "")
        return try BlEphemeralConfig(profile: BlConsoleProfile(accessToken: token,
                                                                region: route.region,
                                                                site: route.site,
                                                                switchAgent: route.switchAgent))
    }

    /// 拉起浏览器控制台登录:`bl auth login --console --console-site domestic`
    public static func relogin() {
        guard let blPath = BlExecutable.resolve() else { return }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: blPath)
        proc.arguments = ["auth", "login", "--console", "--console-site", "domestic"]
        proc.environment = BlExecutable.enrichedEnvironment()
        try? proc.run()
    }

    /// 查询已安装 bl 的版本号(如 "bl 1.13.0" → "1.13.0")。失败返回 nil。
    public static func installedVersion() async -> String? {
        guard let blPath = BlExecutable.resolve() else { return nil }
        let result = await ProcessRunner.runAsync(
            executable: URL(fileURLWithPath: blPath),
            arguments: ["--version"],
            environment: BlExecutable.enrichedEnvironment(),
            timeout: 10
        )
        guard !result.timedOut, result.exitCode == 0 else { return nil }
        let raw = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        // 形如 "bl 1.13.0",取最后的 x.y.z
        return raw.split(separator: " ").last.map(String.init) ?? raw
    }

    /// 查询 npm 上最新 bl 版本(`npm view bailian-cli version`)。失败返回 nil。
    public static func latestVersion() async -> String? {
        let result = await ProcessRunner.runAsync(
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["npm", "view", "bailian-cli", "version"],
            environment: BlExecutable.enrichedEnvironment(),
            timeout: 30   // npm view 联网慢,给足 30s
        )
        guard !result.timedOut, result.exitCode == 0 else { return nil }
        let v = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }

    /// 一键更新 bl:`npm install -g bailian-cli@latest`。
    /// 在新终端窗口跑(让用户看到进度),返回是否成功拉起。
    @discardableResult
    public static func updateBl() -> Bool {
        // 用 osascript 开 Terminal 跑,用户可见进度
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", """
        tell application "Terminal"
            activate
            do script "npm install -g bailian-cli@latest && echo \\"✓ bl 已更新,可关闭此窗口\\"" 
        end tell
        """]
        proc.environment = BlExecutable.enrichedEnvironment()
        do { try proc.run(); return true } catch { return false }
    }
}

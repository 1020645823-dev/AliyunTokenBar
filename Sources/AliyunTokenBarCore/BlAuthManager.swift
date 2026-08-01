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

    /// 综合:bl 未装 → .blNotInstalled;装了但解析不出有效 console → .notLoggedIn;否则 .ok。
    /// 注意:.ok 只表示配置存在,实际是否过期要靠调用 RPC 才知道。
    public static func currentAuthState() async -> AuthState {
        guard let blPath = BlExecutable.resolve() else { return .blNotInstalled }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: blPath)
        proc.arguments = ["auth", "status", "--output", "json"]
        let pipe = Pipe(); proc.standardOutput = pipe; proc.standardError = Pipe()
        proc.environment = BlExecutable.enrichedEnvironment()
        do { try proc.run() } catch { return .notLoggedIn }
        let out = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        proc.waitUntilExit()
        return parseAuthStatus(out)
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
}

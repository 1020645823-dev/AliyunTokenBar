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

    /// 查询已安装 bl 的版本号(如 "bl 1.13.0" → "1.13.0")。失败返回 nil。
    public static func installedVersion() -> String? {
        guard let blPath = BlExecutable.resolve() else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: blPath)
        proc.arguments = ["--version"]
        let pipe = Pipe(); proc.standardOutput = pipe; proc.standardError = Pipe()
        proc.environment = BlExecutable.enrichedEnvironment()
        do { try proc.run() } catch { return nil }
        let out = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        let raw = String(data: out, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // 形如 "bl 1.13.0",取最后的 x.y.z
        return raw.split(separator: " ").last.map(String.init) ?? raw
    }

    /// 查询 npm 上最新 bl 版本(`npm view bailian-cli version`)。失败返回 nil。
    public static func latestVersion() async -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["npm", "view", "bailian-cli", "version"]
        let pipe = Pipe(); proc.standardOutput = pipe; proc.standardError = Pipe()
        proc.environment = BlExecutable.enrichedEnvironment()
        do { try proc.run() } catch { return nil }
        // npm view 会联网,给足时间
        for _ in 0..<60 {
            if !proc.isRunning { break }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        if proc.isRunning { proc.terminate() }
        let out = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        return String(data: out, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
            ? String(data: out, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
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

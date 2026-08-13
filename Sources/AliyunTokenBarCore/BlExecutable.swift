import Foundation

/// 解析 bl CLI 的绝对路径 + GUI 友好的 PATH。
///
/// 问题:从 .app bundle 启动的 GUI 进程,PATH 只含 /usr/bin:/bin:/usr/sbin:/sbin,
/// 不含 homebrew(/opt/homebrew/bin)、npm global、nvm 等,导致 `which bl` 失败、
/// bl 内部 spawn node 也失败。这里显式探测常见安装路径,并补全 PATH。
public enum BlExecutable {
    /// bl 可能的安装路径(按优先级)。homebrew arm/intel + npm global + nvm。
    private static let candidatePaths: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "/opt/homebrew/bin/bl",                       // homebrew Apple Silicon
            "/usr/local/bin/bl",                          // homebrew Intel
            "\(home)/.npm-global/bin/bl",                 // npm global 自定义前缀
            "\(home)/.local/bin/bl",                      // 用户本地
            "/usr/local/lib/node_modules/bailian-cli/dist/bailian.mjs",  // npm global 默认(直接 mjs)
        ]
        // nvm:扫描 ~/.nvm/versions/node/*/bin/bl
            + nvmBlPaths(home: home)
    }()

    private static func nvmBlPaths(home: String) -> [String] {
        let nvmDir = "\(home)/.nvm/versions/node"
        guard let versions = try? FileManager.default.contentsOfDirectory(atPath: nvmDir) else {
            return []
        }
        return versions.map { "\(nvmDir)/\($0)/bin/bl" }
    }

    /// 找到 bl 的绝对路径;PATH 里有就用 which,否则扫候选路径。找不到返回 nil。
    public static func resolve() -> String? {
        // 1. 先试当前 PATH(终端启动的场景)
        if let p = findInPath() { return p }
        // 2. 扫候选绝对路径
        for path in candidatePaths where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    private static func findInPath() -> String? {
        let result = ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["which", "bl"],
            timeout: 5
        )
        guard !result.timedOut, result.exitCode == 0 else { return nil }
        let s = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    /// 构造一个 GUI 友好的 PATH:在现有 PATH 前面补上 homebrew/npm/nvm 等目录。
    /// bl 是 node 脚本,spawn 时需要找到 node,所以 PATH 要含 node 所在目录。
    public static func enrichedEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extraDirs = [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/sbin",
            "\(home)/.npm-global/bin",
            "\(home)/.local/bin",
        ] + nvmBinDirs(home: home)
        let existing = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let fm = FileManager.default
        let extras = extraDirs.filter { path in
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
        }
        env["PATH"] = (extras.joined(separator: ":") + ":" + existing)
        return env
    }

    private static func nvmBinDirs(home: String) -> [String] {
        let nvmDir = "\(home)/.nvm/versions/node"
        guard let versions = try? FileManager.default.contentsOfDirectory(atPath: nvmDir) else {
            return []
        }
        return versions.map { "\(nvmDir)/\($0)/bin" }
    }
}

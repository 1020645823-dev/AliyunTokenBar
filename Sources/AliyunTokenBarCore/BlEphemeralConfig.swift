import Foundation

/// 生成 bl 临时 config 所需的非敏感 console profile。
public struct BlConsoleProfile: Equatable {
    public let accessToken: String
    public let region: String
    public let site: String
    public let switchAgent: Int?

    public init(accessToken: String, region: String = "cn-beijing",
                site: String = "domestic", switchAgent: Int? = nil) {
        self.accessToken = accessToken
        self.region = region
        self.site = site
        self.switchAgent = switchAgent
    }
}

/// 只在内存中保存短期 token，并在需要时生成 0600 临时 bl 配置目录。
public final class BlEphemeralConfig {
    public let directoryURL: URL
    public let environment: [String: String]

    public init(profile: BlConsoleProfile) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodingTokenBar-bl-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        var configProfile: [String: Any] = [
            "access_token": profile.accessToken,
            "console_region": profile.region,
            "console_site": profile.site
        ]
        if let switchAgent = profile.switchAgent {
            configProfile["console_switch_agent"] = switchAgent
        }
        let config: [String: Any] = [
            "token-plan": configProfile,
            "active_config": "token-plan"
        ]
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted])
        let configURL = directory.appendingPathComponent("config.json")
        try data.write(to: configURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
        directoryURL = directory
        var env = BlExecutable.enrichedEnvironment()
        env["BAILIAN_CONFIG_DIR"] = directory.path
        env["NO_COLOR"] = "1"
        environment = env
    }

    deinit {
        try? FileManager.default.removeItem(at: directoryURL)
    }

    /// P1-C8:启动时清扫上次崩溃遗留的临时配置目录。
    /// deinit 只在正常退出时执行;崩溃/强杀会残留 CodingTokenBar-bl-* 目录。
    /// 只删超过 olderThan(默认 24h)的残留,避免误删正在运行的另一个实例。
    public static func sweepStaleTempDirectories(olderThan: TimeInterval = 24 * 3600) {
        let tmp = FileManager.default.temporaryDirectory
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: tmp, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        ) else { return }
        let now = Date()
        for url in entries where url.lastPathComponent.hasPrefix("CodingTokenBar-bl-") {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let mtime = attrs[.modificationDate] as? Date,
                  now.timeIntervalSince(mtime) > olderThan else { continue }
            try? FileManager.default.removeItem(at: url)
            AppLog.info("清扫崩溃残留临时目录: \(url.lastPathComponent)", category: .general)
        }
    }
}

public enum BlAuthError: Error, Equatable {
    case missingCredential
    case invalidResponse
    case network(String)
    case unauthorized
    case verification(String)
}

/// 自动恢复冷却判断（纯函数，无 Combine 依赖，Verify 直接测此入口）。
/// failedAt 为 nil（从未失败）→ 不冷却；否则检查是否仍在窗口内。
/// cooldownMinutes 钳制到最小 1，避免 0 导致秒级冷却失效。
public enum AliyunAuthRecovery {
    public static func inCooldown(
        failedAt: Date?, now: Date, cooldownMinutes: Int
    ) -> Bool {
        guard let failedAt else { return false }
        return now.timeIntervalSince(failedAt) < TimeInterval(max(cooldownMinutes, 1) * 60)
    }
}

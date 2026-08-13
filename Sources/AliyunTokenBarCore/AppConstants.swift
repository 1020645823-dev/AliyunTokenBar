import Foundation

// MARK: - 配置/凭据常量集中(P1-D10)
//
// 此前 UserDefaults 键、Keychain account 是散落字符串字面量,改一处漏一处,
// 且 CLAUDE.md 键清单与代码漂移(缺 systemStatsEnabled)。全部收归此处:
// 新增键必须同步更新 CLAUDE.md 的副作用边界表。

public enum UserDefaultsKeys {
    public static let refreshIntervalMinutes = "refreshIntervalMinutes"
    public static let thresholdWarning = "thresholdWarning"
    public static let thresholdCritical = "thresholdCritical"
    public static let sparklineEnabled = "sparklineEnabled"
    public static let notificationsEnabled = "notificationsEnabled"
    public static let appTheme = "appTheme"
    public static let menuBarScheme = "menuBarScheme"
    public static let openCodeWorkspaceID = "openCodeWorkspaceID"
    public static let systemStatsEnabled = "systemStatsEnabled"
    /// 阿里云套餐到期提醒"今日已提醒"标记(P1-B2)
    public static let subscriptionExpiryWarnedDay = "subscriptionExpiryWarnedDay"
    /// 每日用量摘要开关(P2-B7)
    public static let dailyDigestEnabled = "dailyDigestEnabled"
}

public enum KeychainAccounts {
    /// 所有凭据共用同一 Keychain service(bundle id 连续性要求,勿改)。
    public static let service = "com.aliyuntokenbar"
    public static let openCodeCookie = "opencode-auth-cookie"
    public static let aliyunAKSK = "aliyun-ak-sk"
    public static let kimiWebToken = "kimi-web-token"
}

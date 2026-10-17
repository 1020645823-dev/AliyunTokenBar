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
    /// 兼容代理键:本机列开关。真值已并入 `disabledProviders`("system" 条目),
    /// 此键仍同步写入,供旧读取路径(AppDelegate 订阅等)无感过渡。
    public static let systemStatsEnabled = "systemStatsEnabled"
    /// 已停用数据源(ProviderKind.rawValue 数组)。停用语义 = 全面停用:
    /// 菜单栏不出列、面板不出 tab、停止轮询刷新、不参与告警与每日摘要。
    public static let disabledProviders = "disabledProviders"
    /// 阿里云套餐到期提醒"今日已提醒"标记(P1-B2)
    public static let subscriptionExpiryWarnedDay = "subscriptionExpiryWarnedDay"
    /// 每日用量摘要开关(P2-B7)
    public static let dailyDigestEnabled = "dailyDigestEnabled"
    /// 阶跃 web_id(platform.stepfun.com 登录窗从 localStorage 抓取;
    /// 非敏感随机设备标识,SPA 的 Oasis-Webid 请求头同源;UserDefaults 足够)
    public static let stepfunWebId = "stepfunWebId"
    /// 阶跃会话是否验证通过(常驻 WebView 会话的持久标记;
    /// 决定冷启动是否预载会话页与 tab 可见性)
    public static let stepfunSessionActive = "stepfunSessionActive"
    /// 阶跃已登录账户列表(JSON:[{id,label}];id 同时是会话仓库标识,
    /// 首账户固定 "main" 沿用默认仓库,其余为 UUID+命名仓库)
    public static let stepfunAccounts = "stepfunAccounts"
    /// 智谱已配置账户列表(JSON:[{id,label}];Key 按 id 分槽:
    /// main 复用 `zhipu-api-key` 槽,其余 `zhipu-api-key-<id>`)
    public static let zhipuAccounts = "zhipuAccounts"
    /// Kimi 已登录账户列表(JSON:[{id,label}];web JWT 按 id 分槽:
    /// main 复用 `kimi-web-token` 槽,其余 `kimi-web-token-<id>`)
    public static let kimiAccounts = "kimiAccounts"
    /// OpenCode Go 受监控 workspace 列表(JSON:[{id,label}];id = workspace ID
    /// (wrk_xxx/org_xxx),登录 cookie 全账户共享一份,见 KeychainAccounts.openCodeCookie)
    public static let openCodeWorkspaces = "openCodeWorkspaces"
}

public enum KeychainAccounts {
    /// 所有凭据共用同一 Keychain service(bundle id 连续性要求,勿改)。
    public static let service = "com.aliyuntokenbar"
    /// OpenCode Go 网页登录 auth cookie(整段 Cookie 头;一个 opencode.ai 账户一份,
    /// 该账户下全部 workspace 共用此 cookie,配额按 workspace ID 分别抓取)
    public static let openCodeCookie = "opencode-auth-cookie"
    public static let aliyunAKSK = "aliyun-ak-sk"
    public static let kimiWebToken = "kimi-web-token"
    /// DeepSeek 开放平台 API Key(sk-...)
    public static let deepSeekAPIKey = "deepseek-api-key"
    /// 智谱 GLM Coding Plan API Key(自动发现 opencode 配置时无需此项)
    public static let zhipuAPIKey = "zhipu-api-key"
    /// 小米 MiMo 开放平台控制台 Cookie(整段 Cookie 请求头;旧版单键,保留兼容与回滚)
    public static let mimoCookie = "mimo-console-cookie"
    /// 小米 MiMo 两域 Cookie jar(JSON:platform 段 + account 段 passToken,用于静默续期)
    public static let mimoCookieJar = "mimo-cookie-jar"
    /// MiniMax Coding Plan API Key
    public static let minimaxAPIKey = "minimax-api-key"
    /// Ollama Cloud API Key(ollama.com/settings/keys 创建;不过期可吊销)
    public static let ollamaAPIKey = "ollama-api-key"
    /// 阶跃星辰 Step Plan 控制台登录态(platform.stepfun.com 的 Oasis-Token;
    /// 网页登录 Cookie,会过期;API Key 查不了额度,见 StepFunUsageService)
    public static let stepfunConsoleToken = "stepfun-console-token"
}

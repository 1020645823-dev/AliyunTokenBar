import Foundation
import SwiftUI
import Combine

@MainActor
public final class TokenPlanModel: ObservableObject {
    public static let shared = TokenPlanModel()

    @Published public var quota: TokenPlanQuota?
    @Published public var isLoading = false
    @Published public var authState: AuthState = .unknown
    @Published public var lastError: String?
    @Published public var lastUpdated: Date?

    /// 已安装的 bl 版本(如 "1.13.0");未装为 nil
    @Published public var blInstalledVersion: String?
    /// npm 上最新 bl 版本;查询失败为 nil
    @Published public var blLatestVersion: String?
    /// bl 是否可更新(installed < latest)
    public var blUpdateAvailable: Bool {
        guard let i = blInstalledVersion, let l = blLatestVersion else { return false }
        return compareVersions(i, l) < 0
    }

    // MARK: - OpenCode Go

    /// OpenCode Go 用量(三窗口);未配置/未拉取为 nil
    @Published public var openCodeQuota: OpenCodeQuota?
    /// OpenCode 是否配置了(cookie+workspace 都填了)
    public var openCodeConfigured: Bool {
        !openCodeCookie.isEmpty && !openCodeWorkspaceID.isEmpty
    }
    /// OpenCode auth cookie(浏览器 opencode.ai 的 auth cookie)。
    /// 读:CredentialStore(Keychain,默认)/ 写:同步回写。
    /// cookie 是敏感凭据,不再入 UserDefaults(旧值由首启迁移,见 init)。
    @Published public var openCodeCookie: String {
        didSet { credentialStore.write(openCodeCookie, account: Self.openCodeCookieAccount) }
    }
    /// OpenCode workspace ID(wrk_xxx,非敏感,仍用 UserDefaults)
    @Published public var openCodeWorkspaceID: String {
        didSet { UserDefaults.standard.set(openCodeWorkspaceID, forKey: "openCodeWorkspaceID") }
    }
    @Published public var openCodeError: String?

    // MARK: - Kimi Code

    /// Kimi Code 套餐用量(5h/周/月度总额 + 加油包)
    @Published public var kimiQuota: KimiQuota?
    /// Kimi 是否已配置(本机存在 KimiCodeBar / Kimi CLI 凭证)
    public var kimiConfigured: Bool {
        KimiUsageService.tokenExists()
    }
    /// Kimi 网页控制台是否已登录(提供月度总额度数据)
    public var kimiWebLoggedIn: Bool {
        KimiUsageService.loadWebToken() != nil
    }
    @Published public var kimiError: String?

    /// 刷新间隔(分钟),用户可在设置改;默认 10。只影响 usage(高频)。
    @Published public var refreshIntervalMinutes: Int = 10 {
        didSet { UserDefaults.standard.set(refreshIntervalMinutes, forKey: "refreshIntervalMinutes"); resetTimer() }
    }

    // MARK: - 阈值 / 通知 / 历史(P0-P1)

    /// 告警阈值(默认 warning 80 / critical 90),用户可在设置改。
    @Published public var thresholdConfig: ThresholdConfig = ThresholdConfig() {
        didSet { UserDefaults.standard.set(thresholdConfig.warning, forKey: "thresholdWarning")
                 UserDefaults.standard.set(thresholdConfig.critical, forKey: "thresholdCritical") }
    }
    /// 是否启用接近上限通知(默认开)。用户可在设置关。
    @Published public var notificationsEnabled: Bool = true {
        didSet { UserDefaults.standard.set(notificationsEnabled, forKey: "notificationsEnabled") }
    }
    /// 面板 sparkline 是否显示(默认开)。
    @Published public var sparklineEnabled: Bool = true {
        didSet { UserDefaults.standard.set(sparklineEnabled, forKey: "sparklineEnabled") }
    }
    /// 菜单栏是否显示本机 CPU/内存(默认开)。
    @Published public var systemStatsEnabled: Bool = true {
        didSet { UserDefaults.standard.set(systemStatsEnabled, forKey: "systemStatsEnabled") }
    }
    /// 重新登录轮询是否在跑(面板显示"等待浏览器登录完成…")。
    @Published public var isReloginWatching = false
    /// Keychain 中是否已保存阿里云 OpenAPI AK/SK。
    @Published public var aliyunAKSKConfigured = false
    /// 正在通过 AK/SK 自动配置 bl（面板显示 loading）。
    @Published public var aliyunAKSKConfiguring = false
    /// 当前进程使用的短期 bl 配置；释放时自动删除临时目录。
    private var aliyunEphemeralConfig: BlEphemeralConfig?
    /// 上次自动恢复失败时间；nil = 从未失败或已成功重置。
    @Published public var aliyunAutoRecoveryFailedAt: Date?

    /// 冷却窗口：刷新间隔的 2 倍，确保至少跳过一个 timer tick（最小 10 分钟）。
    private var autoRecoveryCooldownMinutes: Int {
        max(refreshIntervalMinutes * 2, 10)
    }
    /// 多窗口通知状态机(纯值,内部维护)。
    public private(set) var notificationTracker = NotificationTracker()

    /// 历史仓库(默认文件落盘;测试/预览可注入内存实现)。
    public let historyStore: HistoryStore

    /// 通知触发闭包:逻辑层评估出应通知的窗口时回调,executable 层注入真正的 UNUserNotificationCenter。
    /// 默认 no-op(逻辑层零副作用),避免 Core 依赖 UserNotifications 框架。
    public var notifySink: ((WatchKey, UsageBand) -> Void)?

    /// 凭据存储(默认 Keychain;测试可注入内存实现)。
    public let credentialStore: CredentialStore

    /// CredentialStore 里 OpenCode cookie 的 account 名。
    public static let openCodeCookieAccount = "opencode-auth-cookie"

    /// CredentialStore 里阿里云 OpenAPI AK/SK 的 account 名（JSON: {"accessKeyId":"...","accessKeySecret":"..."}）。
    public static let aliyunAKSKAccount = "aliyun-ak-sk"

    /// 菜单栏图标预渲染缓存(数据更新时生成,label 只读)。
    @Published public var renderedIcon: NSImage?
    /// 最近一次预渲染的菜单栏 tooltip(与 renderedIcon 同批更新)。
    @Published public var menuBarTooltip: String?
    /// 渲染图标的闭包:由 executable 层注入(因 MenuBarTextRenderer 在 executable 层)。
    public var renderIconSink: ((TokenPlanModel) -> NSImage?)?
    /// 菜单栏 tooltip 渲染闭包(App 目标注入,与 renderIconSink 同批)。
    public var renderTooltipSink: ((TokenPlanModel) -> String?)?

    private var timer: AnyCancellable?

    /// 辅助数据(subscription/addon)上次拉取时间。这俩一天内基本不变,24h 拉一次即可,
    /// 避免每轮刷新都 spawn 3 个 node 进程(降 2/3 开销)。
    private var lastAuxFetch: Date?
    private let auxRefreshInterval: TimeInterval = 24 * 60 * 60  // 24 小时

    /// Keychain 是否已加载(延迟到首次访问,避免启动时序问题)
    private var credentialLoaded = false

    private init() {
        let defaults = UserDefaults.standard
        refreshIntervalMinutes = defaults.object(forKey: "refreshIntervalMinutes") as? Int ?? 10

        // 阈值/通知/sparkline 配置
        let w = defaults.object(forKey: "thresholdWarning") as? Int ?? 80
        let c = defaults.object(forKey: "thresholdCritical") as? Int ?? 90
        thresholdConfig = ThresholdConfig(warning: w, critical: c)
        if defaults.object(forKey: "notificationsEnabled") != nil {
            notificationsEnabled = defaults.bool(forKey: "notificationsEnabled")
        }
        if defaults.object(forKey: "sparklineEnabled") != nil {
            sparklineEnabled = defaults.bool(forKey: "sparklineEnabled")
        }
        if defaults.object(forKey: "systemStatsEnabled") != nil {
            systemStatsEnabled = defaults.bool(forKey: "systemStatsEnabled")
        }

        credentialStore = KeychainCredentialStore(service: "com.aliyuntokenbar")
        openCodeCookie = ""   // 延迟到 ensureCredentialLoaded() 读取
        openCodeWorkspaceID = defaults.string(forKey: "openCodeWorkspaceID") ?? ""

        historyStore = HistoryStore(backend: FileHistoryBackend(url: HistoryStore.defaultURL()))
    }

    /// 延迟加载 Keychain 中的 cookie(避免启动时序问题)。幂等。
    public func ensureCredentialLoaded() {
        guard !credentialLoaded else { return }
        credentialLoaded = true
        CredentialMigration.migrate(legacyKey: "openCodeCookie",
                                    account: Self.openCodeCookieAccount, to: credentialStore)
        openCodeCookie = credentialStore.read(account: Self.openCodeCookieAccount) ?? ""
    }

    /// 启动定时刷新
    public func startTimer() {
        resetTimer()
        ensureCredentialLoaded()
        Task { await checkAuthAndRefresh() }
        Task { await checkBlVersion() }
        Task { await recoverOpenCodeIfNeeded(); await refreshOpenCode() }
        Task { await refreshKimi() }
        if loadAliyunAKSK() != nil {
            aliyunAKSKConfigured = true
        }
    }

    /// 自愈:若已有 cookie 但缺 workspace(如旧版登录失败遗留,或 discover 逻辑修复后首次启动),
    /// 用现存 cookie 自动重新发现 workspace,免去用户手动重登。
    private func recoverOpenCodeIfNeeded() async {
        ensureCredentialLoaded()
        guard !openCodeCookie.isEmpty, openCodeWorkspaceID.isEmpty else { return }
        if let wsID = await OpenCodeUsageService.discoverWorkspaceID(cookie: openCodeCookie) {
            openCodeWorkspaceID = wsID
        }
    }

    /// 拉一次 OpenCode Go 用量(cookie + workspace 配置后)
    public func refreshOpenCode() async {
        ensureCredentialLoaded()
        guard openCodeConfigured else { return }
        let result = await OpenCodeUsageService.fetchQuota(cookie: openCodeCookie, workspaceID: openCodeWorkspaceID)
        switch result {
        case .success(let q):
            openCodeQuota = q
            openCodeError = nil
            AppLog.debug("OpenCode 用量刷新成功 rolling=\(q.rolling.pct)% weekly=\(q.weekly.pct)%", category: .opencode)
            recordAndNotify()
        case .failure(let e):
            switch e {
            case .authExpired: openCodeError = "OpenCode cookie 已过期,请在设置更新"
            case .network(let s): openCodeError = "OpenCode 网络错误: \(s)"
            case .parse: openCodeError = "OpenCode 页面格式变化,解析失败"
            case .invalidResponse: openCodeError = "OpenCode 响应异常"
            case .unknown(let s): openCodeError = s
            }
        }
    }

    // MARK: - Kimi Code

    /// 拉取 Kimi Code 套餐用量(读本机 KimiCodeBar/Kimi CLI 凭证 + web 控制台登录)。
    /// 凭证不存在时静默跳过(设置页有引导)。
    public func refreshKimi() async {
        guard kimiConfigured else { return }
        let result = await KimiUsageService.fetchQuota()
        switch result {
        case .success(let q):
            kimiQuota = q
            kimiError = nil
            AppLog.debug("Kimi 用量刷新成功 5h=\(q.fiveHour.pct)% weekly=\(q.weekly.pct)%", category: .kimi)
            recordAndNotify()
        case .failure(let e):
            switch e {
            case .authExpired: kimiError = "Kimi 登录已过期,请重新登录 KimiCodeBar / Kimi CLI"
            case .network(let s): kimiError = "Kimi 网络错误: \(s)"
            case .parse: kimiError = "Kimi 响应格式变化,解析失败"
            case .invalidResponse: kimiError = "Kimi 响应异常"
            case .unknown(let s): kimiError = s
            }
        }
    }

    /// 清空 Kimi 状态(不删共享凭证文件;web 登录 token 一并清)。
    public func clearKimi() {
        kimiQuota = nil
        kimiError = nil
        KimiUsageService.clearWebToken()
        notificationTracker.clear(provider: "kimi")
    }

    // MARK: - 阿里云 OpenAPI AK/SK（console token 自动刷新）

    /// 保存 AK/SK 到 Keychain。
    @discardableResult
    public func saveAliyunAKSK(accessKeyID: String, accessKeySecret: String) -> Bool {
        guard let credential = AliyunOpenAPICredential(accessKeyID: accessKeyID,
                                                       accessKeySecret: accessKeySecret) else {
            return false
        }
        guard let payload = try? JSONEncoder().encode(credential),
              let str = String(data: payload, encoding: .utf8) else { return false }
        credentialStore.write(str, account: Self.aliyunAKSKAccount)
        aliyunAKSKConfigured = true
        return true
    }

    /// 从 Keychain 读取 AK/SK。
    public func loadAliyunAKSK() -> AliyunOpenAPICredential? {
        guard let raw = credentialStore.read(account: Self.aliyunAKSKAccount),
              let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AliyunOpenAPICredential.self, from: data)
    }

    /// 删除 Keychain 中的 AK/SK。临时 profile 由其生命周期自动清理。
    public func clearAliyunAKSK() {
        credentialStore.delete(account: Self.aliyunAKSKAccount)
        aliyunEphemeralConfig = nil
        aliyunAutoRecoveryFailedAt = nil
        aliyunAKSKConfigured = false
        aliyunAKSKConfiguring = false
    }

    /// 当前进程使用的 bl 环境；没有短期配置时使用用户默认环境。
    private var aliyunEnvironment: [String: String]? {
        aliyunEphemeralConfig?.environment
    }

    /// 交换短期 token、验证 usage RPC 并在成功后保存 AK/SK。
    /// 自动恢复和手动配置共用此入口，避免同时写入临时配置。
    public func configureAliyun(accessKeyID: String, accessKeySecret: String) async -> Result<Void, BlAuthError> {
        guard !aliyunAKSKConfiguring else {
            return .failure(.verification("已有配置操作正在进行"))
        }
        guard let credential = AliyunOpenAPICredential(accessKeyID: accessKeyID,
                                                       accessKeySecret: accessKeySecret) else {
            return .failure(.invalidResponse)
        }
        aliyunAKSKConfiguring = true
        defer { aliyunAKSKConfiguring = false }
        do {
            let ephemeral = try await BlAuthManager.makeEphemeralConfig(credential: credential)
            let data = try await BlUsageService.callRPC(BlUsageService.usageAPI,
                                                        environment: ephemeral.environment)
            let usage = try BlUsageService.parseUsage(data)
            aliyunEphemeralConfig = ephemeral
            aliyunAutoRecoveryFailedAt = nil   // 手动/自动配置成功 → 冷却清零
            guard saveAliyunAKSK(accessKeyID: credential.accessKeyID,
                                  accessKeySecret: credential.accessKeySecret) else {
                return .failure(.verification("凭据保存失败"))
            }
            quota = TokenPlanQuota(usage: usage,
                                   subscription: quota?.subscription,
                                   addon: quota?.addon)
            lastUpdated = Date()
            lastError = nil
            authState = .ok
            recordAndNotify()
            return .success(())
        } catch let error as BlAuthError {
            return .failure(error)
        } catch let error as UsageError {
            return .failure(.verification(String(describing: error)))
        } catch {
            return .failure(.verification(error.localizedDescription))
        }
    }

    /// 交换短期 token 后用临时 profile 验证 usage RPC；失败则回退浏览器登录。
    /// 失败后进入冷却窗口（刷新间隔 ×2，最小 10 分钟），避免每个 timer tick 重复
    /// 弹出浏览器标签。手动配置成功后冷却清零。
    public func autoConfigureAliyunIfNeeded() async {
        guard authState == .expired || authState == .notLoggedIn else { return }
        guard !aliyunAKSKConfiguring else { return }
        guard let credential = loadAliyunAKSK() else { return }
        guard !AliyunAuthRecovery.inCooldown(
            failedAt: aliyunAutoRecoveryFailedAt,
            now: Date(),
            cooldownMinutes: autoRecoveryCooldownMinutes
        ) else { return }
        let result = await configureAliyun(accessKeyID: credential.accessKeyID,
                                           accessKeySecret: credential.accessKeySecret)
        switch result {
        case .success:
            AppLog.info("阿里云 AK/SK 自动恢复成功", category: .aliyun)
        case .failure(let e):
            AppLog.warning("阿里云 AK/SK 自动恢复失败: \(String(describing: e)),进入冷却并回退浏览器登录", category: .aliyun)
            aliyunAutoRecoveryFailedAt = Date()
            aliyunEphemeralConfig = nil
            lastError = "自动恢复失败,请重新登录"
            relogin()
        }
    }

    // MARK: - 历史记录 + 通知评估(P0-P1)

    /// 把当前已知用量落盘一条快照,并对所有窗口跑一次通知评估。
    /// 在任一 Provider 刷新成功后调用(两个 Provider 任一更新都会聚合一条快照)。
    public func recordAndNotify() {
        let snap = UsageSnapshot(
            timestamp: Date(),
            aliyunFiveHour: quota?.usage.fiveHour.percentageInt,
            aliyunOneWeek: quota?.usage.oneWeek.percentageInt,
            opencodeRolling: openCodeQuota?.rolling.pct,
            opencodeWeekly: openCodeQuota?.weekly.pct,
            opencodeMonthly: openCodeQuota?.monthly.pct,
            kimiFiveHour: kimiQuota?.fiveHour.pctInt,
            kimiWeekly: kimiQuota?.weekly.pctInt,
            kimiMonthly: kimiQuota?.monthly?.pctInt
        )
        historyStore.append(snap)

        // 预渲染菜单栏图标(数据更新后,主线程上下文稳定)
        prerenderIcon()

        guard notificationsEnabled else { return }
        var entries: [(WatchKey, Int)] = []
        if let q = quota {
            entries.append((WatchKey(provider: "aliyun", window: "5h"), q.usage.fiveHour.percentageInt))
            entries.append((WatchKey(provider: "aliyun", window: "7d"), q.usage.oneWeek.percentageInt))
        }
        if let oc = openCodeQuota {
            entries.append((WatchKey(provider: "opencode", window: "rolling"), oc.rolling.pct))
            entries.append((WatchKey(provider: "opencode", window: "weekly"), oc.weekly.pct))
        }
        if let k = kimiQuota {
            entries.append((WatchKey(provider: "kimi", window: "5h"), k.fiveHour.pctInt))
            entries.append((WatchKey(provider: "kimi", window: "weekly"), k.weekly.pctInt))
            if let m = k.monthly {
                entries.append((WatchKey(provider: "kimi", window: "monthly"), m.pctInt))
            }
        }
        for (key, band) in notificationTracker.evaluate(entries, config: thresholdConfig) {
            notifySink?(key, band)
        }
    }

    /// 登出 OpenCode:清凭据 + 重置状态 + 清通知记忆(下次登录重新走首次通知)。
    public func clearOpenCode() {
        credentialStore.delete(account: Self.openCodeCookieAccount)
        openCodeCookie = ""
        openCodeWorkspaceID = ""
        openCodeQuota = nil
        openCodeError = nil
        notificationTracker.clear(provider: "opencode")
    }

    /// 预渲染图标:数据更新后调用。若 renderIconSink 为 nil 则跳过。
    public func prerenderIcon() {
        menuBarTooltip = renderTooltipSink?(self)
        renderedIcon = renderIconSink?(self)
    }

    /// 查 bl 已装版本 + 最新版本(后台,不阻塞主流程)
    public func checkBlVersion() async {
        blInstalledVersion = await BlAuthManager.installedVersion()
        blLatestVersion = await BlAuthManager.latestVersion()
    }

    private func resetTimer() {
        timer?.cancel()
        timer = Timer.publish(every: TimeInterval(refreshIntervalMinutes * 60), on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                Task {
                    await self?.refresh()
                    await self?.refreshOpenCode()   // OpenCode 随定时器一起刷
                    await self?.refreshKimi()       // Kimi 随定时器一起刷
                }
            }
    }

    /// 先查环境；默认 bl session 无效时，若已有 AK/SK 则走一次短期 token 恢复。
    public func checkAuthAndRefresh() async {
        authState = await BlAuthManager.currentAuthState()
        if authState == .ok {
            await refresh()
        } else if loadAliyunAKSK() != nil {
            aliyunAKSKConfigured = true
            await autoConfigureAliyunIfNeeded()
        }
    }

    /// 重新登录:拉起浏览器授权,并轮询 `bl auth status`(每 5s,最多 3 分钟)。
    /// 浏览器登录完成后自动回置 .ok 并立即刷数据,无需用户手动操作或等定时器。
    /// 已有轮询在跑时不重复起。
    public func relogin() {
        BlAuthManager.relogin()
        guard !isReloginWatching else { return }
        isReloginWatching = true
        Task {
            for _ in 0..<36 {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if await BlAuthManager.currentAuthState() == .ok {
                    authState = .ok
                    await refresh()
                    break
                }
            }
            isReloginWatching = false
        }
    }

    /// 拉数据。usage 每次都拉(高频);subscription/addon 仅超过 24h 或首次才拉(低频),
    /// 否则沿用上次缓存。失败时:auth 错误 → 置 .expired;其他 → 保留旧数据 + 记录错误。
    public func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        let start = Date()
        defer { isLoading = false }

        // 是否需要刷新辅助数据(首次 或 超过 24h)
        let needAux = lastAuxFetch == nil || Date().timeIntervalSince(lastAuxFetch!) >= auxRefreshInterval

        if needAux {
            // 全量拉(3 RPC)。usage 失败则以 usage-only 重试仍走全量错误路径。
            let result = await BlUsageService.fetchQuota(environment: aliyunEnvironment)
            switch result {
            case .success(let q):
                quota = q
                lastAuxFetch = Date()
                lastUpdated = Date()
                lastError = nil
                authState = authState.afterRefresh(error: nil)
                AppLog.info("阿里云全量刷新成功 5h=\(q.usage.fiveHour.percentageInt)% 7d=\(q.usage.oneWeek.percentageInt)% 耗时=\(String(format: "%.1f", Date().timeIntervalSince(start)))s", category: .aliyun)
                recordAndNotify()
            case .failure(let e):
                authState = authState.afterRefresh(error: e)
                lastError = errorMessage(e)
                AppLog.warning("阿里云全量刷新失败: \(String(describing: e))", category: .aliyun)
                if e == .authExpired { Task { await autoConfigureAliyunIfNeeded() } }
            }
        } else {
            // 只拉 usage(1 RPC),辅助数据沿用缓存
            let result = await BlUsageService.fetchUsageOnly(environment: aliyunEnvironment)
            switch result {
            case .success(let usage):
                quota = TokenPlanQuota(usage: usage,
                                       subscription: quota?.subscription,
                                       addon: quota?.addon)
                lastUpdated = Date()
                lastError = nil
                authState = authState.afterRefresh(error: nil)
                AppLog.debug("阿里云 usage 刷新成功 5h=\(usage.fiveHour.percentageInt)% 耗时=\(String(format: "%.1f", Date().timeIntervalSince(start)))s", category: .aliyun)
                recordAndNotify()
            case .failure(let e):
                authState = authState.afterRefresh(error: e)
                lastError = errorMessage(e)
                AppLog.warning("阿里云 usage 刷新失败: \(String(describing: e))", category: .aliyun)
                if e == .authExpired { Task { await autoConfigureAliyunIfNeeded() } }
            }
        }
    }

    /// 手动刷新(用户点"刷新"按钮):强制全量拉一次,无视 24h 缓存。
    public func refreshFull() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let result = await BlUsageService.fetchQuota(environment: aliyunEnvironment)
        switch result {
        case .success(let q):
            quota = q
            lastAuxFetch = Date()
            lastUpdated = Date()
            lastError = nil
            authState = authState.afterRefresh(error: nil)
            recordAndNotify()
        case .failure(let e):
            authState = authState.afterRefresh(error: e)
            lastError = errorMessage(e)
        }
    }

    private func errorMessage(_ e: UsageError) -> String {
        switch e {
        case .authExpired: return "控制台登录已过期"
        case .network(let s): return "网络错误: \(s)"
        case .parse: return "数据解析失败"
        case .invalidResponse: return "响应异常"
        case .unknown(let s): return s
        }
    }

    /// 语义化版本比较:返回 -1(a<b)/0(=)/1(a>b)。解析失败按字符串比。
    private func compareVersions(_ a: String, _ b: String) -> Int {
        let pa = a.split(separator: ".").compactMap { Int($0) }
        let pb = b.split(separator: ".").compactMap { Int($0) }
        if pa.isEmpty || pb.isEmpty { return a < b ? -1 : (a > b ? 1 : 0) }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        return 0
    }
}

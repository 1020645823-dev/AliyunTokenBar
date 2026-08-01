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

    /// 菜单栏图标预渲染缓存(数据更新时生成,label 只读)。
    @Published public var renderedIcon: NSImage?
    /// 渲染图标的闭包:由 executable 层注入(因 MenuBarTextRenderer 在 executable 层)。
    public var renderIconSink: ((TokenPlanModel) -> NSImage?)?

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

    // MARK: - 历史记录 + 通知评估(P0-P1)

    /// 把当前已知用量落盘一条快照,并对所有窗口跑一次通知评估。
    /// 在任一 Provider 刷新成功后调用(两个 Provider 任一更新都会聚合一条快照)。
    public func recordAndNotify() {
        let snap = UsageSnapshot(
            timestamp: Date(),
            aliyunFiveHour: quota?.usage.fiveHour.percentage,
            aliyunOneWeek: quota?.usage.oneWeek.percentage,
            opencodeRolling: openCodeQuota?.rolling.pct,
            opencodeWeekly: openCodeQuota?.weekly.pct,
            opencodeMonthly: openCodeQuota?.monthly.pct
        )
        historyStore.append(snap)

        // 预渲染菜单栏图标(数据更新后,主线程上下文稳定)
        prerenderIcon()

        guard notificationsEnabled else { return }
        var entries: [(WatchKey, Int)] = []
        if let q = quota {
            entries.append((WatchKey(provider: "aliyun", window: "5h"), q.usage.fiveHour.percentage))
            entries.append((WatchKey(provider: "aliyun", window: "7d"), q.usage.oneWeek.percentage))
        }
        if let oc = openCodeQuota {
            entries.append((WatchKey(provider: "opencode", window: "rolling"), oc.rolling.pct))
            entries.append((WatchKey(provider: "opencode", window: "weekly"), oc.weekly.pct))
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
        renderedIcon = renderIconSink?(self)
    }

    /// 查 bl 已装版本 + 最新版本(后台,不阻塞主流程)
    public func checkBlVersion() async {
        blInstalledVersion = BlAuthManager.installedVersion()
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
                }
            }
    }

    /// 先查环境,环境 OK 再拉数据
    public func checkAuthAndRefresh() async {
        authState = await BlAuthManager.currentAuthState()
        guard authState == .ok else { return }
        await refresh()
    }

    /// 拉数据。usage 每次都拉(高频);subscription/addon 仅超过 24h 或首次才拉(低频),
    /// 否则沿用上次缓存。失败时:auth 错误 → 置 .expired;其他 → 保留旧数据 + 记录错误。
    public func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        // 是否需要刷新辅助数据(首次 或 超过 24h)
        let needAux = lastAuxFetch == nil || Date().timeIntervalSince(lastAuxFetch!) >= auxRefreshInterval

        if needAux {
            // 全量拉(3 RPC)。usage 失败则以 usage-only 重试仍走全量错误路径。
            let result = await BlUsageService.fetchQuota()
            switch result {
            case .success(let q):
                quota = q
                lastAuxFetch = Date()
                lastUpdated = Date()
                lastError = nil
                recordAndNotify()
            case .failure(let e):
                if e == .authExpired { authState = .expired }
                lastError = errorMessage(e)
            }
        } else {
            // 只拉 usage(1 RPC),辅助数据沿用缓存
            let result = await BlUsageService.fetchUsageOnly()
            switch result {
            case .success(let usage):
                quota = TokenPlanQuota(usage: usage,
                                       subscription: quota?.subscription,
                                       addon: quota?.addon)
                lastUpdated = Date()
                lastError = nil
                recordAndNotify()
            case .failure(let e):
                if e == .authExpired { authState = .expired }
                lastError = errorMessage(e)
            }
        }
    }

    /// 手动刷新(用户点"刷新"按钮):强制全量拉一次,无视 24h 缓存。
    public func refreshFull() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let result = await BlUsageService.fetchQuota()
        switch result {
        case .success(let q):
            quota = q
            lastAuxFetch = Date()
            lastUpdated = Date()
            lastError = nil
            recordAndNotify()
        case .failure(let e):
            if e == .authExpired { authState = .expired }
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

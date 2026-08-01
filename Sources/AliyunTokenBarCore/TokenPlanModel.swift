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

    /// 刷新间隔(分钟),用户可在设置改;默认 10。只影响 usage(高频)。
    @Published public var refreshIntervalMinutes: Int = 10 {
        didSet { UserDefaults.standard.set(refreshIntervalMinutes, forKey: "refreshIntervalMinutes"); resetTimer() }
    }

    private var timer: AnyCancellable?

    /// 辅助数据(subscription/addon)上次拉取时间。这俩一天内基本不变,24h 拉一次即可,
    /// 避免每轮刷新都 spawn 3 个 node 进程(降 2/3 开销)。
    private var lastAuxFetch: Date?
    private let auxRefreshInterval: TimeInterval = 24 * 60 * 60  // 24 小时

    private init() {
        refreshIntervalMinutes = UserDefaults.standard.object(forKey: "refreshIntervalMinutes") as? Int ?? 10
    }

    /// 启动定时刷新
    public func startTimer() {
        resetTimer()
        Task { await checkAuthAndRefresh() }
        // 后台查 bl 版本(检查是否需要更新 bl,非阻塞)
        Task { await checkBlVersion() }
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
                Task { await self?.refresh() }
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

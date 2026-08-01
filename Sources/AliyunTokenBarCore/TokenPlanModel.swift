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

    /// 刷新间隔(分钟),用户可在设置改;默认 10
    @Published public var refreshIntervalMinutes: Int = 10 {
        didSet { UserDefaults.standard.set(refreshIntervalMinutes, forKey: "refreshIntervalMinutes"); resetTimer() }
    }

    private var timer: AnyCancellable?

    private init() {
        refreshIntervalMinutes = UserDefaults.standard.object(forKey: "refreshIntervalMinutes") as? Int ?? 10
    }

    /// 启动定时刷新
    public func startTimer() {
        resetTimer()
        Task { await checkAuthAndRefresh() }
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

    /// 拉一次数据。失败时:auth 错误 → 置 .expired;其他 → 保留旧数据 + 记录错误。
    public func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        let result = await BlUsageService.fetchQuota()
        switch result {
        case .success(let q):
            quota = q
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
}

import Foundation
import UserNotifications
import AliyunTokenBarCore

/// macOS 原生通知桥:把 Core 层纯逻辑的「应通知」决定落地为真正弹出的通知。
///
/// 分层:Core 的 NotificationTracker 决定「要不要通知」(纯逻辑,可测);
/// 本类负责「怎么通知」(UNUserNotificationCenter,依赖系统框架,不可单测)。
/// 经 notifySink 闭包注入 Core,Core 不反向依赖本类。
@MainActor
final class NotificationManager: NSObject, ObservableObject {
    static let shared = NotificationManager()

    /// 通知授权状态(供 UI 显示是否需要引导授权)。
    @Published private(set) var authorized = false

    private override init() { super.init() }

    /// 请求通知授权。调用时机:App 完全启动后(onAppear)或用户首次打开通知开关时。
    func requestAuthorization() {
        // 进程是否运行在正式 .app bundle 内(有 bundle id)。
        // `swift run` 裸二进制时无 bundleProxy,UNUserNotificationCenter 会抛
        // NSInternalInconsistencyException;此时安全降级为「不发通知」而非崩溃。
        // 打包成 .app 后此检查恒为 true。
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            DispatchQueue.main.async { self?.authorized = granted }
        }
    }

    /// 把 (key, band) 翻译成一条人类可读通知并发出。
    /// band 同时编码严重度:critical 用更急促的标题/图标。
    func notify(key: WatchKey, band: UsageBand) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let providerName: String
        switch key.provider {
        case "aliyun": providerName = "阿里云"
        case "opencode": providerName = "OpenCode Go"
        case "kimi": providerName = "Kimi Code"
        default: providerName = key.provider
        }
        let windowName: String
        switch key.window {
        case "5h": windowName = "5小时限额"
        case "7d": windowName = "7天限额"
        case "rolling": windowName = "滚动限额"
        case "weekly": windowName = "每周限额"
        case "monthly": windowName = "每月限额"
        default: windowName = key.window
        }
        let isCritical = band == .critical
        let title = isCritical ? "⚠️ \(providerName) \(windowName)接近上限" : "⚡ \(providerName) \(windowName)用量较高"
        let body = "当前已超过\(isCritical ? "严重" : "告警")阈值,请注意控制用量。"

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = isCritical ? .defaultCritical : .default

        let req = UNNotificationRequest(
            identifier: "\(key.provider).\(key.window)",
            content: content,
            trigger: nil   // 立即发出
        )
        AppLog.info("发出用量告警 \(key.provider).\(key.window) band=\(band.rawValue)", category: .general)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    /// 绑定到 TokenPlanModel:把 Core 的 notifySink 指向本类的 notify。
    func attach(to model: TokenPlanModel) {
        model.notifySink = { [weak self] key, band in
            self?.notify(key: key, band: band)
        }
    }
}

extension NotificationManager: UNUserNotificationCenterDelegate {
    // 允许 App 在前台时也能弹通知(默认前台会被系统抑制)。
    // 非 @MainActor:delegate 方法签名不由 main actor 定义,需 nonisolated 以满足协议要求。
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

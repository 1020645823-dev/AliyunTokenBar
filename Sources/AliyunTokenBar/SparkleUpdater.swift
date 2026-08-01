import Foundation
import AppKit
import Sparkle

/// Sparkle 自动更新管理器(单例)。
/// 仿 KimiCodeBar 的 SparkleUpdater:探测更新(不弹窗)、检测到新版本时通知 UI、引导重启安装。
@MainActor
final class SparkleUpdater: ObservableObject {
    static let shared = SparkleUpdater()

    @Published var isUpdateAvailable = false
    @Published var isUpdateReadyToRestart = false
    @Published var didDownloadFail = false
    @Published var lastCheckedAt: Date?

    /// 探测最小间隔,避免频繁开面板时反复请求更新源
    private let minCheckInterval: TimeInterval = 180
    private var lastCheckDate: Date?

    private let updaterController: SPUStandardUpdaterController
    private let delegate: UpdaterDelegate

    private init() {
        let delegate = UpdaterDelegate()
        self.delegate = delegate
        // startingUpdater: true 启动后自动按 SUScheduledCheckInterval 定时检查
        self.updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: delegate,
            userDriverDelegate: nil
        )
        delegate.owner = self
    }

    /// 探测是否有新版本(不弹窗、不自动下载)。面板打开时调用,节流 3 分钟。
    func checkForUpdateInformation() {
        if let last = lastCheckDate, Date().timeIntervalSince(last) < minCheckInterval {
            return
        }
        lastCheckDate = Date()
        updaterController.updater.checkForUpdateInformation()
    }

    /// 弹出标准更新 UI(用户点"检查更新"时)
    func showStandardUpdateUI() {
        updaterController.updater.checkForUpdates()
    }

    /// 重启并安装已下载的更新。
    /// Sparkle 2.x 没有独立的 "立即安装" API——更新就绪后由 user driver 弹窗引导安装/重启,
    /// 所以这里复用标准 UI(它会显示"安装并重启"选项)。
    func restartToInstallUpdate() {
        updaterController.updater.checkForUpdates()
    }
}

/// Sparkle 回调代理:把状态变化同步到 SparkleUpdater 的 @Published 属性。
private final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    weak var owner: SparkleUpdater?

    func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {}

    // 检测到可用更新
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        Task { @MainActor in owner?.isUpdateAvailable = true }
    }

    // 没有更新
    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Task { @MainActor in owner?.isUpdateAvailable = false }
    }

    // 下载/安装失败
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        Task { @MainActor in owner?.didDownloadFail = true }
    }

    // 更新已就绪,等待重启安装
    func updater(_ updater: SPUUpdater, didExtractUpdate item: SUAppcastItem) {
        Task { @MainActor in owner?.isUpdateReadyToRestart = true }
    }
}

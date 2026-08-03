import SwiftUI
import AppKit
import Combine
import UserNotifications
import AliyunTokenBarCore

/// 手动管理 NSStatusItem + NSPopover 的 AppDelegate。
///
/// 为什么不用 MenuBarExtra:macOS 26 的「允许在菜单栏中显示」开关一旦被系统关闭,
/// MenuBarExtra 的场景无法挂载,整个进程会被框架优雅回收(exit 0,无崩溃日志)。
/// 手动 NSStatusItem 在系统隐藏时只是 isVisible=false,进程存活。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var cancellables = Set<AnyCancellable>()
    private var visibilityMonitor = StatusItemVisibilityMonitor(requiredHiddenSamples: 3)
    private var appearanceObservation: NSKeyValueObservation?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 禁用自动终止(双保险:NSStatusItem 本身已规避 MenuBarExtra 的回收路径)
        ProcessInfo.processInfo.disableAutomaticTermination("menubar-extra")
        setupStatusItem()
        setupPopover()
        observeModel()
        // 等菜单栏完成启动布局后连续采样,避免把瞬态不可见误判为隐藏。
        scheduleVisibilityCheck()
        // 数据刷新(原 MenuBarExtra 的 .task 逻辑)——App 启动即开始,不等面板打开
        NotificationManager.shared.requestAuthorization()
        NotificationManager.shared.attach(to: TokenPlanModel.shared)
        TokenPlanModel.shared.startTimer()
        // 本机 CPU/内存:开关变化 → 启停采样(@Published 订阅即回放当前值,启动即生效);
        // 采样值变化 → 重渲染图标(renderIconSink 内部读 monitor 现值)。
        TokenPlanModel.shared.$systemStatsEnabled
            .sink { enabled in
                if enabled {
                    SystemMetricsMonitor.shared.start()
                } else {
                    SystemMetricsMonitor.shared.stop()
                }
                TokenPlanModel.shared.prerenderIcon()
            }
            .store(in: &cancellables)
        SystemMetricsMonitor.shared.$cpuPercent
            .combineLatest(SystemMetricsMonitor.shared.$memoryPercent)
            .sink { _ in TokenPlanModel.shared.prerenderIcon() }
            .store(in: &cancellables)
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.isVisible = true
        if let button = item.button {
            button.image = TokenPlanModel.shared.renderedIcon ?? fallbackIcon()
            // 不再强制 isTemplate:渲染器已为各 scheme 设好(迷你表格=非模板,其余=模板);
            // fallbackIcon(SF Symbol)默认即模板,无需处理。
            button.target = self
            button.action = #selector(togglePopover)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = TokenPlanModel.shared.menuBarTooltip
            // 菜单栏明暗:初始读 + KVO 跟踪;变化时重渲染(迷你表格基底色依赖它)。
            MenuBarAppearance.shared.isDark =
                button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            appearanceObservation = button.observe(\.effectiveAppearance, options: [.new]) { button, _ in
                let dark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                Task { @MainActor in
                    MenuBarAppearance.shared.isDark = dark
                    TokenPlanModel.shared.prerenderIcon()
                }
            }
            // 用真实明暗值重渲染一次(首个图标可能在读到 appearance 前已按默认浅色基底渲染)
            TokenPlanModel.shared.prerenderIcon()
        }
        statusItem = item
    }

    private func setupPopover() {
        let p = NSPopover()
        p.contentSize = NSSize(width: 340, height: 560)
        p.behavior = .transient
        p.animates = true
        p.contentViewController = NSHostingController(rootView: TokenPlanMenu())
        popover = p
    }

    /// 订阅模型:renderedIcon 更新时同步到状态项按钮(含 tooltip)。
    private func observeModel() {
        let model = TokenPlanModel.shared
        model.$renderedIcon
            .receive(on: RunLoop.main)
            .sink { [weak self] icon in
                guard let self, let button = self.statusItem?.button else { return }
                if let icon {
                    button.image = icon   // isTemplate 由渲染器决定,此处不覆写
                } else {
                    button.image = self.fallbackIcon()
                    button.image?.isTemplate = true
                }
                button.toolTip = model.menuBarTooltip
            }
            .store(in: &cancellables)
    }

    @objc private func togglePopover() {
        guard let popover, let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func scheduleVisibilityCheck() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, let statusItem = self.statusItem else { return }
            if statusItem.isVisible { return }
            if self.visibilityMonitor.record(isVisible: false) {
                self.handleVisibilityFallback()
            } else {
                self.scheduleVisibilityCheck()
            }
        }
    }

    /// 多次未检测到状态项时回退:改为 .regular 显示 Dock 图标 + 通知引导。
    private func handleVisibilityFallback() {
        NSApp.setActivationPolicy(.regular)
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = "未检测到菜单栏图标"
        content.body = "图标可能因菜单栏空间不足或系统设置而未显示。请检查 系统设置 → 控制中心 → 菜单栏,或从 Dock 图标打开。"
        content.sound = .default
        center.add(UNNotificationRequest(identifier: "menubar-hidden-fallback", content: content, trigger: nil))
    }

    private func fallbackIcon() -> NSImage {
        NSImage(systemSymbolName: "cloud.fill", accessibilityDescription: "CodingTokenBar")
            ?? NSImage(size: NSSize(width: 22, height: 22))
    }
}
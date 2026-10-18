import SwiftUI
import AppKit
import Combine
import UserNotifications
import AliyunTokenBarCore

/// 灵动岛悬停转发器:NSTrackingArea 的 owner 必须是 NSResponder 子类,
/// AppDelegate 不是 responder,收不到 mouseEntered——用它接住再转回 AppDelegate。
@MainActor
private final class IslandHoverTracker: NSResponder {
    var onEnter: (() -> Void)?
    override func mouseEntered(with event: NSEvent) { onEnter?() }
}

/// 手动管理 NSStatusItem + NSPopover 的 AppDelegate。
///
/// 为什么不用 MenuBarExtra:macOS 26 的「允许在菜单栏中显示」开关一旦被系统关闭,
/// MenuBarExtra 的场景无法挂载,整个进程会被框架优雅回收(exit 0,无崩溃日志)。
/// 手动 NSStatusItem 在系统隐藏时只是 isVisible=false,进程存活。
///
/// 存活不等于可达:macOS 26 也会在运行期把状态项隐藏/「停放」到屏幕外(菜单栏
/// 空间竞争、全屏应用、系统级开关)。Accessory 应用无 Dock 图标,状态项是唯一
/// 入口,因此本类常驻可见性监控(StatusItemRecoveryMonitor):连续异常按阶梯
/// 恢复(重设可见 → 重建状态项 → Dock 回退),并对外提供 codingtokenbar://open
/// 与双击 .app 重开(reopen)两条救生索。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var cancellables = Set<AnyCancellable>()
    private var recoveryMonitor = StatusItemRecoveryMonitor(requiredHiddenSamples: 3)
    private var themeChangeObserver: NSObjectProtocol?
    private var visibilityTimer: Timer?
    /// 启动期未见可见前用 1s 快采样(与旧启动自检节奏一致),确认可见后转 30s 慢采样。
    private var hasSeenStatusItemVisible = false
    /// 上次采样的有效可见值(变化时落 OSLog,便于事后诊断)。
    private var lastLoggedEffectivelyVisible: Bool?
    /// 灵动岛 scheme 下,状态项按钮上的悬停追踪区(进入 → 展开动态岛)。
    private var islandTrackingArea: NSTrackingArea?
    /// tracking area owner 必须是 NSResponder 子类(AppDelegate 不是),用它转发。
    private let islandHoverTracker = IslandHoverTracker()

    /// P1-C10:URL scheme 触发刷新(codingtokenbar://refresh),供脚本/快捷指令调用;
    /// codingtokenbar://open 为救生索:状态项不可见时兜底弹设置窗。
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "codingtokenbar" {
            switch url.host {
            case nil, "refresh":
                AppLog.info("URL scheme 触发刷新: \(url.absoluteString)", category: .general)
                Task { await TokenPlanModel.shared.refreshAll() }
            case "open", "panel", "settings":
                AppLog.info("URL scheme 打开面板: \(url.absoluteString)", category: .general)
                openPanelOrFallback()
            default:
                break
            }
        }
    }

    /// 双击 .app/Dock 图标重开运行中的实例:状态项可见则弹面板,不可见则兜底
    /// Dock 图标+设置窗——避免「进程在跑但无处可点」被感知为「应用打不开」。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openPanelOrFallback()
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 单实例保护(P0-D2):双开会并发写 history.json + 双状态项 + 通知双发。
        // swift run 裸二进制无 bundle id,自动跳过;history 写入另有 flock 双保险。
        enforceSingleInstance()
        // 禁用自动终止(双保险:NSStatusItem 本身已规避 MenuBarExtra 的回收路径)
        ProcessInfo.processInfo.disableAutomaticTermination("menubar-extra")
        setupStatusItem()
        setupPopover()
        observeModel()
        // 常驻可见性监控:启动 1s 快采样对齐旧自检节奏,运行期 30s 慢采样,
        // 连续异常走恢复阶梯(详见 StatusItemRecoveryMonitor)。
        scheduleNextVisibilityTick(interval: 1)
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
        // 菜单栏样式切换:即时重渲染图标(此前只有数据刷新才重建图),
        // 并装/拆灵动岛的悬停追踪区。
        MenuBarStyleManager.shared.$scheme
            .receive(on: RunLoop.main)
            .sink { [weak self] scheme in
                TokenPlanModel.shared.prerenderIcon()
                self?.updateIslandWiring(scheme)
            }
            .store(in: &cancellables)
        updateIslandWiring(MenuBarStyleManager.shared.scheme)
        // 岛行点击 → 面板跳转:由 AppDelegate 自己注入。**不要**在别处用
        // `NSApp.delegate as? AppDelegate` —— SwiftUI 的 NSApplicationDelegateAdaptor
        // 会把 delegate 包一层代理,强转必然失败(实测 delegate=false,点击静默无效果)。
        IslandOverlayController.shared.openPanelSink = { [weak self] kind in
            guard let self,
                  let tab = ProviderTab(kind: ProviderKind.from(menuBarColumnKind: kind)) else { return }
            self.openPanel(tab: tab)
        }
        // 占位 scene 的空白窗:SwiftUI 在启动/激活时自动打开它 → 出现即关(见方法注释)。
        // ⚠️ 启动期而不是「激活通知」才是主路径:实测 `open -g -j`(隐藏启动)不弹,
        // 普通 `open` 就弹,且此时 NSApplication.didBecomeActiveNotification 未必发。
        // 故启动后连扫四次(0/0.5/1.5/3s)兜住 SwiftUI 稍后才 orderFront 的情况。
        Task { @MainActor in
            let delays: [UInt64] = [0, 500_000_000, 1_500_000_000, 3_000_000_000]
            for d in delays {
                if d > 0 { try? await Task.sleep(nanoseconds: d) }
                self.closePlaceholderWindows()
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.closePlaceholderWindows()
                try? await Task.sleep(nanoseconds: 400_000_000)
                self?.closePlaceholderWindows()
            }
        }
        // 该窗口若成为 key/main(用户点了它),也立刻关掉
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let w = note.object as? NSWindow else { return }
                Task { @MainActor in
                    guard let self, self.isPlaceholderWindowTitle(w.title) else { return }
                    AppLog.info("关闭 SwiftUI 占位空白窗(\(w.title))", category: .general)
                    w.orderOut(nil)
                }
            }
        }
    }

    // MARK: - 灵动岛(菜单栏悬停展开)

    /// 按 scheme 装/拆状态项悬停追踪区;离开 island scheme 时立即收起动态岛。
    private func updateIslandWiring(_ scheme: MenuBarDisplayScheme) {
        if scheme == .island {
            ensureIslandTrackingArea()
            IslandOverlayController.shared.prewarm()
        } else {
            removeIslandTrackingArea()
            IslandOverlayController.shared.collapseNow()
        }
    }

    private func ensureIslandTrackingArea() {
        guard let button = statusItem?.button, islandTrackingArea == nil else { return }
        islandHoverTracker.onEnter = { [weak self] in
            // 主面板打开中不展开(岛与弹层同区会叠在一起)
            guard self?.popover?.isShown != true else { return }
            self?.islandExpand()
        }
        // .inVisibleRect:rect 由按钮实际 bounds 决定(胶囊宽度随内容变)
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: islandHoverTracker)
        button.addTrackingArea(area)
        islandTrackingArea = area
    }

    private func removeIslandTrackingArea() {
        if let area = islandTrackingArea {
            statusItem?.button?.removeTrackingArea(area)
            islandTrackingArea = nil
        }
    }

    /// 鼠标进入胶囊 → 展开动态岛(由 IslandHoverTracker 转发)。
    private func islandExpand() {
        IslandOverlayController.shared.expandIfNeeded(statusItem?.button)
    }

    /// 岛行点击/重登:写路由 → 收起岛并抑制 → 打开面板(与状态项点击同一路径)。
    /// 弹出**延后一拍**:触发这次跳转的点击落在岛的覆盖面板上(popover 之外),
    /// transient popover 的事件监视器会把同一次点击当成「点外面」而立刻关闭(实测)。
    func openPanel(tab: ProviderTab) {
        PanelRouter.shared.open(tab: tab)
        guard let popover, let button = statusItem?.button else { return }
        IslandOverlayController.shared.collapseNow()
        IslandOverlayController.shared.setSuppressed(true)
        guard !popover.isShown else { return }
        DispatchQueue.main.async {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    /// 检测已有实例:存在则激活它并退出自己(幂等,首启无副作用)。
    private func enforceSingleInstance() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        let mine = ProcessInfo.processInfo.processIdentifier
        guard running.contains(where: { $0.processIdentifier != mine }) else { return }
        if let other = running.first(where: { $0.processIdentifier != mine }) {
            other.activate(options: [.activateAllWindows])
            // 已有实例可能状态项不可见(无处可点),借 URL scheme 让它把 UI 亮出来。
            NSWorkspace.shared.open(URL(string: "codingtokenbar://open")!)
        }
        NSApp.terminate(nil)
    }

    private func setupStatusItem() {
        rebuildStatusItem()
        // 菜单栏明暗:读系统全局域 AppleInterfaceStyle。
        // 不能用 button.effectiveAppearance——用户强制 app 主题时 NSApp.appearance
        // 会污染按钮外观,与菜单栏真实明暗脱节(曾致黑字隐没于深菜单栏)。
        themeChangeObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshMenuBarAppearance()
                TokenPlanModel.shared.prerenderIcon()
            }
        }
        // 用真实明暗值重渲染一次(首个图标可能在读取前已按默认浅色基底渲染)
        TokenPlanModel.shared.prerenderIcon()
    }

    /// (重)建状态项:恢复阶梯的 recreate 级也走这里——移除旧 item(停放坐标
    /// 挂在旧 item 上,remove 即释放)后新建,由系统重新布局。
    private func rebuildStatusItem() {
        if let old = statusItem {
            NSStatusBar.system.removeStatusItem(old)
            statusItem = nil
        }
        // 旧按钮随 removeStatusItem 释放,其 tracking area 一并失效;引用清零后
        // 由 updateIslandWiring 按当前 scheme 重装。动态岛面板锚在旧胶囊上,先收。
        islandTrackingArea = nil
        IslandOverlayController.shared.collapseNow()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.isVisible = true
        if let button = item.button {
            button.image = TokenPlanModel.shared.renderedIcon ?? fallbackIcon()
            // 不再强制 isTemplate:渲染器已为各 scheme 设好(迷你表格=非模板,其余=模板);
            // fallbackIcon(SF Symbol)默认即模板,无需处理。
            button.target = self
            button.action = #selector(togglePopover)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            // 灵动岛模式下 tooltip 与展开卡片同区,省略(卡片本身信息更全)
            button.toolTip = MenuBarStyleManager.shared.scheme == .island
                ? nil : TokenPlanModel.shared.menuBarTooltip
            refreshMenuBarAppearance()
        }
        statusItem = item
        updateIslandWiring(MenuBarStyleManager.shared.scheme)
    }

    /// 菜单栏明暗 = 系统外观(全局域 AppleInterfaceStyle,深色时存在,浅色时缺省)。
    /// 与 app 内强制主题(ThemeManager)正交:菜单栏永远跟随系统,不跟随 app。
    private func refreshMenuBarAppearance() {
        let global = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)
        MenuBarAppearance.shared.isDark = (global?["AppleInterfaceStyle"] as? String) == "Dark"
    }

    func setupPopover() {
        let p = NSPopover()
        p.contentSize = NSSize(width: 360, height: 560)
        p.behavior = .transient
        p.animates = true
        p.contentViewController = NSHostingController(rootView: TokenPlanMenu())
        popover = p
        // 弹层外观跟随 app 主题:强制浅/深时与设置窗/登录窗一致;
        // 跟随系统时 NSApp.appearance=nil → popover 保持默认(跟随系统)。
        // (NSPopover 默认只跟系统外观,不跟 NSApp.appearance——
        //  强制浅色 + 系统深色时弹层会黑、窗口白,主题割裂。)
        NSApp.publisher(for: \.appearance, options: [.initial, .new])
            .sink { [weak self] appearance in
                self?.popover?.appearance = appearance
            }
            .store(in: &cancellables)
        // 弹层被 Esc/点外面关掉(不经 togglePopover)时解除动态岛抑制,
        // 否则悬停胶囊再也不展开。
        NotificationCenter.default.addObserver(
            forName: NSPopover.didCloseNotification, object: popover, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.islandPopoverDidClose()
            }
        }
    }

    private func islandPopoverDidClose() {
        IslandOverlayController.shared.setSuppressed(false)
    }

    // MARK: - 占位 scene 空白窗(唤醒即弹)

    /// SwiftUI 在 app「被激活且没有任何窗口」时会自动打开它声明的 scene —— 我们的
    /// 占位 `Settings { EmptyView() }` 因此表现为一个空白白窗(标题「CodingTokenBar设置」,
    /// 恢复上次窗口帧)。触发场景:`open .app`(install-update.sh 即如此)、Dock/Finder
    /// 激活;`open -g` 不激活则不弹。本 app 的 UI 全在 AppKit,不需要任何 SwiftUI 窗口,
    /// 出现即关。macOS 15+ 本可用 `.defaultLaunchBehavior(.suppressed)`,但 SceneBuilder
    /// 不支持 `if #available` 分支(编译不过)。
    /// 按**标题精确匹配**,不误伤登录窗(「CodingTokenBar · 阿里云登录」)与设置面板(「设置」)。
    private func isPlaceholderWindowTitle(_ title: String) -> Bool {
        title == "CodingTokenBar" || title == "CodingTokenBar设置"
    }

    private func closePlaceholderWindows() {
        for w in NSApp.windows where w.isVisible && isPlaceholderWindowTitle(w.title) {
            AppLog.info("关闭 SwiftUI 占位空白窗(\(w.title))", category: .general)
            w.orderOut(nil)
        }
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
                button.toolTip = MenuBarStyleManager.shared.scheme == .island
                    ? nil : model.menuBarTooltip
            }
            .store(in: &cancellables)
    }

    @objc private func togglePopover() {
        guard let popover, let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            IslandOverlayController.shared.setSuppressed(false)
        } else {
            // 开主面板前收起动态岛,并抑制期间再展开(岛与弹层同区)
            IslandOverlayController.shared.collapseNow()
            IslandOverlayController.shared.setSuppressed(true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    // MARK: - 常驻可见性监控与恢复阶梯

    private func scheduleNextVisibilityTick(interval: TimeInterval) {
        visibilityTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.tickVisibilityMonitor() }
        }
        RunLoop.main.add(timer, forMode: .common)
        visibilityTimer = timer
    }

    private func currentEffectivelyVisible() -> Bool {
        guard let statusItem else { return false }
        return StatusItemRecoveryMonitor.isEffectivelyVisible(
            isVisible: statusItem.isVisible,
            buttonFrame: statusItem.button?.window?.frame,
            screenFrames: NSScreen.screens.map(\.frame)
        )
    }

    private func tickVisibilityMonitor() {
        let effectivelyVisible = currentEffectivelyVisible()
        if effectivelyVisible {
            hasSeenStatusItemVisible = true
        }
        if lastLoggedEffectivelyVisible != effectivelyVisible {
            lastLoggedEffectivelyVisible = effectivelyVisible
            // 不可见走 warning 级(OSLog info 默认不落盘,真出事时要能事后检索到)
            if effectivelyVisible {
                AppLog.info("状态项有效可见性 → true", category: .general)
            } else {
                AppLog.warning("状态项有效可见性 → false(被系统隐藏/停放?)", category: .general)
            }
        }
        let action = recoveryMonitor.sample(isEffectivelyVisible: effectivelyVisible)
        switch action {
        case .none:
            break
        case .resurrect:
            AppLog.warning("状态项持续不可见,尝试重设 isVisible", category: .general)
            statusItem?.isVisible = true
        case .recreate:
            AppLog.warning("状态项仍不可见,重建状态项(对抗系统停放)", category: .general)
            rebuildStatusItem()
            TokenPlanModel.shared.prerenderIcon()
        case .dockFallback:
            handleVisibilityFallback()
        }
        // 恢复动作后 5s 复评(给动作留生效窗口);其余按 启动快/运行慢 节奏。
        let next: TimeInterval
        if action != .none {
            next = 5
        } else {
            next = hasSeenStatusItemVisible ? 30 : 1
        }
        scheduleNextVisibilityTick(interval: next)
    }

    /// 多次未检测到状态项时回退:改为 .regular 显示 Dock 图标 + 通知引导。
    private func handleVisibilityFallback() {
        AppLog.warning("菜单栏状态项持续不可见,回退 Dock 图标 + 通知引导", category: .general)
        NSApp.setActivationPolicy(.regular)
        // `swift run` 裸二进制无 bundleProxy,UNUserNotificationCenter 会抛
        // NSInternalInconsistencyException(Swift 不可 catch)——只对有 bundle 的进程发通知。
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = "未检测到菜单栏图标"
        content.body = "图标可能因菜单栏空间不足或系统设置而未显示。请检查 系统设置 → 控制中心 → 菜单栏,或从 Dock 图标打开。"
        content.sound = .default
        center.add(UNNotificationRequest(identifier: "menubar-hidden-fallback", content: content, trigger: nil))
    }

    // MARK: - 救生索入口(URL scheme open / 双击 .app reopen 共用)

    /// 状态项有效可见 → 弹出面板;否则落 Dock 图标 + 弹设置窗(保证总有入口)。
    private func openPanelOrFallback() {
        if currentEffectivelyVisible(), let popover, let button = statusItem?.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        } else {
            AppLog.warning("打开面板:状态项不可见,回退 Dock 图标 + 设置窗", category: .general)
            NSApp.setActivationPolicy(.regular)
            SettingsWindowManager.shared.show()
        }
    }

    private func fallbackIcon() -> NSImage {
        NSImage(systemSymbolName: "cloud.fill", accessibilityDescription: "CodingTokenBar")
            ?? NSImage(size: NSSize(width: 22, height: 22))
    }
}

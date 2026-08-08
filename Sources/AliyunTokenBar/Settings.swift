import SwiftUI
import AppKit
import ServiceManagement
import AliyunTokenBarCore

// MARK: - 开机自启

@MainActor
final class LaunchAtLoginManager: ObservableObject {
    static let shared = LaunchAtLoginManager()
    @Published private(set) var isEnabled = SMAppService.mainApp.status == .enabled
    func toggle(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch { /* 系统设置手动改动时保持现状 */ }
        isEnabled = SMAppService.mainApp.status == .enabled
    }
}

// MARK: - 设置窗口管理(单例,Settings 环境注入)

@MainActor
final class SettingsWindowManager: ObservableObject {
    static let shared = SettingsWindowManager()
    func show() { SettingsWindow.shared.show() }
}

@MainActor
private final class SettingsWindow {
    static let shared = SettingsWindow()
    private var panel: NSPanel?
    func show() {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 480),
                            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            p.title = "CodingTokenBar 设置"
            p.isFloatingPanel = true
            p.minSize = NSSize(width: 560, height: 460)
            p.center()
            panel = p
        }
        panel?.contentView = NSHostingView(rootView: SettingsView())
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - 设置页分组

/// 设置页:通用 / 外观 / 通知 / 服务(系统设置式侧边栏导航)。
enum SettingsPage: String, CaseIterable, Identifiable {
    case general, appearance, notifications, services
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: return "通用"
        case .appearance: return "外观"
        case .notifications: return "通知"
        case .services: return "服务"
        }
    }
    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintpalette"
        case .notifications: return "bell"
        case .services: return "cloud"
        }
    }
}

// MARK: - 设置主页(侧边栏 + 详情)

struct SettingsView: View {
    @StateObject private var model = TokenPlanModel.shared
    @State private var selection: SettingsPage? = .general

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(SettingsPage.allCases) { page in
                    Label(page.title, systemImage: page.icon).tag(page)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 160, ideal: 160, max: 160)
        } detail: {
            detailView(selection ?? .general)
        }
        .frame(minWidth: 620, minHeight: 460)
        .onChange(of: model.notificationsEnabled) { on in
            // 打开通知开关时(重新)请求系统授权:用户可能首次拒绝过
            if on { NotificationManager.shared.requestAuthorization() }
        }
    }

    @ViewBuilder
    private func detailView(_ page: SettingsPage) -> some View {
        switch page {
        case .general: GeneralSettingsPage()
        case .appearance: AppearanceSettingsPage()
        case .notifications: NotificationSettingsPage()
        case .services: ServicesSettingsPage()
        }
    }
}

// MARK: - 通用

private struct GeneralSettingsPage: View {
    @StateObject private var model = TokenPlanModel.shared
    @StateObject private var launch = LaunchAtLoginManager.shared
    var body: some View {
        Form {
            Section("启动") {
                Toggle("开机自动启动", isOn: Binding(get: { launch.isEnabled }, set: { launch.toggle($0) }))
            }
            Section("刷新") {
                Picker("刷新间隔", selection: $model.refreshIntervalMinutes) {
                    Text("5 分钟").tag(5); Text("10 分钟").tag(10)
                    Text("30 分钟").tag(30); Text("60 分钟").tag(60)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 外观

private struct AppearanceSettingsPage: View {
    @StateObject private var model = TokenPlanModel.shared
    @StateObject private var theme = ThemeManager.shared
    @StateObject private var menuBarStyle = MenuBarStyleManager.shared
    var body: some View {
        Form {
            Section("主题") {
                Picker("主题", selection: $theme.theme) {
                    ForEach(AppTheme.allCases) { t in
                        Label(t.displayName, systemImage: t.iconName).tag(t)
                    }
                }
            }
            Section("菜单栏") {
                Picker("菜单栏样式", selection: $menuBarStyle.scheme) {
                    ForEach(MenuBarDisplayScheme.allCases) { s in
                        Text(s.displayName).tag(s)
                    }
                }
                Toggle("显示本机 CPU/内存", isOn: $model.systemStatsEnabled)
            }
            Section("面板") {
                Toggle("显示用量趋势线", isOn: $model.sparklineEnabled)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 通知

private struct NotificationSettingsPage: View {
    @StateObject private var model = TokenPlanModel.shared
    var body: some View {
        Form {
            Section("用量告警") {
                Toggle("接近上限时通知", isOn: $model.notificationsEnabled)
                if model.notificationsEnabled {
                    // 告警阈值(提示级):50/70/80
                    Picker("提示阈值", selection: Binding(
                        get: { model.thresholdConfig.warning },
                        set: { model.thresholdConfig = ThresholdConfig(warning: $0, critical: model.thresholdConfig.critical) }
                    )) {
                        Text("50%").tag(50); Text("70%").tag(70); Text("80%").tag(80)
                    }
                    // 严重阈值:80/90/95
                    Picker("严重阈值", selection: Binding(
                        get: { model.thresholdConfig.critical },
                        set: { model.thresholdConfig = ThresholdConfig(warning: model.thresholdConfig.warning, critical: $0) }
                    )) {
                        Text("80%").tag(80); Text("90%").tag(90); Text("95%").tag(95)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 服务(Task 4 填卡片,先占位编译通过)

private struct ServicesSettingsPage: View {
    var body: some View {
        Text("服务")
    }
}

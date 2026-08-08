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

// MARK: - 服务(状态卡片)

private struct ServicesSettingsPage: View {
    @StateObject private var model = TokenPlanModel.shared
    @State private var showOpenCodeLogin = false
    @State private var showKimiLogin = false

    var body: some View {
        ScrollView {
            VStack(spacing: DesignTokens.spacingM) {
                aliyunCard
                kimiCard
                openCodeCard
            }
            .padding(DesignTokens.spacingL)
        }
        .sheet(isPresented: $showOpenCodeLogin) { OpenCodeLoginView() }
        .sheet(isPresented: $showKimiLogin) { KimiLoginView() }
    }

    // MARK: 阿里云

    private var aliyunCard: some View {
        cardContainer(icon: "cloud.fill", iconColor: .atbBlue, title: "阿里云 (百炼)") {
            if model.aliyunAKSKConfigured {
                statusRow("OpenAPI AK/SK 已配置,token 过期将自动刷新")
                Button("清除 AK/SK") { model.clearAliyunAKSK() }
                    .buttonStyle(ATBTextButtonStyle(color: .red)).font(.system(size: 12))
            } else {
                Button("配置 OpenAPI AK/SK (推荐)") { AliyunAKSKWindowManager.shared.show() }
                    .buttonStyle(ATBPrimaryButtonStyle())
                caption("配置后 token 过期将自动刷新,无需浏览器登录。AK/SK 保存在系统钥匙串,仅本应用可读取。")
            }
        }
    }

    // MARK: Kimi

    private var kimiCard: some View {
        cardContainer(icon: "sparkles", iconColor: .teal, title: "Kimi Code") {
            if model.kimiConfigured {
                statusRow("已连接(复用本机 KimiCodeBar / Kimi CLI 凭证)")
                if model.kimiWebLoggedIn {
                    statusRow("已登录网页控制台(订阅总额度可用)")
                    Button("登出网页控制台") { model.clearKimi() }
                        .buttonStyle(ATBTextButtonStyle(color: .red)).font(.system(size: 12))
                } else {
                    Button("登录 Kimi 网页控制台") { showKimiLogin = true }
                        .buttonStyle(ATBPrimaryButtonStyle())
                    caption("登录后可查看订阅总额度(月度用量)。点击登录,在弹出窗口完成 Kimi 账号授权。")
                }
                Button("立即刷新") { Task { await model.refreshKimi() } }
                    .buttonStyle(ATBTextButtonStyle()).font(.system(size: 12))
            } else {
                caption("未检测到本机 Kimi 登录凭证。请先安装并登录 Kimi Code CLI 或 KimiCodeBar。")
            }
        }
    }

    // MARK: OpenCode

    private var openCodeCard: some View {
        cardContainer(icon: "bolt.fill", iconColor: .purple, title: "OpenCode Go") {
            if model.openCodeConfigured {
                statusRow("已登录 (workspace: \(model.openCodeWorkspaceID.prefix(12))...)")
                Button("登出") { model.clearOpenCode() }
                    .buttonStyle(ATBTextButtonStyle(color: .red)).font(.system(size: 12))
            } else {
                Button("登录 OpenCode") { showOpenCodeLogin = true }
                    .buttonStyle(ATBPrimaryButtonStyle())
                caption("点击登录,在弹出窗口完成 OpenCode 授权。cookie 会过期,届时可重新登录。")
            }
        }
    }

    // MARK: 卡片零件

    /// 卡片容器:头部(图标+标题)+ 内容,视觉 token 与弹层卡片一致。
    private func cardContainer<Content: View>(icon: String, iconColor: Color, title: String,
                                              @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingS + 2) {
            HStack(spacing: DesignTokens.spacingS) {
                Image(systemName: icon).font(.system(size: 13, weight: .bold)).foregroundStyle(iconColor)
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(.atbTextPrimary)
            }
            content()
        }
        .padding(DesignTokens.spacingL)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.atbCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radiusL))
        .shadow(color: Color.black.opacity(0.04), radius: 2, y: 1)
    }

    /// 已连接状态行:绿勾 + 描述。
    private func statusRow(_ text: String) -> some View {
        HStack(spacing: DesignTokens.spacingXS + 2) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text(text).font(.system(size: 11)).foregroundStyle(.atbTextSecondary)
        }
    }

    /// 说明文字(未配置引导/补充描述)。
    private func caption(_ text: String) -> some View {
        Text(text).font(.system(size: 10)).foregroundStyle(.atbTextSecondary)
    }
}

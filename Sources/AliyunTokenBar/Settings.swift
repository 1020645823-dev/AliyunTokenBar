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
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 300),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
            p.title = "AliyunTokenBar 设置"
            p.isFloatingPanel = true
            p.center()
            panel = p
        }
        panel?.contentView = NSHostingView(rootView: SettingsView())
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct SettingsView: View {
    @StateObject private var model = TokenPlanModel.shared
    @StateObject private var launch = LaunchAtLoginManager.shared
    @StateObject private var theme = ThemeManager.shared
    @StateObject private var menuBarStyle = MenuBarStyleManager.shared
    @State private var showOpenCodeLogin = false
    @State private var showKimiLogin = false
    var body: some View {
        Form {
            Section("外观") {
                Picker("主题", selection: $theme.theme) {
                    ForEach(AppTheme.allCases) { t in
                        Label(t.displayName, systemImage: t.iconName).tag(t)
                    }
                }
                Picker("菜单栏样式", selection: $menuBarStyle.scheme) {
                    ForEach(MenuBarDisplayScheme.allCases) { s in
                        Text(s.displayName).tag(s)
                    }
                }
                Toggle("显示本机 CPU/内存", isOn: $model.systemStatsEnabled)
            }
            Section("刷新") {
                Picker("刷新间隔", selection: $model.refreshIntervalMinutes) {
                    Text("5 分钟").tag(5); Text("10 分钟").tag(10); Text("30 分钟").tag(30); Text("60 分钟").tag(60)
                }
            }
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
            Section("面板趋势") {
                Toggle("显示用量趋势线", isOn: $model.sparklineEnabled)
            }
            Section("OpenCode Go") {
                if model.openCodeConfigured {
                    HStack {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("已登录 (workspace: \(model.openCodeWorkspaceID.prefix(12))...)").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Button("登出") {
                        model.clearOpenCode()
                    }.buttonStyle(.plain).foregroundStyle(.red).font(.system(size: 12))
                } else {
                    Button("登录 OpenCode") { showOpenCodeLogin = true }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(Color.purple.opacity(0.8))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    Text("点击登录,在弹出窗口完成 OpenCode 授权。cookie 会过期,届时可重新登录。")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            Section("Kimi Code") {
                if model.kimiConfigured {
                    HStack {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("已连接(复用本机 KimiCodeBar / Kimi CLI 凭证)").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    if model.kimiWebLoggedIn {
                        HStack {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            Text("已登录网页控制台(订阅总额度可用)").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Button("登出网页控制台") {
                            model.clearKimi()
                        }.buttonStyle(.plain).foregroundStyle(.red).font(.system(size: 12))
                    } else {
                        Button("登录 Kimi 网页控制台") { showKimiLogin = true }
                            .buttonStyle(.plain)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16).padding(.vertical, 8)
                            .background(Color.teal.opacity(0.8))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        Text("登录后可查看订阅总额度(月度用量)。点击登录,在弹出窗口完成 Kimi 账号授权。")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Button("立即刷新") { Task { await model.refreshKimi() } }
                        .buttonStyle(.plain).foregroundStyle(.atbBlue).font(.system(size: 12))
                } else {
                    Text("未检测到本机 Kimi 登录凭证。请先安装并登录 Kimi Code CLI 或 KimiCodeBar。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Section("通用") {
                Toggle("开机自动启动", isOn: Binding(get: { launch.isEnabled }, set: { launch.toggle($0) }))
            }
        }
        .padding(16)
        .sheet(isPresented: $showOpenCodeLogin) {
            OpenCodeLoginView()
        }
        .sheet(isPresented: $showKimiLogin) {
            KimiLoginView()
        }
        .onChange(of: model.notificationsEnabled) { on in
            // 打开通知开关时(重新)请求系统授权:用户可能首次拒绝过
            if on { NotificationManager.shared.requestAuthorization() }
        }
    }
}

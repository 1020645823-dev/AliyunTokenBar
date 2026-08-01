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
            }
            Section("刷新") {
                Picker("刷新间隔", selection: $model.refreshIntervalMinutes) {
                    Text("5 分钟").tag(5); Text("10 分钟").tag(10); Text("30 分钟").tag(30); Text("60 分钟").tag(60)
                }
            }
            Section("OpenCode Go") {
                TextField("Workspace ID", text: $model.openCodeWorkspaceID)
                    .font(.system(size: 12, design: .monospaced))
                SecureField("Auth Cookie", text: $model.openCodeCookie)
                Text("在浏览器登录 opencode.ai 后,F12 → Network → 任一请求的 Cookie 头复制 auth 值;Workspace ID 在 Go 页面 URL(wrk_xxx)。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Section("通用") {
                Toggle("开机自动启动", isOn: Binding(get: { launch.isEnabled }, set: { launch.toggle($0) }))
            }
        }.padding(16)
    }
}

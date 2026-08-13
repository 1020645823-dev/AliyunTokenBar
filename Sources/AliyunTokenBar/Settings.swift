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
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 700, height: 560),
                            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            p.title = "设置"
            p.isFloatingPanel = true
            p.minSize = NSSize(width: 620, height: 500)
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
    case general, appearance, notifications, services, history
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: return "通用"
        case .appearance: return "外观"
        case .notifications: return "通知"
        case .services: return "服务"
        case .history: return "历史"
        }
    }
    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintpalette"
        case .notifications: return "bell"
        case .services: return "cloud"
        case .history: return "chart.xyaxis.line"
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
        .frame(minWidth: 620, minHeight: 500)
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
        case .history: HistorySettingsPage()
        }
    }
}

// MARK: - 通用

private struct GeneralSettingsPage: View {
    @StateObject private var model = TokenPlanModel.shared
    @StateObject private var launch = LaunchAtLoginManager.shared
    @State private var checkingUpdate = false
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
            Section("关于") {
                LabeledContent("版本", value: SelfUpdater.currentVersion())
                HStack {
                    if let update = model.appUpdate {
                        Label("新版本 \(update.version) 可用", systemImage: "arrow.down.circle.fill")
                            .font(.system(size: 12)).foregroundStyle(.orange)
                        Spacer()
                        Button("前往下载") { model.openUpdatePage() }
                            .buttonStyle(ATBTextButtonStyle())
                    } else {
                        Text(checkingUpdate ? "正在检查…" : "已是最新版本")
                            .font(.system(size: 12)).foregroundStyle(.atbTextSecondary)
                        Spacer()
                        Button("检查更新") {
                            checkingUpdate = true
                            Task {
                                await model.checkAppUpdate()
                                checkingUpdate = false
                            }
                        }
                        .buttonStyle(ATBTextButtonStyle())
                        .disabled(checkingUpdate)
                    }
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
    @StateObject private var notifier = NotificationManager.shared
    var body: some View {
        Form {
            Section("系统授权") {
                HStack {
                    Image(systemName: notifier.authorized ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(notifier.authorized ? .green : .orange)
                    Text(notifier.authorized ? "通知权限已授予" : "通知权限未授予")
                        .font(.system(size: 12)).foregroundStyle(.atbTextSecondary)
                    Spacer()
                    if !notifier.authorized {
                        Button("打开系统设置") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(ATBTextButtonStyle())
                    }
                }
            }
            Section("用量告警") {
                Toggle("接近上限时通知", isOn: $model.notificationsEnabled)
                Toggle("每日用量摘要", isOn: $model.dailyDigestEnabled)
                if model.dailyDigestEnabled {
                    Text("每天 20:00 汇总阿里云 / OpenCode / Kimi 用量发送一条通知。")
                        .font(.system(size: 10)).foregroundStyle(.atbTextSecondary)
                }
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
    @State private var manualWorkspaceID = ""
    @State private var manualWorkspaceError: String?

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
                manualWorkspaceRow
                Button("登出") {
                    model.clearOpenCode()
                    OpenCodeWebCleanup.clearCookies()   // P1-D7:清共享 WebView 登录态
                }
                .buttonStyle(ATBTextButtonStyle(color: .red)).font(.system(size: 12))
            } else {
                Button("登录 OpenCode") { showOpenCodeLogin = true }
                    .buttonStyle(ATBPrimaryButtonStyle())
                caption("点击登录,在弹出窗口完成 OpenCode 授权。cookie 会过期,届时可重新登录。")
                // P1-B3:登录成功但 workspace 发现失败时,可在这里手动填写(此前提示的死胡同)
                manualWorkspaceRow
            }
        }
    }

    /// 手动填写/修改 workspace ID(P1-B3)。
    private var manualWorkspaceRow: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingS - 2) {
            HStack(spacing: DesignTokens.spacingS) {
                TextField("workspace ID (wrk_xxx)", text: $manualWorkspaceID)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .onAppear { manualWorkspaceID = model.openCodeWorkspaceID }
                Button("保存") { saveManualWorkspace() }
                    .buttonStyle(ATBTextButtonStyle())
                    .font(.system(size: 11, weight: .medium))
            }
            if let manualWorkspaceError {
                Text(manualWorkspaceError)
                    .font(.system(size: 10)).foregroundStyle(.atbCritical)
            } else {
                caption("登录后自动发现失败时可手动填写;保存后立即拉取用量。")
            }
        }
    }

    private func saveManualWorkspace() {
        let ws = manualWorkspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ws.hasPrefix("wrk_") else {
            manualWorkspaceError = "ID 应以 wrk_ 开头"
            return
        }
        guard !model.openCodeCookie.isEmpty else {
            manualWorkspaceError = "请先登录 OpenCode 获取凭据"
            return
        }
        manualWorkspaceError = nil
        model.openCodeWorkspaceID = ws
        Task { await model.refreshOpenCode() }
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

// MARK: - 历史(P2-B5)

/// 历史分析页:各窗口趋势 sparkline + 近 7 天每日汇总 + CSV 导出。
private struct HistorySettingsPage: View {
    @StateObject private var model = TokenPlanModel.shared
    @State private var exportDone = false
    @State private var exportCount = 0

    private var snapshots: [UsageSnapshot] {
        model.historyStore.recent(1000)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.spacingM) {
                trendSection
                dailySummarySection
                exportSection
            }
            .padding(DesignTokens.spacingL)
        }
    }

    // MARK: 趋势

    private var trendSection: some View {
        historyCard(icon: "chart.xyaxis.line", iconColor: .atbBlue, title: "用量趋势(近 40 个采样点)") {
            trendRow("阿里云 · 5小时", color: .atbBlue, provider: "aliyun", window: "5h")
            trendRow("阿里云 · 7天", color: .orange, provider: "aliyun", window: "7d")
            if model.openCodeConfigured {
                trendRow("OpenCode · 滚动", color: .purple, provider: "opencode", window: "rolling")
                trendRow("OpenCode · 每周", color: .atbBlue, provider: "opencode", window: "weekly")
                trendRow("OpenCode · 每月", color: .orange, provider: "opencode", window: "monthly")
            }
            if model.kimiConfigured {
                trendRow("Kimi · 5小时", color: .teal, provider: "kimi", window: "5h")
                trendRow("Kimi · 每周", color: .indigo, provider: "kimi", window: "weekly")
            }
        }
    }

    private func trendRow(_ label: String, color: Color, provider: String, window: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(.atbTextPrimary)
                Spacer()
                LimitEstimateLabel(provider: provider, window: window)
            }
            UsageSparkline(provider: provider, window: window, color: color, height: 22)
        }
    }

    // MARK: 每日汇总

    private var dailySummarySection: some View {
        historyCard(icon: "calendar", iconColor: .green, title: "每日汇总(近 7 天,各窗口峰值)") {
            let rows = dailyRows()
            if rows.isEmpty {
                Text("暂无历史数据,积累中…")
                    .font(.system(size: 11)).foregroundStyle(.atbTextTertiary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                    GridRow {
                        Text("日期").font(.system(size: 9, weight: .semibold)).foregroundStyle(.atbTextTertiary)
                        Text("阿里云 7d").font(.system(size: 9, weight: .semibold)).foregroundStyle(.atbTextTertiary)
                        Text("OpenCode 月").font(.system(size: 9, weight: .semibold)).foregroundStyle(.atbTextTertiary)
                        Text("Kimi 周").font(.system(size: 9, weight: .semibold)).foregroundStyle(.atbTextTertiary)
                    }
                    ForEach(rows, id: \.date) { row in
                        GridRow {
                            Text(row.date).font(.system(size: 10, design: .monospaced)).foregroundStyle(.atbTextSecondary)
                            Text(row.aliyun).font(.system(size: 10, design: .monospaced)).foregroundStyle(.atbTextPrimary)
                            Text(row.opencode).font(.system(size: 10, design: .monospaced)).foregroundStyle(.atbTextPrimary)
                            Text(row.kimi).font(.system(size: 10, design: .monospaced)).foregroundStyle(.atbTextPrimary)
                        }
                    }
                }
            }
        }
    }

    private struct DailyRow {
        let date: String
        let aliyun: String
        let opencode: String
        let kimi: String
    }

    private func dailyRows() -> [DailyRow] {
        let cal = Calendar.current
        let snaps = snapshots
        guard !snaps.isEmpty else { return [] }
        var byDay: [Date: [UsageSnapshot]] = [:]
        for s in snaps {
            let day = cal.startOfDay(for: s.timestamp)
            byDay[day, default: []].append(s)
        }
        let fmt = DateFormatter()
        fmt.dateFormat = "MM-dd"
        let days = byDay.keys.sorted().suffix(7)
        return days.map { day in
            let ss = byDay[day] ?? []
            func maxOf(_ f: (UsageSnapshot) -> Int?) -> String {
                let v = ss.compactMap(f).max()
                return v.map { "\($0)%" } ?? "—"
            }
            return DailyRow(
                date: fmt.string(from: day),
                aliyun: maxOf { $0.aliyunOneWeek },
                opencode: maxOf { $0.opencodeMonthly },
                kimi: maxOf { $0.kimiWeekly }
            )
        }
    }

    // MARK: 导出

    private var exportSection: some View {
        historyCard(icon: "square.and.arrow.up", iconColor: .orange, title: "导出") {
            HStack(spacing: DesignTokens.spacingM) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(snapshots.count) 条历史快照(最多保留 7 天)")
                        .font(.system(size: 11)).foregroundStyle(.atbTextSecondary)
                    if exportDone {
                        Text("已导出 \(exportCount) 条到 CSV")
                            .font(.system(size: 10)).foregroundStyle(.green)
                    }
                }
                Spacer()
                Button("导出 CSV") { exportCSV() }
                    .buttonStyle(ATBPrimaryButtonStyle())
            }
        }
    }

    private func exportCSV() {
        let csv = HistoryStore.csv(snapshots)
        guard !csv.isEmpty else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "coding-token-bar-history.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.begin { resp in
            guard resp == .OK, let url = panel.url else { return }
            do {
                try csv.write(to: url, atomically: true, encoding: .utf8)
                exportCount = snapshots.count
                exportDone = true
            } catch {
                AppLog.error("CSV 导出失败: \(error.localizedDescription)", category: .history)
            }
        }
    }

    private func historyCard(icon: String, iconColor: Color, title: String,
                             @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingM) {
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
}

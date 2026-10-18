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
final class SettingsWindow {
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
            Section {
                Picker("菜单栏样式", selection: $menuBarStyle.scheme) {
                    ForEach(MenuBarDisplayScheme.allCases) { s in
                        Text(s.displayName).tag(s)
                    }
                }
            } header: {
                Text("菜单栏")
            } footer: {
                Text("灵动岛:菜单栏常驻一枚黑色胶囊,汇总全部已启用数据源的健康度(需处理/告急/预警计数);鼠标悬停即弹簧展开为剩余口径实时卡片,点某一行直接跳到该数据源标签页,点胶囊仍打开主面板。")
                    .font(.system(size: 10))
            }
            Section {
                ForEach(ProviderKind.allCases) { kind in
                    Toggle(isOn: Binding(
                        get: { model.isEnabled(kind) },
                        set: { model.setEnabled(kind, $0) }
                    )) {
                        Label {
                            Text(kind.displayName)
                        } icon: {
                            // 真实品牌 logo(原色);「本机」回落 SF Symbol
                            if let mark = kind.brandMark {
                                mark.mark(in: CGRect(x: 0, y: 0, width: 14, height: 14))
                            } else {
                                Image(systemName: kind.settingsIconName)
                            }
                        }
                    }
                }
            } header: {
                Text("数据源")
            } footer: {
                Text("关闭后:菜单栏不出列、面板不出标签页、停止该数据源的后台刷新,并不再参与告警与每日摘要。全部关闭时菜单栏降级为仅图标。")
                    .font(.system(size: 10))
            }
            Section {
                HStack {
                    Text("余额告急下限")
                    Spacer()
                    TextField("", value: $model.moneyFloor, format: .number)
                        .frame(width: 70)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                    Text("¥").foregroundStyle(.secondary)
                }
                Text("判定对象:DeepSeek 余额、MiMo 余额(「今日花费」不参与)。填 0 关闭余额判定。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            } header: {
                Text("灵动岛")
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
                    Text("每天 20:00 汇总阿里云 / OpenCode / Kimi / DeepSeek / 智谱 / MiMo / MiniMax 用量发送一条通知。")
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
    @State private var showMiMoLogin = false
    @State private var deepSeekDraftKey = ""
    @State private var deepSeekSaveError: String?
    @State private var zhipuDraftKey = ""
    @State private var zhipuSaveError: String?
    @State private var mimoDraftCookie = ""
    @State private var mimoSaveError: String?
    @State private var minimaxDraftKey = ""
    @State private var minimaxSaveError: String?
    @State private var ollamaDraftKey = ""
    @State private var ollamaSaveError: String?
    @State private var showStepFunLogin = false

    /// Kimi 登录窗参数:main=旧单账户槽;UUID=新账户。
    @State private var kimiLoginAccountID: String = "main"
    @State private var kimiLoginLabel: String?
    @State private var renamingKimiID: String?
    @State private var kimiRenameDraft = ""
    @State private var renamingZhipuID: String?
    @State private var zhipuRenameDraft = ""

    /// OpenCode workspace 行内重命名
    @State private var renamingOpenCodeID: String?
    @State private var openCodeRenameDraft = ""

    /// 阶跃登录窗参数:未配置=首账户(main);已配置=新账户(UUID)。
    @State private var stepfunLoginAccountID: String = "main"
    @State private var stepfunLoginLabel: String?

    var body: some View {
        ScrollView {
            VStack(spacing: DesignTokens.spacingM) {
                credentialsStorageCard
                aliyunCard
                kimiCard
                openCodeCard
                deepSeekCard
                zhipuCard
                mimoCard
                minimaxCard
                ollamaCard
                stepfunCard
            }
            .padding(DesignTokens.spacingL)
        }
        .sheet(isPresented: $showOpenCodeLogin) { OpenCodeLoginView() }
        .sheet(isPresented: $showKimiLogin) {
            KimiLoginView(accountID: kimiLoginAccountID, newAccountLabel: kimiLoginLabel)
        }
        .sheet(isPresented: $showMiMoLogin) { MiMoLoginView() }
        .sheet(isPresented: $showStepFunLogin) {
            StepFunLoginView(accountID: stepfunLoginAccountID, newAccountLabel: stepfunLoginLabel)
        }
    }

    // MARK: 登录态存储(维护入口)

    /// 全部登录态持久化在 .app 包内凭证文件(2026-10-17 用户要求):
    /// 展示位置 + 访达入口;文件为明文 JSON,可手动编辑维护;更新由安装脚本保留。
    private var credentialsStorageCard: some View {
        cardContainer(icon: "key.fill", iconColor: .atbBlue, title: "登录态存储") {
            let store = AppFileCredentialStore.shared
            let url = store.credentialsFileURL
            let inApp = url.path.contains(".app/Contents/Resources")
            statusRow(inApp ? "存储在应用包内(拷贝 .app 即带走全部登录态)"
                            : "存储在应用支持目录(开发态回退位置)")
            HStack(spacing: DesignTokens.spacingS) {
                Text(url.path)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.atbTextTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: DesignTokens.spacingXS)
                Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    .buttonStyle(ATBTextButtonStyle()).font(.system(size: 11))
            }
            caption("明文 JSON,可用任意文本编辑器维护(改完重启生效);应用更新时由安装脚本自动保留,不会丢登录态。")
        }
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

    // MARK: Kimi(多账户)

    private var kimiCard: some View {
        cardContainer(icon: "sparkles", iconColor: .teal, title: "Kimi Code") {
            if model.kimiConfigured {
                statusRow("已连接(复用本机 KimiCodeBar / Kimi CLI 凭证)")
                if model.kimiWebLoggedIn {
                    statusRow("已登录网页控制台(订阅总额度可用)")
                }
                // 账户列表(多账户:逐账户移除;单账户=传统登出)
                if !model.kimiAccounts.isEmpty {
                    VStack(alignment: .leading, spacing: DesignTokens.spacingXS) {
                        ForEach(model.kimiAccounts) { account in
                            HStack(spacing: DesignTokens.spacingS) {
                                Circle().fill(Color.teal).frame(width: 6, height: 6)
                                Text(account.label).font(.system(size: 12))
                                if let hint = model.kimiAccountHint(account.id) {
                                    Text(hint)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.atbTextTertiary)
                                }
                                if let snap = model.kimiAccountQuotas.first(where: { $0.id == account.id }) {
                                    Text("5h \(snap.quota.fiveHour.pctInt)%")
                                        .font(.system(size: 11, design: .rounded))
                                        .monospacedDigit()
                                        .foregroundStyle(.atbTextSecondary)
                                } else if let err = model.kimiAccountErrors[account.id] {
                                    Text(err).font(.system(size: 10)).foregroundStyle(.atbCritical).lineLimit(1)
                                }
                                Spacer(minLength: DesignTokens.spacingXS)
                                if renamingKimiID == account.id {
                                    TextField("账户名", text: $kimiRenameDraft)
                                        .textFieldStyle(.roundedBorder)
                                        .font(.system(size: 11))
                                        .frame(width: 110)
                                    Button("保存") {
                                        model.renameKimiAccount(id: account.id, label: kimiRenameDraft)
                                        renamingKimiID = nil
                                    }
                                    .buttonStyle(ATBPrimaryButtonStyle()).font(.system(size: 10))
                                    Button("取消") { renamingKimiID = nil }
                                        .buttonStyle(ATBTextButtonStyle()).font(.system(size: 10))
                                } else {
                                    Button("重命名") {
                                        kimiRenameDraft = account.label
                                        renamingKimiID = account.id
                                    }
                                    .buttonStyle(ATBTextButtonStyle()).font(.system(size: 11))
                                    Button("移除") { model.removeKimiAccount(id: account.id) }
                                        .buttonStyle(ATBTextButtonStyle(color: .red)).font(.system(size: 11))
                                }
                            }
                        }
                    }
                }
                HStack(spacing: DesignTokens.spacingS) {
                    if model.kimiWebLoggedIn {
                        Button("登录新账户") {
                            kimiLoginAccountID = UUID().uuidString
                            kimiLoginLabel = model.kimiNextAccountLabel
                            showKimiLogin = true
                        }
                        .buttonStyle(ATBPrimaryButtonStyle())
                        Button("登出网页控制台") { model.clearKimi() }
                            .buttonStyle(ATBTextButtonStyle(color: .red)).font(.system(size: 11))
                    } else {
                        Button("登录 Kimi 网页控制台") {
                            kimiLoginAccountID = "main"
                            kimiLoginLabel = nil
                            showKimiLogin = true
                        }
                        .buttonStyle(ATBPrimaryButtonStyle())
                    }
                }
                caption("每个账户 = 一次 www.kimi.com 网页登录(独立 JWT);多账户自动合计,菜单栏/告警按账户分。")
                Button("立即刷新") { Task { await model.refreshKimi(force: true) } }
                    .buttonStyle(ATBTextButtonStyle()).font(.system(size: 12))
            } else {
                caption("未检测到本机 Kimi 登录凭证。请先安装并登录 Kimi Code CLI 或 KimiCodeBar。")
            }
        }
    }

    // MARK: OpenCode

    private var openCodeCard: some View {
        cardContainer(icon: "bolt.fill", iconColor: .purple, title: "OpenCode Go") {
            if !model.openCodeCookie.isEmpty {
                statusRow("已登录(opencode.ai 账户,\(model.openCodeWorkspaces.count) 个受监控 workspace)")
                // workspace 列表(逐行重命名/移除)
                if !model.openCodeWorkspaces.isEmpty {
                    VStack(alignment: .leading, spacing: DesignTokens.spacingXS) {
                        ForEach(model.openCodeWorkspaces) { ws in
                            HStack(spacing: DesignTokens.spacingS) {
                                Circle().fill(Color.purple).frame(width: 6, height: 6)
                                Text(ws.label).font(.system(size: 12))
                                Text(ws.id)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.atbTextTertiary)
                                    .lineLimit(1)
                                if let snap = model.openCodeWorkspaceQuotas.first(where: { $0.id == ws.id }) {
                                    Text("滚动 \(snap.quota.rolling.pct)% · 周 \(snap.quota.weekly.pct)%")
                                        .font(.system(size: 11, design: .rounded))
                                        .monospacedDigit()
                                        .foregroundStyle(.atbTextSecondary)
                                } else if let err = model.openCodeWorkspaceErrors[ws.id] {
                                    Text(err).font(.system(size: 10)).foregroundStyle(.atbCritical).lineLimit(1)
                                }
                                Spacer(minLength: DesignTokens.spacingXS)
                                if renamingOpenCodeID == ws.id {
                                    TextField("名称", text: $openCodeRenameDraft)
                                        .textFieldStyle(.roundedBorder)
                                        .font(.system(size: 11))
                                        .frame(width: 110)
                                    Button("保存") {
                                        model.renameOpenCodeWorkspace(id: ws.id, label: openCodeRenameDraft)
                                        renamingOpenCodeID = nil
                                    }
                                    .buttonStyle(ATBPrimaryButtonStyle()).font(.system(size: 10))
                                    Button("取消") { renamingOpenCodeID = nil }
                                        .buttonStyle(ATBTextButtonStyle()).font(.system(size: 10))
                                } else {
                                    Button("重命名") {
                                        openCodeRenameDraft = ws.label
                                        renamingOpenCodeID = ws.id
                                    }
                                    .buttonStyle(ATBTextButtonStyle()).font(.system(size: 11))
                                    Button("移除") { model.removeOpenCodeWorkspace(id: ws.id) }
                                        .buttonStyle(ATBTextButtonStyle(color: .red)).font(.system(size: 11))
                                }
                            }
                        }
                    }
                }
                HStack(spacing: DesignTokens.spacingS) {
                    Button("发现全部 workspace") { Task { await model.discoverOpenCodeWorkspaces() } }
                        .buttonStyle(ATBPrimaryButtonStyle())
                    Button("登出") {
                        model.clearOpenCode()
                        OpenCodeWebCleanup.clearCookies()   // P1-D7:清共享 WebView 登录态
                    }
                    .buttonStyle(ATBTextButtonStyle(color: .red)).font(.system(size: 11))
                }
                caption("一个 opencode.ai 账户一份登录;每个 workspace 是独立订阅,多 workspace 自动合计(取最险),告警按 workspace 分。")
                Button("立即刷新") { Task { await model.refreshOpenCode(force: true) } }
                    .buttonStyle(ATBTextButtonStyle()).font(.system(size: 12))
            } else {
                Button("登录 OpenCode") { showOpenCodeLogin = true }
                    .buttonStyle(ATBPrimaryButtonStyle())
                caption("点击登录,在弹出窗口完成 OpenCode 授权。登录后自动发现账户下全部 workspace;cookie 会过期,届时可重新登录。")
            }
        }
    }

    // MARK: DeepSeek

    private var deepSeekCard: some View {
        cardContainer(icon: "brain.head.profile", iconColor: .atbBlue, title: "DeepSeek API") {
            if model.deepSeekConfigured {
                statusRow("已配置 (sk-…(model.deepSeekAPIKey.suffix(4)))")
                HStack(spacing: DesignTokens.spacingM) {
                    Button("立即刷新") { Task { await model.refreshDeepSeek() } }
                        .buttonStyle(ATBTextButtonStyle()).font(.system(size: 12))
                    Button("移除 API Key") { model.clearDeepSeek() }
                        .buttonStyle(ATBTextButtonStyle(color: .red)).font(.system(size: 12))
                }
            } else {
                HStack(spacing: DesignTokens.spacingS) {
                    SecureField("sk-...", text: $deepSeekDraftKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                    Button("保存并查询") { saveDeepSeekKey() }
                        .buttonStyle(ATBPrimaryButtonStyle())
                        .font(.system(size: 11, weight: .medium))
                }
                if let deepSeekSaveError {
                    Text(deepSeekSaveError).font(.system(size: 10)).foregroundStyle(.atbCritical)
                }
                caption("在 platform.deepseek.com → API Keys 创建。Key 只存系统钥匙串;官方接口仅提供余额,当日费用按余额差累计(0 点起)。")
            }
        }
    }

    private func saveDeepSeekKey() {
        let k = deepSeekDraftKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else {
            deepSeekSaveError = "请输入 API Key"
            return
        }
        deepSeekSaveError = nil
        model.deepSeekAPIKey = k
        deepSeekDraftKey = ""
        Task { await model.refreshDeepSeek() }
    }

    // MARK: 智谱 GLM(多账户)

    private var zhipuCard: some View {
        cardContainer(icon: "atom", iconColor: .atbBrandZhipu, title: "智谱 GLM Coding Plan") {
            if model.zhipuConfigured {
                if model.zhipuAccounts.isEmpty {
                    caption("凭据仍在,但账户已全部移除。在面板智谱 tab 或此处重新粘贴 Key 即可启用。")
                } else {
                    if model.zhipuAPIKey.isEmpty, model.zhipuAccounts.contains(where: { $0.id == "main" }) {
                        statusRow("已自动发现(opencode 配置 zhipuai-coding-plan)")
                        caption("在 ~/.config/opencode/opencode.json 检测到 Coding Plan API Key,直接使用,不复制存储。")
                    }
                }
                // 账户列表:main=手动 Key 或自动发现;其余=独立 Key
                VStack(alignment: .leading, spacing: DesignTokens.spacingXS) {
                    ForEach(model.zhipuAccounts) { account in
                        HStack(spacing: DesignTokens.spacingS) {
                            Circle().fill(Color.atbBrandZhipu).frame(width: 6, height: 6)
                            Text(account.label).font(.system(size: 12))
                            if let hint = model.zhipuAccountHint(account.id) {
                                Text(hint)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.atbTextTertiary)
                            }
                            if let snap = model.zhipuAccountQuotas.first(where: { $0.id == account.id }) {
                                Text("5h \(snap.quota.fiveHour?.pctInt ?? 0)%")
                                    .font(.system(size: 11, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundStyle(.atbTextSecondary)
                            } else if let err = model.zhipuAccountErrors[account.id] {
                                Text(err).font(.system(size: 10)).foregroundStyle(.atbCritical).lineLimit(1)
                            }
                            Spacer(minLength: DesignTokens.spacingXS)
                            if renamingZhipuID == account.id {
                                TextField("账户名", text: $zhipuRenameDraft)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 11))
                                    .frame(width: 110)
                                Button("保存") {
                                    model.renameZhipuAccount(id: account.id, label: zhipuRenameDraft)
                                    renamingZhipuID = nil
                                }
                                .buttonStyle(ATBPrimaryButtonStyle()).font(.system(size: 10))
                                Button("取消") { renamingZhipuID = nil }
                                    .buttonStyle(ATBTextButtonStyle()).font(.system(size: 10))
                            } else {
                                Button("重命名") {
                                    zhipuRenameDraft = account.label
                                    renamingZhipuID = account.id
                                }
                                .buttonStyle(ATBTextButtonStyle()).font(.system(size: 11))
                                Button("移除") { model.removeZhipuAccount(id: account.id) }
                                    .buttonStyle(ATBTextButtonStyle(color: .red)).font(.system(size: 11))
                            }
                        }
                    }
                }
                HStack(spacing: DesignTokens.spacingS) {
                    SecureField("新账户 API Key", text: $zhipuDraftKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                    Button("添加并查询") { saveZhipuKey() }
                        .buttonStyle(ATBPrimaryButtonStyle())
                        .font(.system(size: 11, weight: .medium))
                }
                if let zhipuSaveError {
                    Text(zhipuSaveError).font(.system(size: 10)).foregroundStyle(.atbCritical)
                }
                caption("多账户 = 多把独立 Key(各自存钥匙串);合计口径 = 5h/周取最险账户,MCP 按次求和。")
                Button("立即刷新") { Task { await model.refreshZhipu(force: true) } }
                    .buttonStyle(ATBTextButtonStyle()).font(.system(size: 12))
            } else {
                HStack(spacing: DesignTokens.spacingS) {
                    SecureField("API Key(可选)", text: $zhipuDraftKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                    Button("保存并查询") { saveZhipuKey() }
                        .buttonStyle(ATBPrimaryButtonStyle())
                        .font(.system(size: 11, weight: .medium))
                }
                if let zhipuSaveError {
                    Text(zhipuSaveError).font(.system(size: 10)).foregroundStyle(.atbCritical)
                }
                caption("无需手动配置:本机安装 opencode 并配置智谱 Coding Plan 后自动发现。也可在 bigmodel.cn → API Keys 创建后粘贴;Key 只存系统钥匙串。")
            }
        }
    }

    private func saveZhipuKey() {
        let k = zhipuDraftKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else {
            zhipuSaveError = "请输入 API Key"
            return
        }
        zhipuSaveError = nil
        if model.zhipuAccounts.isEmpty {
            // 无账户:首把 Key 落到 main 槽(didSet 会登记 main 账户)
            model.zhipuAPIKey = k
        } else {
            model.addZhipuAccount(label: model.zhipuNextAccountLabel, apiKey: k)
        }
        zhipuDraftKey = ""
        Task { await model.refreshZhipu(force: true) }
    }

    // MARK: 小米 MiMo

    private var mimoCard: some View {
        cardContainer(icon: "waveform", iconColor: .atbBrandMiMo, title: "小米 MiMo 开放平台") {
            if model.mimoConfigured {
                statusRow(model.mimoAutoRenewEnabled ? "已配置 · 自动续期已启用" : "已配置 · 自动续期未启用")
                HStack(spacing: DesignTokens.spacingM) {
                    Button("登录平台") { showMiMoLogin = true }
                        .buttonStyle(ATBTextButtonStyle(color: .atbBrandMiMo)).font(.system(size: 12))
                    Button("立即刷新") { Task { await model.refreshMiMo(force: true) } }
                        .buttonStyle(ATBTextButtonStyle()).font(.system(size: 12))
                    Button("移除 Cookie") { model.clearMiMo() }
                        .buttonStyle(ATBTextButtonStyle(color: .red)).font(.system(size: 12))
                }
                if !model.mimoAutoRenewEnabled {
                    caption("未取到小米账号 passToken,登录态过期后需重新登录。点「登录平台」在窗内登录一次即可启用自动续期。")
                }
            } else {
                VStack(alignment: .leading, spacing: DesignTokens.spacingS - 2) {
                    Button("登录平台(推荐)") { showMiMoLogin = true }
                        .buttonStyle(ATBPrimaryButtonStyle())
                        .font(.system(size: 11, weight: .medium))
                    SecureField("或手工粘贴:Cookie: api-platform_serviceToken=…; userId=…",
                                text: $mimoDraftCookie)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                    Button("保存并查询") { saveMiMoCookie() }
                        .buttonStyle(ATBTextButtonStyle())
                        .font(.system(size: 11, weight: .medium))
                    if let mimoSaveError {
                        Text(mimoSaveError).font(.system(size: 10)).foregroundStyle(.atbCritical)
                    }
                }
                caption("MiMo 未开放 API Key 余额接口。推荐在窗内登录 platform.xiaomimimo.com:App 会自动保存平台与小米账号两域 Cookie,并在登录态过期时静默续期。手工粘贴只含平台段,过期后需重新粘贴。Cookie 只存系统钥匙串。")
            }
        }
    }

    private func saveMiMoCookie() {
        let c = mimoDraftCookie.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.isEmpty else {
            mimoSaveError = "请粘贴 Cookie 请求头"
            return
        }
        guard MiMoUsageService.normalizedCookie(from: c) != nil else {
            mimoSaveError = "缺少必需 cookie(api-platform_serviceToken / userId)"
            return
        }
        mimoSaveError = nil
        model.mimoCookie = c
        mimoDraftCookie = ""
        Task { await model.refreshMiMo() }
    }

    // MARK: MiniMax

    private var minimaxCard: some View {
        cardContainer(icon: "infinity", iconColor: .atbBrandMiniMax, title: "MiniMax Coding Plan") {
            if model.minimaxConfigured {
                statusRow("已配置 (…\(model.minimaxAPIKey.suffix(4)))")
                HStack(spacing: DesignTokens.spacingM) {
                    Button("立即刷新") { Task { await model.refreshMiniMax() } }
                        .buttonStyle(ATBTextButtonStyle()).font(.system(size: 12))
                    Button("移除 API Key") { model.clearMiniMax() }
                        .buttonStyle(ATBTextButtonStyle(color: .red)).font(.system(size: 12))
                }
            } else {
                VStack(alignment: .leading, spacing: DesignTokens.spacingS - 2) {
                    HStack(spacing: DesignTokens.spacingS) {
                        SecureField("API Key(eyJ…)", text: $minimaxDraftKey)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11, design: .monospaced))
                        Button("保存并查询") { saveMiniMaxKey() }
                            .buttonStyle(ATBPrimaryButtonStyle())
                            .font(.system(size: 11, weight: .medium))
                    }
                    if let minimaxSaveError {
                        Text(minimaxSaveError).font(.system(size: 10)).foregroundStyle(.atbCritical)
                    }
                }
                caption("在 platform.minimaxi.com → 账户管理 → API Key 创建 Coding Plan Key 后粘贴(国际版为 platform.minimax.io)。Key 只存系统钥匙串;国内/国际端点自动尝试。")
            }
        }
    }

    private func saveMiniMaxKey() {
        let k = minimaxDraftKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else {
            minimaxSaveError = "请输入 API Key"
            return
        }
        minimaxSaveError = nil
        model.minimaxAPIKey = k
        minimaxDraftKey = ""
        Task { await model.refreshMiniMax() }
    }

    // MARK: Ollama Cloud

    private var ollamaCard: some View {
        cardContainer(icon: "hare.fill", iconColor: .atbBrandOllama, title: "Ollama Cloud") {
            if model.ollamaConfigured {
                statusRow(ollamaStatusText)
                HStack(spacing: DesignTokens.spacingM) {
                    Button("立即刷新") { Task { await model.refreshOllama() } }
                        .buttonStyle(ATBTextButtonStyle()).font(.system(size: 12))
                    Button("移除 API Key") { model.clearOllama() }
                        .buttonStyle(ATBTextButtonStyle(color: .red)).font(.system(size: 12))
                }
            } else {
                VStack(alignment: .leading, spacing: DesignTokens.spacingS - 2) {
                    HStack(spacing: DesignTokens.spacingS) {
                        SecureField("API Key", text: $ollamaDraftKey)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11, design: .monospaced))
                        Button("保存并查询") { saveOllamaKey() }
                            .buttonStyle(ATBPrimaryButtonStyle())
                            .font(.system(size: 11, weight: .medium))
                    }
                    if let ollamaSaveError {
                        Text(ollamaSaveError).font(.system(size: 10)).foregroundStyle(.atbCritical)
                    }
                }
                caption("在 ollama.com → Settings → Keys 创建 API Key 后粘贴(Key 不过期,可随时吊销;只存系统钥匙串)。用量显示近 30 天消费(美元)及占套餐月度额度比例;接口不返回重置时间,故不显示倒计时。")
            }
        }
    }

    /// 已配置状态行文案(含套餐档位 + 近 30 天消费;档位来自远程 /api/me,
    /// 拿不到则省略)。
    private var ollamaStatusText: String {
        var status = "已配置 (…\(model.ollamaAPIKey.suffix(4)))"
        if let q = model.ollamaQuota {
            if let plan = q.planDisplay { status += " · 套餐 \(plan)" }
            status += " · 近 30 天 \(OllamaMoney.full(q.spentUSD30d))"
        }
        return status
    }

    private func saveOllamaKey() {
        let k = ollamaDraftKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else {
            ollamaSaveError = "请输入 API Key"
            return
        }
        ollamaSaveError = nil
        model.ollamaAPIKey = k
        ollamaDraftKey = ""
        Task { await model.refreshOllama() }
    }

    // MARK: 阶跃 Step Plan(多账户)

    private var stepfunCard: some View {
        cardContainer(icon: "stairs", iconColor: .atbBrandStepFun, title: "阶跃 Step Plan (StepFun)") {
            if model.stepfunConfigured {
                statusRow(stepfunStatusText)
                // 账户清单(多账户时逐行展示;单账户并入状态行)
                ForEach(model.stepfunAccounts) { account in
                    HStack(spacing: DesignTokens.spacingS) {
                        Text(account.label)
                            .font(.system(size: 11))
                            .foregroundStyle(.atbTextSecondary)
                        // 身份展示:优先手机号尾号(****5678),区分账户/暴露重复登录
                        if let identity = account.identityDisplay {
                            Text(identity)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.atbTextTertiary)
                        }
                        if model.stepfunDuplicateAccountIDs.contains(account.id) {
                            Text("重复")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.orange)
                        }
                        if let q = model.stepfunAccountQuotas.first(where: { $0.id == account.id })?.quota,
                           let m = q.subscription {
                            Text("月池 \(m.usedPctInt)%")
                                .font(.system(size: 11, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(.atbTextSecondary)
                        }
                        Spacer()
                        Button("移除") {
                            model.removeStepFunAccount(id: account.id)
                            StepFunSessionController.shared.logout(accountID: account.id)
                        }
                        .buttonStyle(ATBTextButtonStyle(color: .red)).font(.system(size: 11))
                    }
                }
                // 重复账户一键清理(同一 oasis_id 只保留第一个)
                if !model.stepfunDuplicateAccountIDs.isEmpty {
                    Button("移除重复账户(合计已只计一次)") {
                        for id in model.removeStepFunDuplicateAccounts() {
                            StepFunSessionController.shared.logout(accountID: id)
                        }
                    }
                    .buttonStyle(ATBTextButtonStyle(color: .orange)).font(.system(size: 12))
                }
                HStack(spacing: DesignTokens.spacingM) {
                    Button("添加账户") {
                        stepfunLoginAccountID = UUID().uuidString
                        stepfunLoginLabel = "账户\(model.stepfunAccounts.count + 1)"
                        showStepFunLogin = true
                    }
                    .buttonStyle(ATBPrimaryButtonStyle()).font(.system(size: 12))
                    Button("立即刷新") { Task { await model.refreshStepFun(force: true) } }
                        .buttonStyle(ATBTextButtonStyle()).font(.system(size: 12))
                    Button("全部移除") {
                        model.clearStepFun()
                        StepFunSessionController.shared.logoutAll()
                    }
                    .buttonStyle(ATBTextButtonStyle(color: .red)).font(.system(size: 12))
                }
                if let err = model.stepfunError {
                    Text(err).font(.system(size: 10)).foregroundStyle(.atbCritical)
                }
            } else {
                VStack(alignment: .leading, spacing: DesignTokens.spacingS - 2) {
                    Button("登录 platform.stepfun.com") {
                        stepfunLoginAccountID = "main"
                        stepfunLoginLabel = nil
                        showStepFunLogin = true
                    }
                    .buttonStyle(ATBPrimaryButtonStyle())
                    .font(.system(size: 11, weight: .medium))
                }
                caption("额度查询走控制台登录态,且平台登录凭据会持续轮换——App 登录一次后在后台保持会话自动续期,无需粘贴任何 Cookie(API Key 也查不了额度)。可登录多个账户,各账户独立会话、独立展示。")
            }
        }
    }

    /// 已配置状态行文案(账户数 + 聚合月池)。
    private var stepfunStatusText: String {
        var status = model.stepfunAccounts.count > 1
            ? "已登录 \(model.stepfunAccounts.count) 个账户(后台保持会话)"
            : "已登录(后台保持会话)"
        if let q = model.stepfunQuota {
            status += " · \(q.billingDisplay)"
            if let sub = q.subscription { status += " \(sub.usedPctInt)%" }
        }
        return status
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
            // 窗口按 quota 实际形态出趋势行(5h/周被官方取消时隐藏;无 quota 保留全部)。
            if model.quota?.usage.fiveHour != nil || model.quota == nil {
                trendRow("阿里云 · 5小时", color: .atbBlue, provider: "aliyun", window: "5h")
            }
            if model.quota?.usage.oneWeek != nil || model.quota == nil {
                trendRow("阿里云 · 7天", color: .orange, provider: "aliyun", window: "7d")
            }
            if model.quota?.usage.oneMonth != nil || model.quota == nil {
                trendRow("阿里云 · 月度", color: .orange, provider: "aliyun", window: "monthly")
            }
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
            UsageSparkline(provider: provider, window: window, brand: color, height: 22)
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
                        Text("阿里云 月").font(.system(size: 9, weight: .semibold)).foregroundStyle(.atbTextTertiary)
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
                // 主窗取月(2026-09 新契约),旧记录无月值时回退周
                aliyun: maxOf { $0.aliyunOneMonth ?? $0.aliyunOneWeek },
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

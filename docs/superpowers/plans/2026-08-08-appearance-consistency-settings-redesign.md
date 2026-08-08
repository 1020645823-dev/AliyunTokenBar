# 明暗一致性修复 + 设置面板重设计 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 修复弹层在深色模式下的硬编码黑色缺陷并透出 popover 原生材质;把设置面板从裸 Form 重构为系统设置式侧边栏布局。

**Architecture:** 视图层改动,不动 Core 逻辑。明暗修复 = 4 处硬编码色改自适应 + 删 4 处不透明背景;设置面板 = `NavigationSplitView` 四页(通用/外观/通知/服务),服务页用状态卡片,全部复用现有 DesignTokens/按钮样式/语义色。

**Tech Stack:** SwiftUI(macOS 13+)、AppKit(NSPanel/NSPopover)、SwiftPM。

**设计文档:** `docs/superpowers/specs/2026-08-08-appearance-consistency-settings-redesign-design.md`

## Global Constraints

- 部署目标 macOS 13(`.macOS(.v13)`),`NavigationSplitView`/`navigationSplitViewColumnWidth` 均可用。
- 本机无 XCTest:验证 = `swift build` 编译通过 + `swift run Verify` 现有断言全绿 + 手动视觉验收。
- 只允许使用自适应色(`Color.primary`/语义 NSColor 封装 `.atb*`),禁止新增硬编码 `Color.black/.white` 于面板/设置视图。
- **不动菜单栏图标渲染链路**(App.swift 的 `.black` 为模板图正确用法)。
- **不动** `ThemeManager.didSet`、`LaunchAtLoginManager`、阈值 `Binding` 写法、通知授权 `onChange` 逻辑。
- 登录/AKSK 窗口(OpenCodeLoginView/KimiLoginView/AliyunAKSKInputView)保留 `atbPanelBackground` 不动。
- 提交信息风格:中文 conventional commits(参照 git log,如 `fix(panel): …`)。

---

### Task 1: 深色模式硬编码色修复(4 处)

**Files:**
- Modify: `Sources/AliyunTokenBar/Menu.swift:833,844,853`
- Modify: `Sources/AliyunTokenBar/Sparkline.swift:25`

**Interfaces:**
- Consumes: 无(纯视图层颜色替换)
- Produces: 无新接口

- [ ] **Step 1: 修 Kimi 订阅分段条 Work 段与剩余段**

`Sources/AliyunTokenBar/Menu.swift` 中 `KimiSubscriptionCard.body` 的 GeometryReader 内:

```swift
// 改前(:833/:844)
Rectangle()
    .fill(Color.black.opacity(0.88))
    .frame(width: proxy.size.width * CGFloat(work / 100))
Rectangle()
    .fill(Color.atbBlue)
    .frame(width: proxy.size.width * CGFloat(code / 100))
// …else 分支略…
Rectangle()
    .fill(Color.black.opacity(0.08))

// 改后
Rectangle()
    .fill(Color.primary)
    .frame(width: proxy.size.width * CGFloat(work / 100))
Rectangle()
    .fill(Color.atbBlue)
    .frame(width: proxy.size.width * CGFloat(code / 100))
// …else 分支不动…
Rectangle()
    .fill(Color.primary.opacity(0.10))
```

- [ ] **Step 2: 修图例调用点(.black → .primary)**

同文件 `KimiSubscriptionCard` 图例行(:853):

```swift
// 改前
KimiSubscriptionLegend(color: .black, title: "Kimi/Work", percent: work)
// 改后
KimiSubscriptionLegend(color: .primary, title: "Kimi/Work", percent: work)
```

- [ ] **Step 3: 修 sparkline 占位条**

`Sources/AliyunTokenBar/Sparkline.swift:25`:

```swift
// 改前
.fill(Color.black.opacity(0.08))
// 改后
.fill(Color.primary.opacity(0.08))
```

- [ ] **Step 4: 编译 + 回归验证**

```bash
cd /Users/weiwei.g.zhang/Documents/worker_space/AliyuntokenCal
swift build 2>&1 | tail -5
swift run Verify 2>&1 | tail -5
```

Expected: `Build complete!`;Verify 输出全绿、退出码 0。

- [ ] **Step 5: Commit**

```bash
git add Sources/AliyunTokenBar/Menu.swift Sources/AliyunTokenBar/Sparkline.swift
git commit -m "fix(panel): 深色模式硬编码黑改自适应色(Kimi 订阅条/图例/sparkline 占位)"
```

---

### Task 2: 弹层透出 NSPopover 原生材质

**Files:**
- Modify: `Sources/AliyunTokenBar/Menu.swift:107,689,775,976`

**Interfaces:**
- Consumes: Task 1 的颜色修复(同一文件,先提交避免冲突)
- Produces: 无新接口

- [ ] **Step 1: 删除 4 处不透明面板背景**

`Sources/AliyunTokenBar/Menu.swift` 中删除以下 4 行(只删行,不改其他):

1. `TokenPlanMenu.body` 尾部(:107 附近):`.background(Color.atbPanelBackground)`
   上下文:
   ```swift
   .frame(width: 340)
   .background(Color.atbPanelBackground)   // ← 删这行
   .task {
   ```
2. `OpenCodeCard.body` 尾部(:689 附近):
   ```swift
   .padding(DesignTokens.spacingL)
   .frame(maxWidth: .infinity, alignment: .leading)
   .background(Color.atbPanelBackground)   // ← 删这行
   ```
3. `KimiCodeCard.body` 尾部(:775 附近):同上模式的 `.background(Color.atbPanelBackground)` 一行
4. `SystemProcessesCard.body` 尾部(:976 附近):同上模式的 `.background(Color.atbPanelBackground)` 一行

注意:登录/AKSK 视图(OpenCodeLoginView/KimiLoginView/AliyunAKSKInputView)里的 `atbPanelBackground` **不删**;`atbPanelBackground` token 定义(App.swift:9)**保留**(登录窗仍在用)。

- [ ] **Step 2: 编译 + 回归验证**

```bash
cd /Users/weiwei.g.zhang/Documents/worker_space/AliyuntokenCal
swift build 2>&1 | tail -5
swift run Verify 2>&1 | tail -5
```

Expected: `Build complete!`;Verify 全绿。

- [ ] **Step 3: 手动视觉验收(弹层材质)**

```bash
swift run AliyunTokenBar &
```

点菜单栏图标打开面板,检查:
- 面板背景呈半透明毛玻璃(透出桌面/壁纸色),非死白/死灰
- 切系统外观(系统设置 → 外观 → 深色)后面板随之变深、文字对比度正常
- Kimi tab 分段条两段 + 图例在浅色/深色下均可辨
- 若透出失败(看到异常底色/全透明):兜底——在 `TokenPlanMenu.body` 原位置改挂 `.background(.ultraThinMaterial)`,重验后记录在实际提交信息中

验收完 `kill %1` 或 Activity Monitor 结束进程。

- [ ] **Step 4: Commit**

```bash
git add Sources/AliyunTokenBar/Menu.swift
git commit -m "feat(panel): 删除不透明背景,透出 NSPopover 原生 vibrant 材质(自动跟随系统明暗)"
```

---

### Task 3: 设置窗口骨架——NSPanel 尺寸 + NavigationSplitView 四页框架

**Files:**
- Modify: `Sources/AliyunTokenBar/Settings.swift`(整文件重构)

**Interfaces:**
- Consumes: 现有 `LaunchAtLoginManager`、`ThemeManager`、`MenuBarStyleManager`、`TokenPlanModel` 公开属性(`refreshIntervalMinutes`/`systemStatsEnabled`/`sparklineEnabled`/`notificationsEnabled`/`thresholdConfig`)
- Produces: `enum SettingsPage`(internal,CaseIterable/Identifiable,4 case:general/appearance/notifications/services);`SettingsView` 接口不变(无参构造),`SettingsWindowManager.shared.show()` 调用契约不变

- [ ] **Step 1: 重写 Settings.swift(骨架 + 通用/外观/通知三页;服务页先放占位)**

完整替换 `Sources/AliyunTokenBar/Settings.swift` 为:

```swift
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
```

- [ ] **Step 2: 编译 + 回归验证**

```bash
cd /Users/weiwei.g.zhang/Documents/worker_space/AliyuntokenCal
swift build 2>&1 | tail -5
swift run Verify 2>&1 | tail -5
```

Expected: `Build complete!`;Verify 全绿。

- [ ] **Step 3: Commit**

```bash
git add Sources/AliyunTokenBar/Settings.swift
git commit -m "feat(settings): 重构为系统设置式侧边栏(NavigationSplitView 四页骨架,窗口 620x480)"
```

---

### Task 4: 服务页状态卡片(阿里云 / Kimi / OpenCode)

**Files:**
- Modify: `Sources/AliyunTokenBar/Settings.swift`(替换 Task 3 的 `ServicesSettingsPage` 占位)

**Interfaces:**
- Consumes: `TokenPlanModel` 的 `aliyunAKSKConfigured`/`clearAliyunAKSK()`、`kimiConfigured`/`kimiWebLoggedIn`/`clearKimi()`/`refreshKimi()`、`openCodeConfigured`/`openCodeWorkspaceID`/`clearOpenCode()`;`AliyunAKSKWindowManager.shared.show()`;`OpenCodeLoginView()`/`KimiLoginView()`;样式 `ATBPrimaryButtonStyle`/`ATBTextButtonStyle`、`DesignTokens`、`.atb*` 色
- Produces: 无新公开接口(`ServicesSettingsPage` 保持 private)

- [ ] **Step 1: 用状态卡片实现替换占位**

把 Task 3 文件末尾的 `// MARK: - 服务(Task 4 填卡片,先占位编译通过)` 整节替换为:

```swift
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
```

注意:原设置里 Kimi「未登录凭证」与登录状态的文案字号(11/10)在此统一走 `statusRow`(11pt)/`caption`(10pt)——视觉统一优先于逐字保留样式,文案内容不变。

- [ ] **Step 2: 编译 + 回归验证**

```bash
cd /Users/weiwei.g.zhang/Documents/worker_space/AliyuntokenCal
swift build 2>&1 | tail -5
swift run Verify 2>&1 | tail -5
```

Expected: `Build complete!`;Verify 全绿。

- [ ] **Step 3: Commit**

```bash
git add Sources/AliyunTokenBar/Settings.swift
git commit -m "feat(settings): 服务页改状态卡片(阿里云/Kimi/OpenCode 连接状态+操作)"
```

---

### Task 5: 全量验证 + 视觉验收清单

**Files:** 无(验证任务)

**Interfaces:**
- Consumes: Task 1-4 全部提交
- Produces: 验收结论(用户确认)

- [ ] **Step 1: 全量编译(含 release,与打包同路径)**

```bash
cd /Users/weiwei.g.zhang/Documents/worker_space/AliyuntokenCal
swift build 2>&1 | tail -3
swift build -c release 2>&1 | tail -3
swift run Verify 2>&1 | tail -5
```

Expected: 两个 `Build complete!`;Verify 全绿。

- [ ] **Step 2: 启动应用做视觉验收**

```bash
swift run AliyunTokenBar &
```

逐项检查(系统设置 → 外观 切浅色/深色各过一遍):

| 项 | 验收点 |
|---|---|
| 弹层背景 | 半透明毛玻璃;深浅两模式自动跟随 |
| Kimi tab 订阅分段条 | 两段(Kimi/Work 深/浅主色 + Code 蓝)+ 图例两模式可辨 |
| sparkline 占位条 | 「趋势积累中…」占位两模式可见(需先关趋势线开关再开/或未积累场景) |
| 设置窗 | 侧边栏 4 项切换;服务页三卡片;主题切「浅色/深色」设置窗即时跟随 |

- [ ] **Step 3: 用户确认验收结论**

向用户汇报上表逐项结果,请用户最终确认。发现不符项回到对应 Task 修复。

---

## Self-Review 记录

- **规格覆盖**:Part1 五行修复 → Task 1(3 处)+ Task 1 Step3(sparkline)+ Task 2(材质透出,含兜底);Part2 → Task 3(骨架/三页/窗口尺寸)+ Task 4(服务卡);Part3 验证 → 各 Task 的 build/Verify 步骤 + Task 5 视觉清单。登录窗背景不动、菜单栏链路不动已写入 Global Constraints。
- **占位符**:Task 3 的 `ServicesSettingsPage` 占位是**故意的中间态**(该 Task 内需编译通过),Task 4 Step1 给出完整替换代码,非 TODO。
- **类型一致性**:`SettingsPage` 的 case 名(general/appearance/notifications/services)在 Task 3 的 enum/switch/detailView 三处一致;`ServicesSettingsPage` 在 Task 3 定义、Task 4 整体替换(同名同 private 性);`cardContainer`/`statusRow`/`caption` 仅在 Task 4 内部使用,签名与调用点一致。

# AliyunTokenBar 设计文档

> 仿 KimiCodeBar 的阿里云百炼 Token Plan 套餐用量菜单栏仪表盘
> 创建:2026-08-01 | 状态:待实现

## 1. 背景与目标

做一个 macOS 菜单栏 App,实时显示阿里云百炼 **Token Plan 个人订阅套餐**的用量(5小时限额 / 7天限额百分比),仿照 [KimiCodeBar](https://github.com/xifandev/KimiCodeBar) 的形态:右上角图标常驻,点击弹出用量面板。

**核心需求**:
- 右上角菜单栏图标,显示用量百分比
- 点击弹出下拉面板,展示 5小时/7天限额用量、套餐状态、加购包
- 能安装成原生 .app,支持开机自启

**非目标(YAGNI)**:
- 多账号支持(个人版套餐,只有一个账号)
- 绝对额度展示(API 只返回百分比)
- 本地 token 消耗统计
- Sparkle 自动更新(首版不做)

## 2. 关键技术约束(均已实测验证)

### 2.1 数据源:bl CLI + 控制台私有 RPC

阿里云百炼**没有公开 API** 查 Token Plan 套餐用量。经 Playwright 抓包 + `bl console call` 验证,套餐用量通过三个**控制台私有 RPC** 获取,可用百炼 CLI(`bl`)调用:

```bash
bl console call --api "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/usage" --data '{}' --output json
```

**三个 RPC 及返回结构**(2026-08-01 实测):

| RPC | 返回字段 | 说明 |
|---|---|---|
| `.../api/v2/usage` | `per5HourPercentage`(float 0–1)、`per1WeekPercentage`、`per5HourResetTime`(ms 时间戳)、`per1WeekResetTime` | **核心用量** |
| `.../api/v2/subscription` | `specCode`("pro"等)、`status`("VALID")、`remainingDays`、`startTime`、`endTime`、`autoRenewFlag`、`instanceCode` | 套餐状态 |
| `.../api/v2/addon/summary` | `remainingCredits`、`totalCredits`、`activeCount` | 加购包余额 |

**返回 JSON 三层嵌套**:`data.DataV2.data.data.<实际字段>`

**约束**:
- API 只返回**百分比**(0.x 浮点),无 used/limit 绝对值 → 面板只显示百分比
- 重置时间为**毫秒时间戳**

### 2.2 鉴权:控制台 token,会过期 ⚠️

- 鉴权依赖 `bl` 的**控制台登录态**(access_token,存于 `~/.bailian/config.json`)
- 控制台 token **几天就过期**(实测:几天前登录的 token 已失效)
- Token Plan 的 `sk-sp-` API Key **查不了用量**(实测确认,必须控制台登录)
- App **不自己管理登录**,而是:检测 bl 登录态 → 过期时引导用户跑 `bl auth login --console`

**这是本项目最大的 UX 痛点**,必须在 App 内清晰引导。

### 2.3 外部依赖

- **bl CLI 必须已安装**(Node.js 18+,`npm install -g bailian-cli`)
- **bl 必须已控制台登录**(`bl auth login --console --console-site domestic`)
- App 通过 `Process` shell out 调用 bl,不直接打 HTTP

## 3. 架构

```
┌──────────────────────────────────────────────────────┐
│  AliyunTokenBar.app  (原生 SwiftUI MenuBarExtra)     │
│                                                      │
│  右上角图标 → NSImage 渲染 "35/61"(5h/7d 百分比)     │
│  点击 → 下拉面板 (width 340):                        │
│    ├─ Header: logo + "AliyunTokenBar" + 控制台按钮   │
│    ├─ 用量卡片区:                                     │
│    │   ├─ 5小时限额卡 (35% · 进度条 · 重置时间)      │
│    │   └─ 7天限额卡  (61% · 进度条 · 重置时间)      │
│    ├─ 套餐状态行 (Pro · 生效中 · 剩余291天)          │
│    ├─ 加购包行 (如有余额)                            │
│    └─ 操作按钮: [刷新] [控制台] [设置] [退出]        │
│                                                      │
│  未登录/过期遮罩: "控制台登录已过期,点此重新登录"    │
│                                                      │
│  BlUsageService (数据层):                            │
│    └─ Process ×3: bl console call usage/subscription │
│       /addon → 解析三层嵌套 JSON → TokenPlanQuota    │
│                                                      │
│  TokenPlanModel (状态层):                            │
│    ├─ @Published quota / isLoading / authState       │
│    ├─ 定时刷新 (10分钟) + 手动刷新                   │
│    └─ token 过期检测                                 │
└──────────────────────────────────────────────────────┘
```

## 4. 模块设计

7 个 Swift 文件,仿 KimiCodeBar 结构精简:

### 4.1 `AliyunTokenBarApp.swift` — 入口与配色
- `@main struct AliyunTokenBarApp: App` + `MenuBarExtra(.window)`
- 配色 token(`aliyunPanelBackground`、`aliyunBlue`、`aliyunTextPrimary` 等动态色)—— 复刻 KimiCodeBar 的 `dynamicColor`
- `MenuBarTextRenderer`:将 "35/61" 渲染为 template NSImage(蓝橙双色可选)
- `ThemeManager`、`LaunchAtLoginManager`(SMAppService)—— 直接复刻

### 4.2 `BlUsageService.swift` — 数据获取
- `func fetchQuota() async -> Result<TokenPlanQuota, UsageError>`
- 内部用 `Process` 顺序执行 3 个 `bl console call` 命令
- 解析三层嵌套 JSON(`data.DataV2.data.data`)
- 检测 "Console session is not logged in" 错误 → 返回 `.authExpired`

```swift
struct TokenPlanQuota: Equatable {
    let fiveHour: UsageDetail
    let oneWeek: UsageDetail
    let subscription: SubscriptionDetail?
    let addon: AddonSummary?
}

struct UsageDetail {
    let percentage: Int      // 0-100,从 per5HourPercentage(0.35) 转
    let resetTime: Date?     // 从 ms 时间戳转
    var timeUntilReset: String { /* "X小时Y分钟后重置" */ }
}

struct SubscriptionDetail {
    let specCode: String     // "pro"
    let status: String       // "VALID"
    let remainingDays: Int   // 291
    let endTime: Date?
    let autoRenewFlag: Bool
}

struct AddonSummary {
    let remainingCredits: Double
    let totalCredits: Double
    let activeCount: Int
}
```

### 4.3 `TokenPlanModel.swift` — 状态管理
- `@MainActor final class TokenPlanModel: ObservableObject`
- `@Published quota: TokenPlanQuota?`、`isLoading`、`authState: AuthState`
- `enum AuthState { case unknown, ok, notInstalled, notLoggedIn, expired }`
- 定时刷新:`Timer.publish(every: 600)` + 面板打开时立即刷新 + 手动刷新
- `func refresh()`:调 BlUsageService,失败且为 auth 错误 → 置 `authState = .expired`

### 4.4 `BlAuthManager.swift` — 鉴权检测
- 启动时检测 `bl` 是否在 PATH(`which bl`)
- 检测控制台登录态(`bl auth status --output json` 的 `console` 字段)
- `func relogin()`:用 Process 跑 `bl auth login --console --console-site domestic`(开浏览器)

### 4.5 `TokenPlanMenu.swift` — 下拉面板
- 仿 KimiCodeBar 的 `KimiMenu` 结构
- Header + 用量卡片区(`UsageCard` ×2)+ 套餐状态行 + 操作按钮
- 未登录/过期时覆盖 `AuthOverlayView`(引导重登)
- 操作按钮:刷新 / 控制台(开浏览器到 token-plan 页)/ 设置 / 退出

### 4.6 `UsageCard.swift` — 用量卡片(复刻 KimiCodeBar)
- 标题 + 大百分比(32pt bold rounded)+ 进度条 + 重置时间
- 直接移植 KimiCodeBar 的 `UsageCard`,改配色 token

### 4.7 `Settings.swift` — 设置窗口
- 刷新间隔、开机自启、主题、显示格式(紧凑/单行)
- 复刻 KimiCodeBar 的 `SettingsWindowManager` 单例模式

## 5. 数据流

```
[定时器10min / 面板打开 / 手动点刷新]
        ↓
TokenPlanModel.refresh()
        ↓
BlUsageService.fetchQuota()
        ↓
  Process: bl console call --api .../usage --data '{}' --output json
  Process: bl console call --api .../subscription --data '{}' --output json
  Process: bl console call --api .../addon/summary --data '{}' --output json
        ↓
  解析三层嵌套 JSON → TokenPlanQuota
        ↓
  [@Published quota 更新] → SwiftUI 自动刷新面板 + 图标
        ↓
  若返回 auth 错误 → authState = .expired → 显示重登遮罩
```

## 6. 关键风险与对策

| 风险 | 对策 |
|---|---|
| 控制台 token 过期(几天) | 自动检测过期,面板显示重登引导,一键调 `bl auth login` |
| bl CLI 未安装 | 启动检测,引导安装(`npm install -g bailian-cli`) |
| bl 接口/返回格式变更 | 三层嵌套解析容错(逐层 try?,缺字段返回 nil) |
| 进程启动开销(每次 3 个 Process) | 并发执行 3 个 Process(`async let`);缓存上一次成功结果 |
| 阿里云风控(频繁调用) | 默认 10 分钟间隔,不过频;失败退避 |

## 7. 实现顺序(构建序列)

1. Xcode 项目骨架(`AliyunTokenBarApp` + `MenuBarExtra` + 基础配色)
2. `BlUsageService`(数据层,先用硬编码 JSON 验证解析)
3. `TokenPlanModel`(状态层 + 刷新逻辑)
4. `BlAuthManager`(鉴权检测)
5. `UsageCard` + `TokenPlanMenu`(面板 UI)
6. `AuthOverlayView`(过期遮罩)
7. `Settings`(设置窗口)
8. 图标渲染(`MenuBarTextRenderer`)
9. 开机自启、打磨、签名打包

## 8. 验收标准

- [ ] `bl` 已登录时,打开面板 3 秒内显示真实用量百分比
- [ ] 5小时/7天百分比与控制台页面 `#/efm/subscription/token-plan/personal` 一致
- [ ] 重置时间正确显示("X小时Y分钟后重置")
- [ ] token 过期时显示重登引导,点击后能拉起 `bl auth login`
- [ ] bl 未安装时显示安装引导
- [ ] 开机自启可用(SMAppService)
- [ ] 定时 10 分钟刷新 + 手动刷新均工作

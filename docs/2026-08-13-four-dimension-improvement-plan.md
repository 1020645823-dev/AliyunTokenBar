# CodingTokenBar 四维变革与改善方案

**分析维度**:先进性(Advancement)/ 全面性(Comprehensiveness)/ 自动性(Automation)/ 稳定性(Stability)
**分析方式**:逐文件精读 `Sources/` 全部 27 个 Swift 文件 + 打包脚本 + CI + 历史文档,并以 grep 证据交叉验证
**分析日期**:2026-08-13
**验证基线**:`swift build` green(0.12s,无警告)、`swift run Verify` **ALL PASS**(实测通过)

---

## Executive Summary

CodingTokenBar 是一个**工程深度明显高于同类**的菜单栏用量仪表盘:3 个 AI 套餐 Provider(阿里云百炼 / OpenCode Go / Kimi Code)+ 本机系统指标(CPU/内存/进程 Top10 + kill),逻辑层纯函数化 + 副作用注入,私有 RPC 直连、ACS3 AK/SK 自动续期、libproc 零 spawn 采样、macOS 26 状态项回收规避——这些能力在 KimiCodeBar / opencode-bar / CursorMeter 等对标品中属第一梯队。

但四个维度各有明确短板,且呈现"**功能扩张快于工程治理**"的特征:

| 维度 | 总体评价 | 最痛的问题(各 1 条) |
|---|---|---|
| 先进性 | ★★★★☆ 架构思路先进,工具链陈旧 | 解析层全是 `[String:Any]` 手写取数,无 Codable;CI 钉死已退役的 macos-13 镜像 |
| 全面性 | ★★★☆☆ 覆盖面广,数据-呈现断层 | 阿里云加购包(addon)**拉取了但 UI 零展示**;预测硬编码只算阿里云 7d |
| 自动性 | ★★★★☆ 鉴权自愈出色,系统级自动化缺位 | App 自身无自动更新;睡眠唤醒不刷新、断网不退避、重置边界不触发 |
| 稳定性 | ★★★☆☆ 单点防御多,系统性防线少 | bl 子进程**无超时**(挂死 → 刷新永久锁死);无单实例保护;AK/SK 特性**未提交**;首启通知风暴 |

**优先级总纲:先止血(稳定性 P0)→ 补自动化 → 补全面性 → 再谈先进性重构。**

> **实施状态(2026-08-13 当日跟进)**:P0 全部落地并提交(0c65758/54d20cf/95f3cdd)、P1 全部落地并提交(95f2ac5/e661ed2/0323bac)、P2 核心项落地并提交(64bfe1d/b0f73c1/643e560)。UI/UX 精打磨随各批次完成(hover 态、离线提示、更新角标、授权状态、无障碍标签)。剩余 P3 长期项(成本估算/多账号/Sparkle 公证/全局快捷键/B8 网络磁盘指标)按需启动。每批改动均通过 `swift build` + `swift run Verify`(当前 240+ 断言 ALL PASS)。

---

## 一、先进性(Advancement)

### 1.1 现状亮点(代码实证)

- **现代技术栈**:Swift 5.9 + SwiftUI + SPM 纯源码工程(无 .xcodeproj),`Package.swift` 三 target 分层(Core 纯逻辑 / App UI / Verify 断言)。
- **macOS 26 前瞻性规避**:MenuBarExtra 在 macOS 26 会被系统"隐藏状态项"机制回收进程,项目主动改用 `NSStatusItem + NSPopover` 手动管理(`AppDelegate.swift`),并叠加 `StatusItemVisibilityMonitor` 连续 3 次采样不可见后回退 Dock 图标 + 引导通知。同类工具大多尚未处理此问题。
- **架构分层优秀**:副作用全注入——通知经 `notifySink`、图标经 `renderIconSink`、历史经 `HistoryStorageBackend/HistoryClock` 协议、凭据经 `CredentialStore` 协议,Core 层零系统框架依赖,Verify 可全内存测试。
- **鉴权工程前沿**:阿里云 OpenAPI ACS3-HMAC-SHA256 签名 + 短期 token 交换(`AliyunOpenAPIService.swift`),AK/SK 只进 Keychain、不进 argv/日志,临时 bl 配置目录 0700/0600 权限(`BlEphemeralConfig.swift`)。
- **性能意识**:libproc 直调零 spawn 采样进程(`ProcessMonitorService.swift`,含 mach 时基换算与计数器回绕防护);辅助数据 24h 低频拉取(每轮刷新少 spawn 2/3 的 node 进程)。

### 1.2 先进性差距

| # | 差距 | 证据 |
|---|---|---|
| A-1 | 解析层全部 `JSONSerialization` + `[String:Any]` 手写取数,无 Codable 模型;字段漂移只能靠 Verify fixture 手工同步 | `BlUsageService.swift:31-60`、`KimiUsageService.swift:parse`(400+ 行 dict 操作) |
| A-2 | 测试为自制断言器:无分组、无覆盖统计、无 XCTest 生态;CI 有完整 Xcode 却不用 `swift test` | `Verify/main.swift`(689 行顺序断言)、`.github/workflows/ci.yml` |
| A-3 | CI 钉死 macos-13(已退役镜像)+ Xcode 15.0;只跑 master push;无 release 打包、无 lint | `ci.yml:11,16` |
| A-4 | 无结构化日志(OSLog 0 命中):线上问题只能看 UI 上的 `lastError` 字符串 | grep 全仓 `import OSLog` 0 命中 |
| A-5 | 阻塞式 Process 调用跑在 async 上下文:占用协作线程池;且无 Swift 6 严格并发前瞻 | `BlUsageService.swift:92-93`(readToEnd+waitUntilExit)、Package.swift 无 swiftSettings |
| A-6 | 单体化:`Menu.swift` 1170 行、`TokenPlanModel` 541 行 god-object;Keychain service / UserDefaults 键散落字符串 | `KimiUsageService.swift:188-211`(service 4 处)、`TokenPlanModel.swift` |
| A-7 | 分发停留在 ad-hoc 签名 + 手动 dmg;Sparkle 已删但无任何替代更新通道 | `build-package.sh`、README"更新方式:手动" |
| A-8 | 数据持久化全量重写:每次 append 读全文件 → 改 → 写全文件,无 schemaVersion 迁移 | `HistoryStore.swift:append` |
| A-9 | 细节:DateFormatter 每次新建 7 处;进程图标每 3 秒逐个 `NSWorkspace.icon(forFile:)` 无缓存;OpenCode 解析靠正则匹配 SSR 内联 JS(status 字段抓了不用) | `OpenCodeUsageService.swift:parse` |

### 1.3 变革方案(先进性)

**A1. 解析层 Codable 化(P2,1-2 天,最大单点收益)**
为 bl 三层嵌套响应与 Kimi API 定义 Codable DTO,自定义宽容解码(缺失/null/字符串数字转换),替代全部 `[String:Any]` 取数。Verify fixture 同步迁移(契约注释已有,风险可控)。收益:类型安全、字段漂移定位从"手工比对"变"解码错误指名道姓"、解析代码量减半。

**A2. 测试双轨(P2,0.5 天)**
CI(有完整 Xcode)增加 `swift test` 薄封装 XCTest 套件跑 Verify 等价断言,获得覆盖率与失败聚合;本地保留 `swift run Verify` 零依赖路径。CI 增加 `swift-format lint --strict`(或 swiftlint)。

**A3. CI 现代化(P1,0.3 天)**
升级 `macos-14/15` 矩阵 + 最新 Xcode;`pull_request` 与 `push` 全跑;新增 release job(跑 `build-package.sh`,上传 dmg artifact);构建加 `-warn-concurrency` 前瞻。

**A4. 结构化观测(P0,0.3 天)**
引入 OSLog 子系统 `com.zww.aliyuntokenbar`,分层 logger(network/bl/kimi/keychain);所有状态迁移(authState、refresh 成功/失败/耗时、通知触发)落日志;设置页加"导出诊断包"(日志 + history.json + 版本信息)一键拷贝。这是后续所有稳定性问题的诊断基础。

**A5. 并发正确性(P2,1 天)**
抽 `ProcessRunner`(async、超时、输出截断、terminationHandler),替换全部 Process 调用点;target 开启 Swift 6 渐进迁移(`.enableUpcomingFeature("StrictConcurrency")`),逐步消除 @MainActor 单例上的数据竞争隐患。

**A6. 模块化拆分(P2,1 天)**
`Menu.swift` 按 Provider 拆 5-6 个文件;`TokenPlanModel` 拆为 ProviderController 协议(aliyun/opencode/kimi 各自 controller),model 只保留聚合/定时/通知编排;UserDefaults 键与 Keychain account 收归常量枚举。

**A7. 分发现代化(P2 可选,0.5 天)**
轻量方案:GitHub Releases + 内置"检查更新"(比对最新 release tag → 提示 + 跳转下载),不引入签名成本;完整方案(Sparkle + Developer ID + 公证)需付费账号,列为 P3 可选。

**A8. 数据层演进(P2,0.5 天)**
`history.json` 加 `schemaVersion` + 迁移钩子;或改 JSONL 逐行追加 + 定期 compact,消除全量重写放大。

**A9. 体验细节(P2,0.3 天)**
DateFormatter/ISO8601DateFormatter 静态缓存;进程图标缓存字典;popover 自适应内容尺寸;关键控件补 accessibility。

---

## 二、全面性(Comprehensiveness)

### 2.1 现状亮点

- **4 大板块**:阿里云(5h/7d + 订阅状态)、OpenCode(rolling/weekly/monthly)、Kimi(5h/周/月度 + 共享订阅池 Work/Code 分段 + 加油包 + 会员等级)、本机(CPU/内存/进程 Top10 + 两步确认 kill)。
- **仪表盘能力齐全**:阈值变色、迟滞通知、sparkline 趋势、耗尽预测、7 天历史、订阅剩余天数、bl 版本管理。
- **设置四页**:通用/外观/通知/服务(状态卡片式),主题、5 种菜单栏样式、开机自启。

### 2.2 全面性缺口

| # | 缺口 | 证据 |
|---|---|---|
| B-1 | **阿里云加购包(addon)拉取了但 UI 零展示**:数据采集与呈现断层的典型 | `BlUsageService.swift:43,105,140` 有 parseAddon/fetchAuxOnly;UI 层 grep `addon` **0 命中** |
| B-2 | 订阅信息单薄:只显示套餐名 + 剩余天数;`autoRenewFlag`、起止日期已解析但未展示;无到期预警 | `Models.swift:SubscriptionDetail`(6 字段,UI 只用 3 个) |
| B-3 | OpenCode:登录失败提示"请在设置手动填 workspace ID",但**设置页根本没有该输入框**(死胡同 UX);登出只删 Keychain,不清共享 WKWebsiteDataStore 的 cookie;无多 workspace | `OpenCodeLoginView.swift:66` vs `Settings.swift:openCodeCard` |
| B-4 | Kimi 加油包只读展示,无"月度消费/上限"进度;无配置入口引导 | `KimiBoosterRow` |
| B-5 | 历史只有单窗口 sparkline:无日聚合/周报、无峰值标注、无 CSV 导出 | `HistoryStore.swift` |
| B-6 | **预测硬编码只算阿里云 7d**:OpenCode/Kimi 各窗口无预测(函数签名根本没有 provider/window 参数) | `HistoryStore.swift:151-155`(直接读 `snap.aliyunOneWeek`) |
| B-7 | 通知维度窄:无每日用量摘要、无"回落安全区"提醒;首启还可能一次弹 8 条(见 D-3) | `TokenPlanModel.swift:recordAndNotify` |
| B-8 | 本机指标无网络/磁盘/温度/电池;进程列表无搜索过滤 | `SystemMetricsMonitor.swift` |
| B-9 | 无成本(¥/$)估算维度(上游无 token 数,但 Kimi 已有 ¥ 数据可扩展) | — |
| B-10 | 无多账号(阿里云单 profile / OpenCode 单 workspace) | — |
| B-11 | 无首启 onboarding 引导、无更新日志展示 | — |

### 2.3 变革方案(全面性)

**B1. addon 卡片上线(P1,0.2 天,纯 UI,数据已就绪)**
阿里云 tab 增加加购包行:剩余 credits / 总量 / 生效包数,与订阅行并列。

**B2. 订阅信息补全 + 到期预警(P1,0.2 天)**
订阅行补 `autoRenewFlag`(自动续费角标)与起止日期;`remainingDays ≤ 7` 时橙色告警,并接入通知(独立 WatchKey 或启动时检查一次)。

**B3. OpenCode 配置闭环(P1,0.3 天)**
设置页补 workspace ID 手动输入框 + "校验"按钮(调 `validateCookie`);登出时同步 `WKWebsiteDataStore.default().removeData(ofTypes: [.cookies], for: [opencode.ai])`,消除隐私残留。

**B4. Kimi 加油包进度(P2,0.2 天)**
加油包行加"本月消费 / 上限"迷你进度条 + 超限告警;补网页控制台引导链接。

**B5. 历史分析页(P2,1 天)**
面板新 tab 或设置页"历史":近 7 天多窗口趋势图(Charts 已具备)、每日汇总表(峰值/均值/日均增速)、CSV 导出(NSSavePanel)。

**B6. 预测泛化(P2,0.3 天)**
`estimateMinutesToLimit(provider:window:snapshots:)` 签名化,每张用量卡显示各自窗口的耗尽估算(标注"估算")。

**B7. 通知策略扩展(P2,0.5 天)**
新增"每日用量摘要"开关(每日定时汇总 3 家 Provider 用量);可选"回落安全区"提醒;解决首启风暴(见 D-3)。

**B8. 系统指标扩展(P3,0.5-1 天)**
网络状态(NWPathMonitor 展示连接质量即可)、磁盘剩余空间;进程列表加搜索框与按名称过滤。

**B9-B11(长期/P3)**
成本估算(本地维护套餐价表 × 用量% = 当月估算消费,先覆盖 Kimi 加油包 ¥ 数据)、多账号(bl 多 profile / OpenCode 多 workspace)、首启 onboarding + 更新日志。

---

## 三、自动性(Automation)

### 3.1 现状亮点

- **鉴权自愈闭环**:AK/SK → 短期 token 交换 → 验证 usage RPC → 失败冷却(2× 刷新间隔,最小 10 分钟)→ 回退浏览器重登 + 轮询(36×5s)自动完成登录。
- **凭据自动流转**:OpenCode workspace 自动发现(cookie → `/auth` 重定向 + HTML 双通道);Kimi token 过期自动 refresh 并写回 KimiCodeBar/CLI 文件;web JWT 15 分钟级自动刷新,web 失败自动回退 coding API。
- **刷新分层**:usage 每 tick 拉,subscription/addon 24h 低频,手动刷新强制全量。
- **系统级自动**:开机自启(SMAppService)、状态项不可见自动回退 Dock + 通知、采样器随开关/面板开合自动启停、历史自动淘汰、bl 版本检测。

### 3.2 自动性缺口

| # | 缺口 | 证据 |
|---|---|---|
| C-1 | **App 自身无自动更新**:Sparkle 已移除,更新全靠手动下载 dmg 覆盖 | README"更新方式:手动";`Package.swift` 注释 |
| C-2 | 睡眠唤醒不刷新:合盖再开,数据陈旧,需等下一个 timer tick(最长 60 分钟) | grep `didWakeNotification` 0 命中 |
| C-3 | 无网络感知:断网期间每次 tick 照常空转报错,网络恢复后不立即刷新 | grep `NWPathMonitor/SCNetworkReachability` 0 命中 |
| C-4 | 无失败退避:连续失败仍按固定间隔反复打 bl/网络 | `TokenPlanModel.swift:resetTimer`(固定 interval) |
| C-5 | bl 更新检查仅启动时一次;更新动作丢给 Terminal 且不验证结果 | `BlAuthManager.swift:updateBl`(osascript 开 Terminal) |
| C-6 | 重置边界无事件触发:5h/7d 窗口 reset 时刻过后不立即刷新(仍等 tick) | grep reset 调度 0 命中 |
| C-7 | 无低电量/省电模式降频 | grep `isLowPowerModeEnabled` 0 命中 |
| C-8 | 临时 bl 配置目录崩溃泄漏:清理依赖 deinit,异常退出后 `CodingTokenBar-bl-*` 永久残留 | `BlEphemeralConfig.swift:deinit` |
| C-9 | relogin 轮询固定 3 分钟(36×5s),浏览器登录慢则超时无提示 | `TokenPlanModel.swift:442` |
| C-10 | 无外部触发入口:无全局快捷键 / URL scheme / CLI 子命令 | grep `URLScheme/NSEvent.addGlobal` 0 命中 |
| C-11 | AK/SK 自动恢复失败即 `relogin()` 弹浏览器,且每冷却周期重试一次 → 可能反复弹浏览器骚扰用户 | `TokenPlanModel.swift:autoConfigureAliyunIfNeeded` |

### 3.3 变革方案(自动性)

**C1. 检查更新(P1,0.3 天)**
GitHub Releases API 比对版本 → 菜单栏/设置页提示 + 一键跳转下载页(不下载不安装,零签名成本)。完整 Sparkle 待签名公证后启用(P3)。

**C2. 唤醒刷新 + C3. 网络感知 + C6. 重置边界调度(P1,0.5 天)**
订阅 `NSWorkspace.didWakeNotification` → 立即 `refresh()`;`NWPathMonitor` satisfied 跳变 → 立即刷新,断网时暂停 tick 并在 UI 显示"离线";按 `usage.resetTimeMs` 排一次精确时刻刷新(重置后 10 秒内捕捉归零)。

**C4. 失败退避 + C7. 省电降频(P1,0.5 天)**
失败计数 n,下次间隔 `min(base × 2^n, 30min)` + 随机抖动,成功后复位;`isLowPowerModeEnabled` 时刷新间隔 ×2、系统指标采样暂停。

**C5. bl 更新进程内化(P2,0.3 天)**
更新检查每日化;`npm install -g` 改为子进程内执行 + 进度输出到面板 + 完成后重读 `installedVersion()` 校验结果。

**C8. 临时目录启动清扫(P1,0.1 天)**
启动时扫描 `tmp/CodingTokenBar-bl-*`,mtime 超 24h 的删除。

**C9. relogin 监听改进(P2,0.2 天)**
监听时长可配(默认延长到 5 分钟),超时在面板给出明确提示与"再次尝试"按钮。

**C10. 自动化入口(P3,0.5 天)**
全局快捷键(如 ⌥⌘T 开面板/⌥⌘R 刷新)+ `codingtokenbar://refresh` URL scheme;可选 CLI 子命令 `CodingTokenBar status` 供脚本消费。

**C11. 自动恢复防骚扰(P1,0.2 天)**
弹浏览器前先发一条通知("即将打开浏览器以恢复阿里云登录,可点击取消"),连续 2 次失败后暂停自动弹窗,改为面板内红色提示。

---

## 四、稳定性(Stability)

### 4.1 现状亮点

- **构建与测试基线健康**:`swift build` 0 警告,`swift run Verify` ALL PASS(解析/鉴权状态机/阈值迟滞/历史淘汰/进程采样/菜单栏表格模型全覆盖)。
- **历史事故的防御沉淀**:鉴权状态机防死循环(`AuthState.afterRefresh`)、宽容解析防"整次更新失败静默旧值"、旧值展示带"刷新失败"橙色告警、通知迟滞防抖动、滑动窗口空窗倒计时隐藏——每条都是 2026-08-03 事故后的修复。
- **安全基线**:Keychain 存储、AK/SK 不进 argv/日志、临时配置 0700/0600、atomic 写入、root 进程 kill 禁能 + 两步确认、GUI PATH 补全。
- **macOS 26 适配**:状态项回收规避 + 连续采样可见性回退,双保险。

### 4.2 稳定性风险(按严重度排序)

| # | 级别 | 风险 | 证据 |
|---|---|---|---|
| D-1 | **高** | **bl 子进程无超时**:`readToEnd + waitUntilExit` 无限阻塞;bl(node)挂死 → `isLoading` 恒 true → `guard !isLoading` 使此后**所有刷新永久失效**,且阻塞 Swift 协作线程池 | `BlUsageService.swift:92-93`;同模式在 `BlAuthManager.swift:43-133` 4 处(仅 `latestVersion` 有 30s 超时) |
| D-2 | **高** | **无单实例保护**:双开 App → 两个进程并发读-改-写 `history.json`(数据损坏)+ 两个状态项 + 通知双发 | grep `LSMultipleInstancesProhibited/NSRunningApplication` 0 命中 |
| D-3 | **高** | **首启通知风暴**:`NotificationTracker` 空态"首见即弹",首刷 3 Provider 8 个窗口可一次弹 8 条通知,直接摧毁用户信任 | `ThresholdLogic.swift:NotificationState.update`(lastBand==nil 即触发) |
| D-4 | **中高** | **重要功能未提交**:AK/SK 自动续期特性(9 个文件修改 + 6 个新文件)全部在工作区未提交——无评审记录、不可回滚、无 CI 验证;且改动了 `BlUsageService`/Verify 契约文件未走双检查 | `git status`:9 modified + 6 untracked(含 `AliyunOpenAPIService.swift` 等) |
| D-5 | **中** | Kimi token 回写外部文件:重写 KimiCodeBar 的 `credentials.json`,与对方进程并发写有损坏对方凭据的风险,且无锁无备份 | `KimiUsageService.swift:131-159` |
| D-6 | **中** | OpenCode 解析脆弱:正则匹配 SSR 内联 JS,页面改版即整体 parse 失败;`status` 字段抓了不校验 | `OpenCodeUsageService.swift:parse` |
| D-7 | **中** | 登出不彻底:OpenCode 登出只删 Keychain,共享 `WKWebsiteDataStore.default()` 中 auth cookie 残留(隐私 + 误判登录态) | `OpenCodeLoginView.swift:config.websiteDataStore = .default()` |
| D-8 | **中** | CI 镜像已退役(macos-13)+ Xcode 15.0 钉死;PR 不跑 CI;无 lint、无超时、无 release job | `ci.yml:3-16` |
| D-9 | **中低** | history.json 全量重写:每次 append 读改写全文件,三 Provider 每 10 分钟一次,写放大 + 异常断电窗口虽被 atomic 掩盖但无 schema 迁移 | `HistoryStore.swift:append` |
| D-10 | **中低** | 配置键/Keychain service 字符串散落(service 4 处、UserDefaults 键多处),改一处漏一处;且 CLAUDE.md 键清单缺 `systemStatsEnabled`(文档漂移) | `KimiUsageService.swift:188-211` |
| D-11 | **低** | 进程 kill 的 pid 复用窗口:3 秒确认期内 pid 可能已被系统回收给新进程,`kill` 打错对象 | `Menu.swift:killTapped` |
| D-12 | **低** | WKWebView localStorage 轮询无上限(每 3 秒一次直到登录成功),无超时取消 | `KimiLoginView.swift:pollLocalStorage` |
| D-13 | **低** | 分布式通知 observer 未注销(进程级,可接受) | `AppDelegate.swift:themeChangeObserver` |

### 4.3 变革方案(稳定性)

**D1. 统一 ProcessRunner + 超时(P0,0.5 天)**
抽 `ProcessRunner.run(executable:args:env:timeout:)` async 封装:30s 默认超时 → 终止子进程 → 返回明确错误。替换 `BlUsageService.callRPC` 与 `BlAuthManager` 全部 4 处 spawn。挂死场景从"永久锁死"降级为"单次失败 + UI 报错 + 下轮重试"。

**D2. 单实例保护(P0,0.2 天)**
启动时 `NSRunningApplication.runningApplications(withBundleIdentifier:)` 检测已有实例 → `activate` 并退出;或 Info.plist 加 `LSMultipleInstancesProhibited`。另给 history.json 写入加 flock 双保险。

**D3. 通知首刷静默种子(P0,0.2 天)**
启动后第一个评估周期只记录 band 不弹通知(`NotificationState` 加 seedOnly 模式),或把 tracker 状态与 history 同生命周期持久化,升级/重装后不重复轰炸。

**D4. 提交 AK/SK 特性 + 补断言(P0,0.5 天)**
按功能拆分 commit(ACS3 签名与 token 交换 / ephemeral 配置 / UI 接线);补 Verify:固定 timestamp+nonce 的 ACS3 签名向量断言、`parseAccessToken` 各路径、`AliyunAuthRecovery.inCooldown` 边界、`BlEphemeralConfig` 目录权限;CI 绿后再继续新功能。

**D5. Kimi 回写保护(P1,0.3 天)**
写回改为临时文件 + 原子替换 + 失败静默(不影响自身拉取),写前对目标文件做 flock 或至少备份 `.bak`。

**D6. OpenCode 解析加固(P1,0.3 天)**
多候选正则(兼容键序/空格差异)+ 三窗口一致性自检 + `status != "ok"` 时按 authExpired/parse 分流;失败提示明确"页面结构可能变化"并提供重新登录入口。

**D7. 登出清 cookie(P1,0.2 天)**
`clearOpenCode()` 同步清理 WKWebsiteDataStore 中 opencode.ai 的 cookies。

**D8. CI 升级(P1,0.3 天)**
macos-14/15 矩阵 + 最新 Xcode + PR/push 全跑 + `swift-format lint` + job timeout + release job(打包上传 artifact)。

**D9. History JSONL 化(P1,0.5 天)** ✅ 已实施
写入 v1 JSONL(首行 schemaVersion 注释 + 一行一条快照,单行损坏不影响整体);v0 旧 JSON 数组透明读取、下次写入自动迁移;flock 互斥(D2)保证并发安全。

**D10. 常量集中(P1,0.2 天)**
`UserDefaultsKeys` / `KeychainAccounts` 枚举;同步更新 CLAUDE.md 键清单(补 `systemStatsEnabled`),消灭文档漂移。

**D11. kill 前复核(P2,0.1 天)**
确认态点击时重新采样校验 pid→进程名一致再 SIGKILL。

**D12. 轮询超时(P2,0.1 天)**
WKWebView localStorage 轮询加 5 分钟上限 + 页面导航变化时重置。

---

## 五、路线图(按优先级 × ROI)

### P0 止血(0.5-2 天,稳定性优先,建议本周完成)

| 行动 | 维度 | 工作量 |
|---|---|---|
| D1 ProcessRunner 统一超时 | 稳定性 | 0.5d |
| D2 单实例保护 + history 写锁 | 稳定性 | 0.2d |
| D3 通知首刷静默种子 | 稳定性 | 0.2d |
| D4 提交 AK/SK 特性 + 补断言 | 稳定性 | 0.5d |
| A4 OSLog 结构化日志 | 先进性 | 0.3d |

### P1 补自动化与全面性(1-2 周)

| 行动 | 维度 | 工作量 |
|---|---|---|
| C2+C3+C6 唤醒/网络/重置边界刷新 | 自动性 | 0.5d |
| C4+C7 失败退避 + 省电降频 | 自动性 | 0.5d |
| C1 检查更新 + C8 临时目录清扫 + C11 防骚扰弹窗 | 自动性 | 0.6d |
| B1 addon 展示 + B2 订阅到期预警 | 全面性 | 0.3d |
| B3 OpenCode workspace 输入 + 登出清 cookie | 全面性 | 0.3d |
| D5/D6/D7/D8/D10 Kimi 回写保护、OpenCode 加固、登出清 cookie、CI 升级、常量集中 | 稳定性 | 1.2d |
| D9 历史 JSONL 化 | 稳定性 | 0.5d |

### P2 先进性重构(2-4 周)

| 行动 | 维度 | 工作量 |
|---|---|---|
| A1 解析层 Codable 化(全量 Verify 回归) | 先进性 | 1-2d |
| A5 并发正确性 + Swift 6 渐进 | 先进性 | 1d |
| A6 模块化拆分(Menu/TokenPlanModel) | 先进性 | 1d |
| A2 测试双轨 + 覆盖率 + lint | 先进性 | 0.5d |
| A8/A9 数据 schema 演进 + 性能细节 | 先进性 | 0.8d |
| B5 历史分析页 + CSV 导出 + B6 预测泛化 | 全面性 | 1.3d |
| B7 每日摘要通知 | 全面性 | 0.5d |

### P3 长期差异化(1-2 月,按需取舍)

B8 网络/磁盘指标;A7 Sparkle + 公证(需开发者账号);B9 成本估算;B10 多账号;B11 onboarding + 更新日志;C10 全局快捷键/URL scheme/CLI。

---

## 附:证据索引

- 构建/测试基线:本次实测 `swift build` green、`swift run Verify` ALL PASS
- 未提交工作区:`git status` 9 modified + 6 untracked(AK/SK 特性),master 分支
- addon 断层:Core 有 `parseAddon`(`BlUsageService.swift:43`),UI 层 `addon` 引用 0
- 预测硬编码:`HistoryStore.swift:151-155`
- 子进程无超时:`BlUsageService.swift:92-93`、`BlAuthManager.swift:43-133`(唯一有超时的是 `latestVersion`)
- 单实例/OSLog/唤醒/网络感知/省电/URL scheme/CSV/摘要:grep 全 0 命中
- CI 退役镜像:`.github/workflows/ci.yml:11,16`
- Kimi 外部文件回写:`KimiUsageService.swift:131-159`
- 通知首见即弹:`ThresholdLogic.swift:NotificationState.update`

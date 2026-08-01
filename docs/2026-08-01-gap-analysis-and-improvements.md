# AliyunTokenBar 仪表盘能力对标分析与显著改进方案

**对标类型**：功能性对标(同类 menubar 用量监控工具) | **分析目的**：识别能力缺口、设计显著改进 | **日期**：2026-08-01
**基准版本**：v1.0.11(1761 行 Swift,`swift build` green,`swift run Verify` ALL PASS)

---

## 核心发现(Executive Summary)

AliyunTokenBar 当前是一个**「实时快照型」仪表盘**:擅长"此刻用量百分比 + 倒计时"的常驻展示,但作为「仪表盘(dashboard)」存在 5 类关键能力缺失。对标 2026 年同期 10+ 款同类工具(KimiCodeBar / opencode-bar / CursorMeter / ClaudeMeter / tokscale / Tokcat / BurnRate / onWatch 等),最关键的 4 项缺口已**接近行业标配**:

1. **限额预警通知**——用量接近上限时无任何主动提醒(7/10 竞品已具备,含开源的 coding-plan-monitor / CursorMeter)。**关键差距。**
2. **用量历史/趋势**——零历史持久化,刷新即覆盖,无法回答"我这周用量走势如何/何时会爆"。**关键差距。**
3. **颜色阈值/视觉告警**——菜单栏图标在 95% 和 30% 时视觉无差异,失去"扫一眼即知风险"的仪表盘核心价值。**关键差距。**
4. **成本/消耗预测**——无 $ 成本、无月度预测、无超额预警(阿里云侧因数据源所限为弱项,但本地日志可补)。

此外有 **2 项工程债**(Sparkle 已删但 entitlements/README 仍引用,造成混淆与潜在 Gatekeeper 风险)、**1 项凭据安全隐患**(OpenCode cookie 明文存 UserDefaults)。

**最大既有优势**:`bl console call` 的私有 RPC 直连 + 双 Provider 彩色区分 + 辅助数据 24h 低频拉取(32MB/0% idle 的性能)——这些是多数竞品不具备的工程深度,应保留。

---

## 一、当前能力盘点(代码实证)

基于逐文件阅读(`Sources/` 全 8 文件 + `Verify/main.swift` + `Package.swift`)的实证清单:

| 能力维度 | 现状 | 代码证据 |
|---|---|---|
| 常驻菜单栏展示 | ✅ 4 种样式(cloudPercent/compact/singleLine/iconOnly) | `App.swift:84-266` `MenuBarTextRenderer` |
| 双 Provider 彩色区分 | ✅ 阿里云橙 + OpenCode 紫 | `App.swift:134-159` `cloudPercentImage` |
| 面板用量卡片 | ✅ 5h/7d 百分比 + 进度条 + 倒计时 | `Menu.swift:128-155` `UsageCard` |
| OpenCode 三窗口 | ✅ rolling/weekly/monthly | `Menu.swift:276-317` `OpenCodeCard` |
| 多 Provider 架构 | ✅ TokenPlanModel 同时持有阿里云 + OpenCode quota | `TokenPlanModel.swift:9,28` |
| 自动定时刷新 | ✅ 可配 5/10/30/60 分钟;辅助数据 24h 低频 | `TokenPlanModel.swift:44,94-104,115-151` |
| 手动刷新 | ✅ 强制全量(`refreshFull`) | `TokenPlanModel.swift:154-169` |
| 鉴权态机 | ✅ unknown/ok/blNotInstalled/notLoggedIn/expired | `Models.swift:85-91`,`BlAuthManager.swift` |
| 一键登录 | ✅ 阿里云(bl 浏览器) + OpenCode(WKWebView 抓 cookie) | `BlAuthManager.swift:40`,`OpenCodeLoginView.swift` |
| bl 安装引导 + 版本检查 | ✅ 安装命令可复制 + 一键更新 | `Menu.swift:182-270` |
| 主题(浅/深/跟随) + 开机自启 | ✅ | `App.swift:41-80`,`Settings.swift:9-18,95` |
| **限额预警通知** | ❌ 全代码无 `UNUserNotificationCenter`/`alert` | grep 全仓 0 命中 |
| **用量历史/趋势** | ❌ `lastUpdated` 单值,无时序持久化 | `TokenPlanModel.swift:13`;无 CoreData/JSON 落盘 |
| **颜色阈值告警** | ❌ 橙/紫固定色,95% 与 30% 同色 | `App.swift:136-137` 硬编码 |
| **成本/消耗** | ❌ 仅百分比,无 token 数 / $ / 预测 | `Models.swift` 无 cost 字段 |
| **本地日志扫描** | ❌ 不读 `~/.claude` / opencode session 日志 | 无文件 tail 逻辑 |
| **凭据存储安全** | ⚠️ OpenCode cookie 明文存 UserDefaults | `TokenPlanModel.swift:34-39` |
| 测试 | ✅ Verify 断言 18+ 项(解析/鉴权/OpenCode) | `Verify/main.swift` |

---

## 二、对标矩阵(我方 vs 标杆)

> 数据来源:竞品 README/源码/HN/Reddit 公开信息,`[推断]` 标注者基于代码逻辑推断。
| 能力 | AliyunTokenBar (我方) | KimiCodeBar (基准) | opencode-bar (功能标杆) | CursorMeter (通知标杆) | Tokcat/tokscale (分析天花板) | 行业普及度 | 我方差距 |
|---|---|---|---|---|---|---|---|
| 限额预警通知 | ❌ | ❌ | ⚠️色变 | ✅可配阈值+spike | ❌/❌ | 7/10 | **关键** |
| 颜色阈值图标 | ❌(固定色) | ❌ | ✅绿黄橙红 | ✅ | — | 4/10 | **关键** |
| 历史趋势图 | ❌ | ❌ | ✅30天 | ✅7天柱图 | ✅日/时/分+贡献图 | 6/10 | **关键** |
| 消耗/预测 | ❌ | ⚠️(仅加油包) | ✅月末预测 | ✅含$ | ✅ per-model | 6/10 | **重要** |
| 多 Provider | ✅2 | ❌(1) | ✅15+ | ❌ | ✅10-40+ | 中 | 中(架构已就绪) |
| 多账号 | ❌ | ❌ | ✅ | ❌ | — | 低 | 低 |
| 本地日志扫描 | ❌ | ❌ | ❌ | ✅活动驱动 | ✅ | 中 | 中(差异化点) |
| 凭据安全 | ⚠️明文 | — | ✅Keychain | ✅Keychain | — | 中 | **重要** |

**差距分级**:
- **关键差距**(>30% 普及度且影响核心价值):限额通知、颜色阈值、历史趋势
- **重要差距**(影响深度/安全):成本预测、凭据安全(Keychain)
- **一般差距**(差异化机会,非必须):多账号、本地日志扫描、velocity/spike 动效

---

## 三、关键差距根因分析(两层 Why)

### 差距 1:无限额预警通知(关键)
- **Why-1(能力层)**:代码中从未请求通知授权、未注册 `UNUserNotificationCenter` delegate、刷新后只更新 `@Published` 不触发任何副作用。
- **Why-2(设计层)**:最初定位是 KimiCodeBar 的"展示型"仿品,沿用了其"被动展示"心智,未演进到"主动看护"的仪表盘定位。这是**定位漂移**——产品名带 "Bar" 但目标已是 dashboard。
- **影响**:用户必须主动点开面板才知道接近上限,完全失去"后台守护"价值。这是**最高 ROI 改进项**。

### 差距 2:无历史趋势(关键)
- **Why-1(能力层)**:数据模型只有快照(`quota: TokenPlanQuota?`),无时间轴;无持久化层(无 CoreData/SwiftData/JSON 落盘),每次刷新覆盖。
- **Why-2(架构层)**:纯内存单例 + UserDefaults(只存配置),从未规划时序存储。`lastAuxFetch` 24h 缓存说明已意识到数据分层,但只做到"少拉",没做到"留存"。
- **影响**:无法回答"走势/峰值/何时耗尽";趋势分析是仪表盘区别于"只读仪表"的分水岭。

### 差距 3:颜色阈值无区分(关键)
- **Why-1(能力层)**:`cloudPercentImage` 用 `renderColored`(非模板),颜色硬编码为品牌橙/紫(`App.swift:136-137`),与百分比无函数关系。
- **Why-2(取舍层)**:为"双 Provider 区分度"主动放弃了明暗适配,选了固定品牌色;但没把"阈值变色"纳入同一渲染管线。**这是当年合理的取舍,但现在可解耦**——品牌色用于图标形状/前缀,阈值色用于百分比数字。
- **影响**:95% 看起来和 30% 一样,仪表盘最关键的"异常即视"失效。

### 差距 4:无成本/预测(重要)
- **Why-1(能力层)**:阿里云 `bl` RPC 只回百分比 + resetTime,无 token 数 / $ 数据;OpenCode SSR 同样只有百分比。
- **Why-2(数据源层)**:这是**上游 API 限制**(`[[aliyun-bailian-no-public-usage-api]]` 记录的约束),非代码缺陷。但可经**本地日志扫描**旁路补足(opencode/claude session JSONL 含真实 token 数)。
- **影响**:无法做预算管理;对付费用户价值打折。

---

## 四、显著改进方案(按优先级 × ROI 排序)

### 🥇 方案 A:限额预警通知系统(P0,预计 0.5 天,ROI 最高)
**目标**:用量跨越 70%/90% 阈值时弹 macOS 原生通知,跨阈值只通知一次(hysteresis)。

**设计**:
- 新文件 `Sources/AliyunTokenBarCore/NotificationManager.swift`(纯逻辑,可 Verify):
  - `requestAuthorization()`:`UNUserNotificationCenter.current().requestAuthorization([.alert,.sound])`
  - `evaluate(percentage: Int, window: String, provider: String)`:阈值状态机,记录上次区间(`<70`/`70-90`/`≥90`),仅**跨区上行**时发通知。
  - 阈值可配(设置项:告警阈值 70/80/90 三选,默认 80)。
- 接入点:`TokenPlanModel.refresh()` 成功后对 5h/7d/rolling/weekly 各调一次 `evaluate`。
- 通知文案例:`⚠️ 阿里云 5小时限额已达 82%(剩 18 分钟重置)`。
- Verify:加状态机单测(70→85 触发,85→88 不触发,88→68 不触发,68→91 触发)。

**对标**:对齐 CursorMeter(80/90%)、ClaudeMeter(70/90%)、coding-plan-monitor(90%)。

---

### 🥈 方案 B:用量历史持久化 + sparkline 趋势(P1,预计 1.5 天)
**目标**:每次刷新落盘一条快照,面板展示 7 天 sparkline,菜单栏可选紧凑 sparkline。

**设计**:
- **存储**:`~/Library/Application Support/AliyunTokenBar/history.json`(轻量,纯 Foundation `JSONEncoder`,不引入 SwiftData 以免依赖升级)。结构:
  ```swift
  struct Snapshot: Codable { let ts: Date; let fiveHour: Int; let oneWeek: Int;
                             let ocRolling: Int?; let ocWeekly: Int?; let ocMonthly: Int? }
  ```
  环形缓冲(每窗口最多 7天/2小时一条,自动淘汰)。
- **写入**:`TokenPlanModel.refresh()` 成功后 append;读取时按窗口聚合。
- **展示**:
  - 面板每张 `UsageCard` 底部加一条 60pt 高 sparkline(`SwiftUI Charts` 框架,iOS16+/macOS13+ 已满足)。
  - 新菜单栏样式 `sparkline`:阿里云 7d 趋势线 + OpenCode weekly 趋势线。
- **预测(增量价值)**:基于近 7 天 7d 百分比线性外推,显示"按当前速率约 X 天后达上限"——对齐 opencode-bar 的 "Predicted EOM"。

**对标**:对齐 CursorMeter(7天柱图)、opencode-bar(30天)、Tokcat(30天堆叠图)。

---

### 🥉 方案 C:阈值颜色编码(P1,预计 0.5 天,与 A 协同)
**目标**:菜单栏百分比数字 + 进度条按用量变色,保留 Provider 品牌色于图标前缀。

**设计**:
- 新 `func thresholdColor(_ pct: Int, base: Color) -> Color`:<70→base;70-89→`orange`;≥90→`red`。
- `cloudPercentImage`:云朵/bolt 图标保持品牌橙/紫(区分 Provider),**百分比数字改用 `thresholdColor`**(区分风险)。
- 面板 `UsageCard` 进度条同步:`color = thresholdColor(detail.percentage, base: .atbBlue)`。
- 新菜单栏 iconOnly 样式:外环颜色按阈值变色(目前固定 `.black`)。
- Verify:`thresholdColor(69)==base`,`thresholdColor(70)==orange`,`thresholdColor(90)==red`。

**对标**:对齐 opencode-bar(绿黄橙红)、CursorMeter(仪表盘环)、ClaudeMeter。

> 取舍说明:方案 C 与现有"双 Provider 彩色区分"看起来冲突,实则是**正交**的——形状/前缀编码 Provider,数字/进度条编码风险。两者可共存,反而比单纯品牌色信息量更高。

---

### 方案 D:凭据安全——OpenCode cookie 入 Keychain(P2,预计 0.3 天)
**目标**:OpenCode auth cookie 从 UserDefaults 迁到 macOS Keychain。

**设计**:
- 新 `Sources/AliyunTokenBarCore/KeychainStore.swift`:`get/set/delete(account:)`,服务名 `com.aliyuntokenbar.opencode`。
- `TokenPlanModel.openCodeCookie` 的 `didSet` 改写 Keychain;`workspaceID` 可留 UserDefaults(非敏感)。
- 首启迁移:读旧 UserDefaults 值 → 写 Keychain → 删 UserDefaults 键。
- Verify:mock keychain(注入 closure)测读写删。

**对标**:对齐 CursorMeter / opencode-bar(均 Keychain)。

---

### 方案 E:工程债清理(P2,预计 0.2 天)
- **entitlements**:`packaging/AliyunTokenBar.entitlements` 仍含 `disable-library-validation` + `allow-unsigned-executable-memory`(Sparkle 残留)。Sparkle 已于 v1.0.8 删除,这两项应移除——**减小攻击面**,且消除 Gatekeeper 审查疑点。
- **README**:仍大段描述 Sparkle 安装/发布流程(v1.0.8 已删),误导贡献者。改为"手动更新"说明 + OpenCode 登录章节。

---

### 方案 F:本地日志扫描(差异化,P3,预计 1 天)
**目标**:扫描 `~/.claude/projects/**/sessions/*.jsonl`、`~/.local/share/opencode/sessions/` 的真实 token 计数,补足"百分比之外的真实消耗",并经此推算 $ 成本(查 LiteLLM 价表)。

**对标**:对齐 Tokcat/tokscale(均靠本地日志绕过 API 限制)。
> 这是绕开"阿里云/OpenCode 无公开 API"约束的最有潜力路径(`[[opencode-go-usage-no-public-api]]` 记录的痛点)。但工作量较大,列为 P3,待 A-C 验证后推进。

---

## 五、追赶路径(分阶段)

### 短期速赢(0–1 周)→ 目标:补齐行业标配
| 行动 | 弥合差距 | 工作量 | 预期效果 |
|---|---|---|---|
| 方案 A 通知 | 关键差距 1 | 0.5d | 用户不再需要主动查看即知风险 |
| 方案 C 颜色阈值 | 关键差距 3 | 0.5d | 扫一眼即知风险,仪表盘感成立 |
| 方案 E 工程债 | 安全/文档 | 0.2d | 攻击面↓,贡献者不误导 |

### 中期建设(1–3 周)→ 目标:成为真正"仪表盘"
| 行动 | 弥合差距 | 工作量 | 预期效果 |
|---|---|---|---|
| 方案 B 历史+sparkline | 关键差距 2 | 1.5d | 趋势可视化 + 耗尽预测 |
| 方案 D Keychain | 重要差距 | 0.3d | 凭据安全达标 |

### 长期差异化(1–2 月)→ 目标:超越标配
| 行动 | 弥合差距 | 工作量 | 预期效果 |
|---|---|---|---|
| 方案 F 本地日志扫描 | 成本预测/真实消耗 | 1d+ | 绕开 API 限制,补 token/$ 维度 |

---

## 六、数据缺口与风险

- **`brfid/quotactl` / `mtrojnar/pi-usage`** 两个仓库未能验证存在(可能已改名/私有);改用 opencode-bar/tokscale 作替代标杆,不影响结论。
- **方案 B 的预测精度**:7d 窗口百分比线性外推仅粗略,因阿里云 5h 窗口是滚动非固定周期。文档中标注"估算"。
- **方案 A 通知授权**:首次需用户授权,拒绝时降级为面板内红字提示(不阻塞)。
- **不编造**:阿里云/OpenCode 仍无公开 token/$ API,成本类方案(F)依赖本地日志,非上游数据。

---

## 附:验证基线(本分析前已确认)
- `swift build`:Build complete ✅
- `swift run Verify`:ALL PASS(18+ 断言)✅
- 代码逐文件阅读:`Sources/` 8 文件 + `Package.swift` + `Verify/main.swift` ✅
- 竞品来源:KimiCodeBar / opencode-bar / CursorMeter / ClaudeMeter / tokscale / Tokcat / coding-plan-monitor / BurnRate / onWatch / iStat Menus,均引公开 README/源码/HN。

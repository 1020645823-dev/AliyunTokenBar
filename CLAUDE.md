# AliyunTokenBar — Agent Instructions

macOS 菜单栏 App(SwiftUI + Swift Package Manager,无 Xcode 项目文件)。
实时显示阿里云百炼 Token Plan + OpenCode Go + Kimi Code + DeepSeek API(总余额/当日费用)+ 智谱 GLM Coding Plan + 小米 MiMo(余额/套餐)+ MiniMax Coding Plan + Ollama Cloud 用量 + 阶跃星辰 StepFun Step Plan(月池/加油包)+ 本机 CPU/内存/进程指标。

## 命令

```bash
swift build                              # 构建(编译检查)
swift run AliyunTokenBar                 # 运行 App
swift run Verify                         # 跑断言测试(替代 XCTest,因开发机无完整 Xcode)
VERSION=x.y.z ./packaging/build-package.sh  # 打包 .app + .dmg
./packaging/install-update.sh            # 一键更新现场:构建(默认已装版本 patch+1)→ 退出 → 替换 /Applications → 重启
```

⚠️ **本机必须指定 SDK**(无 Xcode;默认 MacOSX27.0.sdk 缺 SwiftUI 宏插件会构建失败):

```bash
export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
swift build && swift run Verify           # 先 export 再跑,一次设置全场生效
```

**每次修改代码后,必须运行 `swift build` + `swift run Verify` 确认通过。**

## 架构(3 个 SPM target)

| Target | 类型 | 职责 |
|--------|------|------|
| `AliyunTokenBarCore` | library | 纯逻辑层:模型/解析/鉴权/阈值/历史/凭据(可直接测试) |
| `AliyunTokenBar` | executable | SwiftUI UI + `@main` 入口(不可直接测试) |
| `Verify` | executable | 断言测试(替代 XCTest,`check()` 函数,非 XCTest API) |

### 数据源 Registry(⚠️ 唯一权威)

「有哪些数据源」由 `ProviderRegistry.swift` 的 `ProviderKind`(10 case:aliyun/openCode/kimi/deepSeek/zhipu/mimo/minimax/ollama/stepfun/system)统一驱动:显示开关(全面停用语义:菜单栏不出列、面板不出 tab、停止轮询、不参与告警/摘要)、面板 tab 顺序、刷新调度 `refresh(provider:)`、configured 判定 `isConfigured(_:)` 均由它收口。**新增数据源必须挂进 registry**,不要再加平行的枚举/布尔标志。停用集合存 `disabledProviders` 键;`systemStatsEnabled` 仅作本机开关的兼容代理(真值在停用集合)。菜单栏 10 列(v1.0.47 起智谱/MiMo 有列:智谱=5h/周,MiMo=套餐%/余额;v1.0.48 起金额列去币种符号(compactDigits ≤5 字符),值域统一 34pt/列距 4pt/图标位 8pt;Ollama 列随数据形态变形:新计费=月度单值列、旧计费=5小时+周双值列;阶跃列标签随形态:月池/加油包 或 5小时/周,由调用方按数据传入;列序= `MenuBarColumnKind` 声明序,与面板 tab 序刻意不同)。

### 订阅卡 UI 系统(v1.0.66:StepFun 设计范式泛化到全部内置订阅)

StepFun 卡 v1.0.65 验证过的设计语言已泛化,**所有订阅卡共用底座、各有特色**:

- **Core 预测层** `UsageForecast.swift`(纯函数,Verify 覆盖):`monthEndPct`(月池/固定边界窗口→重置时刻百分比)、`pctPerHour/pctPerDay`、`minutesToLimit`(速率触顶:窗口类回答"还有多久被限流",回落/不足→nil 不猜)、`burnPerDay/runwayDays`(余额类→还能撑几天)、`durationText`(时长文案)。数据门槛:≥2 点且跨度 ≥6h,否则 UI 显示"趋势积累中"。`StepFunForecast` 仅为兼容 typealias。
- **App 共享组件** `ATBUsageKit.swift`:`ATBRefreshButton`/`ATBSubtitleText`/`ATBBrandTag`/`ATBBrandActionButton`(品牌行零件)、`atbStripeCard(brand:hero:)`(品牌竖纹卡修饰符,取代各卡重复的 overlay/clipShape 组合)、`ATBMiniRing`(46pt 环)、`ATBForecastRow`(预测行)、`ATBInfoRow`(图标+单行明细)、`ATBThinMeterRow`(3pt 细条行)、`ATBUnavailableRow`(横杠)、`ATBErrorHintCard`、`ATBLoadingCard`、`ATBTimeFormat`(更新时间/历史最新快照取数)、`ATBHistory`(序列提取:pctSamples/valueSamples,provider/window 命名同 HistoryStore.series)。
- **每卡固定增强**:品牌行副标题带**数据更新时间**;窗口类卡出**触顶预测行**(projected≥99.5% → "约 X 后触顶"橙色告警,否则 "预计重置时用到 X%");远期(如 Ollama >30 天、MiMo <14 天 runway)才用警告色。**各家特色**:Kimi=token 绝对量行(used/limit)+订阅共享池分段(Work/Code);智谱=MCP 按次明细+Max/Lite/Pro 徽章;MiniMax=多模型细条行(video 专项)+积分;MiMo=¥余额 hero+runway、套餐 mini-ring+次数口径+周期预测+自动续期/本机 CLI 账本行;DeepSeek=¥hero+近7日条图+余额 runway;Ollama=月度 credits+模型 Top3+4 周按量消费(无重置时间→用速率外推不用"重置时");阿里云 tab v1.0.66 补上统一 header(此前没有)+月度窗口预测+Pro 徽章。
- ⚠️ 预测是线性外推粗估,文案一律"约/预计";`@ViewBuilder` 计算属性不能带参数(会报 must have Optional type),细节视图用 `具体类型?` 计算属性 + `if let`。

### 多账户/多 workspace 统筹(v1.0.67:智谱/Kimi 跟进阶跃;v1.0.81:OpenCode Go 按 workspace 监控)

- **阶跃(v1.0.64)**:账户 = 网页会话(每账户独立 WKWebsiteDataStore;v1.0.90 起 main 也用固定 UUID 命名仓库 `6C2E1A50-…`,不再用默认仓库——默认仓库 cookie 落盘文件会整文件丢失,之后登录态只活在僵尸 WebKit 进程内存里,进程一死全丢,已实测复现;命名仓库 cookie 稳定落盘)。
- **智谱(v1.0.67)**:账户 = 独立 API Key(凭证文件按 id 分槽:`zhipu-api-key` 主槽,其余 `zhipu-api-key-<id>`,v1.0.82 前在 Keychain);`zhipuKey(accountID:)` 取 key(main 享 opencode 自动发现兜底);聚合口径(`ZhipuQuota.aggregate`):5h/周窗口**取 max**(最险账户),MCP 按次**求和**+details 按 modelCode 归并。
- **Kimi(v1.0.67)**:账户 = 独立 www.kimi.com 网页登录(`KimiUsageService.loadWebToken/saveWebToken/clearWebToken/fetchQuota` 均带 `accountID` 参数,默认 "main" 走旧路径:本机 KimiCodeBar/Kimi CLI 凭证 + legacy web 槽;JWT 存凭证文件);聚合口径(`KimiQuota.aggregate`):计数窗口**求和**、订阅池比率**取 max**、加油包金额**求和**、到期取最早。
- **OpenCode Go(v1.0.81)**:⚠️ **一个 opencode.ai 账户下有多个 workspace,每个 workspace 是独立订阅/独立配额**(用户 2026-10-17 澄清)——不是多账户。登录 cookie 全账户共享一份(`opencode-auth-cookie` 单槽;登录窗打包 WKWebView 该域全部 cookie,实测会话 cookie 名是 `__Host-console_session`,不假设名字);受监控 workspace 列表 `OpenCodeWorkspace{id,label}` 落 UserDefaults `openCodeWorkspaces`(id=wrk_xxx/org_xxx)。workspace 发现:`OpenCodeUsageService.listWorkspaces(cookie:)` → `GET /console/api/user/workspaces`(逆自 console SPA bundle;响应 `[{id,name,...}]`,宽容解析 Verify 覆盖),登录/「发现工作区」时并入(保留用户重命名,label 默认取 workspace 名);端点失效→卡片内手动填 wrk_xxx。配额:`GET /console/api/go/status` + `x-org-id`(同一 cookie),`parseGoStatus(data:now:)` 纯函数解析 meters(Verify 覆盖)。聚合口径(`OpenCodeQuota.aggregate`):三窗口都是独立订阅池百分比,**取 max**;迁移:旧单 cookie+旧 `openCodeWorkspaceID` 键 → 首个 workspace(列表键存在=已迁移,防复活)。
- **账户可区分(v1.0.68)**:`zhipuAccountHint(id)`=Key 尾 4 位;`kimiAccountHint(id)`=登录态 JWT 的用户标识尾 6 位(`KimiUsageService.jwtSubject/accountSubject`,本地 base64 解 payload 的 sub/user_id/abstract_user_id,纯函数 Verify 覆盖)。OpenCode workspace 的 label 默认即 workspace 名(列表端点返回),天然可区分。单账户时提示进副标题(太长会被截断,Kimi 单账户省去"三窗口共用"),多账户时进每账户细条行(`ATBThinMeterRow.hint`);账户可**重命名**(面板右键菜单 / 设置页按钮,`rename<Provider>Account`)。
- **共同口径**:`<provider>Accounts`(UserDefaults JSON,键存在=已迁移,防止移除全部后被凭据复活)、`<provider>AccountQuotas`/`AccountErrors`、`add/remove<Provider>Account`;menu bar/历史/告警继续用**聚合值**(单账户时聚合=原值,零行为变化),告警多账户时走 `窗口·<账户标签>` 独立流;每日摘要附每账户行。⚠️ 移除 main 后不删 main 槽位(Kimi 的 coding 凭证文件也不删),刷新时**不补 main**(否则复活),卡片显示"登录/添加"引导。
- UI:智谱卡内联添加 Key 表单(面板直接加,不用去设置);Kimi 添加账户=窗内登录新账户(KimiLoginView 按 accountID 存 JWT 并登记);OpenCode 添加 workspace=「发现工作区」自动并入或手动填 wrk_xxx。

### 灵动岛汇总语义(v1.0.104:胶囊 = 健康度计数,展开卡 = 剩余口径)

- **收起态胶囊 = 全源健康度计数**(不再是最初的单列聚焦):判定在 Core 纯函数 —— `MenuBarTable.state(_:config:moneyFloor:)`(需处理 > 告急 > 预警 > 正常,两窗口取最严重)、`islandHealth`(计数)、`islandHealthText`(文案:单类带量词「2 项告急」,多类去量词「1 需处理 · 1 告急」,第三类省略为「+n」)。
- **阈值不新增**:剩余 ≤20% 预警、≤10% 告急(= 已用 80/90 的镜像,沿用 `thresholdConfig`)。**余额**低于 `moneyFloor`(UserDefaults `moneyFloor`,默认 ¥50,0=关闭)→ 告急;判定对象只有**余额行**(`balanceValue`/`mimoBalanceValue` 携带原始值),DeepSeek「今日花费」用 `moneyValue`(amount 恒 nil)不参与。
- **「需处理」只算鉴权类失败**(未登录/过期/凭据无效):`AuthIssueClass` 纯函数 + 8 个 provider 刷新路径的 `noteAuthIssue(kind, _)` 登记(`authIssueProviders`),阿里云按 `authState` 推导。网络/解析类失败保留旧数据**不登记**,否则网络一抖胶囊常年报「需处理」。
- **展开卡**:行文案剩余口径(`islandRowText` →「5小时 剩 90% · 周 剩 20%」)+ 头部「口径:剩余」;排序 `islandRows` = 状态优先 → 同级**已用降序**(剩余少的最上;纯金额列同档末尾)→ 固定列序。面板卡片与其余 scheme 一律保持已用%。
- ⚠️ **覆盖面板事件三坑**(踩过,别再踩):① 卡顶若与胶囊顶对齐会盖住胶囊,而悬停即展开 → 「点胶囊开面板」动线被吃掉,卡必须**从胶囊下沿向下生长**;② 系统按**窗口帧**挑事件接收者,`NSView.hitTest` 返回 nil **不会**把点击转交下层状态项 → 必须用 `ignoresMouseEvents` 随指针位置翻转(`checkMouse` 轮询里做),卡内才吃事件;③ `NSApp.delegate as? AppDelegate` **恒为 nil**(SwiftUI `NSApplicationDelegateAdaptor` 会包一层代理)→ 岛行跳转的 sink 由 AppDelegate 自己注入,别处不要强转。
- 行点击 → `PanelRouter.shared.pendingTab` → 面板 `consumePendingTab()` 落该源 tab;弹 popover 要**延后一拍** `DispatchQueue.main.async`,否则触发跳转的那次点击会被 transient 弹层当成「点外面」立刻关掉。
- 已知独立问题(非本特性引入):app 被**激活**时(如 `open .app`、安装脚本重启)SwiftUI 的 `Settings { EmptyView() }` scene 会自动弹一个空白设置窗(标题「CodingTokenBar设置」);`open -g` 不激活则不弹。实际设置窗是自绘 NSPanel(`SettingsWindowManager`),两者并存。

### 数据契约(⚠️ 重要)

`BlUsageService.swift` 的 JSON 解析与 `Verify/main.swift` 的 fixture 字符串**必须保持同步**:

- `parseUsage()` ↔ `usageFixture`(旧 5h+周 形状回归)+ `usageMonthlyFixture`(2026-09 起月度形状,实测仅 per1Month*)
- `parseSubscription()` ↔ `subscriptionFixture`
- `parseAddon()` ↔ `addonFixture`
- `classifyError()` ↔ `expiredFixture`
- `DeepSeekUsageService.parseBalance()` ↔ `dsFixture`(官方 /user/balance 样例)
- `DeepSeekDailyLedger` 纯函数 ↔ `ds ledger` 系列断言(余额差快照法)
- `DeepSeekMoneyFormat`/`MiMoMoneyFormat` ↔ `ds money` 系列断言(compact ≤7 字符;compactDigits 无符号 ≤5 字符,菜单栏金额列专用)
- `MiMoUsageService.parseBalance/parsePlanDetail/parsePlanUsage/normalizedCookie/classifyHTTP/classifyEnvelope/envelopeError/combine/authRetryCooldownSeconds` ↔ `mimo` 系列断言(platform.xiaomimimo.com 控制台私有 API)
  ⚠️ `Set-Cookie` 两条真机陷阱:① `URLSession.allHeaderFields` 把重复 `Set-Cookie` 折叠成逗号分隔单值(而 `Expires` 自身含逗号)→ 必须用 `HTTPCookie.cookies(withResponseHeaderFields:for:)` 解析;② `HTTPCookie.value` **保留外层引号**,`token=""` 不是空串 → 必须 `unquote` 后按空值剔除,否则平台的"清除"cookie 会被当成续期成功。会话过期有**两种**表达:HTTP 401(带 `loginUrl`)与 HTTP 200 + `{"code":401}`;后者由 `envelopeError` 归类,漏接会把"该重登"误报成"响应格式变化"。`combine` 决定三端点归并语义:balance 失败优先,plan 端点的**鉴权类**失败必须整体暴露,网络/解析类仍静默降级
- `MiMoCookieJar`(两域 Cookie jar:`platformHeader` + `accountHeader`)与 `MiMoSessionRenewal.renew/loginURL/isPlatformDomain/isAccountDomain` + `MiMoResponseCookie.parseHeaderFields` + `MiMoCookieJar.unquote/merging` ↔ `mimo jar`/`mimo 续期` 系列断言;续期链路用可注入 `MiMoTransport` 离线驱动(`Sources/Verify/MiMoTransportScript.swift`),真机由 `MIMO_E2E=1` 门控集成断言覆盖
- `OpenCodeUsageService.parseGoStatus(data:now:)`/`parseWorkspaceList(data:)` + `OpenCodeQuota.aggregate` ↔ `opencode` 系列断言(console API:`access.meters.{fiveHour,week,month}` 的 limitMicroCents/usedMicroCents/resetsAt;⚠️ 均为**字符串型数字**,百分比=used/limit×100 取整;resetsAt 缺省/null→0)
- `AppFileCredentialStore`(读写/删除/重开持久化/空值不落项/0600/路径解析)↔ `file store` 系列断言;凭据文件位于 `.app/Contents/Resources/atb-credentials.json`(更新保留见 install-update.sh)
- `MiMoLocalLedger.parseRows/aggregate/querySQL/todayTokens/totalTokens`(本机 CLI 用量账本) + `MiMoLocalUsageCollector.candidateDBPaths/collect` + `MiMoLastUsageStore` ↔ `mimo local`/`mimo last` 系列断言;⚠️ 本地账本统计的是**原始 tokens**、且只覆盖本机 CLI(读 `~/.local/share/{mimocode,opencode}/*.db` 的 `$.tokens.*`,只读打开),而控制台是 **Credits** 且覆盖全部客户端(实测差约 2000 倍)→ **两者不可互相界定**,它只是"本机 CLI 活动量/趋势",不得称作上下界、不得冒充控制台百分比
- `MiniMaxUsageService.parseQuota/envelopeError/epochMs/resetTimeMs` ↔ `minimax` 系列断言(token_plan/remains;⚠️ `*_usage_count` 实际是剩余次数,`*_remaining_percent` 是剩余百分比)
- `OllamaUsageService.parseQuota/classifyHTTP` ↔ `ollama` 系列断言(ollama.com/api/usage 私有端点;⚠️ `limits.*.usage` 是 **0-1 小数**不是美元,`OllamaPlan.normalizedPct` 兜 >1 的口径漂移;窗口子集可变:新计费 only monthly / 旧计费 session+weekly)
- `OllamaPlan.monthlyCapUSD/normalizedPct` ↔ `ollama 档位额度表`/`ollama 越界→…` 断言
- `StepFunUsageService.parseQuota/normalizedToken/classifyEnvelope/classifyHTTP/epochMs/leftRateToUsedPct/bucketUsedPct/authRetryCooldownSeconds` ↔ `stepfun` 系列断言(platform.stepfun.com 控制台私有 RPC `QueryStepPlanRateLimit`)。⚠️ 三坑:① 所有 `*_rate` 字段是**剩余**(left)百分比,0-1 小数或 0-100 均可能,解析层统一反推为已用;② 响应三种形状依次兜底(credit_buckets 计数 → 纯 rate → 旧 5h/周),snake/camel 双键名;③ 时间戳秒/毫秒双形态(>20e9=毫秒)。加油包桶判定:type 含 TOPUP 或 =="2";多包聚合(求和+最早到期)
- `MenuBarTable.columns(disabled:)` ↔ `mt` 系列断言(列过滤/横杠/顺序/tooltip/字符宽度契约/停用集过滤/单值列变形)
- `ProviderKind` registry 元数据(tab 顺序/列映射/恒在项)+ `ProviderVisibilityMigration.initialDisabledSet` ↔ `registry`/`迁移` 系列断言

**修改以上服务的 JSON 键名/结构或金额格式契约时,必须同步更新 `Verify/main.swift` 中对应 fixture/断言,然后运行 `swift run Verify` 确认通过。**

## 副作用边界

修改以下模块时需注意向后兼容,避免数据丢失或权限问题:

| 通道 | 模块 | 说明 |
|------|------|------|
| 凭据存储 | `CredentialStore.swift` | **v1.0.82 起全部登录态持久化在 `.app/Contents/Resources/atb-credentials.json`**(用户要求"应用文件中",明文 JSON、0600、可文本编辑维护;`AppFileCredentialStore` 实现同一 `CredentialStore` 协议,调用点零改动;首次启动从 Keychain 一次性迁入——`migratedFromKeychain` 标记后不再回读,防移除复活;Keychain 旧值保留作回滚备份)。account 名不变:OpenCode auth cookie(`opencode-auth-cookie`,一个账户一份、其下全部 workspace 共用)、阿里云 AK/SK(`aliyun-ak-sk`)、Kimi web JWT(`kimi-web-token` + `-<id>` 分槽)、DeepSeek(`deepseek-api-key`)、智谱(`zhipu-api-key` + `-<id>` 分槽)、MiMo(`mimo-console-cookie` 旧单键/`mimo-cookie-jar` 两域 jar)、MiniMax(`minimax-api-key`)、Ollama(`ollama-api-key`)、阶跃(`stepfun-console-token`)。**更新保留**:`packaging/install-update.sh` 替换 .app 前把凭证文件备份到 `/tmp`、装完写回新包(否则整包替换即丢登录态);开发态(swift run)回退到应用支持目录 |
| 当日费用账本 | `DeepSeekDailyLedger.swift` | 写入 `~/Library/Application Support/AliyunTokenBar/deepseek-daily.json`(v1 JSON:32 天余额快照,当日费用=基线余额−当前余额) |
| MiMo 本地兜底 | `MiMoLocalLedger.swift` | 写入 `~/Library/Application Support/AliyunTokenBar/mimo-local.json`(v1 JSON:按天 token 聚合) 与 `mimo-last.json`(v1:上次控制台成功快照)。**只读**打开 `~/.local/share/{mimocode,opencode}/*.db`,不写入他方数据库 |
| 配置持久化 | `TokenPlanModel.swift` | UserDefaults 键(常量收口于 `AppConstants.swift` 的 `UserDefaultsKeys`): `refreshIntervalMinutes`, `thresholdWarning`, `thresholdCritical`, `sparklineEnabled`, `notificationsEnabled`, `appTheme`, `menuBarScheme`, `openCodeWorkspaceID`(v1.0.81 前旧单 workspace;多 workspace 后仅迁移读取), `disabledProviders`(数据源停用集合,真值), `systemStatsEnabled`(兼容代理:本机开关,真值已并入 `disabledProviders`), `subscriptionExpiryWarnedDay`, `dailyDigestEnabled`, `moneyFloor`(灵动岛「余额告急下限」¥,0=关闭);多账户/多 workspace 列表键(JSON,存在=已迁移): `stepfunAccounts`, `zhipuAccounts`, `kimiAccounts`, `openCodeWorkspaces`({id,label},id=wrk_xxx/org_xxx) |
| 历史文件 | `HistoryStore.swift` | 写入 `~/Library/Application Support/AliyunTokenBar/history.json`(v1 JSONL:首行 schemaVersion 注释 + 每行一条快照;旧 JSON 数组透明读取) |
| 子进程 | `BlExecutable.swift` | 生成 `bl` CLI 子进程(需 PATH 包含 `/opt/homebrew/bin`) |
| macOS 通知 | `NotificationManager.swift` | UNUserNotificationCenter 推送用量告警 |

## 技术约束

- **阿里云无公开用量 API**:套餐用量经 `bl console call` 私有 RPC 获取。⚠️ usage RPC 窗口形态随官方规则多次调整,**解析层按「来什么字段归什么窗」**:5h 窗口 2026-08-15 起取消、周窗口 2026-09 起取消(个人版改月限额,Credits 单位,订阅日起每 30 天重置,见官方 Token Plan FAQ),现主窗口为 `per1Month*`(2026-09-23 实测响应仅含 per1MonthPercentage/per1MonthResetTime);三窗口(5h/周/月)在 `UsageWindows` 中全为可选,缺失即隐藏统计,不冒充 0%
- **OpenCode Go 无公开用量 API**:走 console JSON API(2026-10-17 重写;⚠️ 旧 SSR 路线已作废——控制台迁到 `/console` SPA + `__Host-console_session` 会话 cookie 后,vanity 路由 `/auth`、`/workspace/{id}/go` 对 console 会话一律 302 到 `/console/login`,"auth cookie 名假设"和正则抓取同时失效,均已删除)。现行:`GET /console/api/user/workspaces`(cookie)→ 账户下全部 workspace(逆自 console SPA bundle);`GET /console/api/go/status` + `x-org-id: <workspaceID>`(cookie)→ 该 workspace 的 Go 三窗口(`access.meters.{fiveHour,week,month}` 各含 `limitMicroCents`/`usedMicroCents`/`resetsAt`,百分比=used/limit×100 取整,对齐控制台整数显示)。**多 workspace(v1.0.81)**:一个账户多个 workspace(各自独立订阅,用户 2026-10-17 澄清),登录 cookie 全账户共享一份(登录窗打包 WKWebView 该域**全部** cookie,不假设会话 cookie 名);三窗口百分比跨 workspace 取 max
- **DeepSeek 官方只有余额接口**(`GET /user/balance`,Bearer API Key):当日费用无官方接口,由 `DeepSeekDailyLedger` 余额差快照法计算(0点基线;充值重设基线;应用启动晚于0点时标记"估算")
- **小米 MiMo 无公开用量 API**:走 platform.xiaomimimo.com 控制台私有 API(`/api/v1/balance` + `/tokenPlan/*`),Cookie 认证(必需 `api-platform_serviceToken` + `userId`)。⚠️ **单位是 Credits 不是 tokens**(2026-09-25 由 `/api/v1/tokenPlan/list` 确证:standard → `tokenQuotaCn="110 亿 Credits"` = 11,000,000,000,与 API `limit` 吻合;lite 41 亿/pro 380 亿/max 820 亿;控制台文案 1 token = 2 Credits)。API **字段名**是 `month_total_token`/`plan_total_token` 且响应**无单位字段**——字段命名≠单位规格,UI 一律用 `MiMoUsageService.planQuotaUnit`(Verify 有断言守着);`usedPct` 与单位无关。⚠️ 实测(2026-09-25)`token-plan-{cn,ams,sgp}.xiaomimimo.com/v1` 的 `tp-` API Key **只能聊天、查不到用量**(无 usage 端点、响应头无配额),所以 Cookie 仍是唯一用量来源;但会话可**静默续期**:401 的 `loginUrl` → `account.xiaomi.com/pass/serviceLogin`(带 `passToken`)→ 302 回平台 `/sts` → 下发新 `api-platform_serviceToken`。故 App 存**两域 jar**而非单段请求头:`MiMoLoginView` 登录后抓 `WKWebsiteDataStore` 两域 Cookie,`MiMoSessionRenewal` 负责续期重试;手工粘贴仅含 platform 段,退化为"过期需重登"(不劣化)。续期失败才降频(P0:鉴权失败 15/30/60/120 分钟封顶——**必须够保守**:实测小米 SSO 对密集重试会软拒绝,首档过短会一边被拒一边续上软拒绝窗口而自锁)
- **MiniMax Coding Plan 用量接口未公开文档**:国内 `api.minimaxi.com/v1/token_plan/remains` → 国际 `api.minimax.io` → 旧 web 端点 `www.minimaxi.com/v1/api/openplatform/coding_plan/remains` 依次尝试,Bearer coding plan key;CN 端点 `model_remains` 直接挂根(旧 web 端点包在 `data` 内,两形态都解析);`general` 条目为纯百分比窗口(total=0),`video` 等专项为日/周次数;`*_remaining_percent` 是剩余百分比且优先采用——计数口径 2026-08-18 实测为字面语义(`*_usage_count`=已用,与 2026-04 社区实现的相反口径已在解析层规避)
- **Ollama Cloud 用量接口未公开文档但维护者背书**:`GET https://ollama.com/api/usage` + `Authorization: Bearer <API Key>`(key 在 ollama.com/settings/keys 创建,不过期);维护者 `rick-github` 在 ollama/ollama#17451 公开指引该端点。⚠️ 三坑:① `limits.*.usage` 是 **0-1 小数**(onWatch 误读为美元,`OllamaPlan.normalizedPct` 对 >1 取值按套餐档位换算兜底);② 窗口子集可变(2026-09 起计费改 credits,新套餐只有 `limits.monthly`,旧套餐为 `session`+`weekly`)→ 解析层「来什么归一化什么」;③ **响应不含重置时间也不含套餐名**——套餐名走本机 daemon `POST 127.0.0.1:11434/api/me`(daemon 用 `~/.ollama/id_ed25519` Ed25519 自签,免凭据),而该 CLI 私钥**不能**用于 `/api/usage`(401),故用量必须用 API Key
- **阶跃星辰 Step Plan 用量接口未公开文档**:走 platform.stepfun.com 控制台 RPC `POST /api/step.openapi.devcenter.Dashboard/QueryStepPlanRateLimit`(响应形状对齐 codex-switcher 生产实现;2026-10-02 匿名探测实锤存活)。⚠️ **凭据是滚动轮换的网页会话,静态复制必死**(实勘:真实未过期 pair 在页面上下文内同源 fetch 同样被判 `oasis-token is embezzled`——SPA 在浏览器里持续换新 pair,复制出来的几分钟内作废;API Key 401;`~/.stepcode` OAuth token 被 `permission_denied`)。**唯一可靠通道 = 常驻 WKWebView 会话(v1.0.60+ 架构)**:`StepFunSessionController` 每账户一个持久隐藏 WebView,额度查询经 `stepfunConsoleFetchSink(accountID)` 在**页面内发同源 fetch**(Cookie 自动轮换/WAF/TLS 与浏览器等价);登录窗内嵌对应账户的 WebView,登录判定 = 页面内 RPC 成功(游客 Cookie activated:false 会被 401,窗口保持等待);⚠️ 页面内 JS 必须 completion 回调版 evaluateJavaScript + 1.5s 单次超时(async 版 SPA 导航期会挂起),且仅当页面位于 platform.stepfun.com 时发(登录流程途经 account.stepfun.com)。**多账户(v1.0.64)**:全部账户 UUID+`WKWebsiteDataStore(forIdentifier:)`(需 macOS 14+,Package.swift 已提 v14);⚠️ v1.0.90 起首账户 id="main" 也用固定 UUID 命名仓库(`StepFunSessionController.mainStoreIdentifier`)——**默认仓库的 cookie 落盘文件会整文件丢失**(2026-10-17 实勘:文件消失后登录态只存活于僵尸 WebKit 网络进程内存,app 重启能续命只因进程还活着,进程一死默认仓库 cookie 21→0 全丢;诊断法:同 bundle id 探针进程读 `WKWebsiteDataStore.default()` 的 getAllCookies/fetchDataRecords)。会话页软卡死(加载失败/SPA wedged,非鉴权失败)自愈 v1.0.90 起也触发重载(`stepfunPageStalls` 连续 ≥1 重载、≥4 明确要求重登),此前只有鉴权失败才重载会永久卡在「会话页面加载中」;账户列表 UserDefaults `stepfunAccounts` JSON;聚合口径 = 月池/加油包跨账户求和后算比例(`StepFunQuota.aggregate`,纯函数),重置取最早,纯百分比形状取 max;菜单栏显聚合月池单值列,面板多账户时=合计环+每账户紧凑行(可独立重登/移除);告警单账户=monthly 旧口径,多账户=每账户 `月池·<标签>`。其余坑:① 所有 `*_rate` 字段是**剩余**(left)百分比;② 响应三种形状依次兜底(credit_buckets 计数 → 纯 rate → 旧 5h/周),snake/camel 双键名;③ **旧 5h/周字段在月池计费下以 proto3 零值残留下发**(left_rate=0 且无重置时间 ≠ 100% 已用)——credit_buckets 存在时必须忽略;④ 时间戳秒/毫秒双形态(>20e9=毫秒);加油包桶 type 含 TOPUP 或 =="2",多包聚合。现行计费=Credit 月池(1M Credit=¥1,月末清零,**无 5h/周限制**)+加油包(30 天)。鉴权失败清遗留 token + 15/30/60/120 分钟冷却(仅当**全部**账户鉴权失败)。国内=platform.stepfun.com,海外另有 platform.stepfun.ai(未接)
- **控制台 token 几天过期**:App 检测过期后引导用户重登
- **GUI App PATH 问题**:`.app` 只继承 `/usr/bin:/bin`,bl/node 在 `/opt/homebrew/bin`;`BlExecutable` 解析绝对路径 + 补 PATH
- **本机无 Xcode,只能用 CommandLineTools SDK 构建**:默认 `MacOSX27.0.sdk` 缺 SwiftUI 宏插件(`external macro implementation type 'SwiftUIMacros.StateMacro' could not be found`),必须 `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk` 才能构建 App/Verify 目标(Core 目标不受影响)
- **macOS 26 兼容**:MenuBarExtra 在 macOS 26.5.2 可能被自动终止,NSStatusItem 可存活但图标渲染有问题(待解决)

## 打包

```bash
VERSION=1.0.14 ./packaging/build-package.sh
```

- ad-hoc 签名(`codesign -s -`,无需开发者账号)
- 产出: `dist/CodingTokenBar.app` + `dist/CodingTokenBar-<version>-mac.dmg`
- 命名约定: 显示名/包名 = CodingTokenBar;SwiftPM target 与二进制仍叫 AliyunTokenBar(`BIN_NAME` vs `APP_NAME`),bundle id `com.zww.aliyuntokenbar` 不变(保设置/钥匙串连续性)
- 分发时 macOS Gatekeeper 会拦截(用户右键打开即可)

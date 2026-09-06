# AliyunTokenBar — Agent Instructions

macOS 菜单栏 App(SwiftUI + Swift Package Manager,无 Xcode 项目文件)。
实时显示阿里云百炼 Token Plan + OpenCode Go + Kimi Code + DeepSeek API(总余额/当日费用)+ 智谱 GLM Coding Plan + 小米 MiMo(余额/套餐)+ MiniMax Coding Plan 用量 + 本机 CPU/内存/进程指标。

## 命令

```bash
swift build                              # 构建(编译检查)
swift run AliyunTokenBar                 # 运行 App
swift run Verify                         # 跑断言测试(替代 XCTest,因开发机无完整 Xcode)
VERSION=x.y.z ./packaging/build-package.sh  # 打包 .app + .dmg
./packaging/install-update.sh            # 一键更新现场:构建(默认已装版本 patch+1)→ 退出 → 替换 /Applications → 重启
```

**每次修改代码后,必须运行 `swift build` + `swift run Verify` 确认通过。**

## 架构(3 个 SPM target)

| Target | 类型 | 职责 |
|--------|------|------|
| `AliyunTokenBarCore` | library | 纯逻辑层:模型/解析/鉴权/阈值/历史/凭据(可直接测试) |
| `AliyunTokenBar` | executable | SwiftUI UI + `@main` 入口(不可直接测试) |
| `Verify` | executable | 断言测试(替代 XCTest,`check()` 函数,非 XCTest API) |

### 数据契约(⚠️ 重要)

`BlUsageService.swift` 的 JSON 解析与 `Verify/main.swift` 的 fixture 字符串**必须保持同步**:

- `parseUsage()` ↔ `usageFixture`
- `parseSubscription()` ↔ `subscriptionFixture`
- `parseAddon()` ↔ `addonFixture`
- `classifyError()` ↔ `expiredFixture`
- `DeepSeekUsageService.parseBalance()` ↔ `dsFixture`(官方 /user/balance 样例)
- `DeepSeekDailyLedger` 纯函数 ↔ `ds ledger` 系列断言(余额差快照法)
- `DeepSeekMoneyFormat` ↔ `ds money` 系列断言(紧凑格式 ≤7 字符契约)
- `MiMoUsageService.parseBalance/parsePlanDetail/parsePlanUsage/normalizedCookie/classifyHTTP/classifyEnvelope` ↔ `mimo` 系列断言(platform.xiaomimimo.com 控制台私有 API)
- `MiniMaxUsageService.parseQuota/envelopeError/epochMs/resetTimeMs` ↔ `minimax` 系列断言(token_plan/remains;⚠️ `*_usage_count` 实际是剩余次数,`*_remaining_percent` 是剩余百分比)

**修改以上服务的 JSON 键名/结构或金额格式契约时,必须同步更新 `Verify/main.swift` 中对应 fixture/断言,然后运行 `swift run Verify` 确认通过。**

## 副作用边界

修改以下模块时需注意向后兼容,避免数据丢失或权限问题:

| 通道 | 模块 | 说明 |
|------|------|------|
| 凭据存储 | `CredentialStore.swift` | Keychain 读写 OpenCode auth cookie(account: `opencode-auth-cookie`)、阿里云 AK/SK(`aliyun-ak-sk`)、Kimi web JWT(`kimi-web-token`)、DeepSeek API Key(`deepseek-api-key`)、智谱 API Key(`zhipu-api-key`)、小米 MiMo 控制台 Cookie(`mimo-console-cookie`)、MiniMax API Key(`minimax-api-key`) |
| 当日费用账本 | `DeepSeekDailyLedger.swift` | 写入 `~/Library/Application Support/AliyunTokenBar/deepseek-daily.json`(v1 JSON:32 天余额快照,当日费用=基线余额−当前余额) |
| 配置持久化 | `TokenPlanModel.swift` | UserDefaults 键(常量收口于 `AppConstants.swift` 的 `UserDefaultsKeys`): `refreshIntervalMinutes`, `thresholdWarning`, `thresholdCritical`, `sparklineEnabled`, `notificationsEnabled`, `appTheme`, `menuBarScheme`, `openCodeWorkspaceID`, `systemStatsEnabled`, `subscriptionExpiryWarnedDay`, `dailyDigestEnabled` |
| 历史文件 | `HistoryStore.swift` | 写入 `~/Library/Application Support/AliyunTokenBar/history.json`(v1 JSONL:首行 schemaVersion 注释 + 每行一条快照;旧 JSON 数组透明读取) |
| 子进程 | `BlExecutable.swift` | 生成 `bl` CLI 子进程(需 PATH 包含 `/opt/homebrew/bin`) |
| macOS 通知 | `NotificationManager.swift` | UNUserNotificationCenter 推送用量告警 |

## 技术约束

- **阿里云无公开用量 API**:套餐用量经 `bl console call` 私有 RPC 获取
- **OpenCode Go 无公开用量 API**:经 auth cookie 抓 SSR 页面正则提取
- **DeepSeek 官方只有余额接口**(`GET /user/balance`,Bearer API Key):当日费用无官方接口,由 `DeepSeekDailyLedger` 余额差快照法计算(0点基线;充值重设基线;应用启动晚于0点时标记"估算")
- **小米 MiMo 无 API Key 余额接口**:走 platform.xiaomimimo.com 控制台私有 API(`/api/v1/balance` + `/tokenPlan/*`),Cookie 认证(必需 `api-platform_serviceToken` + `userId`),用户整段粘贴 Cookie 请求头;会话过期靠 30x/401 归类提示重登
- **MiniMax Coding Plan 用量接口未公开文档**:国内 `api.minimaxi.com/v1/token_plan/remains` → 国际 `api.minimax.io` → 旧 web 端点 `www.minimaxi.com/v1/api/openplatform/coding_plan/remains` 依次尝试,Bearer coding plan key;CN 端点 `model_remains` 直接挂根(旧 web 端点包在 `data` 内,两形态都解析);`general` 条目为纯百分比窗口(total=0),`video` 等专项为日/周次数;`*_remaining_percent` 是剩余百分比且优先采用——计数口径 2026-08-18 实测为字面语义(`*_usage_count`=已用,与 2026-04 社区实现的相反口径已在解析层规避)
- **控制台 token 几天过期**:App 检测过期后引导用户重登
- **GUI App PATH 问题**:`.app` 只继承 `/usr/bin:/bin`,bl/node 在 `/opt/homebrew/bin`;`BlExecutable` 解析绝对路径 + 补 PATH
- **macOS 26 兼容**:MenuBarExtra 在 macOS 26.5.2 可能被自动终止,NSStatusItem 可存活但图标渲染有问题(待解决)

## 打包

```bash
VERSION=1.0.14 ./packaging/build-package.sh
```

- ad-hoc 签名(`codesign -s -`,无需开发者账号)
- 产出: `dist/CodingTokenBar.app` + `dist/CodingTokenBar-<version>-mac.dmg`
- 命名约定: 显示名/包名 = CodingTokenBar;SwiftPM target 与二进制仍叫 AliyunTokenBar(`BIN_NAME` vs `APP_NAME`),bundle id `com.zww.aliyuntokenbar` 不变(保设置/钥匙串连续性)
- 分发时 macOS Gatekeeper 会拦截(用户右键打开即可)

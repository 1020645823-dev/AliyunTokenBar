# AliyunTokenBar — Agent Instructions

macOS 菜单栏 App(SwiftUI + Swift Package Manager,无 Xcode 项目文件)。
实时显示阿里云百炼 Token Plan + OpenCode Go 双套餐用量。

## 命令

```bash
swift build                              # 构建(编译检查)
swift run AliyunTokenBar                 # 运行 App
swift run Verify                         # 跑断言测试(替代 XCTest,因开发机无完整 Xcode)
VERSION=x.y.z ./packaging/build-package.sh  # 打包 .app + .dmg
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

**修改 `BlUsageService.swift` 的 JSON 键名/结构时,必须同步更新 `Verify/main.swift` 中对应 fixture 的字段,然后运行 `swift run Verify` 确认通过。**

## 副作用边界

修改以下模块时需注意向后兼容,避免数据丢失或权限问题:

| 通道 | 模块 | 说明 |
|------|------|------|
| 凭据存储 | `CredentialStore.swift` | Keychain 读写 OpenCode auth cookie(account: `opencode-auth-cookie`) |
| 配置持久化 | `TokenPlanModel.swift` | UserDefaults 键: `refreshIntervalMinutes`, `thresholdWarning`, `thresholdCritical`, `sparklineEnabled`, `notificationsEnabled`, `appTheme`, `menuBarScheme`, `openCodeWorkspaceID` |
| 历史文件 | `HistoryStore.swift` | 写入 `~/.aliyun-token-bar/history.json`(用量快照时序 JSON) |
| 子进程 | `BlExecutable.swift` | 生成 `bl` CLI 子进程(需 PATH 包含 `/opt/homebrew/bin`) |
| macOS 通知 | `NotificationManager.swift` | UNUserNotificationCenter 推送用量告警 |

## 技术约束

- **阿里云无公开用量 API**:套餐用量经 `bl console call` 私有 RPC 获取
- **OpenCode Go 无公开用量 API**:经 auth cookie 抓 SSR 页面正则提取
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

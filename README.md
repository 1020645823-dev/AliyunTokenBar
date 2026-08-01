# AliyunTokenBar

macOS 菜单栏 App,实时显示**多个 AI Coding 套餐**的用量仪表盘:
**阿里云百炼 Token Plan**(5 小时 / 7 天限额)+ **OpenCode Go**(滚动 / 每周 / 每月限额)。
仿 [KimiCodeBar](https://github.com/xifandev/KimiCodeBar),并补齐了告警、趋势、安全等仪表盘能力。

![macOS](https://img.shields.io/badge/macOS-13%2B-333333?logo=apple&logoColor=white)
![Swift](https://img.shields.io/badge/Swift-5.9-F05138?logo=swift&logoColor=white)

## 它做什么

- 右上角菜单栏常驻图标,彩色区分双 Provider:阿里云橙 `☁ 5h X% · 7d Y%` + OpenCode 紫 `⚡ rolling% · weekly%`
- **阈值变色**:百分比数字 / 进度条按风险变橙(提示)/ 红(严重),扫一眼即知风险
- **接近上限通知**:跨越阈值(默认 80%/90%)时弹 macOS 原生通知(带迟滞,回落/同级不打扰)
- **用量趋势**:面板内 sparkline 趋势线 + 线性「约 X 小时后达上限」估算
- 面板:用量卡片(百分比 + 进度条 + 倒计时 + 趋势)、套餐状态、bl 版本检查、OpenCode 三窗口
- 一键登录:阿里云(bl 浏览器授权)+ OpenCode(WKWebView 内嵌登录,自动抓 cookie)
- 自动刷新(5/10/30/60 分钟可配,辅助数据 24h 低频拉取降开销)+ 手动刷新
- 开机自启、主题(跟随系统/浅色/深色)、菜单栏图标 4 种样式
- OpenCode 凭据存 **Keychain**(非明文)

> 更新方式:**手动**(下载新 dmg 覆盖)。Sparkle 自动更新已于 v1.0.8 移除。

## 前置要求

1. **百炼 CLI (`bl`) 已安装**:`npm install -g bailian-cli`(Node.js 18+)
2. **控制台已登录**:`bl auth login --console --console-site domestic`(浏览器扫码)
   - ⚠️ 控制台 token **几天会过期**,过期时面板会提示重新登录
3. **OpenCode Go**(可选):设置 → OpenCode Go →「登录 OpenCode」,在弹出窗口完成 GitHub/Google 授权

> App 不直接调阿里云 API,而是通过 `bl console call` 拿套餐用量数据(阿里云无公开用量 API)。
> OpenCode 同样无公开用量 API,经 auth cookie 抓取 SSR 页面正则提取(详见代码 `OpenCodeUsageService`)。

## 开发

```bash
swift build                  # 构建
swift run AliyunTokenBar     # 运行
swift run Verify             # 跑逻辑层断言测试(本机无完整 Xcode,用此替代 XCTest)
```

### 结构(3 个 SPM target)

```
Sources/
├── AliyunTokenBarCore/   # library:模型/解析/鉴权/状态/阈值逻辑/历史存储/凭据存储(逻辑层,纯可测)
│   ├── Models.swift               # 用量/套餐/OpenCode 数据模型
│   ├── BlUsageService.swift       # bl console call 数据层(三层嵌套 JSON 解析)
│   ├── BlAuthManager.swift        # bl 鉴权态检测 + 版本检查 + 一键更新
│   ├── BlExecutable.swift         # bl 路径解析 + GUI 友好 PATH 补全
│   ├── OpenCodeUsageService.swift # OpenCode cookie + SSR 正则提取
│   ├── TokenPlanModel.swift       # 全局状态单例:刷新/通知评估/历史/凭据
│   ├── ThresholdLogic.swift       # UsageBand 阈值 + NotificationTracker 状态机(P0)
│   ├── HistoryStore.swift         # 用量快照 JSON 时序持久化 + sparkline/预测(P1)
│   └── CredentialStore.swift      # Keychain 凭据存储 + UserDefaults 迁移(P2)
├── AliyunTokenBar/       # executable:@main SwiftUI App + UI
│   ├── App.swift                  # MenuBarExtra + 菜单栏图标渲染(阈值变色)
│   ├── Menu.swift                 # 面板:用量卡/套餐/bl版本/OpenCode 卡
│   ├── Settings.swift             # 设置:外观/刷新/告警阈值/趋势/OpenCode/自启
│   ├── NotificationManager.swift  # UNUserNotificationCenter 通知桥(P0)
│   ├── Sparkline.swift            # SwiftUI Charts 趋势线 + 耗尽预测(P1)
│   └── OpenCodeLoginView.swift    # WKWebView 内嵌登录
└── Verify/               # executable:纯 Swift 断言(替代 XCTest)
packaging/               # build-package.sh / dev-prepare.sh / Info.plist / entitlements
```

## 打包成 .app + .dmg

```bash
./packaging/build-package.sh
# 产出:dist/AliyunTokenBar.app 和 dist/AliyunTokenBar-<version>-mac.dmg
```

ad-hoc 签名(`codesign -s -`,无需开发者账号)。本机能直接跑;分发给别人时 macOS Gatekeeper
会拦(用户右键打开即可)。无 Sparkle,不依赖 EdDSA / 公证。

## 技术约束(已实测)

- 阿里云无公开用量 API;套餐用量经控制台私有 RPC 拿(`bl console call` 打 3 个 `zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/*` 接口)
- OpenCode Go 无公开用量 API;经 `auth` cookie 抓 SSR 页面正则提取(社区逆向方案)
- 控制台 token 几天过期,App 检测过期后引导重登
- 控制台 token **不能**用 Token Plan 的 `sk-sp-` API Key 代替(实测查不了用量)
- 数据契约见 `Sources/AliyunTokenBarCore/BlUsageService.swift`,变更需同步 `Sources/Verify/main.swift` 的 fixture

## 许可

MIT

# CodingTokenBar(原名 AliyunTokenBar)

macOS 菜单栏 App,实时显示**多家 AI Coding 套餐**的用量仪表盘:
**阿里云百炼 Token Plan**(5 小时 / 7 天限额 + 套餐/加购包)+ **OpenCode Go**(滚动 / 每周 / 每月)+ **Kimi Code**(5 小时 / 每周 / 月度 + 共享订阅池 + 加油包)+ **本机指标**(CPU/内存/进程 Top10)。
仿 [KimiCodeBar](https://github.com/xifandev/KimiCodeBar),并补齐告警、趋势、自愈、历史分析等仪表盘能力。

![macOS](https://img.shields.io/badge/macOS-13%2B-333333?logo=apple&logoColor=white)
![Swift](https://img.shields.io/badge/Swift-5.9-F05138?logo=swift&logoColor=white)

## 它做什么

- **菜单栏常驻**:5 种样式(云朵百分比 / 迷你表格 / 单行 / 进度环 / 本机指标),阈值变色(橙=提示、红=严重),悬停 tooltip
- **接近上限通知**:跨越阈值(默认 80%/90%)弹 macOS 原生通知(迟滞防抖动,首刷静默防风暴);每日 20:00 用量摘要(可开关);套餐到期(≤7 天)提醒
- **用量趋势与预测**:面板 sparkline + 每窗口「约 X 小时后达上限」估算;**历史页**提供多窗口趋势、近 7 天每日峰值汇总、CSV 导出
- **鉴权自愈**:阿里云 AK/SK 自动续期(ACS3 签名交换短期 token,失败冷却 + 防骚扰回退);控制台过期一键浏览器重登 + 自动完成;OpenCode workspace 自动发现(可手动填写);Kimi token 自动刷新并回写
- **系统级自动化**:睡眠唤醒/网络恢复即时刷新、用量重置边界精确调度、失败指数退避、低电量降频、开机自启、状态项不可见自动回退
- **本机进程管理**:CPU/内存 Top 10 + 两步确认 kill(root 进程禁能)
- **自动更新检查**:GitHub Releases 比对提示 + 一键跳转下载;bl CLI 版本检测与一键更新
- 主题(跟随系统/浅色/深色)、OpenCode 凭据存 **Keychain**、单实例保护、结构化日志(OSLog)

## 前置要求

1. **百炼 CLI (`bl`) 已安装**:`npm install -g bailian-cli`(Node.js 18+)
2. **控制台已登录**:`bl auth login --console --console-site domestic`(浏览器扫码),或在设置中配置 OpenAPI AK/SK(推荐,自动续期)
   - ⚠️ 控制台 token **几天会过期**,过期时 App 自动恢复(AK/SK)或引导重登
3. **OpenCode Go**(可选):设置 → 服务 →「登录 OpenCode」
4. **Kimi Code**(可选):本机已登录 KimiCodeBar / Kimi CLI 自动接入;网页控制台登录可解锁月度总额度

> 阿里云/OpenCode 无公开用量 API:分别经 `bl console call` 私有 RPC 与 auth cookie + SSR 正则提取(社区逆向方案)。

## 开发

```bash
swift build                  # 构建
swift run AliyunTokenBar     # 运行
swift run Verify             # 逻辑层断言(开发机无完整 Xcode,替代 XCTest)
swift test                   # CI 专用(macos-14/15 完整 Xcode 环境)
```

### 结构

```
Sources/
├── AliyunTokenBarCore/   # 纯逻辑层:模型/解析(Codable)/鉴权/阈值/历史(JSONL)/凭据/进程执行/自愈调度
│   ├── BlUsageService.swift       # bl console call + 四层嵌套 Codable 解析
│   ├── KimiUsageService.swift     # Kimi coding/web 双通道 + Codable 解析
│   ├── OpenCodeUsageService.swift # SSR 正则提取(键序无关加固)
│   ├── TokenPlanModel.swift       # 全局状态:刷新调度/通知评估/自愈/摘要
│   ├── ProcessRunner.swift        # 子进程统一执行(30s 超时 + SIGKILL)
│   ├── SelfUpdater.swift          # GitHub Releases 检查更新
│   ├── HistoryStore.swift         # JSONL 历史 + 预测 + CSV
│   ├── ThresholdLogic.swift       # 阈值分段 + 通知迟滞状态机
│   ├── AppLogger.swift            # OSLog 结构化日志
│   └── AppConstants.swift         # UserDefaults/Keychain 常量收口
├── AliyunTokenBar/       # SwiftUI UI(面板按职责拆 6 文件 + 设置/登录/渲染)
└── Verify/               # 断言测试;Tests/ 为 CI XCTest 双轨
packaging/                # build-package.sh / Info.plist / entitlements / 图标
```

## 打包成 .app + .dmg

```bash
VERSION=1.0.28 ./packaging/build-package.sh
# 产出:dist/CodingTokenBar.app 和 dist/CodingTokenBar-<version>-mac.dmg
```

ad-hoc 签名(无需开发者账号)。分发时 macOS Gatekeeper 会拦截(用户右键打开即可)。
CI(tag 推送)自动打包上传 artifact。

## 技术约束(已实测)

- 阿里云无公开用量 API;套餐用量经控制台私有 RPC(`bl console call` 打 3 个 `zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/*` 接口)
- OpenCode Go 无公开用量 API;经 `auth` cookie 抓 SSR 页面正则提取(社区逆向方案)
- 控制台 token 几天过期;不能只用 Token Plan 的 `sk-sp-` API Key 代替(实测查不了用量);AK/SK OpenAPI 凭据可自动续期
- 数据契约见 `Sources/AliyunTokenBarCore/BlUsageService.swift`,变更需同步 `Sources/Verify/main.swift` 的 fixture 并跑 `swift run Verify`

## 许可

MIT

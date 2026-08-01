# AliyunTokenBar

macOS 菜单栏 App,实时显示**阿里云百炼 Token Plan 个人订阅套餐**用量(5 小时限额 / 7 天限额百分比)。仿 [KimiCodeBar](https://github.com/xifandev/KimiCodeBar)。

![menu bar](https://img.shields.io/badge/macOS-13%2B-333333?logo=apple&logoColor=white)

## 它做什么

- 右上角菜单栏常驻图标,显示 `5h NN% / 7d NN%`(当前套餐用量)
- 点击弹出面板:5 小时/7 天限额卡片(百分比 + 进度条 + 重置倒计时)、套餐状态(Pro/生效中/剩余天数)、检查更新
- 自动刷新(默认 10 分钟,可在设置改)+ 手动刷新
- 开机自启、Sparkle 自动更新

## 前置要求

1. **百炼 CLI (`bl`) 已安装**:`npm install -g bailian-cli`(Node.js 18+)
2. **控制台已登录**:`bl auth login --console --console-site domestic`(浏览器扫码)
   - ⚠️ 控制台 token **几天会过期**,过期时面板会提示重新登录

> App 不直接调阿里云 API,而是通过 `bl console call` 拿套餐用量数据(阿里云无公开用量 API)。

## 开发

```bash
swift build              # 构建
swift run AliyunTokenBar # 运行
swift run Verify         # 跑逻辑层断言测试(本机无完整 Xcode,用此替代 XCTest)
```

### 结构(3 个 SPM target)

```
Sources/
├── AliyunTokenBarCore/   # library:模型/解析/鉴权/状态(逻辑层)
├── AliyunTokenBar/       # executable:@main SwiftUI App + UI(依赖 Core + Sparkle)
└── Verify/               # executable:纯 Swift 断言(替代 XCTest)
Vendor/Sparkle/           # 本地 Sparkle 包(预编译 xcframework,避开 github 网络问题)
packaging/                # 打包脚本 + Info.plist + entitlements + appcast 模板
```

## 打包成 .app + .dmg

```bash
./packaging/build-package.sh
# 产出:dist/AliyunTokenBar.app 和 dist/AliyunTokenBar-1.0.0-mac.dmg
```

**前置**:把 Sparkle.framework 和工具放到 `packaging/`(见下),并生成 EdDSA 密钥。

### Sparkle 依赖(首次准备)

本机 GitHub 网络受限,无法用远程 SPM 依赖,改用本地预编译:

1. 下载 [Sparkle-x.x.x.tar.xz](https://github.com/sparkle-project/Sparkle/releases)
2. 解压后:
   - `Sparkle.framework/` → `packaging/Frameworks/Sparkle.framework`(嵌入 .app)
   - 从中提取 `Sparkle.xcframework` → 打 zip → `Vendor/Sparkle/Sparkle.xcframework.zip`(供 `import Sparkle`)
   - `bin/generate_keys`、`bin/sign_update` → `packaging/bin/`(签名工具)
3. 首次生成 EdDSA 密钥(存 macOS Keychain):`packaging/bin/generate_keys`,记录输出的公钥

### 发布更新

1. 改版本号跑 `VERSION=1.0.1 ./packaging/build-package.sh`
2. 把产出的 `appcast-fragment-1.0.1.xml` 合并进线上 `appcast.xml`
3. 上传 dmg 到 release,app 会通过 Sparkle 自动检测更新

## 技术约束(已实测)

- 阿里云无公开用量 API;套餐用量经控制台私有 RPC 拿(`bl console call` 打 3 个 `zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/*` 接口)
- 控制台 token 几天过期,App 检测过期后引导重登
- 控制台 token **不能**用 Token Plan 的 `sk-sp-` API Key 代替(实测查不了用量)
- 数据契约见 `Sources/AliyunTokenBarCore/BlUsageService.swift`,变更需同步 `Sources/Verify/main.swift` 的 fixture

## 许可

MIT

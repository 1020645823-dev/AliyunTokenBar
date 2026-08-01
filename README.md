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
./packaging/dev-prepare.sh   # 首次/清理后:把 Sparkle.framework 拷到 swift run 的 rpath 路径
swift build                  # 构建
swift run AliyunTokenBar     # 运行
swift run Verify             # 跑逻辑层断言测试(本机无完整 Xcode,用此替代 XCTest)
```

> Sparkle.framework 必须物理存在于 `.build/.../Frameworks/`(SIP 下 DYLD 无效),
> 所以 `swift run` 前要跑 `dev-prepare.sh`。打包脚本(`build-package.sh`)会自动嵌入 framework,不依赖此步。

### 结构(3 个 SPM target)

```
Sources/
├── AliyunTokenBarCore/   # library:模型/解析/鉴权/状态(逻辑层)
├── AliyunTokenBar/       # executable:@main SwiftUI App + UI(通过 unsafeFlags 链接 Sparkle)
└── Verify/               # executable:纯 Swift 断言(替代 XCTest)
Vendor/Sparkle/Sparkle.framework   # 预编译 Sparkle.framework(供编译-F + 运行时嵌入)
packaging/               # build-package.sh / dev-prepare.sh / setup-sparkle.sh + Info.plist + entitlements + appcast 模板
```

## 打包成 .app + .dmg

```bash
./packaging/build-package.sh
# 产出:dist/AliyunTokenBar.app 和 dist/AliyunTokenBar-1.0.0-mac.dmg
```

ad-hoc 签名(`codesign -s -`,无需开发者账号)。本机能直接跑;分发给别人时 macOS Gatekeeper
会拦(用户右键打开即可)。Sparkle 用 EdDSA 签名验证更新,不依赖 Apple 公证。

### Sparkle 依赖(首次准备,已做好)

本机 GitHub 网络极慢无法走远程 SPM,改用本地预编译 Sparkle.framework + `unsafeFlags` 链接:

1. `packaging/setup-sparkle.sh <Sparkle-x.x.x.tar.xz>` —— 解压 tar,把 framework/工具就位
2. 把 framework 拷到 `Vendor/Sparkle/Sparkle.framework`(供编译 `-F` + 打包嵌入)
3. Package.swift 用 `unsafeFlags(["-F","Vendor/Sparkle"])` + `linkerSettings` `-framework Sparkle`
4. entitlements 加 `disable-library-validation`(ad-hoc 签名加载第三方框架必需)

### 发布更新(需线上 appcast + EdDSA 私钥)

1. 首次:`packaging/bin/generate_keys`(私钥存 macOS Keychain,记录公钥填 Info.plist `SUPublicEDKey`)
2. 改版本号跑 `VERSION=1.0.1 ./packaging/build-package.sh`
3. 把产出的 `dist/appcast-fragment-1.0.1.xml` 合并进线上 `appcast.xml`(`sign_update` 签 dmg)
4. 上传 dmg 到 release,app 通过 Sparkle 自动检测更新

## 技术约束(已实测)

- 阿里云无公开用量 API;套餐用量经控制台私有 RPC 拿(`bl console call` 打 3 个 `zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/*` 接口)
- 控制台 token 几天过期,App 检测过期后引导重登
- 控制台 token **不能**用 Token Plan 的 `sk-sp-` API Key 代替(实测查不了用量)
- 数据契约见 `Sources/AliyunTokenBarCore/BlUsageService.swift`,变更需同步 `Sources/Verify/main.swift` 的 fixture

## 许可

MIT

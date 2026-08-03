# 菜单栏迷你表格 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把菜单栏 compact 显示从「2×2 标签混排网格」替换为「迷你表格」(列=数据源、行=主/次指标、固定列宽、风险变色),解决凌乱/不对齐/难区分。

**Architecture:** 列过滤/横杠/tooltip 文案抽成 Core 纯函数 `MenuBarTable`(Verify 全覆盖);渲染层(App 目标)新增 `miniTableImage` 非模板渲染,基底色按 statusItem button 的 `effectiveAppearance` 手选(KVO 跟踪明暗);`isTemplate` 所有权从 AppDelegate 收归渲染器。

**Tech Stack:** Swift 5.9 / SwiftUI ImageRenderer / AppKit NSStatusItem + KVO / SwiftPM(CLT,无 XCTest,用 Verify executable 断言)。

**Spec:** `docs/superpowers/specs/2026-08-03-menubar-mini-table-design.md`

## Global Constraints

- 平台 floor:macOS 13(Package.swift);**不可用 XCTest**(本机仅 CLT),逻辑验证走 `swift run Verify`。
- **不用 MenuBarExtra**;状态项由 AppDelegate 手动管理(NSStatusItem + NSPopover),该结构不动。
- 非模板渲染**仅**作用于 compact/迷你表格;其余 4 个 scheme(cloudPercent/singleLine/iconOnly/systemStats)保持 `isTemplate = true`,代码与行为一律不动。
- 风险变色色值沿用面板现有:warning 橙 `(0.95, 0.55, 0.10)`、critical 红 `(0.92, 0.23, 0.21)`(即 App.swift 现有 `thresholdColor`)。
- `MenuBarDisplayScheme` 枚举 rawValue 与设置存储键 `menuBarScheme` 不动(老用户无感升级)。
- 列固定顺序:☁aliyun → ✨kimi → ⚡openCode → ▣system;阿里云恒显示;nil → 横杠 `—`,横杠不着色。
- 表格总高 ≤21pt(值 11pt 两行溢出则降 10.5pt);总宽 ≈175pt 以内。
- 提交信息:中文 conventional commits(参照 git log 现有风格,如 `feat(menubar): ...`)。

---

### Task 1: Core 纯模型 `MenuBarTable`(列过滤 + 横杠 + tooltip)

**Files:**
- Create: `Sources/AliyunTokenBarCore/MenuBarTable.swift`
- Test: `Sources/Verify/main.swift`(追加断言到文件尾部 print 汇总之前)

**Interfaces:**
- Produces(Task 2/3 依赖):
  - `MenuBarTableValue { text: String; pct: Int? }`(Equatable)
  - `MenuBarColumnKind: String { aliyun, kimi, openCode, system }` — `.symbolName`(SF Symbol 名)、`.displayName`、`.primaryLabel`、`.secondaryLabel`
  - `MenuBarTableColumn { kind: MenuBarColumnKind; primary: MenuBarTableValue; secondary: MenuBarTableValue }`(Equatable)
  - `MenuBarTable.columns(aliyunFiveHour:aliyunOneWeek:kimiConfigured:kimiHasError:kimiFiveHour:kimiWeekly:openCodeConfigured:openCodeHasError:openCodeRolling:openCodeWeekly:systemEnabled:cpu:memory:) -> [MenuBarTableColumn]`(全 Int?/Bool 参数)
  - `MenuBarTable.tooltip(columns:) -> String`

- [ ] **Step 1: 写失败断言**

在 `Sources/Verify/main.swift` 的结尾汇总打印(`if fails > 0 ...` 之类结尾逻辑)**之前**追加:

```swift
// --- MenuBarTable:迷你表格列模型 ---
func mtCols(
    a5: Int? = 40, a7: Int? = 18,
    kConf: Bool = true, kErr: Bool = false, k5: Int? = 0, kW: Int? = 58,
    oConf: Bool = true, oErr: Bool = false, oR: Int? = 3, oW: Int? = 2,
    sysOn: Bool = true, cpu: Int? = 12, mem: Int? = 25
) -> [MenuBarTableColumn] {
    MenuBarTable.columns(aliyunFiveHour: a5, aliyunOneWeek: a7,
        kimiConfigured: kConf, kimiHasError: kErr, kimiFiveHour: k5, kimiWeekly: kW,
        openCodeConfigured: oConf, openCodeHasError: oErr, openCodeRolling: oR, openCodeWeekly: oW,
        systemEnabled: sysOn, cpu: cpu, memory: mem)
}

let mtAll = mtCols()
check("mt 4列全显示且固定顺序", mtAll.map(\.kind) == [.aliyun, .kimi, .openCode, .system])
check("mt 阿里云主次值", mtAll[0].primary.text == "40%" && mtAll[0].secondary.text == "18%")
check("mt 0% 不省略", mtAll[1].primary.text == "0%" && mtAll[1].primary.pct == 0)
check("mt 未配置Kimi→隐藏", mtCols(kConf: false).map(\.kind) == [.aliyun, .openCode, .system])
check("mt 未配置OpenCode→隐藏", mtCols(oConf: false).map(\.kind) == [.aliyun, .kimi, .system])
check("mt 本机关闭→隐藏", mtCols(sysOn: false).map(\.kind) == [.aliyun, .kimi, .openCode])
let mtErr = mtCols(k5: nil, kW: nil, kErr: true)
check("mt 已配置+出错→横杠列", mtErr.map(\.kind).contains(.kimi)
      && mtErr[1].primary.text == "—" && mtErr[1].primary.pct == nil
      && mtErr[1].secondary.text == "—")
check("mt 已配置无数据无错→隐藏", !mtCols(k5: nil, kW: nil).map(\.kind).contains(.kimi))
check("mt 本机未采样→横杠", mtCols(cpu: nil, mem: nil)[3].primary.text == "—")
check("mt 阿里云恒显示(nil→横杠)", mtCols(a5: nil, a7: nil)[0].primary.text == "—")
let mtTip = MenuBarTable.tooltip(columns: mtAll)
check("mt tooltip 全文", mtTip == "阿里云 5小时 40% · 7天 18% | Kimi 5小时 0% · 周 58% | OpenCode 滚动 3% · 周 2% | 本机 CPU 12% · 内存 25%")
check("mt tooltip 横杠形态", MenuBarTable.tooltip(columns: mtErr).contains("Kimi 5小时 — · 周 —"))
```

- [ ] **Step 2: 运行确认失败**

Run: `swift run Verify`
Expected: 编译失败,`cannot find 'MenuBarTable' in scope`(TDD 的"红"在此体现为类型不存在)

- [ ] **Step 3: 实现 `Sources/AliyunTokenBarCore/MenuBarTable.swift`**

```swift
import Foundation

// MARK: - 菜单栏迷你表格(纯数据模型)
//
// 列过滤/横杠/tooltip 文案全部在此,Verify 无 UI 全覆盖;
// 渲染层(App 目标 miniTableImage)只负责把 [MenuBarTableColumn] 画出来。

/// 单个值:展示文本 + 原始百分比(pct 供阈值变色;nil = 横杠,不着色)。
public struct MenuBarTableValue: Equatable {
    public let text: String
    public let pct: Int?
    public init(text: String, pct: Int?) {
        self.text = text
        self.pct = pct
    }
}

/// 列身份:固定顺序即 CaseIterable 声明顺序 ☁→✨→⚡→▣。
public enum MenuBarColumnKind: String, CaseIterable, Equatable {
    case aliyun, kimi, openCode, system

    public var symbolName: String {
        switch self {
        case .aliyun: return "cloud.fill"
        case .kimi: return "sparkles"
        case .openCode: return "bolt.fill"
        case .system: return "desktopcomputer"
        }
    }
    public var displayName: String {
        switch self {
        case .aliyun: return "阿里云"
        case .kimi: return "Kimi"
        case .openCode: return "OpenCode"
        case .system: return "本机"
        }
    }
    /// 上行(主窗口)tooltip 标签
    public var primaryLabel: String {
        switch self {
        case .aliyun, .kimi: return "5小时"
        case .openCode: return "滚动"
        case .system: return "CPU"
        }
    }
    /// 下行(次窗口)tooltip 标签
    public var secondaryLabel: String {
        switch self {
        case .aliyun: return "7天"
        case .kimi, .openCode: return "周"
        case .system: return "内存"
        }
    }
}

public struct MenuBarTableColumn: Equatable {
    public let kind: MenuBarColumnKind
    public let primary: MenuBarTableValue    // 上行:5h/5h/滚/CPU
    public let secondary: MenuBarTableValue  // 下行:7d/周/周/内存
    public init(kind: MenuBarColumnKind, primary: MenuBarTableValue, secondary: MenuBarTableValue) {
        self.kind = kind
        self.primary = primary
        self.secondary = secondary
    }
}

public enum MenuBarTable {
    /// 值 → 展示文本:nil → 横杠(沿用菜单栏既有约定)。
    static func value(_ pct: Int?) -> MenuBarTableValue {
        MenuBarTableValue(text: pct.map { "\($0)%" } ?? "—", pct: pct)
    }

    /// 计算可见列(输出顺序恒为 ☁→✨→⚡→▣,与配置无关)。
    /// 阿里云恒显示;Kimi/OpenCode 已配置且(有数据或出错)时显示,出错→横杠;
    /// 本机开关开时显示,采样未就绪→横杠。
    public static func columns(
        aliyunFiveHour: Int?, aliyunOneWeek: Int?,
        kimiConfigured: Bool, kimiHasError: Bool, kimiFiveHour: Int?, kimiWeekly: Int?,
        openCodeConfigured: Bool, openCodeHasError: Bool, openCodeRolling: Int?, openCodeWeekly: Int?,
        systemEnabled: Bool, cpu: Int?, memory: Int?
    ) -> [MenuBarTableColumn] {
        var cols: [MenuBarTableColumn] = [
            MenuBarTableColumn(kind: .aliyun,
                               primary: value(aliyunFiveHour), secondary: value(aliyunOneWeek))
        ]
        if kimiConfigured && (kimiHasError || kimiFiveHour != nil || kimiWeekly != nil) {
            cols.append(MenuBarTableColumn(kind: .kimi,
                                           primary: value(kimiFiveHour), secondary: value(kimiWeekly)))
        }
        if openCodeConfigured && (openCodeHasError || openCodeRolling != nil || openCodeWeekly != nil) {
            cols.append(MenuBarTableColumn(kind: .openCode,
                                           primary: value(openCodeRolling), secondary: value(openCodeWeekly)))
        }
        if systemEnabled {
            cols.append(MenuBarTableColumn(kind: .system,
                                           primary: value(cpu), secondary: value(memory)))
        }
        return cols
    }

    /// 悬停 tooltip:每列「名称 主标签 值 · 次标签 值」,列间「 | 」分隔。
    public static func tooltip(columns: [MenuBarTableColumn]) -> String {
        columns.map { col in
            "\(col.kind.displayName) \(col.kind.primaryLabel) \(col.primary.text) · \(col.kind.secondaryLabel) \(col.secondary.text)"
        }.joined(separator: " | ")
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `swift run Verify`
Expected: 新增 13 条全部 `PASS mt ...`,既有断言无回归,退出码 0

- [ ] **Step 5: Commit**

```bash
git add Sources/AliyunTokenBarCore/MenuBarTable.swift Sources/Verify/main.swift
git commit -m "feat(core): MenuBarTable 迷你表格列模型+tooltip 纯函数(Verify 13 断言)"
```

---

### Task 2: Core 管线 — 模型适配器 + tooltip sink

**Files:**
- Modify: `Sources/AliyunTokenBarCore/MenuBarTable.swift`(尾部追加 extension)
- Modify: `Sources/AliyunTokenBarCore/TokenPlanModel.swift:104`(`renderIconSink` 附近)和 `:275-278`(`prerenderIcon`)

**Interfaces:**
- Consumes: Task 1 的 `MenuBarTable.columns` / `MenuBarTable.tooltip`
- Produces(Task 3/4 依赖):
  - `TokenPlanModel.menuBarColumns() -> [MenuBarTableColumn]`(模型现值 → 列,渲染与 tooltip 共用,避免两处映射漂移)
  - `TokenPlanModel.renderTooltipSink: ((TokenPlanModel) -> String?)?`
  - `TokenPlanModel.menuBarTooltip: String?`(@Published,prerenderIcon 内先于 renderedIcon 赋值)

- [ ] **Step 1: TokenPlanModel 加 sink 与发布属性**

`Sources/AliyunTokenBarCore/TokenPlanModel.swift` 第 104 行 `public var renderIconSink: ...` 之后插入:

```swift
    /// 菜单栏 tooltip 渲染闭包(App 目标注入,与 renderIconSink 同批)。
    public var renderTooltipSink: ((TokenPlanModel) -> String?)?
```

同文件 `@Published public var renderedIcon` 声明附近插入:

```swift
    /// 最近一次预渲染的菜单栏 tooltip(与 renderedIcon 同批更新)。
    @Published public var menuBarTooltip: String?
```

`prerenderIcon()`(约 276 行)改为(**先 tooltip 后 icon**:$renderedIcon 订阅方 AppDelegate 读到 icon 时 tooltip 必已就绪):

```swift
    /// 预渲染图标:数据更新后调用。若 renderIconSink 为 nil 则跳过。
    public func prerenderIcon() {
        menuBarTooltip = renderTooltipSink?(self)
        renderedIcon = renderIconSink?(self)
    }
```

- [ ] **Step 2: MenuBarTable.swift 尾部追加模型适配器**

```swift
extension TokenPlanModel {
    /// 从模型现值计算迷你表格列(菜单栏渲染与 tooltip 共用这一个映射)。
    /// 可见性语义与原 renderIconSink 内联逻辑一致:
    /// Kimi/OpenCode = 有数据,或已配置且出错(→横杠列);本机 = 开关开。
    public func menuBarColumns() -> [MenuBarTableColumn] {
        let monitor = SystemMetricsMonitor.shared
        return MenuBarTable.columns(
            aliyunFiveHour: quota?.usage.fiveHour.percentageInt,
            aliyunOneWeek: quota?.usage.oneWeek.percentageInt,
            kimiConfigured: kimiConfigured, kimiHasError: kimiError != nil,
            kimiFiveHour: kimiQuota?.fiveHour.pctInt, kimiWeekly: kimiQuota?.weekly.pctInt,
            openCodeConfigured: openCodeConfigured, openCodeHasError: openCodeError != nil,
            openCodeRolling: openCodeQuota?.rolling.pct, openCodeWeekly: openCodeQuota?.weekly.pct,
            systemEnabled: systemStatsEnabled,
            cpu: monitor.cpuPercent, memory: monitor.memoryPercent)
    }
}
```

注意:若编译器报 actor 隔离错误,按 `TokenPlanModel` 类自身的隔离标注给 extension 方法补 `@MainActor`。

- [ ] **Step 3: 构建 + 回归**

Run: `swift build && swift run Verify`
Expected: 构建成功;Verify 全部 PASS 无回归(适配器/sink 暂无 UI 消费方,只验证编译与既有断言)

- [ ] **Step 4: Commit**

```bash
git add Sources/AliyunTokenBarCore/MenuBarTable.swift Sources/AliyunTokenBarCore/TokenPlanModel.swift
git commit -m "feat(core): menuBarColumns 适配器 + renderTooltipSink/menuBarTooltip 管线"
```

---

### Task 3: 渲染器 — `miniTableImage` 替换 compact 实现

**Files:**
- Modify: `Sources/AliyunTokenBar/App.swift`(`MenuBarTextRenderer` 内:新增 miniTableImage、render 加 isTemplate 参数、image() 分发;删除旧 `compactImage` 约 :236-275;`MenuBarDisplayScheme.compact` displayName :99;App.init 的 sink :389-414;新增 `MenuBarAppearance` 类)

**Interfaces:**
- Consumes: Task 1 `MenuBarTableColumn.kind.symbolName`、`primary/secondary.text/.pct`;Task 2 `model.menuBarColumns()`、`renderTooltipSink`
- Produces(Task 4 依赖):
  - `MenuBarAppearance.shared.isDark: Bool`(@MainActor 单例,AppDelegate KVO 写入)
  - `MenuBarTextRenderer.image(..., columns: [MenuBarTableColumn]?, isDark: Bool, ...)`(compact 分支走 miniTableImage,产物 `isTemplate = false`;其他 scheme 产物仍为模板)

- [ ] **Step 1: 新增 `MenuBarAppearance`(放在 `MenuBarTextRenderer` enum 之前)**

```swift
/// 菜单栏明暗状态:AppDelegate 对 statusItem button 的 effectiveAppearance 做 KVO 写入;
/// 非模板渲染(miniTableImage)读它选基底色——深菜单栏→白,浅菜单栏→黑。
@MainActor
final class MenuBarAppearance {
    static let shared = MenuBarAppearance()
    var isDark = false
    private init() {}
}
```

- [ ] **Step 2: `render()` 加 isTemplate 参数(默认 true,其他 scheme 调用点不变)**

```swift
@MainActor
private static func render<V: View>(_ content: V, isTemplate: Bool = true) -> NSImage {
    let renderer = ImageRenderer(content: content)
    renderer.scale = NSScreen.main?.backingScaleFactor ?? 2.0
    guard let img = renderer.nsImage, img.size.width > 0, img.size.height > 0 else {
        // 渲染失败:返回固定云朵图标(确保 label 非空,避免系统自动终止)
        return NSImage(systemSymbolName: "cloud.fill", accessibilityDescription: "AliyunTokenBar") ?? NSImage(size: NSSize(width: 48, height: 20))
    }
    img.isTemplate = isTemplate   // 迷你表格传 false:保留风险变色;其余 scheme 维持模板
    return img
}
```

- [ ] **Step 3: 新增 `miniTableImage`,删除旧 `compactImage` 整个函数**

```swift
/// 默认紧凑:迷你表格——列=数据源(☁✨⚡▣,顺序固定),行=主/次指标。
/// 每列固定宽:图标位 10pt + 值域 30pt("100%" @11pt 等宽数字为最宽),值右对齐;
/// 下行缩进图标位宽度,8 个数字严格成网格。
/// 非模板渲染:基底色按菜单栏明暗手选;数字独立按阈值 band 变色
/// (safe→基底 / warning→橙 / critical→红),图标恒基底色——颜色只编码风险。
/// 横杠(pct=nil)不着色。总高 ≈21pt;若视觉验收发现溢出/挤压,先把 11pt 降 10.5pt 再调 valueWidth。
@MainActor
private static func miniTableImage(columns: [MenuBarTableColumn], isDark: Bool,
                                   thresholdConfig: ThresholdConfig) -> NSImage {
    let base: Color = isDark ? .white : .black
    let valueWidth: CGFloat = 30
    let iconWidth: CGFloat = 10
    let content = HStack(alignment: .top, spacing: 7) {
        ForEach(columns, id: \.kind) { col in
            VStack(spacing: -1) {
                HStack(spacing: 2) {
                    Image(systemName: col.kind.symbolName)
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: iconWidth, alignment: .leading)
                    Text(col.primary.text)
                        .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                        .frame(width: valueWidth, alignment: .trailing)
                        .foregroundStyle(col.primary.pct.map { thresholdColor($0, config: thresholdConfig, base: base) } ?? base)
                }
                Text(col.secondary.text)
                    .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                    .frame(width: iconWidth + 2 + valueWidth, alignment: .trailing)
                    .foregroundStyle(col.secondary.pct.map { thresholdColor($0, config: thresholdConfig, base: base) } ?? base)
            }
        }
    }
    .foregroundStyle(base)   // 图标继承;Text 各自显式覆盖
    .fixedSize(horizontal: true, vertical: true)
    return render(content, isTemplate: false)
}
```

- [ ] **Step 4: `image()` 加分发参数并改 compact 分支**

签名加两个带默认值的参数(其余参数不动):

```swift
static func image(scheme: MenuBarDisplayScheme, fiveHour: Int?, oneWeek: Int?,
                  openCodeRolling: Int? = nil, openCodeWeekly: Int? = nil,
                  kimiFiveHour: Int? = nil, kimiWeekly: Int? = nil,
                  cpu: Int? = nil, memory: Int? = nil,
                  columns: [MenuBarTableColumn]? = nil, isDark: Bool = false,
                  thresholdConfig: ThresholdConfig = ThresholdConfig()) -> NSImage {
```

compact 分支改为:

```swift
case .compact: return miniTableImage(columns: columns ?? [], isDark: isDark,
                                     thresholdConfig: thresholdConfig)
```

(删除原 `compactImage(fiveHour:...)` 调用与函数本体。)

- [ ] **Step 5: App.init 的 sink 接线(列与 tooltip 同源)**

`renderIconSink` 闭包内 return 调用加两个实参(闭包内原有 oc/kimi 的 Int?? 计算保留——其余 4 个 scheme 仍消费这些参数):

```swift
            return MenuBarTextRenderer.image(
                scheme: MenuBarStyleManager.shared.scheme,
                fiveHour: model.quota?.usage.fiveHour.percentageInt,
                oneWeek: model.quota?.usage.oneWeek.percentageInt,
                openCodeRolling: ocRolling ?? nil,
                openCodeWeekly: ocWeekly ?? nil,
                kimiFiveHour: kimiFiveHour ?? nil,
                kimiWeekly: kimiWeekly ?? nil,
                cpu: model.systemStatsEnabled ? monitor.cpuPercent : nil,
                memory: model.systemStatsEnabled ? monitor.memoryPercent : nil,
                columns: model.menuBarColumns(),
                isDark: MenuBarAppearance.shared.isDark,
                thresholdConfig: model.thresholdConfig
            )
```

`renderIconSink` 赋值之后紧接注入 tooltip sink:

```swift
        TokenPlanModel.shared.renderTooltipSink = { model in
            MenuBarTable.tooltip(columns: model.menuBarColumns())
        }
```

- [ ] **Step 6: compact 的展示名换新(纯文案,rawValue 不动)**

`MenuBarDisplayScheme.compact` 的 displayName:`"2×2 网格(默认)"` → `"迷你表格(默认)"`。

- [ ] **Step 7: 构建 + 回归**

Run: `swift build && swift run Verify`
Expected: 构建成功;Verify 全部 PASS

- [ ] **Step 8: Commit**

```bash
git add Sources/AliyunTokenBar/App.swift
git commit -m "feat(menubar): 迷你表格渲染替换 2×2 网格(非模板+风险变色+固定列宽对齐)"
```

---

### Task 4: AppDelegate — isTemplate 所有权 + 明暗 KVO + tooltip

**Files:**
- Modify: `Sources/AliyunTokenBar/AppDelegate.swift`(:14 属性区、:49-60 `setupStatusItem`、:72-82 `observeModel`)

**Interfaces:**
- Consumes: Task 3 `MenuBarAppearance.shared`;Task 2 `model.menuBarTooltip`
- Produces: 无新增接口(行为:明暗切换 → 重渲染;tooltip 随图标同批刷新)

- [ ] **Step 1: 加 KVO 属性**

类属性区(`private var visibilityMonitor ...` 之后):

```swift
    private var appearanceObservation: NSKeyValueObservation?
```

- [ ] **Step 2: `setupStatusItem()` 改造**

```swift
    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.isVisible = true
        if let button = item.button {
            button.image = TokenPlanModel.shared.renderedIcon ?? fallbackIcon()
            // 不再强制 isTemplate:渲染器已为各 scheme 设好(迷你表格=非模板,其余=模板);
            // fallbackIcon(SF Symbol)默认即模板,无需处理。
            button.target = self
            button.action = #selector(togglePopover)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = TokenPlanModel.shared.menuBarTooltip
            // 菜单栏明暗:初始读 + KVO 跟踪;变化时重渲染(迷你表格基底色依赖它)。
            MenuBarAppearance.shared.isDark =
                button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            appearanceObservation = button.observe(\.effectiveAppearance, options: [.new]) { button, _ in
                let dark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                Task { @MainActor in
                    MenuBarAppearance.shared.isDark = dark
                    TokenPlanModel.shared.prerenderIcon()
                }
            }
            // 用真实明暗值重渲染一次(首个图标可能在读到 appearance 前已按默认浅色基底渲染)
            TokenPlanModel.shared.prerenderIcon()
        }
        statusItem = item
    }
```

- [ ] **Step 3: `observeModel()` sink 改造(去掉 isTemplate 强覆写,补 tooltip)**

```swift
    /// 订阅模型:renderedIcon 更新时同步到状态项按钮(含 tooltip)。
    private func observeModel() {
        let model = TokenPlanModel.shared
        model.$renderedIcon
            .receive(on: RunLoop.main)
            .sink { [weak self] icon in
                guard let self, let button = self.statusItem?.button else { return }
                if let icon {
                    button.image = icon   // isTemplate 由渲染器决定,此处不覆写
                } else {
                    button.image = self.fallbackIcon()
                    button.image?.isTemplate = true
                }
                button.toolTip = model.menuBarTooltip
            }
            .store(in: &cancellables)
    }
```

- [ ] **Step 4: 构建 + 回归**

Run: `swift build && swift run Verify`
Expected: 构建成功;Verify 全部 PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/AliyunTokenBar/AppDelegate.swift
git commit -m "feat(menubar): 明暗 KVO 重渲染 + 悬停 tooltip + isTemplate 收归渲染器"
```

---

### Task 5: 视觉验收(截图)+ 尺寸微调 + 全量回归

**Files:**
- 可能微调: `Sources/AliyunTokenBar/App.swift`(仅 `miniTableImage` 的 11pt/valueWidth 30/spacing 7 三个常量)

**Interfaces:**
- Consumes: Task 1-4 全部产物
- Produces: 验收结论(必要时调整上述常量)

- [ ] **Step 1: 打包启动**

```bash
bash packaging/build-package.sh
killall CodingTokenBar 2>/dev/null; sleep 1
open dist/CodingTokenBar.app
sleep 8   # 等首刷数据 + 图标渲染
```

- [ ] **Step 2: 截屏验收对齐与基底色**

```bash
screencapture -x /tmp/menubar-light.png
```

Read `/tmp/menubar-light.png`(如菜单栏图标过小,先 `sips` 裁剪右上角再 Read)。核对:
1. 8 个数字上下两行严格成网格(个位对个位);
2. 四列顺序 ☁✨⚡▣,列间距均匀,无标签字符;
3. 基底色在当前菜单栏壁纸上清晰可读(非纯黑糊/纯白糊);
4. 总高未超出菜单栏(数字未被上下裁切)。

- [ ] **Step 3: 明暗切换验收(KVO)**

系统设置 → 外观,切换 深色↔浅色,各截一张(`/tmp/menubar-dark.png`)。核对:基底色 1-2 秒内自动跟随(深→白字,浅→黑字),无需重启 app。

- [ ] **Step 4: 风险变色验收(临时调阈值)**

```bash
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" packaging/Info.plist)
killall CodingTokenBar 2>/dev/null; sleep 1
defaults write "$BUNDLE_ID" thresholdWarning -int 1
defaults write "$BUNDLE_ID" thresholdCritical -int 2
open dist/CodingTokenBar.app
sleep 8
screencapture -x /tmp/menubar-critical.png
```

核对:所有数字变红(critical);再把 critical 改 99、warning 保持 1 → 全橙。验收后恢复并重启:

```bash
defaults write "$BUNDLE_ID" thresholdWarning -int 80
defaults write "$BUNDLE_ID" thresholdCritical -int 90
killall CodingTokenBar 2>/dev/null; sleep 1; open dist/CodingTokenBar.app
```

- [ ] **Step 5: 尺寸微调(仅当 Step 2 发现溢出/裁切/挤压)**

优先级:值字号 11pt → 10.5pt;再 `valueWidth` 30 → 32;再列间距 7 → 6。每改一次重回 Step 1 流程验收。**不要**同时改多个常量。

- [ ] **Step 6: 全量回归**

Run: `swift run Verify`
Expected: 全部 PASS,退出码 0

- [ ] **Step 7: Commit(仅当有微调)**

```bash
git add Sources/AliyunTokenBar/App.swift
git commit -m "fix(menubar): 迷你表格视觉验收微调(字号/值域/间距)"
```

---

## Self-Review 记录

- **Spec 覆盖**:迷你表格布局→T3;列顺序/隐藏/横杠→T1;tooltip→T1+T2+T4;非模板双套渲染+KVO→T3+T4;风险变色→T3+T5-Step4;替换 compact 其余不动→T3;Verify 断言→T1+T5-Step6;截图人工验收→T5;总高 ≤21pt→T5-Step5。无缺口。
- **占位符**:无 TBD/TODO;所有代码步骤含完整代码。
- **类型一致性**:`MenuBarTable.columns` 参数名(T1)与 `menuBarColumns()` 调用(T2)一致;`MenuBarAppearance.shared.isDark`(T3 定义,T3/T4 使用)一致;`renderTooltipSink`/`menuBarTooltip`(T2 定义,T3/T4 使用)一致;`miniTableImage(columns:isDark:thresholdConfig:)`(T3 定义与调用)一致。

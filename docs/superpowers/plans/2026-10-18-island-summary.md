# 灵动岛汇总形态 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把灵动岛收起态从「单列聚焦(主值)」换成「全源健康度计数(需处理/告急/预警)」,展开卡换成剩余口径 + 紧迫度排序,并支持点击某一行直接跳到面板对应 tab;其他菜单栏 scheme 与面板卡片行为零改动。

**Architecture:** 判定与文案全部下沉到 Core 纯函数(`MenuBarTable`:状态、剩余换算、计数、文案、排序),Verify 全覆盖;模型层新增两个输入:`moneyFloor`(设置项,余额下限)与 `authIssueProviders`(各 provider 刷新路径登记的鉴权类失败);App 层只做渲染与交互(胶囊文案、展开卡行、`hitTest` 白名单让展开卡可点而胶囊区域保持透传),跳转经极小的 `PanelRouter` 传到面板 tab。

**Tech Stack:** Swift 5.9 / SwiftPM(本机仅 CLT,无 XCTest → `swift run Verify`)/ SwiftUI + AppKit(NSStatusItem + 覆盖用 NSPanel + NSHostingView 子类)。

**Spec:** `docs/superpowers/specs/2026-10-18-island-summary-design.md`

**实测依据(为什么改):** 旧胶囊印主行值、而聚焦列的选取依据是两个窗口的最高值 —— 本机 `history.json` 1000 条快照中 **81%** 存在「胶囊主值 ≠ 判据值」,典型为胶囊显示「K 0%」而 Kimi 被选中是因周窗口已用 78%。

## Global Constraints

- **测试只走 Verify**:`swift run Verify` 期望末行 `ALL PASS`(失败时打印 `N FAILED` 并 exit 1)。本机无完整 Xcode,XCTest 不可用。
- **App 目标构建必须指定 SDK**:`SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk`(默认 MacOSX27.0.sdk 缺 SwiftUI 宏插件,App/打包构建会失败;Core 目标不受影响 → 易误判「构建通过」)。
- **交付必须实机安装**:`bash packaging/install-update.sh`(自动 patch 版本 +1;用户验收看的是 `/Applications/CodingTokenBar.app`)。
- **岛专属**:面板卡片、tooltip、其余 5 个 scheme(`cloudPercent`/`compact`/`singleLine`/`iconOnly`/`systemStats`)的行为、文案、渲染一律不动。
- **不动 `MenuBarDisplayScheme` 枚举与 `menuBarScheme` 存储键**,老用户无感升级。
- 提交信息用中文 conventional commits(与 git log 现有风格一致,如 `feat(island): ...`)。
- 需要清理运行实例时用 `pgrep -x AliyunTokenBar` 精确匹配,**不要**宽 `pkill`(会波及用户正在用的 app)。

**新 Core API(接口总览,后面任务按此实现,不得改名):**

```swift
public struct MenuBarTableValue { let text: String; let pct: Int?; let amount: Double? }
public struct MenuBarTableColumn { …; var needsAttention: Bool }
public enum ColumnState: Int, Comparable { case ok, warning, critical, needsAction }
public struct IslandHealth: Equatable { let needAction: Int; let critical: Int; let warning: Int
                                        var total: Int; var worst: ColumnState }

MenuBarTable.state(_:config:moneyFloor:) -> ColumnState
MenuBarTable.remainingText(_:) -> String                      // "剩 22%" / "—" / "12.3万"
MenuBarTable.islandRowText(_:) -> String                      // "5小时 剩 100% · 周 剩 22%"
MenuBarTable.islandHealth(columns:config:moneyFloor:) -> IslandHealth
MenuBarTable.islandHealthText(_:) -> String                   // "1 需处理 · 1 告急"
MenuBarTable.islandRows(columns:config:moneyFloor:) -> [MenuBarTableColumn]
MenuBarTable.columns(…, moneyFloor: Double = 0, needsAttention: Set<String> = [])
```

`IslandStateColor.color(_:) -> Color`(App 目标,岛与胶囊共用的状态色)

---

### Task 1: Core 健康度状态与汇总纯函数

**Files:**
- Modify: `Sources/AliyunTokenBarCore/MenuBarTable.swift`(值/列模型 + 新纯函数)
- Test: `Sources/Verify/main.swift`(追加断言到 `print(fails == 0 …)` 之前)

**Interfaces:**
- Produces(后续所有任务依赖):`MenuBarTableValue.amount`、`MenuBarTableColumn.needsAttention`、`ColumnState`、`IslandHealth`、`state`、`remainingText`、`islandRowText`、`islandHealth`、`islandHealthText`、`islandRows`。
- 保留不动:`band`、`tooltip`、`islandFocus`(岛不再调用,函数与旧断言留着)、`columns`(Task 2 才改)。

- [ ] **Step 1: 写失败断言(先写测试)**

在 `Sources/Verify/main.swift` 现有的 `check("island 列band取主/次高者", …)` 那一段之后、`print(fails == 0 …)` 之前插入:

```swift
// --- 灵动岛汇总:状态 / 剩余 / 计数 / 排序 ---
func islCol(_ kind: MenuBarColumnKind, _ p: Int?, _ s: Int?,
            attention: Bool = false, amount: Double? = nil) -> MenuBarTableColumn {
    var col = MenuBarTableColumn(kind: kind,
                                 primary: MenuBarTableValue(text: p.map { "\($0)%" } ?? "—", pct: p),
                                 secondary: MenuBarTableValue(text: s.map { "\($0)%" } ?? "—", pct: s,
                                                              amount: amount))
    col.needsAttention = attention
    return col
}
check("island state:已用90→告急", MenuBarTable.state(islCol(.kimi, 90, nil), config: islCfg, moneyFloor: 0) == .critical)
check("island state:已用80→预警", MenuBarTable.state(islCol(.kimi, 80, nil), config: islCfg, moneyFloor: 0) == .warning)
check("island state:已用79→正常", MenuBarTable.state(islCol(.kimi, 79, nil), config: islCfg, moneyFloor: 0) == .ok)
check("island state:两窗口取最严重(次窗更紧)", MenuBarTable.state(islCol(.kimi, 0, 88), config: islCfg, moneyFloor: 0) == .warning)
check("island state:次窗触顶→告急", MenuBarTable.state(islCol(.kimi, 0, 95), config: islCfg, moneyFloor: 0) == .critical)
check("island state:需处理压过告急", MenuBarTable.state(islCol(.kimi, 95, nil, attention: true), config: islCfg, moneyFloor: 0) == .needsAction)
check("island state:余额低于下限→告急", MenuBarTable.state(islCol(.mimo, nil, nil, amount: 30), config: islCfg, moneyFloor: 50) == .critical)
check("island state:下限 0→余额不参与", MenuBarTable.state(islCol(.mimo, nil, nil, amount: 30), config: islCfg, moneyFloor: 0) == .ok)
check("island 剩余文案:78→剩 22%", MenuBarTable.remainingText(MenuBarTableValue(text: "78%", pct: 78)) == "剩 22%")
check("island 剩余文案:横杠原样", MenuBarTable.remainingText(MenuBarTableValue(text: "—", pct: nil)) == "—")
check("island 剩余文案:金额原样", MenuBarTable.remainingText(MenuBarTableValue(text: "12.3万", pct: nil, amount: 123_000)) == "12.3万")
check("island 行文案:双窗口剩余", MenuBarTable.islandRowText(islCol(.kimi, 0, 78)) == "5小时 剩 100% · 周 剩 22%")
check("island 行文案:单值列只要主段", {
    let col = MenuBarTableColumn(singleValueKind: .aliyun,
                                 primary: MenuBarTableValue(text: "64%", pct: 64),
                                 primaryLabel: "30天",
                                 secondary: MenuBarTableValue(text: "—", pct: nil))
    return MenuBarTable.islandRowText(col) == "30天 剩 36%"
}())
check("island 汇总计数", MenuBarTable.islandHealth(columns: [islCol(.kimi, 95, nil),
                                                              islCol(.zhipu, 85, nil),
                                                              islCol(.aliyun, 10, nil)],
                                                    config: islCfg, moneyFloor: 0)
      == IslandHealth(needAction: 0, critical: 1, warning: 1))
check("island 文案:全正常", MenuBarTable.islandHealthText(IslandHealth(needAction: 0, critical: 0, warning: 0)) == "一切正常")
check("island 文案:单类带量词", MenuBarTable.islandHealthText(IslandHealth(needAction: 0, critical: 2, warning: 0)) == "2 项告急")
check("island 文案:两类去量词", MenuBarTable.islandHealthText(IslandHealth(needAction: 1, critical: 1, warning: 0)) == "1 需处理 · 1 告急")
check("island 文案:三类省略为 +n", MenuBarTable.islandHealthText(IslandHealth(needAction: 1, critical: 1, warning: 1)) == "1 需处理 · 1 告急 +1")
check("island worst:需处理优先", IslandHealth(needAction: 1, critical: 3, warning: 9).worst == .needsAction)
check("island 排序:状态优先+同级剩余升序", {
    let rows = MenuBarTable.islandRows(columns: [islCol(.aliyun, 10, nil),        // 正常 剩90
                                                 islCol(.kimi, 0, 90),           // 告急 剩10
                                                 islCol(.zhipu, 0, 85),          // 预警 剩15
                                                 islCol(.mimo, nil, nil, attention: true)],  // 需处理
                                 config: islCfg, moneyFloor: 0)
    return rows.map(\.kind) == [.mimo, .kimi, .zhipu, .aliyun]
}())
check("island 排序:金额列进档但不抢档内位次", {
    let rows = MenuBarTable.islandRows(columns: [islCol(.deepSeek, nil, nil, amount: 5),  // 告急但无 pct
                                                 islCol(.kimi, 0, 90)],                  // 告急 剩10
                                 config: islCfg, moneyFloor: 50)
    return rows.map(\.kind) == [.kimi, .deepSeek]
}())
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift run Verify 2>&1 | tail -20`
Expected: 编译失败(`MenuBarTableValue` 没有 `amount`、`MenuBarTable.state` 不存在等),即「测试先红」。

- [ ] **Step 3: 实现(Core 模型 + 纯函数)**

`Sources/AliyunTokenBarCore/MenuBarTable.swift` 顶部结构体替换为:

```swift
/// 单个值:展示文本 + 原始百分比(pct 供阈值变色;nil = 横杠,不着色)+ 余额原始值。
public struct MenuBarTableValue: Equatable {
    public let text: String
    public let pct: Int?
    /// 余额类金额原始值(**仅「余额」行携带**;花费行/百分比行恒 nil)。
    /// 「余额低于下限 → 告急」用它判定——展示文本已格式化,不能再反解析。
    public let amount: Double?
    public init(text: String, pct: Int?, amount: Double? = nil) {
        self.text = text
        self.pct = pct
        self.amount = amount
    }
}
```

`MenuBarTableColumn` 内(`init` 们之后)追加两个属性:

```swift
    /// 该源是否处于「需处理」状态(鉴权类失败:未登录/过期/凭据无效)。
    /// 构造后由 `MenuBarTable.columns(…, needsAttention:)` 置位。
    public var needsAttention: Bool = false
```

文件末尾(`extension TokenPlanModel` 之前)追加:

```swift
// MARK: - 灵动岛汇总(状态 / 剩余 / 计数 / 排序)

/// 岛视角的单列状态:比 UsageBand 多一档「需处理」(鉴权类失败)。
public enum ColumnState: Int, Comparable, Equatable {
    case ok = 0, warning = 1, critical = 2, needsAction = 3

    public static func < (lhs: ColumnState, rhs: ColumnState) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// 岛收起态胶囊的汇总计数(展开卡头部 chip 共用同一套文案)。
public struct IslandHealth: Equatable {
    public let needAction: Int
    public let critical: Int
    public let warning: Int
    public init(needAction: Int, critical: Int, warning: Int) {
        self.needAction = needAction
        self.critical = critical
        self.warning = warning
    }
    public var total: Int { needAction + critical + warning }
    /// 最严重的一类(决定胶囊圆点/文字与展开卡的取色)。
    public var worst: ColumnState {
        if needAction > 0 { return .needsAction }
        if critical > 0 { return .critical }
        if warning > 0 { return .warning }
        return .ok
    }
}

public extension MenuBarTable {
    /// 单列状态:需处理 > 告急 > 预警 > 正常(两窗口取最严重;余额按下限判定)。
    static func state(_ col: MenuBarTableColumn, config: ThresholdConfig, moneyFloor: Double) -> ColumnState {
        if col.needsAttention { return .needsAction }
        var worst = ColumnState.ok
        for v in [col.primary, col.secondary] {
            if let p = v.pct {
                let s: ColumnState = p >= config.critical ? .critical : (p >= config.warning ? .warning : .ok)
                if s > worst { worst = s }
            }
            if moneyFloor > 0, let a = v.amount, a < moneyFloor, worst < .critical {
                worst = .critical
            }
        }
        return worst
    }

    /// 剩余口径文案:"剩 22%";金额与横杠原样返回(金额不折算成百分比)。
    static func remainingText(_ v: MenuBarTableValue) -> String {
        guard let p = v.pct else { return v.text }
        return "剩 \(max(0, min(100, 100 - p)))%"
    }

    /// 展开卡行文案:"5小时 剩 100% · 周 剩 22%";单值列/次行横杠时只显主段。
    static func islandRowText(_ col: MenuBarTableColumn) -> String {
        var text = "\(col.primaryLabel) \(remainingText(col.primary))"
        if let sl = col.secondaryLabel, col.secondary.pct != nil || col.secondary.text != "—" {
            text += " · \(sl) \(remainingText(col.secondary))"
        }
        return text
    }

    /// 汇总计数:单位是**列**(源)不是窗口(Kimi 周剩 22% + 5h 剩 100% → 该源记 1 项预警)。
    static func islandHealth(columns: [MenuBarTableColumn],
                             config: ThresholdConfig,
                             moneyFloor: Double) -> IslandHealth {
        var need = 0, crit = 0, warn = 0
        for c in columns {
            switch state(c, config: config, moneyFloor: moneyFloor) {
            case .needsAction: need += 1
            case .critical: crit += 1
            case .warning: warn += 1
            case .ok: break
            }
        }
        return IslandHealth(needAction: need, critical: crit, warning: warn)
    }

    /// 胶囊/头部文案:单类带量词(「2 项告急」),多类去量词省菜单栏宽度
    /// (「1 需处理 · 1 告急」,第三类省略为「+1」)。
    static func islandHealthText(_ h: IslandHealth) -> String {
        if h.total == 0 { return "一切正常" }
        var parts: [String] = []
        if h.needAction > 0 { parts.append("\(h.needAction) 需处理") }
        if h.critical > 0 { parts.append("\(h.critical) 告急") }
        if h.warning > 0 { parts.append("\(h.warning) 预警") }
        if parts.count == 1 {
            let label = h.needAction > 0 ? "需处理" : (h.critical > 0 ? "告急" : "预警")
            return "\(h.total) 项\(label)"
        }
        var text = parts[0] + " · " + parts[1]
        if parts.count == 3 { text += " +\(h.warning)" }   // 第三类必是预警(优先级顺序固定)
        return text
    }

    /// 展开卡行序:需处理 → 告急 → 预警 → 正常;同级按「最紧窗口」已用升序
    /// (最紧的在上);金额等无 pct 的列置于该档末尾;再同级按固定列序。
    static func islandRows(columns: [MenuBarTableColumn],
                           config: ThresholdConfig,
                           moneyFloor: Double) -> [MenuBarTableColumn] {
        columns.enumerated().sorted { a, b in
            let (sa, sb) = (state(a.element, config: config, moneyFloor: moneyFloor),
                            state(b.element, config: config, moneyFloor: moneyFloor))
            if sa != sb { return sa > sb }
            let (ta, tb) = (tightness(a.element), tightness(b.element))
            if ta != tb { return ta < tb }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// 「最紧窗口」的已用百分比;无百分比(纯金额列)→ Int.max(同档末尾)。
    private static func tightness(_ col: MenuBarTableColumn) -> Int {
        [col.primary.pct, col.secondary.pct].compactMap { $0 }.max() ?? Int.max
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift run Verify 2>&1 | tail -5`
Expected: `ALL PASS`

- [ ] **Step 5: 提交**

```bash
git add Sources/AliyunTokenBarCore/MenuBarTable.swift Sources/Verify/main.swift
git commit -m "feat(island): Core 健康度状态与汇总纯函数(剩余换算/计数/文案/排序)"
```

---

### Task 2: `columns()` 支持余额下限与需处理标记

**Files:**
- Modify: `Sources/AliyunTokenBarCore/MenuBarTable.swift`(`MenuBarTable.columns` 整个函数体 + `moneyValue` 拆出 `balanceValue`)
- Test: `Sources/Verify/main.swift`

**Interfaces:**
- Consumes: Task 1 的 `MenuBarTableValue.amount`、`ColumnState`、`state(_:config:moneyFloor:)`。
- Produces: `columns(…, moneyFloor: Double = 0, needsAttention: Set<String> = [])`;新 `MenuBarTable.balanceValue(_:)`。

- [ ] **Step 1: 写失败断言**

```swift
// --- 余额行携带原始值(花费行不携带) + 需处理标记注入 ---
let islCols = MenuBarTable.columns(
    aliyunFiveHour: nil, aliyunOneWeek: nil, aliyunOneMonth: nil,
    kimiConfigured: true, kimiHasError: false, kimiFiveHour: 0, kimiWeekly: 78,
    openCodeConfigured: false, openCodeHasError: false, openCodeRolling: nil, openCodeWeekly: nil,
    deepSeekConfigured: true, deepSeekHasError: false, deepSeekTodayCost: 3.5, deepSeekBalance: 12,
    zhipuConfigured: false, zhipuHasError: false, zhipuFiveHour: nil, zhipuWeekly: nil,
    mimoConfigured: false, mimoHasError: false, mimoPlanPct: nil, mimoBalance: nil,
    minimaxConfigured: false, minimaxHasError: false, minimaxInterval: nil, minimaxWeekly: nil,
    ollamaConfigured: false, ollamaHasError: false, ollamaPrimary: nil, ollamaSecondary: nil,
    stepfunConfigured: false, stepfunHasError: false, stepfunPrimary: nil, stepfunPrimaryLabel: nil,
    stepfunSecondary: nil, stepfunSecondaryLabel: nil,
    systemEnabled: false, cpu: nil, memory: nil,
    disabled: ["aliyun"], moneyFloor: 50, needsAttention: ["kimi"])
let dsCol = islCols.first { $0.kind == .deepSeek }!
check("columns:余额行带 amount", dsCol.secondary.amount == 12)
check("columns:花费行不带 amount", dsCol.primary.amount == nil)
check("columns:余额低于下限→该列告急", MenuBarTable.state(dsCol, config: islCfg, moneyFloor: 50) == .critical)
check("columns:余额下限 0→正常", MenuBarTable.state(dsCol, config: islCfg, moneyFloor: 0) == .ok)
let kimiCol = islCols.first { $0.kind == .kimi }!
check("columns:需处理集合命中→needsAttention", kimiCol.needsAttention)
check("columns:不在集合→false", !dsCol.needsAttention)
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift run Verify 2>&1 | tail -20`
Expected: 编译失败(`extra arguments at positions…`:`moneyFloor`/`needsAttention` 尚未定义)。

- [ ] **Step 3: 实现**

把 `moneyValue` 改成两个函数(在 `MenuBarTable` 内、`value(_:)` 旁边):

```swift
    /// 金额 → 展示文本(DeepSeek 花费行/MiMo 余额行共用的紧凑格式)。
    /// `amount` **恒 nil**:花费/展示类金额不参与「余额低于下限」判定。
    static func moneyValue(_ v: Double?) -> MenuBarTableValue {
        MenuBarTableValue(text: v.map { DeepSeekMoneyFormat.compactDigits($0) } ?? "—", pct: nil)
    }

    /// 余额 → 展示文本 + 原始值(参与「余额低于下限 → 告急」判定)。
    static func balanceValue(_ v: Double?) -> MenuBarTableValue {
        MenuBarTableValue(text: v.map { DeepSeekMoneyFormat.compactDigits($0) } ?? "—", pct: nil, amount: v)
    }
```

`columns(...)` 末尾新增两个参数:

```swift
        systemEnabled: Bool, cpu: Int?, memory: Int?,
        disabled: Set<String> = [],
        /// 余额告急下限(¥);0 = 余额类不参与岛的告急判定。
        moneyFloor: Double = 0,
        /// 需处理的源(ProviderKind.rawValue 集合);命中即该列 needsAttention = true。
        needsAttention: Set<String> = []
    ) -> [MenuBarTableColumn] {
```

函数体内,`func off(...)` 之后加标记助手:

```swift
        /// 命中需处理集合 → 在列上打标(岛据此计入「需处理」并给「重登」入口)。
        func marked(_ col: MenuBarTableColumn, _ kind: MenuBarColumnKind) -> MenuBarTableColumn {
            guard needsAttention.contains(ProviderKind.from(menuBarColumnKind: kind).rawValue) else { return col }
            var c = col
            c.needsAttention = true
            return c
        }
```

然后把整个 `columns(...)` 函数体替换为下面这份(八处 append 全部过 `marked`,DeepSeek/MiMo 的余额行改用 `balanceValue`,`off(...)` 判断与列顺序保持不变):

```swift
    public static func columns(
        aliyunFiveHour: Int?, aliyunOneWeek: Int?, aliyunOneMonth: Int?,
        kimiConfigured: Bool, kimiHasError: Bool, kimiFiveHour: Int?, kimiWeekly: Int?,
        openCodeConfigured: Bool, openCodeHasError: Bool, openCodeRolling: Int?, openCodeWeekly: Int?,
        deepSeekConfigured: Bool, deepSeekHasError: Bool, deepSeekTodayCost: Double?, deepSeekBalance: Double?,
        zhipuConfigured: Bool, zhipuHasError: Bool, zhipuFiveHour: Int?, zhipuWeekly: Int?,
        mimoConfigured: Bool, mimoHasError: Bool, mimoPlanPct: Int?, mimoBalance: Double?,
        minimaxConfigured: Bool, minimaxHasError: Bool, minimaxInterval: Int?, minimaxWeekly: Int?,
        ollamaConfigured: Bool, ollamaHasError: Bool, ollamaPrimary: Int?, ollamaSecondary: Int?,
        stepfunConfigured: Bool, stepfunHasError: Bool, stepfunPrimary: Int?, stepfunPrimaryLabel: String?,
        stepfunSecondary: Int?, stepfunSecondaryLabel: String?,
        systemEnabled: Bool, cpu: Int?, memory: Int?,
        disabled: Set<String> = [],
        /// 余额告急下限(¥);0 = 余额类不参与岛的告急判定。
        moneyFloor: Double = 0,
        /// 需处理的源(ProviderKind.rawValue 集合);命中即该列 needsAttention = true。
        needsAttention: Set<String> = []
    ) -> [MenuBarTableColumn] {
        func off(_ kind: MenuBarColumnKind) -> Bool {
            disabled.contains(ProviderKind.from(menuBarColumnKind: kind).rawValue)
        }
        /// 命中需处理集合 → 在列上打标(岛据此计入「需处理」并给「重登」入口)。
        func marked(_ col: MenuBarTableColumn, _ kind: MenuBarColumnKind) -> MenuBarTableColumn {
            guard needsAttention.contains(ProviderKind.from(menuBarColumnKind: kind).rawValue) else { return col }
            var c = col
            c.needsAttention = true
            return c
        }
        var cols: [MenuBarTableColumn] = []
        if !off(.aliyun) {
            cols.append(marked(aliyunColumn(fiveHour: aliyunFiveHour, oneWeek: aliyunOneWeek,
                                            oneMonth: aliyunOneMonth), .aliyun))
        }
        if !off(.kimi) && kimiConfigured && (kimiHasError || kimiFiveHour != nil || kimiWeekly != nil) {
            cols.append(marked(MenuBarTableColumn(kind: .kimi,
                                                  primary: value(kimiFiveHour),
                                                  secondary: value(kimiWeekly)), .kimi))
        }
        if !off(.openCode) && openCodeConfigured && (openCodeHasError || openCodeRolling != nil || openCodeWeekly != nil) {
            cols.append(marked(MenuBarTableColumn(kind: .openCode,
                                                  primary: value(openCodeRolling),
                                                  secondary: value(openCodeWeekly)), .openCode))
        }
        if !off(.deepSeek) && deepSeekConfigured && (deepSeekHasError || deepSeekTodayCost != nil || deepSeekBalance != nil) {
            cols.append(marked(MenuBarTableColumn(kind: .deepSeek,
                                                  primary: moneyValue(deepSeekTodayCost),
                                                  secondary: balanceValue(deepSeekBalance)), .deepSeek))
        }
        if !off(.zhipu) && zhipuConfigured && (zhipuHasError || zhipuFiveHour != nil || zhipuWeekly != nil) {
            cols.append(marked(MenuBarTableColumn(kind: .zhipu,
                                                  primary: value(zhipuFiveHour),
                                                  secondary: value(zhipuWeekly)), .zhipu))
        }
        if !off(.mimo) && mimoConfigured && (mimoHasError || mimoPlanPct != nil || mimoBalance != nil) {
            cols.append(marked(MenuBarTableColumn(kind: .mimo,
                                                  primary: value(mimoPlanPct),
                                                  secondary: balanceValue(mimoBalance)), .mimo))
        }
        if !off(.minimax) && minimaxConfigured && (minimaxHasError || minimaxInterval != nil || minimaxWeekly != nil) {
            cols.append(marked(MenuBarTableColumn(kind: .minimax,
                                                  primary: value(minimaxInterval),
                                                  secondary: value(minimaxWeekly)), .minimax))
        }
        if !off(.ollama) && ollamaConfigured && (ollamaHasError || ollamaPrimary != nil || ollamaSecondary != nil) {
            cols.append(marked(ollamaColumn(primary: ollamaPrimary, secondary: ollamaSecondary), .ollama))
        }
        if !off(.stepfun) && stepfunConfigured && (stepfunHasError || stepfunPrimary != nil || stepfunSecondary != nil) {
            cols.append(marked(stepfunColumn(primary: stepfunPrimary, primaryLabel: stepfunPrimaryLabel,
                                             secondary: stepfunSecondary,
                                             secondaryLabel: stepfunSecondaryLabel), .stepfun))
        }
        if !off(.system) && systemEnabled {
            cols.append(marked(MenuBarTableColumn(kind: .system,
                                                  primary: value(cpu),
                                                  secondary: value(memory)), .system))
        }
        return cols
    }
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift run Verify 2>&1 | tail -5`
Expected: `ALL PASS`(含旧断言:列顺序、横杠、tooltip 文案均不变)

- [ ] **Step 5: 提交**

```bash
git add Sources/AliyunTokenBarCore/MenuBarTable.swift Sources/Verify/main.swift
git commit -m "feat(island): columns() 支持余额下限与需处理标记(花费行不参与)"
```

---

### Task 3: 模型层余额下限 + 鉴权失败登记

**Files:**
- Modify: `Sources/AliyunTokenBarCore/AppConstants.swift`(新键)
- Modify: `Sources/AliyunTokenBarCore/TokenPlanModel.swift`(属性 + 登记 + 8 个 provider 的插入点)
- Modify: `Sources/AliyunTokenBarCore/MenuBarTable.swift`(文件末尾 `extension TokenPlanModel.menuBarColumns()` 接线)
- Test: `Sources/Verify/main.swift`

**Interfaces:**
- Consumes: Task 2 的 `columns(…, moneyFloor:needsAttention:)`。
- Produces: `TokenPlanModel.moneyFloor: Double`、`TokenPlanModel.authIssueProviders: Set<String>`(App 层只读)。

- [ ] **Step 1: 写失败断言**

模型层是 `@MainActor` 单例、依赖本机凭据,Verify 里只断言**纯映射**(哪种 typed error 算鉴权类)——用一个新纯函数承载:

```swift
// --- 鉴权类失败归类(岛「需处理」判定) ---
check("attention:UsageError.authExpired→鉴权类", AuthIssueClass.isAuth(UsageError.authExpired))
check("attention:网络错误不算", !AuthIssueClass.isAuth(UsageError.network("timeout")))
check("attention:MiMo loginRequired→鉴权类", AuthIssueClass.isMiMoAuth(.loginRequired))
check("attention:MiMo network 不算", !AuthIssueClass.isMiMoAuth(.network("x")))
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift run Verify 2>&1 | tail -20`
Expected: 编译失败(`AuthIssueClass` 不存在)。

- [ ] **Step 3: 实现**

(a) `AppConstants.swift` 的 `UserDefaultsKeys` 里追加:

```swift
    /// 灵动岛「余额告急下限」(¥)。0 = 余额类不参与岛的告急计数。
    public static let moneyFloor = "moneyFloor"
```

(b) `Sources/AliyunTokenBarCore/TokenPlanModel.swift`:在 `ThresholdConfig` 附近新增纯函数枚举(**放在 TokenPlanModel 类外**,方便 Verify 调用):

```swift
/// 鉴权类失败归类:只有这类才算「需处理」(未登录/过期/凭据无效);
/// 网络/解析类失败保留旧数据、不打扰用户(2026-10-18 岛汇总语义)。
public enum AuthIssueClass {
    public static func isAuth(_ e: UsageError) -> Bool {
        if case .authExpired = e { return true }
        return false
    }
    /// MiMo 的三类鉴权失败(它的错误类型独立于 UsageError)。
    public static func isMiMoAuth(_ e: MiMoUsageService.MiMoError) -> Bool {
        switch e {
        case .loginRequired, .invalidCredentials, .invalidCookie: return true
        case .network, .parse, .unknown: return false
        }
    }
}
```

(c) 模型属性(紧跟 `thresholdConfig` 之后):

```swift
    /// 灵动岛「余额告急下限」(¥):DeepSeek/MiMo 余额低于该值 → 岛判告急;0 = 不参与。
    @Published public var moneyFloor: Double = 50 {
        didSet {
            UserDefaults.standard.set(moneyFloor, forKey: UserDefaultsKeys.moneyFloor)
            prerenderIcon()
        }
    }

    /// 当前处于「需处理」(鉴权类失败)的源(ProviderKind.rawValue)。
    /// 由各 provider 刷新路径登记;阿里云不在此列(它按 authState 推导,见 attentionProviders)。
    @Published public private(set) var authIssueProviders: Set<String> = []

    /// 登记/清除鉴权失败标记。**变化即重渲染**——多数失败路径不经过 recordAndNotify,
    /// 不主动重渲染胶囊就还是旧计数。
    private func noteAuthIssue(_ kind: ProviderKind, _ active: Bool) {
        let raw = kind.rawValue
        if active {
            guard !authIssueProviders.contains(raw) else { return }
            authIssueProviders.insert(raw)
        } else {
            guard authIssueProviders.contains(raw) else { return }
            authIssueProviders.remove(raw)
        }
        prerenderIcon()
    }
```

(d) 模型 init 载入(紧跟 `thresholdConfig = ThresholdConfig(warning: w, critical: c)` 之后):

```swift
        moneyFloor = defaults.object(forKey: UserDefaultsKeys.moneyFloor) as? Double ?? 50
```

(e) **8 个 provider 的登记点**(每处都是 1 行插入;锚点文本为现有代码):

1. OpenCode 循环失败分支(`errors[ws.id] = openCodeErrorMessage(e)` 之后)与成功分支(`openCodeError = nil` 之后):

```swift
            case .failure(let e):
                errors[ws.id] = openCodeErrorMessage(e)
                if AuthIssueClass.isAuth(e) { noteAuthIssue(.openCode, true) }
```
```swift
            openCodeError = nil
            noteAuthIssue(.openCode, false)
```

2. Kimi:`kimiErrorMessage(e)` 之后 `if AuthIssueClass.isAuth(e) { noteAuthIssue(.kimi, true) }`;`kimiError = nil` 之后 `noteAuthIssue(.kimi, false)`。
3. 智谱:`zhipuErrorMessage(e)` 之后 `if case .authExpired = e { noteAuthIssue(.zhipu, true) }`;`zhipuError = nil` 之后 `noteAuthIssue(.zhipu, false)`。
4. DeepSeek 的 `case .authExpired: deepSeekError = "API Key 无效或已失效,请在设置更新"` 同一分支追加 `noteAuthIssue(.deepSeek, true)`;`deepSeekError = nil` 之后 `noteAuthIssue(.deepSeek, false)`。
5. MiMo 的 `case .loginRequired, .invalidCredentials, .invalidCookie:` 分支(已有降频 switch)追加 `noteAuthIssue(.mimo, true)`;`mimoError = nil` 之后 `noteAuthIssue(.mimo, false)`。
6. MiniMax 的 `case .authExpired: minimaxError = …` 分支追加 `noteAuthIssue(.minimax, true)`;`minimaxError = nil` 之后 `noteAuthIssue(.minimax, false)`。注意 `.noSubscription` **不算**需处理(不是鉴权问题)。
7. Ollama 的 `case .authExpired: ollamaError = …` 分支追加 `noteAuthIssue(.ollama, true)`;`ollamaError = nil` 之后 `noteAuthIssue(.ollama, false)`。
8. 阶跃:多账户循环里三处(`case .sessionExpired:`、包络 `case .authExpired:`、`case .tokenNotPermitted:`)各追加 `noteAuthIssue(.stepfun, true)`;`if anyFresh {` 分支里 `stepfunError = nil` 之后 `noteAuthIssue(.stepfun, false)`;遗留单 token 路径 `applyStepFunResult` 成功分支 `stepfunError = nil` 之后同样清,失败分支的 `.authExpired`/`.tokenNotPermitted` 两例各登记。
9. 清态函数(`clearKimi`/`clearZhipu`/`clearDeepSeek`/`clearMiniMax`/`clearOllama`/`clearStepFun`)末尾各加 `noteAuthIssue(.<kind>, false)`(凭据已清,避免残留标记)。

(f) `MenuBarTable.swift` 末尾 `extension TokenPlanModel` 内:

```swift
    /// 需处理的源集合:各 provider 刷新路径登记 + 阿里云按登录态推导
    /// (阿里云的失败通道是 AuthState,不走错误字符串)。
    private var attentionProviders: Set<String> {
        var set = authIssueProviders
        switch authState {
        case .notLoggedIn, .expired, .blNotInstalled: set.insert(ProviderKind.aliyun.rawValue)
        default: break
        }
        return set
    }

    public func menuBarColumns() -> [MenuBarTableColumn] {
        let monitor = SystemMetricsMonitor.shared
        return MenuBarTable.columns(
            …(现有实参不动)…,
            systemEnabled: systemStatsEnabled && isEnabled(.system),
            cpu: monitor.cpuPercent, memory: monitor.memoryPercent,
            disabled: disabledProviders,
            moneyFloor: moneyFloor,
            needsAttention: attentionProviders
        )
    }
```

- [ ] **Step 4: 跑测试 + 构建确认通过**

Run: `swift run Verify 2>&1 | tail -5 && swift build 2>&1 | tail -3`
Expected: `ALL PASS` 且 `Build complete!`(Core 编译通过;App 目标此处尚未改,可用默认 SDK 一起构建亦可)

- [ ] **Step 5: 提交**

```bash
git add Sources/AliyunTokenBarCore/AppConstants.swift Sources/AliyunTokenBarCore/TokenPlanModel.swift Sources/AliyunTokenBarCore/MenuBarTable.swift Sources/Verify/main.swift
git commit -m "feat(island): 模型层余额下限与鉴权失败登记(8 源精确登记点)"
```

---

### Task 4: 胶囊改健康度汇总

**Files:**
- Modify: `Sources/AliyunTokenBar/App.swift`(`image(scheme:…)` 增参、`islandPillImage` 重写、`islandRiskColor` 删除、`renderIconSink` 接线)
- Modify: `Sources/AliyunTokenBar/IslandOverlay.swift`(新增 `IslandStateColor`)

**Interfaces:**
- Consumes: Task 1 的 `islandHealth`/`islandHealthText`;Task 3 的 `model.moneyFloor`。
- Produces: `IslandStateColor.color(_ s: ColumnState) -> Color`(岛与胶囊共用)。

- [ ] **Step 1: 先加状态色(IslandOverlay.swift,`IslandPalette` 之后)**

```swift
/// 岛状态色(黑底上更亮一档)。胶囊圆点/文字与展开卡行底条、行底色共用同一套,
/// 避免两处色值各写一遍后漂移。
@MainActor
enum IslandStateColor {
    static func color(_ s: ColumnState) -> Color {
        switch s {
        case .needsAction: return Color(red: 0.55, green: 0.68, blue: 1.0)   // 蓝紫:需要你动手
        case .critical: return Color(red: 1.0, green: 0.40, blue: 0.36)      // 红
        case .warning: return Color(red: 1.0, green: 0.65, blue: 0.24)       // 橙
        case .ok: return Color(red: 0.30, green: 0.85, blue: 0.45)           // 绿
        }
    }
}
```

- [ ] **Step 2: 重写胶囊渲染(App.swift)**

把 `islandPillImage(columns:isDark:thresholdConfig:)` 整体替换为:

```swift
    /// 灵动岛收起态:黑色胶囊(非模板,明暗菜单栏下都是黑底白字——动态岛语义),
    /// 内容 = **全源健康度汇总**(需处理/告急/预警计数;全正常=「一切正常」)。
    /// 判定见 MenuBarTable.islandHealth(鉴权类失败优先,余额按设置的下限)。
    @MainActor
    private static func islandPillImage(columns: [MenuBarTableColumn], isDark: Bool,
                                        thresholdConfig: ThresholdConfig, moneyFloor: Double) -> NSImage {
        let health = MenuBarTable.islandHealth(columns: columns, config: thresholdConfig, moneyFloor: moneyFloor)
        let tint = IslandStateColor.color(health.worst)
        let content = HStack(spacing: 4) {
            Circle().fill(tint).frame(width: 6, height: 6)
            // 全正常时文字保持白色(只有圆点绿):避免菜单栏常年挂一条绿字
            Text(MenuBarTable.islandHealthText(health))
                .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                .foregroundStyle(health.total == 0 ? Color.white : tint)
        }
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background(
            Capsule().fill(.black)
                .overlay(Capsule().strokeBorder(.white.opacity(isDark ? 0.16 : 0.08),
                                                lineWidth: 0.5))
        )
        .fixedSize(horizontal: true, vertical: false)
        return render(content, isTemplate: false)
    }
```

同时删除只服务旧胶囊的 `islandRiskColor(_:config:)`,并在 `image(scheme:…)` 上增参透传:

```swift
                      thresholdConfig: ThresholdConfig = ThresholdConfig(),
                      aliyunVisible: Bool = true,
                      moneyFloor: Double = 0) -> NSImage {
        …
        case .island: return islandPillImage(columns: columns ?? [], isDark: isDark,
                                             thresholdConfig: thresholdConfig, moneyFloor: moneyFloor)
```

`renderIconSink`(`App.swift` init 内)的 `MenuBarTextRenderer.image(...)` 调用末尾加一行:

```swift
                aliyunVisible: aliyunOn,
                moneyFloor: model.moneyFloor
```

- [ ] **Step 3: 构建**

Run: `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk swift build --product AliyunTokenBar 2>&1 | tail -5`
Expected: `Build complete!`(若报 `MenuBarTable.islandFocus` 未使用等警告属正常;报错才是问题)

- [ ] **Step 4: 目测(实机已验证前不提交大改)**

Run: `bash packaging/install-update.sh`(任务末尾统一装),或用 `swift run AliyunTokenBar` 快速看胶囊
Expected: 菜单栏出现黑胶囊,内容为「一切正常」或计数文案(**不再是 K/云朵 logo + 百分比**)

- [ ] **Step 5: 提交**

```bash
git add Sources/AliyunTokenBar/App.swift Sources/AliyunTokenBar/IslandOverlay.swift
git commit -m "feat(island): 胶囊改全源健康度汇总(计数+状态色,替代单列聚焦)"
```

---

### Task 5: 展开卡剩余口径 + 紧迫度排序

**Files:**
- Modify: `Sources/AliyunTokenBar/IslandOverlay.swift`(`IslandMetrics` 宽度、`IslandState`、`IslandRootView`、`IslandExpandedContent`、`IslandRow`、控制器数据装配)

**Interfaces:**
- Consumes: Task 1 的 `islandRows`/`islandRowText`/`IslandHealth`;`IslandStateColor`。
- Produces: `IslandState.rows/health/moneyFloor`;`IslandRow` 带 `onTap` 回调(点击行为在 Task 6 接上)。

- [ ] **Step 1: 度量与状态**

```swift
    /// 展开态宽度:剩余口径文案(「5小时 剩 100% · 周 剩 22%」)+ 需处理行的「重登」徽标,
    /// 260 会挤 → 280。
    static let expandedWidth: CGFloat = 280
```

```swift
@MainActor
final class IslandState: ObservableObject {
    @Published var expanded = false
    /// 已按紧迫度排序的源行(需处理 → 告急 → 预警 → 正常)。
    @Published var rows: [MenuBarTableColumn] = []
    @Published var health = IslandHealth(needAction: 0, critical: 0, warning: 0)
    @Published var collapsedRect: CGRect = .zero
    @Published var expandedRect: CGRect = .zero
    var config = ThresholdConfig()
    var moneyFloor: Double = 0
    var updated: Date?
}
```

- [ ] **Step 2: 视图层(IslandRootView / IslandExpandedContent / IslandRow 全量替换)**

```swift
struct IslandRootView: View {
    @ObservedObject var state: IslandState
    /// 点行 → 打开主面板并落在该源 tab(Task 6 接上真实实现)。
    let onTapRow: (MenuBarColumnKind) -> Void

    var body: some View {
        let rect = state.expanded ? state.expandedRect : state.collapsedRect
        ZStack(alignment: .topLeading) {
            RoundedRectangle(
                cornerRadius: state.expanded ? IslandMetrics.expandedCorner : IslandMetrics.collapsedCorner,
                style: .continuous
            )
            .fill(.black)
            .frame(width: rect.width, height: rect.height)
            .offset(x: rect.minX, y: rect.minY)
            IslandExpandedContent(
                rows: state.rows, health: state.health,
                config: state.config, moneyFloor: state.moneyFloor, updated: state.updated,
                onTapRow: onTapRow
            )
            .frame(width: state.expandedRect.width, height: state.expandedRect.height,
                   alignment: .topLeading)
            .offset(x: state.expandedRect.minX, y: state.expandedRect.minY)
            .opacity(state.expanded ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(.spring(response: 0.42, dampingFraction: 0.72), value: state.expanded)
    }
}

private struct IslandExpandedContent: View {
    let rows: [MenuBarTableColumn]
    let health: IslandHealth
    let config: ThresholdConfig
    let moneyFloor: Double
    let updated: Date?
    let onTapRow: (MenuBarColumnKind) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("CodingTokenBar")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.55))
                Spacer(minLength: 4)
                Text("口径:剩余")
                    .font(.system(size: 8.5)).foregroundStyle(.white.opacity(0.35))
                statusChip
            }
            .frame(height: IslandMetrics.headerHeight)
            Rectangle().fill(Color.white.opacity(0.14)).frame(height: 0.5)
                .padding(.bottom, IslandMetrics.gapHeaderRows)
            ForEach(rows, id: \.kind) { col in
                IslandRow(col: col, config: config, moneyFloor: moneyFloor) { onTapRow(col.kind) }
            }
        }
        .padding(.horizontal, IslandMetrics.paddingH)
        .padding(.vertical, IslandMetrics.paddingV)
    }

    /// 与胶囊**同一套**计数文案(需处理/告急/预警),颜色取最严重类别。
    private var statusChip: some View {
        let tint = IslandStateColor.color(health.worst)
        return HStack(spacing: 4) {
            Circle().fill(tint).frame(width: 5, height: 5)
            Text(MenuBarTable.islandHealthText(health))
                .font(.system(size: 9.5, weight: .semibold)).foregroundStyle(tint)
        }
    }
}

private struct IslandRow: View {
    let col: MenuBarTableColumn
    let config: ThresholdConfig
    let moneyFloor: Double
    let onTap: () -> Void

    @State private var hovering = false

    private var state: ColumnState { MenuBarTable.state(col, config: config, moneyFloor: moneyFloor) }

    /// 最紧窗口的剩余比例(0…1);纯金额列无 pct → nil(不画底条)。
    private var remainingFraction: Double? {
        guard let worst = [col.primary.pct, col.secondary.pct].compactMap({ $0 }).max() else { return nil }
        return Double(max(0, min(100, 100 - worst))) / 100
    }

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if let mark = col.kind.brandMark {
                    mark.mark(in: CGRect(x: 0, y: 0, width: 13, height: 13))
                } else {
                    Image(systemName: col.kind.symbolName)
                        .font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                }
            }
            .frame(width: 15, alignment: .leading)
            Text(col.kind.displayName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1).minimumScaleFactor(0.8)
                .frame(width: 52, alignment: .leading)
            Spacer(minLength: 2)
            Text(MenuBarTable.islandRowText(col))
                .font(.system(size: 10.5)).monospacedDigit()
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1).minimumScaleFactor(0.85)
            if state == .needsAction {
                Text("重登")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(IslandStateColor.color(.needsAction))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(IslandStateColor.color(.needsAction).opacity(0.18)))
            }
        }
        .padding(.horizontal, 6)
        .frame(height: IslandMetrics.rowHeight)
        .background(rowBackground)
        .overlay(alignment: .bottom) { meterBar }
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            // 手型光标(项目 floor 是 macOS 14,没有 .pointerStyle):push/pop 必须成对
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .onTapGesture { onTap() }
    }

    /// 行底色:需处理淡蓝紫 / 告急淡红 / 预警淡橙;正常行仅 hover 时微亮。
    private var rowBackground: some View {
        let fill: Color
        switch state {
        case .needsAction: fill = IslandStateColor.color(.needsAction).opacity(0.14)
        case .critical: fill = IslandStateColor.color(.critical).opacity(0.16)
        case .warning: fill = IslandStateColor.color(.warning).opacity(0.10)
        case .ok: fill = hovering ? .white.opacity(0.07) : .clear
        }
        return RoundedRectangle(cornerRadius: 6, style: .continuous).fill(fill)
    }

    /// 行底部 2pt 剩余条(不占横向空间):长度 = 最紧窗口的剩余,颜色随状态。
    @ViewBuilder
    private var meterBar: some View {
        if let fraction = remainingFraction {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.10))
                    Capsule().fill(IslandStateColor.color(state))
                        .frame(width: max(1, geo.size.width * fraction))
                }
            }
            .frame(height: 2)
            .padding(.horizontal, 6)
            .padding(.bottom, 2)
        }
    }
}
```

- [ ] **Step 3: 控制器装配数据(expandIfNeeded / observeModelUpdates)**

`expandIfNeeded` 内的数据赋值段替换为:

```swift
        state.rows = MenuBarTable.islandRows(columns: columns, config: config, moneyFloor: model.moneyFloor)
        state.health = MenuBarTable.islandHealth(columns: columns, config: config, moneyFloor: model.moneyFloor)
        state.config = config
        state.moneyFloor = model.moneyFloor
        state.updated = model.lastUpdated
```

`observeModelUpdates()` 的 sink 内同样换成这两行(`state.rows` / `state.health`)。

顺带删除已被取代的旧计数:Core 的 `MenuBarTable.islandRiskCounts`(以及 Verify 里 `island 风险计数 critical1+warning1`、`island 风险计数 全safe` 两条断言)——`islandHealth` 已完全取代它,留着就是死代码。

新增宿主视图子类(`IslandRootView` 之后;**本步就要定义,否则 `createPanel` 编不过**):

```swift
/// 岛宿主视图:**只让展开卡矩形吃鼠标事件**。覆盖面板叠在状态项之上,
/// 整窗收事件会让点胶囊再也打不开主面板——所以 hitTest 白名单之外一律透传。
@MainActor
final class IslandHostingView: NSHostingView<IslandRootView> {
    /// 事件白名单(视图坐标,左上原点 y 向下);nil = 全窗透传。
    var hitRect: CGRect?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hitRect else { return nil }
        let p = isFlipped ? point : NSPoint(x: point.x, y: bounds.height - point.y)
        return hitRect.contains(p) ? super.hitTest(point) : nil
    }
}
```

`createPanel()` 里的 `NSHostingView(rootView: IslandRootView(state: state))` 改为传闭包(闭包体调用下面这个最小的 `openPanel(for:)`,真正打开面板由 Task 6 注入的 sink 完成):

```swift
        let host = IslandHostingView(rootView: IslandRootView(state: state) { [weak self] kind in
            self?.openPanel(for: kind)
        })
```

控制器新增:

```swift
    /// 点行 → 收起岛并请求打开主面板(实际打开由 App 层注入的 sink 完成)。
    func openPanel(for kind: MenuBarColumnKind) {
        collapseNow()
        setSuppressed(true)
        openPanelSink?(kind)
    }

    /// App 层注入:打开面板并落在该源 tab。
    var openPanelSink: ((MenuBarColumnKind) -> Void)?
```

- [ ] **Step 4: 构建 + 目测**

Run: `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk swift build --product AliyunTokenBar 2>&1 | tail -5`
Expected: `Build complete!`;悬停胶囊(装到 /Applications 后)展开卡行显示「剩 x%」且最紧的在最上

实现提示:替换后 `IslandPalette`(旧行配色)与 `IslandRow.valueColor` 不再被引用,一并删掉避免留死代码;若实机出现「光标卡在手型不放」(行在 hover 中被移除导致 pop 未执行),直接删掉 `NSCursor` 那两行——行高亮本身已足够指示可点。

- [ ] **Step 5: 提交**

```bash
git add Sources/AliyunTokenBar/IslandOverlay.swift
git commit -m "feat(island): 展开卡改剩余口径 + 紧迫度排序 + 行底剩余条"
```

---

### Task 6: 行可点 → 跳面板 tab

**Files:**
- Modify: `Sources/AliyunTokenBar/Menu.swift`(`PanelRouter` + 面板消费)
- Modify: `Sources/AliyunTokenBar/AppDelegate.swift`(`openPanel(tab:)`)
- Modify: `Sources/AliyunTokenBar/App.swift`(注入 sink)
- Modify: `Sources/AliyunTokenBar/IslandOverlay.swift`(`IslandHostingView` + 事件开关)

**Interfaces:**
- Consumes: Task 5 的 `IslandOverlayController.openPanelSink`。
- Produces: `PanelRouter.shared.pendingTab`、`AppDelegate.openPanel(tab:)`、`IslandHostingView`。

- [ ] **Step 1: PanelRouter + 面板消费(Menu.swift)**

```swift
// MARK: - 面板路由(岛 → 面板 tab 跳转)

/// 岛行点击 → 面板落在指定 tab。App 层原本没有跨视图状态通道,
/// 用一个只有单字段的 ObservableObject 承载,避免给 TokenPlanModel 加 UI 状态。
@MainActor
final class PanelRouter: ObservableObject {
    static let shared = PanelRouter()
    /// 待切换目标;面板消费后置 nil。
    @Published var pendingTab: ProviderTab?
    func open(tab: ProviderTab) { pendingTab = tab }
    private init() {}
}
```

`TokenPlanMenuContent` 内加属性与消费:

```swift
    @ObservedObject private var router = PanelRouter.shared
```

```swift
        .onAppear { consumePendingTab() }
        .onChange(of: router.pendingTab) { _, _ in consumePendingTab() }
```

```swift
    /// 消费岛的行点击路由:目标 tab 可用则切过去,不可用(被停用/未配置)则忽略。
    private func consumePendingTab() {
        guard let tab = router.pendingTab else { return }
        if availableTabs.contains(tab) { selectedTab = tab }
        router.pendingTab = nil
    }
```

- [ ] **Step 2: AppDelegate.openPanel(tab:)**

```swift
    /// 岛行点击/重登:写路由 → 收起岛并抑制展开 → 打开面板(与状态项点击同一路径)。
    func openPanel(tab: ProviderTab) {
        PanelRouter.shared.open(tab: tab)
        guard let popover, let button = statusItem?.button else { return }
        IslandOverlayController.shared.collapseNow()
        IslandOverlayController.shared.setSuppressed(true)
        if !popover.isShown {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
```

- [ ] **Step 3: sink 注入(App.swift init,紧随 `renderTooltipSink` 之前)**

```swift
        // 灵动岛点行 → 打开面板并落在对应 tab(岛活在独立覆盖面板里,拿不到 AppDelegate)
        IslandOverlayController.shared.openPanelSink = { kind in
            guard let tab = ProviderTab(kind: ProviderKind.from(menuBarColumnKind: kind)) else { return }
            (NSApp.delegate as? AppDelegate)?.openPanel(tab: tab)
        }
```

- [ ] **Step 4: 事件开关 + 白名单赋值(IslandOverlay.swift)**

`IslandHostingView` 已在 Task 5 定义好,这里只接事件开关与白名单。展开处(`panel.setFrame` 之后)

```swift
        // 展开态才吃事件(外扩 6pt 兼容 spring 回弹);收起态整窗透传
        state.collapsedRect = relRect(pill, in: panelRect)
        state.expandedRect = relRect(expandedRect, in: panelRect)
        panel.setFrame(panelRect, display: true)
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        (panel.contentView as? IslandHostingView)?.hitRect = state.expandedRect.insetBy(dx: -6, dy: -6)
        panel.orderFrontRegardless()
```

`collapse(animated:)` 与 `collapseNow()` 各加:

```swift
        panel?.ignoresMouseEvents = true
        (panel?.contentView as? IslandHostingView)?.hitRect = nil
```

- [ ] **Step 5: 构建**

Run: `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk swift build --product AliyunTokenBar 2>&1 | tail -5`
Expected: `Build complete!`

- [ ] **Step 6: 提交**

```bash
git add Sources/AliyunTokenBar/Menu.swift Sources/AliyunTokenBar/AppDelegate.swift Sources/AliyunTokenBar/App.swift Sources/AliyunTokenBar/IslandOverlay.swift
git commit -m "feat(island): 行可点跳面板 tab(白名单 hitTest + PanelRouter)"
```

---

### Task 7: 设置页「余额告急下限」

**Files:**
- Modify: `Sources/AliyunTokenBar/Settings.swift`(`AppearanceSettingsPage`)

**Interfaces:**
- Consumes: Task 3 的 `model.moneyFloor`。

- [ ] **Step 1: 更新灵动岛的说明文案(旧文案描述的是聚焦列语义)**

```swift
            } footer: {
                Text("灵动岛:菜单栏常驻一枚黑色胶囊,汇总全部已启用数据源的健康度(需处理/告急/预警计数);鼠标悬停即弹簧展开为剩余口径实时卡片,点某一行直接跳到该数据源标签页,点胶囊仍打开主面板。")
                    .font(.system(size: 10))
            }
```

- [ ] **Step 2: 新增余额下限设置项(「面板」Section 之前)**

```swift
            Section {
                HStack {
                    Text("余额告急下限")
                    Spacer()
                    TextField("", value: $model.moneyFloor, format: .number)
                        .frame(width: 70)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                    Text("¥").foregroundStyle(.secondary)
                }
                Text("判定对象:DeepSeek 余额、MiMo 余额(「今日花费」不参与)。填 0 关闭余额判定。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            } header: {
                Text("灵动岛")
            }
```

- [ ] **Step 3: 构建 + 目测**

Run: `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk swift build --product AliyunTokenBar 2>&1 | tail -3`
Expected: `Build complete!`;设置 → 外观 → 灵动岛 出现「余额告急下限 ¥」并能输入

- [ ] **Step 4: 提交**

```bash
git add Sources/AliyunTokenBar/Settings.swift
git commit -m "feat(island): 设置页新增余额告急下限(默认 ¥50,0=关闭)"
```

---

### Task 8: 构建 + Verify + 实机安装 + 手测

**Files:** 无代码改动(只验证与记录)

- [ ] **Step 1: 全量逻辑验证**

Run: `swift run Verify 2>&1 | tail -3`
Expected: `ALL PASS`

- [ ] **Step 2: 实机安装交付**

Run: `bash packaging/install-update.sh`
Expected: 打印目标版本 → `Build complete` → 退出旧实例 → 替换 `/Applications/CodingTokenBar.app` → 重启成功

- [ ] **Step 3: 手测清单(逐条对照 spec §5)**

1. 胶囊显示「一切正常」或「N 项告急/预警/需处理」,圆点颜色随最严重类别(全正常时文字为白)。
2. 悬停展开,头部 chip 与胶囊文案一致,行内每段都是「剩 x%」,最紧的源排最上。
3. 正常态:真实数据核对一处(Kimi 周已用 78% → 「周 剩 22%」)。
4. 行 hover 高亮可见;点某一行 → 面板打开并停在该源 tab(不是第一个 tab)。
5. 点胶囊本体仍能打开主面板(白名单没吃掉胶囊区域)。
6. 岛与主面板不重叠、不抢焦点;鼠标移开自动收起。
7. 老样式回归:切换到「迷你表格/云朵/极简/本机」,显示与 tooltip 文案与改动前一致。
8. 余额下限:设成高于当前余额 → 该行告急、胶囊计数 +1;设 0 → 计数回落。
9. 退出某源登录(如设置里清空 Kimi 凭据)→ 该源行出现「重登」徽标、胶囊「需处理」+1。
10. 展开卡 280pt 宽下无截断/错位(「重登」徽标与剩余文案不挤)。

无法自动化(悬停触发的展开/行点击)由用户手测确认;截图核验按全宽菜单栏截取。

- [ ] **Step 4: 记录验收结果(可选提交)**

```bash
git commit --allow-empty -m "chore(island): 实机验收记录(v<版本> 已装,手测 1-10 通过)"
```

---

### Task 9: 文档

**Files:**
- Modify: `CLAUDE.md`(新增岛语义小节)

- [ ] **Step 1: CLAUDE.md 增补**

在菜单栏相关小节后追加(与项目既有风格一致:版本 + 语义 + 坑):

```markdown
- **灵动岛汇总语义(v1.0.96)**:收起态胶囊 = **全源健康度计数**(需处理 > 告急 > 预警),
  判定在 Core(`MenuBarTable.state/islandHealth/islandHealthText`):剩余 ≤20% 预警、≤10% 告急
  (已用 80/90 的镜像,阈值不新增),余额低于设置下限(默认 ¥50,0=关)记告急,
  鉴权类失败记「需处理」(网络/解析类不算,避免抖动噪声);展开卡改**剩余口径** + 紧迫度排序,
  行可点 → `PanelRouter.pendingTab` → 面板落在该源 tab。旧「单列聚焦」胶囊已废
  (`islandFocus` 仅保留函数与断言,岛不再调用)。覆盖面板宿主换成 `IslandHostingView`,
  `hitTest` 只在展开卡矩形内响应——**整窗收事件会让点胶囊打不开主面板**(旧实现全窗透传)。
  面板卡片与其余 scheme 一律保持已用%,只有岛内是剩余口径。
```

- [ ] **Step 2: 提交**

```bash
git add CLAUDE.md
git commit -m "docs(island): CLAUDE.md 记录岛汇总语义与 hitTest 白名单坑"
```

---

## Spec 偏差记录(实现期已确认的微调)

1. **多类文案去量词**:spec 表里的 `{n} 告急 · {m} 项需处理` 量词不齐,统一为 `1 需处理 · 1 告急`(单类仍带「项」),顺带省菜单栏宽度。spec 已同步更新。
2. **全正常时文字白色**:只有圆点用绿色,避免菜单栏常年挂一条绿字。spec 已同步更新。
3. **不做 `attentionReason` 文案**:岛上只需一个固定「重登」入口,具体原因由面板卡片承担;`needsAttention: Bool` 单字段足够。spec 已同步更新。
4. **不做「点重登 → 直接弹登录窗」**:落该源 tab,登录入口就在卡片首屏,避免误触(spec 原文即如此,这里只是明确实现为同一跳转路径)。
5. **状态色与剩余文案不落 `ATBUsageKit`**:`ATBUsageKit` 是面板组件库,岛是独立覆盖面板,两者共用的只有「状态 → 颜色」一处,落在 `IslandOverlay.swift` 的 `IslandStateColor`;剩余文案是 Core 纯函数 `MenuBarTable.remainingText`(Verify 可断言)。这样避免岛反向依赖面板组件库。

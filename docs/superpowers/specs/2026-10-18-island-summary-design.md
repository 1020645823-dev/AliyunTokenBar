# 灵动岛汇总形态 + 岛↔面板联动 设计(2026-10-18)

**背景**:v1.0.95 的灵动岛(工作区未提交)收起态是「聚焦列」单选 —— 取风险最高/占比最高的那一列,胶囊印它的主行值。实测暴露语义缺陷:胶囊印主行,而选中依据是该列两个窗口的最高值。用本机 `history.json` 1000 条真实快照复算,**81% 的快照里「胶囊主值 ≠ 决定它被选中的那个值」**(典型:胶囊「K 0%」,而 Kimi 被选中是因为周窗口已用 78%),风险色也跟着按主值丢失。

**本设计**:把岛从「单列聚焦」改成**全局汇总的快速 insights** —— 胶囊 = 所有被监控源的**健康度计数**,悬停展开卡 = 全源**剩余口径**列表(紧迫度排序、行可点),详情仍回原来的 tab 页。菜单栏老样式(迷你表格/云朵/极简/本机)完全不变,岛只是 scheme 之一。

**决策记录**(2026-10-18 与用户逐条确认):

| # | 决策项 | 结论 |
|---|---|---|
| 1 | 胶囊汇总口径 | **健康度计数**(告急/预警/需处理 的项数),不做跨源百分比平均 |
| 2 | 「剩余视角」覆盖范围 | **岛内统一剩余**;面板 tab 卡片继续用已用% |
| 3 | 岛与面板的融合 | **岛行可点 → 跳到对应 tab**;面板不新增「总览」tab |
| 4 | 计数范围 | 额度类百分比源(恒)+ 余额类金额(需阈值)+ 未登录/取数失败;**本机 CPU/内存不进计数**(仍显示行) |
| 5 | 展开卡排序 | **紧迫度优先**(打破旧的固定列序) |
| 6 | 胶囊文案 | 文字方案 A(「1 告急 · 1 项需处理」),不用点阵/只显一类 |
| 7 | 余额下限 | 全局单值设置项,**默认 ¥50**,0 = 不参与 |
| 8 | 旧胶囊「最紧一项%」 | 不加子选项(YAGNI) |

---

## 1. 语义定义

### 1.1 状态与判定

每个**列**(= 一个数据源,一列可能含两个窗口)产出一个状态,取该列最严重者:

| 状态 | 判定 |
|---|---|
| `needsAction`(需处理) | 该源**鉴权类**失败:未登录 / 登录过期 / 被拒(模型层按登录态给出)。纯网络超时不算(避免网络抖动让胶囊常年报「需处理」);此时沿用上次有效数据 |
| `critical`(告急) | 任一窗口剩余 ≤ 10%(等价已用 ≥ `ThresholdConfig.critical`,默认 90);或余额 < `moneyFloor` |
| `warning`(预警) | 任一窗口剩余 ≤ 20%(等价已用 ≥ `ThresholdConfig.warning`,默认 80) |
| `ok`(正常) | 其余 |

- 阈值**不新增配置**:沿用现有 `ThresholdConfig(warning: 80, critical: 90)`,岛用其剩余镜像(剩余 = `100 - 已用`,`band(for:)` 的 `>=` 语义保持一致:已用 90 → 剩 10 → 告急)。
- **余额类判定只针对「余额」字段**:DeepSeek 余额(`deepSeekBalance.totalBalance`)、MiMo 余额(`mimoUsage.balance.balance`)。「今日花费」不参与。单档:余额 < `moneyFloor` → 告急(不设余额预警档,需要时再加第二阈值)。
- `moneyFloor == 0` → 余额类完全不参与判定与计数。
- **列集合沿用现状**:`menuBarColumns()` 的输出(已启用且(已配置或出错或有数据))。停用的源既不出行也不计数;从未配置过的源不出现(它不在监控列表里)。

### 1.2 剩余口径(仅岛内)

- 展示层换算:`剩余 = 100 - pct`(pct 口径不变,避免动 Core 的已用语义)。
- 文案:`剩 22%`(主值与次值同口径);无 pct 的窗口=`—`;金额窗口仍显示金额(不换算)。
- 展开卡头部固定一行小字 **「口径:剩余」**,避免与面板的已用% 混淆。

### 1.3 计数与胶囊文案

- 计数单位 = 列(源),不是窗口(Kimi 周剩 22% + 5h剩 100% → 该源记 1 项预警)。
- 优先级:`needsAction` > `critical` > `warning` > `ok`。
- 文案(纯函数,Verify 可断言):

| 情形 | 文案 | 点色 |
|---|---|---|
| 全正常 | `一切正常` | 绿 |
| 仅预警 | `{n} 项预警` | 橙 |
| 仅告急 | `{n} 项告急` | 红 |
| 仅需处理 | `{n} 项需处理` | 蓝紫 |
| 两类同现 | `{n} 需处理 · {m} 告急`(按严重度降序,最多两类;**多类同现时去量词**以省菜单栏宽度) | 最高类别色 |

- 三类同现时第三类省略为 `+{n}`(例:`1 需处理 · 1 告急 +1`)。
- 全正常时**文字用白色、只有圆点是绿的**(避免菜单栏常年挂一条绿字);告急/预警/需处理时文字取该类别色。
- 胶囊宽度从当前约 52pt 增至约 100pt(菜单栏拥挤时依赖 v1.0.45 的自愈机制;必要时再启用紧凑文案后备)。

### 1.4 展开卡行内容与排序

- 头部:`CodingTokenBar` 字标 + 与胶囊**同一套**计数 chip + `口径:剩余`。
- 行:`[品牌 logo 15pt][名称 52pt][窗口段: 主标签 剩 x% · 次标签 剩 y%][需处理行→右侧「重登」]`,行高 21pt 不变。
- 行底部 2pt 剩余条(按该源最紧窗口的剩余,颜色随状态),不占横向空间。
- 排序:`needsAction` → `critical` → `warning` → `ok`;同级按剩余升序(最紧在上);再同级按固定列序(阿里云最前)。金额类无 pct → 按状态分档后置于该档末尾。
- 展开卡宽度 260 → **280**(「剩」字与「重登」按钮所需),面板帧公式(`IslandMetrics`)同步;高度公式不变。

## 2. 交互

| 动作 | 行为 |
|---|---|
| 鼠标进入胶囊 | 现状:弹簧展开实时卡(不变) |
| 行 hover | 行高亮 + 手型光标 |
| 点击行 | 岛立即收起 → 主面板打开并**选中该源的 tab** |
| 需处理行「重登」 | 落该源 tab 并高亮其重登入口(**不**自动弹登录窗,避免误触) |
| 鼠标离开 | 现状:0.1s 轮询 `keepRect` 收起(判定区域不变,点击不会误收起) |
| 主面板打开期间 | 现状:`setSuppressed(true)` 不展开 |

**技术前提**:岛覆盖面板当前 `ignoresMouseEvents = true`(全窗透传)。**不能简单整窗放开**——覆盖面板叠在状态项之上,一旦整窗吃事件,点胶囊就再也打不开主面板。做法:宿主视图换成 `IslandHostingView`(`NSHostingView<IslandRootView>` 子类),`hitTest` 只在**展开卡矩形内**(外扩 6pt 兼容 spring 回弹)返回自身、其余返回 nil 透传;展开时 `ignoresMouseEvents = false` + `acceptsMouseMovedEvents = true`(否则行 hover 不亮),收起/`collapseNow` 恢复 `true` 并清空白名单矩形。面板保持 `.nonactivatingPanel` 不抢激活。

## 3. 实现面(逐文件)

### Core(`Sources/AliyunTokenBarCore/MenuBarTable.swift`)

```swift
// 值:新增金额原始值(金额列判阈值用;百分比列恒 nil)
public struct MenuBarTableValue {
    public let text: String
    public let pct: Int?
    public let amount: Double?      // 新增
}

// 列:新增需处理标记(原因文案由面板卡片承担,岛上只给固定「重登」入口)
public struct MenuBarTableColumn {
    public var needsAttention: Bool = false   // 新增(构造后按需置位)
}

public enum ColumnState: Int, Comparable { case ok, warning, critical, needsAction }

extension MenuBarTable {
    // columns(...) 新增两个参数
    //   moneyFloor: Double = 0            // 0 = 余额类不参与
    //   needsAttention: Set<String> = []  // ProviderKind.rawValue 集合,模型层按登录态给
    static func state(_ col:, config:, moneyFloor:) -> ColumnState          // 列状态(取最严重)
    static func remainingText(_ v: MenuBarTableValue) -> String            // "剩 22%" / "—"
    static func islandHealth(columns:config:moneyFloor:) -> IslandHealth    // needAction/critical/warning/total
    static func islandHealthText(_ h: IslandHealth) -> String              // 胶囊与 chip 共用文案
    static func islandRows(columns:config:moneyFloor:) -> [MenuBarTableColumn]  // 紧迫度排序
}
```

- `islandRiskCounts` 由 `islandHealth` 取代(旧函数删除或改名为内部实现,断言一并更新)。
- `islandFocus` 不再被岛渲染调用;函数与断言保留(Core 无副作用,留作未来子选项复用),文档注明「岛不再使用」。

### App 层

| 文件 | 改动 |
|---|---|
| `App.swift` | `islandPillImage` 改渲染健康度胶囊(点 + 文案,按最严重类别着色);移除 `islandFocus` 调用;状态色统一走 `IslandStateColor.color(_:)` |
| `IslandOverlay.swift` | `IslandState` 增 `health`/`rows`;`IslandRow` 改剩余口径 + 底条 + hover + 点击回调;展开/收起切换 `ignoresMouseEvents`;「重登」回调 |
| `Menu.swift` | 新增 `PanelRouter`(`@Published pendingTab: ProviderTab?` + `open(tab:)`);`TokenPlanMenuContent.selectedTab` 改由 router 驱动(切换入口保留手点) |
| `AppDelegate.swift` | 打开 popover 的入口接受 `targetTab`;岛点击 → `collapseNow()` + `setSuppressed(true)` → 打开面板 |
| `Settings.swift` | 新增「余额告急下限(¥)」:默认 50,0 = 不参与,附说明文案(判定对象=DeepSeek/MiMo 余额) |
| `ATBUsageKit.swift` | 新增剩余文案与状态色 helper(岛与面板卡片共用同一套语义色,避免两处色值漂移) |
| `TokenPlanModel` | 暴露 `moneyFloor` 与「需处理源集合」(按现有 authState / provider error 推导) |

### Verify(`Sources/Verify/main.swift`)

断言清单(全部无 UI):

1. 状态判定:已用 90/80/79 → 告急/预警/正常;剩余换算 78 → `剩 22%`。
2. 列状态取两窗口最严重(Kimi 5h剩100% + 周剩22% → 预警)。
3. 余额:MiMo 余额 ¥30 + floor ¥50 → 告急;floor 0 → 不参与;「今日花费」不参与。
4. 需处理:鉴权类失败的源 → `needsAction`,且优先级高于告急(同列既超阈值又未登录 → 需处理);**纯网络失败且有历史数据 → 不算**需处理。
5. 计数与文案:0/1/2/3 类组合、三类同现的 `+n` 省略、点色取最高类别。
6. 排序:需处理 → 告急 → 预警 → 正常;同级剩余升序;再同级固定列序。
7. 回归:老 scheme 的 `columns()` 输出与 tooltip 文案不变(新参数默认值不改变旧行为)。

## 4. 风险与回退

| 风险 | 说明 | 回退 |
|---|---|---|
| R1 非激活面板收点击/hover | 白名单 `hitTest` 已消掉「整窗吃事件挡住胶囊」的风险,但非激活面板对行的 hover 高亮与点击投递仍需实机验证(`acceptsMouseMovedEvents` 在非 key 窗口上的行为要现场确认) | 岛退回**纯展示**:点击整张卡 → 打开面板并落在**最紧的源 tab**(动线保留,丢的是逐行跳转) |
| R2 胶囊变宽(~100pt) | 菜单栏拥挤时可能被系统隐藏/停车 | 已有 v1.0.45 自愈;必要时加「胶囊文案:详细/紧凑(只显最严重一类)」设置项 |
| R3 口径混淆 | 岛剩余 vs 面板已用 | 头部「口径:剩余」+ 行内「剩」字 |
| R4 岛与 popover 重叠 | 现状已用 `setSuppressed` 处理 | 点击跳转时先 `collapseNow()` |
| R5 余额语义 | 判的是余额不是花费;用户不设下限(0)时余额类完全不参与 | 设置项文案写明判定对象 |

## 5. 验收标准(实机,交付前必须 `install-update.sh` 装到已装 .app)

1. 胶囊与展开卡头部计数一致,点色随最严重类别;全正常时显示 `一切正常`。
2. 真实数据核对:Kimi 周剩 22%(已用 78)不计入告急,若某项剩 ≤ 10 则计入告急。
3. 行 hover 高亮、点击命中准确(行高 21pt 不许串行)。
4. 点击行 → 面板打开并落在正确 tab;Kimi 行 → Kimi tab(而非回退到第一个 tab)。
5. 需处理行「重登」→ 落 tab 且高亮重登入口,不自动弹登录窗。
6. 岛与主面板不重叠、不抢焦点、移开鼠标正常收起。
7. 老 scheme(迷你表格/云朵/极简/本机)行为与 tooltip 文案完全不变。
8. 余额下限:设为高于当前余额 → 该行告急且胶囊 +1;设为 0 → 不参与。
9. 退出某源登录 → 该源显示「需处理」,胶囊计数 +1。
10. 展开卡宽度 280 下无截断、无错位(「剩」字与「重登」按钮不挤)。

## 6. 明确不做(YAGNI)

- 面板新增「总览」tab(岛已是汇总层)。
- 岛内保留旧「最紧一项%」胶囊子选项。
- 跨源百分比加权平均、货币换算/年化、余额换算成百分比。
- 面板卡片口径切换(面板继续已用%)。
- 本机 CPU/内存进健康度计数。

## 7. 未决问题

无。所有条目已在 2026-10-18 会话中逐条确认。

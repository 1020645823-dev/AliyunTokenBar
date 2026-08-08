# 明暗一致性修复 + 设置面板重设计

日期:2026-08-08
状态:已获用户批准(对话中确认 "ok")

## 背景与问题

用户反馈两点:

1. 显示面板(弹层 popover)的浅色/深色需与 macOS 系统外观保持一致。
2. 设置面板 UI/UX 太原始:裸 `Form` 塞进 420×620 `NSPanel`,7 个 Section 一字排开,无导航、无层级。

### 审计发现(代码实证)

主题机制本身正确:`ThemeManager`(App.swift:84)用 `NSApp.appearance` 全局注入,弹层/设置窗/登录窗均继承;语义色(labelColor / windowBackgroundColor / controlBackgroundColor / separatorColor)自动跟随系统。菜单栏图标明暗走独立链路(全局域 `AppleInterfaceStyle`,AppDelegate.swift:82),**本次不动**。

真实缺陷:

| 位置 | 问题 |
|---|---|
| `Menu.swift:833` | Kimi 订阅池分段条 Work 段 `Color.black.opacity(0.88)`,深灰卡片上近不可见 |
| `Menu.swift:853` | 该分段条图例硬编码 `.black`,深色下消失 |
| `Menu.swift:844` | 剩余段 `Color.black.opacity(0.08)`,深色下无层次 |
| `Sparkline.swift:25` | 趋势占位条 `Color.black.opacity(0.08)`,同上 |
| `Menu.swift:107` 等 | 弹层用不透明 `atbPanelBackground`(windowBackgroundColor)盖住 NSPopover 原生 vibrant 材质,丢失 macOS popover 应有的半透明质感 |

## 设计

### Part 1 — 明暗一致性修复

1. `Menu.swift:833` Work 段 `.black.opacity(0.88)` → `Color.primary`
2. `Menu.swift:853` 图例 `.black` → `.primary`(`KimiSubscriptionLegend` 调用点传参)
3. `Menu.swift:844` 剩余段 `.black.opacity(0.08)` → `Color.primary.opacity(0.10)`
4. `Sparkline.swift:25` 占位条 → `Color.primary.opacity(0.08)`
5. 弹层透出原生材质:
   - 删 `TokenPlanMenu.body` 的 `.background(Color.atbPanelBackground)`(Menu.swift:107)
   - 删 `OpenCodeCard` / `KimiCodeCard` / `SystemProcessesCard` 尾部的 `.background(Color.atbPanelBackground)`(Menu.swift:689、775、976)
   - SwiftUI `ScrollView` 默认透明,删除后透出 NSPopover 自带 vibrant 材质,自动跟随系统明暗;app 强制主题时走 `NSApp.appearance`,行为与修复前一致
   - 卡片保留 `controlBackgroundColor`:vibrant 材质上系统自动调配,为原生质感来源
   - 登录/AKSK 窗口(OpenCodeLoginView / KimiLoginView / AliyunAKSKInputView)是 sheet/NSPanel,保留 `atbPanelBackground` 不动

### Part 2 — 设置面板重设计(macOS 系统设置式)

`SettingsView` 由单列 `Form` 改为 `NavigationSplitView`(macOS 13+,项目部署目标 .v13 满足):

- **侧边栏**(宽 ~170):`List` 四项,图标+标签,选中高亮
  - `gearshape` 通用、`paintpalette` 外观、`bell` 通知、`cloud` 服务
- **详情页**:每项一个 `Form`(保留原生控件分组样式,控件不重新造轮子;质感来自导航结构)
  - **通用**:开机自动启动、刷新间隔
  - **外观**:主题、菜单栏样式、显示本机 CPU/内存、显示用量趋势线(原"面板趋势"并入)
  - **通知**:接近上限时通知 + 提示/严重阈值(条件展示逻辑原样迁移)
  - **服务**:阿里云 AK/SK / Kimi / OpenCode 三张**状态卡片**(状态图标 + 连接描述 + 操作按钮),替代纯 Form 行;`sheet`(OpenCodeLoginView / KimiLoginView)挂载点随该页迁移
- **窗口**:`SettingsWindow` NSPanel 420×620 → ~620×480,minSize 相应调整;标题保留
- **不变量**:`ThemeManager.didSet` 即时切换机制、`LaunchAtLoginManager`、阈值 `Binding` 写法、通知授权 `onChange` 逻辑全部原样保留

### Part 3 — 验证

- `swift build` 通过;`Verify` target 现有断言全绿(本次为视图层改动,无新纯函数可断言,不加新断言)
- 手动视觉验收清单(系统外观切换浅色/深色各一遍):
  - 弹层:毛玻璃材质透出、文字对比度正常
  - Kimi tab:订阅分段条两段+图例在两模式下均清晰可辨
  - sparkline 占位条两模式可见
  - 设置窗:四页切换、服务页三张状态卡、主题切换即时生效

## 被否掉的备选

- **顶部工具栏标签页**:经典但老气,不如侧边栏现代
- **单列精修(仅卡片化)**:7 段同屏的信息密度问题没解决
- **popover 保留不透明背景(换 underPageBackgroundColor)**:仍不如原生材质
- **菜单栏图标链路改动**:已由全局域检测覆盖,工作正常,不动

## 风险

- 删除弹层背景后若透出失败会看到异常底色 → 以视觉验收清单为准;兜底方案是 `.background(.ultraThinMaterial)`
- `NSPanel` + `NavigationSplitView` 组合在 macOS 13 上的侧边栏折叠行为 → 锁定 `navigationSplitViewColumnWidth`,禁止折叠

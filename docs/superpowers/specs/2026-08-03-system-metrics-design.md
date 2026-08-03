# 本机 CPU/内存占用显示 — 设计文档

日期:2026-08-03
状态:已确认(逐节评审通过)

## 目标

在 AliyunTokenBar 菜单栏图标中显示本机 CPU 占用与内存占用,与现有套餐用量共存。默认开启,可在设置关闭;提供"仅 CPU/内存"专用显示样式。

## 背景约束

- 显示位置:**仅菜单栏图标**(用户明确选择,面板不动)。
- 刷新节奏:CPU/内存 30 秒采样一次,与套餐用量(10 分钟)互不影响。
- 内存口径:**对齐活动监视器**"已使用内存"(active + wired + compressed),避免数字差异被误认为 bug(项目历史教训:精度显示偏差)。
- 项目无 XCTest(CLT 环境),测试走 Verify 可执行目标 + Swift 断言。

## 架构

```
SystemMetricsMonitor (Core, 新增)
  ├─ 30s Timer (@MainActor)
  ├─ CPU: host_processor_info(PROCESSOR_CPU_LOAD_INFO) 两次采样差值
  ├─ 内存: host_statistics64(HOST_VM_INFO64) + ProcessInfo.physicalMemory
  └─ @Published cpuPercent / memoryPercent (Int?, 0-100)
        │
        ▼ (executable 层订阅,调 TokenPlanModel.prerenderIcon())
MenuBarTextRenderer.image(..., cpu:, memory:) — 各样式追加段
        ▼
NSStatusItem.button.image (现有 renderedIcon 管线)
```

数据采样是纯数据逻辑 → 放 Core(`SystemMetricsMonitor` 新文件);渲染与开关接线 → executable 层。与现有 Provider 服务(BlUsageService 等)同层同模式。

## 数据层: SystemMetricsMonitor

新文件 `Sources/AliyunTokenBarCore/SystemMetricsMonitor.swift`:

```swift
@MainActor
public final class SystemMetricsMonitor: ObservableObject {
    public static let shared = SystemMetricsMonitor()
    @Published public private(set) var cpuPercent: Int?      // 过去 30s 平均 CPU,0-100
    @Published public private(set) var memoryPercent: Int?   // 内存占用,0-100
    public func start()   // 立即采样基线 + 启动 30s Timer
    public func stop()    // 停 Timer,清空两个 published 值(开关关闭时)
}
```

### CPU 采样

- `host_processor_info(PROCESSOR_CPU_LOAD_INFO)` 取全部核心 user/system/nice/idle ticks,按核心求和。
- 每次 Timer 触发时与上一次采样做差值:
  - `busy = (user + system + nice) 差值`, `total = busy + idle 差值`
  - `percent = busy / total * 100`(四舍五入到 Int;total=0 时按 0 处理避免除零)
- 数字含义 = "过去 30 秒平均 CPU",天然平滑,与 30s 刷新节奏自洽。
- `start()` 先取基线,第一个 30 秒即可出数字,不空白。
- 采样/计算拆成静态纯函数以便测试:
  - `static func sampleCPUTicks() -> CPUTicks?`(user/system/nice/idle 聚合)
  - `static func cpuPercent(previous: CPUTicks, current: CPUTicks) -> Int`

### 内存采样

- `host_statistics64(HOST_VM_INFO64)` 取 vm_statistics64;页面大小用 `vm_kernel_page_size`。
- `used = (active_count + wire_count + compressor_page_count) × pageSize`
- `total = ProcessInfo.processInfo.physicalMemory`
- `percent = used / total × 100`,钳制 0-100;total=0 时返回 nil。
- 纯函数:`static func memoryUsedPercent(active: UInt64, wired: UInt64, compressed: UInt64, pageSize: UInt64, totalBytes: UInt64) -> Int?`,采样器喂真实值。
- 对齐活动监视器口径(Stats/MenuMeters 同款公式)。

依赖:零新依赖,纯 Mach/Darwin API。开关关闭时 Timer 不启动,零开销。

## 菜单栏显示格式

`MenuBarTextRenderer.image(...)` 新增参数 `cpu: Int?, memory: Int?`(nil = 不显示)。统一文本格式 `C{cpu}% {·} M{mem}%`(compact 行内用空格分隔、其余用 `·`),monospacedDigit 防抖动,模板图机制不变。

| 样式 | 追加方式 |
|------|----------|
| cloudPercent | 尾部 `C23% · M58%`(与现有 OpenCode/Kimi 段同款 Spacer 分隔) |
| compact | 现有行下方加一行 `C23% M58%`(行内空格分隔、无 `·`,贴近现有双行密度);height frame 由 20 放宽以容纳新增行(Kimi 行存在时共 4 行) |
| singleLine | 尾部 `· C23% M58%` |
| iconOnly | **不追加**,保持纯进度环(避免破坏"仅图标"语义) |
| systemStats(新增) | 只显示 `C23% · M58%` |

compact 高度放宽后需**实测确认菜单栏不裁切**(项目已有 visual verification 先例:61eb897 提交);若 4 行仍裁切,退路是把 CPU/内存合并进现有行。此项列入实施步骤。

**不变色**:CPU/内存数字不套阈值变色,保持模板图纯净。

## 设置与开关

- Settings.swift "外观" Section 新增 Toggle **"显示本机 CPU/内存"**,默认**开**。
- 持久化:`TokenPlanModel.systemStatsEnabled`(`@Published` + didSet 写 UserDefaults,key `systemStatsEnabled`,与 `sparklineEnabled` 同款模式)。切换立即触发重渲染。
- "菜单栏样式" Picker 的 `MenuBarDisplayScheme` 新增 `.systemStats`,显示名"本机 CPU/内存"。

**开关 × 样式组合逻辑**:
- 开关关 → 所有样式不显示 CPU/内存(包括 systemStats,回退云朵图标)。
- 开关开 + 普通样式 → 追加段。
- 开关开 + systemStats → 只显示 CPU/内存。

## 渲染触发链路

1. `AppDelegate.applicationDidFinishLaunching`:开关开 → `SystemMetricsMonitor.shared.start()`。
2. App.init:订阅 `$cpuPercent`/`$memoryPercent` → `TokenPlanModel.shared.prerenderIcon()`(复用现有管线;renderIconSink 闭包内直接读 `SystemMetricsMonitor.shared`)。
3. `systemStatsEnabled` didSet:开 → start + 重渲染;关 → stop + 重渲染。

## 测试(Verify 目标)

`Sources/Verify/main.swift` 追加断言:

1. **CPU 差值**:构造前后 ticks 验证百分比;全 idle → 0%;两次采样相同(total=0)→ 0 不除零;钳制 0-100。
2. **内存公式**:已知 active/wired/compressed/pageSize/totalBytes → 验证结果;totalBytes=0 → nil。
3. 不测 Timer/时序(避免慢测试)。

运行:`swift run Verify`(与现有验证同一入口)。

### 视觉验证(提交前必做)

构建后实际运行 app,确认:
- compact 样式新增行(最多 4 行)在菜单栏完整可见、不裁切;
- 五个样式 + 开关开/关各组合渲染正常;
- 数值每 30 秒更新一次,CPU 数字平滑不跳变;
- 内存数字与活动监视器"已使用内存"大体一致(±2%)。

## 排除项(YAGNI)

- 面板内不显示 CPU/内存(用户明确只要菜单栏)。
- 不做历史曲线/告警(与用量告警体系无耦合需求)。
- iconOnly 样式不追加文字。
- CPU/内存不参与阈值变色。

# 本机 CPU/内存菜单栏显示 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在菜单栏图标中显示本机 CPU 与内存占用(30 秒刷新,可开关,新增"本机 CPU/内存"专用样式)。

**Architecture:** Core 层新增 `SystemMetricsMonitor`(30s Timer + Mach API 采样,纯函数可测);executable 层 `MenuBarTextRenderer` 各样式追加 C/M 段;AppDelegate 订阅开关与采样值,经现有 `renderedIcon` 管线重渲染图标。

**Tech Stack:** Swift 5.9 / SwiftUI / Mach-Darwin API(`host_processor_info` / `host_statistics64`),零新依赖,`swift run Verify` 验证。

**Spec:** `docs/superpowers/specs/2026-08-03-system-metrics-design.md`

## Global Constraints

- 平台 macOS 13+(Package.swift 已定)。
- 零新依赖;禁 spawn 进程(如 `top`/`ps`)采样。
- CPU = 两次采样差值(过去 30 秒平均);内存口径 = active + wired + compressed(对齐活动监视器)。
- 采样间隔 30 秒;开关关闭时 Timer 不运行、published 值清空。
- iconOnly 样式**不追加** C/M;CPU/内存数字**不套阈值变色**。
- 不测 Timer/时序;`swift run Verify` 只跑纯函数。
- 每个 Task 结束必须 `git commit`。
- 注释风格:中文,与现有代码一致(文件头注释说明"为什么")。

---

### Task 1: 数据层 SystemMetricsMonitor + 纯函数测试

**Files:**
- Create: `Sources/AliyunTokenBarCore/SystemMetricsMonitor.swift`
- Test: `Sources/Verify/main.swift`(在 `print(fails == 0 ...)` 行**之前**追加)

**Interfaces:**
- Produces:
  - `public struct CPUTicks: Equatable { user: UInt64, system: UInt64, nice: UInt64, idle: UInt64 }`(public init)
  - `public final class SystemMetricsMonitor: ObservableObject`(@MainActor,`public static let shared`;`@Published public private(set) var cpuPercent: Int?`、`memoryPercent: Int?`;`public func start()`、`public func stop()`;`public static let sampleInterval: TimeInterval = 30`)
  - `public static func sampleCPUTicks() -> CPUTicks?`
  - `public static func cpuPercent(previous: CPUTicks, current: CPUTicks) -> Int`
  - `public static func sampleMemoryPercent() -> Int?`
  - `public static func memoryUsedPercent(active: UInt64, wired: UInt64, compressed: UInt64, pageSize: UInt64, totalBytes: UInt64) -> Int?`
  - Task 2 依赖以上全部类型/签名。

- [ ] **Step 1: 写失败测试**

在 `Sources/Verify/main.swift` 末尾(`print(fails == 0 ...)` 之前)追加:

```swift
// --- SystemMetricsMonitor:CPU/内存纯函数 ---
// CPU 差值:busy +100, total +1000 → 20%
check("cpu delta 20%",
      SystemMetricsMonitor.cpuPercent(previous: CPUTicks(user: 100, system: 100, nice: 0, idle: 800),
                                      current: CPUTicks(user: 200, system: 200, nice: 0, idle: 1600)) == 20)
// 全 idle → 0%
check("cpu all idle -> 0",
      SystemMetricsMonitor.cpuPercent(previous: CPUTicks(user: 100, system: 100, nice: 0, idle: 100),
                                      current: CPUTicks(user: 100, system: 100, nice: 0, idle: 200)) == 0)
// 两次采样相同(total=0)→ 0,不除零
check("cpu same ticks -> 0",
      SystemMetricsMonitor.cpuPercent(previous: CPUTicks(user: 1, system: 1, nice: 1, idle: 1),
                                      current: CPUTicks(user: 1, system: 1, nice: 1, idle: 1)) == 0)
// 计数器回绕(&- 减法):idle 从 UInt64.max 回绕到 0,user 增 1 → busy=1, total=2 → 50%
check("cpu wrap-around safe",
      SystemMetricsMonitor.cpuPercent(previous: CPUTicks(user: 0, system: 0, nice: 0, idle: UInt64.max),
                                      current: CPUTicks(user: 1, system: 0, nice: 0, idle: 0)) == 50)
// 内存:2048 页 × 4096 = 8MB / 16MB → 50%
check("mem 50%",
      SystemMetricsMonitor.memoryUsedPercent(active: 1024, wired: 512, compressed: 512,
                                             pageSize: 4096, totalBytes: 16 * 1024 * 1024) == 50)
// 小占用 → Int 四舍五入为 0%
check("mem small -> 0",
      SystemMetricsMonitor.memoryUsedPercent(active: 1, wired: 1, compressed: 1,
                                             pageSize: 4096, totalBytes: 16 * 1024 * 1024) == 0)
// 钳制:5000 页 × 4096 = 20MB vs 8MB → 244% → 100
check("mem clamp 100",
      SystemMetricsMonitor.memoryUsedPercent(active: 3000, wired: 1000, compressed: 1000,
                                             pageSize: 4096, totalBytes: 8 * 1024 * 1024) == 100)
// total=0 → nil
check("mem zero total -> nil",
      SystemMetricsMonitor.memoryUsedPercent(active: 1, wired: 1, compressed: 1,
                                             pageSize: 4096, totalBytes: 0) == nil)
// 冒烟:本机真实采样必然非 nil
check("smoke sampleCPUTicks", SystemMetricsMonitor.sampleCPUTicks() != nil)
check("smoke sampleMemoryPercent", SystemMetricsMonitor.sampleMemoryPercent() != nil)
```

- [ ] **Step 2: 运行确认失败**

Run: `swift run Verify`
Expected: 编译失败 `cannot find 'SystemMetricsMonitor' in scope`(类型未定义)。

- [ ] **Step 3: 实现 SystemMetricsMonitor**

创建 `Sources/AliyunTokenBarCore/SystemMetricsMonitor.swift`:

```swift
import Foundation
import Combine
import Darwin

/// CPU ticks 聚合(全部核心求和)。两次采样差值 → 百分比。
public struct CPUTicks: Equatable {
    public let user: UInt64
    public let system: UInt64
    public let nice: UInt64
    public let idle: UInt64

    public init(user: UInt64, system: UInt64, nice: UInt64, idle: UInt64) {
        self.user = user; self.system = system; self.nice = nice; self.idle = idle
    }
}

/// 本机 CPU/内存采样器。30 秒一次(与套餐用量 10 分钟互不影响)。
/// CPU = 两次采样差值 → "过去 30 秒平均占用",天然平滑不跳变。
/// 内存口径对齐活动监视器:已用 = (active + wired + compressed) × pageSize。
/// 纯函数(采样/计算)拆出,Verify 目标可测;Timer 时序不测。
@MainActor
public final class SystemMetricsMonitor: ObservableObject {
    public static let shared = SystemMetricsMonitor()

    /// 过去 30 秒平均 CPU 占用(0-100)。start() 后第一个周期即有值;stop() 后为 nil。
    @Published public private(set) var cpuPercent: Int?
    /// 内存已用百分比(0-100,活动监视器口径)。stop() 后为 nil。
    @Published public private(set) var memoryPercent: Int?

    /// 采样间隔(秒)
    public static let sampleInterval: TimeInterval = 30

    private var timer: AnyCancellable?
    private var lastTicks: CPUTicks?

    /// 启动采样:立即取 CPU 基线 + 内存值(第一个 30 秒就能出数字),再按周期推进。
    /// 幂等:已在运行则 no-op。
    public func start() {
        guard timer == nil else { return }
        lastTicks = Self.sampleCPUTicks()
        memoryPercent = Self.sampleMemoryPercent()
        tick()
        timer = Timer.publish(every: Self.sampleInterval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.tick() }
    }

    /// 停止采样并清空数据(开关关闭时调用,零开销)。
    public func stop() {
        timer?.cancel()
        timer = nil
        lastTicks = nil
        cpuPercent = nil
        memoryPercent = nil
    }

    private func tick() {
        if let cur = Self.sampleCPUTicks() {
            if let prev = lastTicks {
                cpuPercent = Self.cpuPercent(previous: prev, current: cur)
            }
            lastTicks = cur
        }
        if let mem = Self.sampleMemoryPercent() {
            memoryPercent = mem
        }
    }
}

// MARK: - 纯函数(Verify 目标可测)

extension SystemMetricsMonitor {
    /// 取全部核心 user/system/nice/idle ticks 并求和。
    /// host_processor_info 失败(非 KERN_SUCCESS)返回 nil。
    public static func sampleCPUTicks() -> CPUTicks? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                         &cpuCount, &info, &infoCount)
        guard result == KERN_SUCCESS, let raw = info else { return nil }
        defer {
            vm_deallocate(mach_task_self_,
                          vm_address_t(UInt(bitPattern: raw)),
                          vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride))
        }
        var ticks = CPUTicks(user: 0, system: 0, nice: 0, idle: 0)
        let buf = UnsafeBufferPointer(start: raw, count: Int(infoCount))
        // 每个核心按 CPU_STATE_MAX 个状态值依次排列;按核心步进,累加四类 ticks
        for i in stride(from: 0, to: buf.count, by: Int(CPU_STATE_MAX)) {
            ticks = CPUTicks(
                user: ticks.user &+ UInt64(buf[i + Int(CPU_STATE_USER)]),
                system: ticks.system &+ UInt64(buf[i + Int(CPU_STATE_SYSTEM)]),
                nice: ticks.nice &+ UInt64(buf[i + Int(CPU_STATE_NICE)]),
                idle: ticks.idle &+ UInt64(buf[i + Int(CPU_STATE_IDLE)])
            )
        }
        return ticks
    }

    /// 两次采样差值 → 0-100 百分比。
    /// 差值用 &- 环绕减法(内核计数器可能回绕,普通减法会 trap)。
    /// total=0(两次采样完全相同)→ 0,避免除零。
    public static func cpuPercent(previous: CPUTicks, current: CPUTicks) -> Int {
        let busy = (current.user &- previous.user)
                + (current.system &- previous.system)
                + (current.nice &- previous.nice)
        let idle = current.idle &- previous.idle
        let total = busy + idle
        guard total > 0 else { return 0 }
        let pct = Double(busy) / Double(total) * 100
        return min(max(Int(pct.rounded()), 0), 100)
    }

    /// 内存已用百分比(对齐活动监视器口径:active + wired + compressed)。
    /// host_statistics64 失败返回 nil。
    public static func sampleMemoryPercent() -> Int? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return memoryUsedPercent(active: UInt64(stats.active_count),
                                 wired: UInt64(stats.wire_count),
                                 compressed: UInt64(stats.compressor_page_count),
                                 pageSize: UInt64(vm_kernel_page_size),
                                 totalBytes: ProcessInfo.processInfo.physicalMemory)
    }

    /// 纯函数:active/wired/compressed 页数 × pageSize = 已用字节 → 0-100 百分比。
    /// totalBytes=0 → nil;结果钳制 0-100。
    public static func memoryUsedPercent(active: UInt64, wired: UInt64, compressed: UInt64,
                                         pageSize: UInt64, totalBytes: UInt64) -> Int? {
        guard totalBytes > 0 else { return nil }
        let used = (active + wired + compressed) * pageSize
        let pct = Double(used) / Double(totalBytes) * 100
        return min(max(Int(pct.rounded()), 0), 100)
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `swift run Verify`
Expected: 末尾输出 `ALL PASS`,且包含 `PASS cpu delta 20%`、`PASS mem 50%`、`PASS smoke sampleCPUTicks` 等新断言(既有断言也全部 PASS)。

- [ ] **Step 5: Commit**

```bash
git add Sources/AliyunTokenBarCore/SystemMetricsMonitor.swift Sources/Verify/main.swift
git commit -m "feat(metrics): SystemMetricsMonitor CPU/内存采样器 + 纯函数测试"
```

---

### Task 2: 显示层 — 开关、新样式、渲染器五样式适配

**Files:**
- Modify: `Sources/AliyunTokenBarCore/TokenPlanModel.swift`(在 `sparklineEnabled` 属性后、`notificationTracker` 前插入开关;在 init 的 sparkline 读取后插入默认值读取)
- Modify: `Sources/AliyunTokenBar/App.swift`(MenuBarDisplayScheme 加 case;MenuBarTextRenderer.image 加参数;cloudPercentImage / compactImage / singleLineImage 追加段;新增 systemStatsImage)
- Modify: `Sources/AliyunTokenBar/Settings.swift`(外观 Section 加 Toggle)

**Interfaces:**
- Consumes: Task 1 的 `SystemMetricsMonitor`(仅 Task 3 用)。
- Produces:
  - `TokenPlanModel.systemStatsEnabled: Bool`(@Published,didSet 持久化到 UserDefaults key `systemStatsEnabled`,默认 true)
  - `MenuBarDisplayScheme.systemStats`(displayName "本机 CPU/内存")
  - `MenuBarTextRenderer.image(scheme:fiveHour:oneWeek:openCodeRolling:openCodeWeekly:kimiWeekly:cpu:memory:thresholdConfig:)` — 新增 `cpu: Int? = nil, memory: Int? = nil` 默认参数,旧调用点无需改
  - Task 3 依赖:renderIconSink 闭包传 `model.systemStatsEnabled ? monitor.cpuPercent : nil` 等。

- [ ] **Step 1: 加开关(模型层)**

`Sources/AliyunTokenBarCore/TokenPlanModel.swift`,在 `sparklineEnabled` 属性块之后插入:

```swift
    /// 菜单栏是否显示本机 CPU/内存(默认开)。
    @Published public var systemStatsEnabled: Bool = true {
        didSet { UserDefaults.standard.set(systemStatsEnabled, forKey: "systemStatsEnabled") }
    }
```

在 init 的 `sparklineEnabled` 读取之后插入:

```swift
        if defaults.object(forKey: "systemStatsEnabled") != nil {
            systemStatsEnabled = defaults.bool(forKey: "systemStatsEnabled")
        }
```

- [ ] **Step 2: 加样式 + 渲染器参数(executable 层)**

`Sources/AliyunTokenBar/App.swift`:

a) `MenuBarDisplayScheme` 加 case 与 displayName(iconOnly 之后):

```swift
    case iconOnly      // 仅图标(进度环)
    case systemStats   // 仅本机 CPU/内存

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .cloudPercent: return "云朵 + 百分比(默认)"
        case .compact: return "5h/7d 双行"
        case .singleLine: return "单行(35%·61%)"
        case .iconOnly: return "仅图标"
        case .systemStats: return "本机 CPU/内存"
        }
    }
```

b) `image(...)` 签名与 switch 更新:

```swift
    @MainActor
    static func image(scheme: MenuBarDisplayScheme, fiveHour: Int?, oneWeek: Int?,
                      openCodeRolling: Int? = nil, openCodeWeekly: Int? = nil,
                      kimiWeekly: Int? = nil,
                      cpu: Int? = nil, memory: Int? = nil,
                      thresholdConfig: ThresholdConfig = ThresholdConfig()) -> NSImage {
        switch scheme {
        case .cloudPercent: return cloudPercentImage(fiveHour: fiveHour, oneWeek: oneWeek,
                                                      openCodeRolling: openCodeRolling, openCodeWeekly: openCodeWeekly,
                                                      kimiWeekly: kimiWeekly, cpu: cpu, memory: memory,
                                                      thresholdConfig: thresholdConfig)
        case .compact: return compactImage(fiveHour: fiveHour, oneWeek: oneWeek,
                                           kimiWeekly: kimiWeekly, cpu: cpu, memory: memory)
        case .singleLine: return singleLineImage(fiveHour: fiveHour, oneWeek: oneWeek, cpu: cpu, memory: memory)
        case .iconOnly: return iconOnlyImage(fiveHour: fiveHour ?? 0, oneWeek: oneWeek ?? 0,
                                              thresholdConfig: thresholdConfig)
        case .systemStats: return systemStatsImage(cpu: cpu, memory: memory)
        }
    }
```

c) `cloudPercentImage` 签名加 `cpu: Int? = nil, memory: Int? = nil`,在 Kimi 段之后追加(整段替换原签名行 + 尾部):

```swift
    @MainActor
    private static func cloudPercentImage(fiveHour: Int?, oneWeek: Int?,
                                          openCodeRolling: Int? = nil, openCodeWeekly: Int? = nil,
                                          kimiWeekly: Int? = nil,
                                          cpu: Int? = nil, memory: Int? = nil,
                                          thresholdConfig: ThresholdConfig = ThresholdConfig()) -> NSImage {
```

Kimi 段(`if kimiWeekly != nil { ... }`)之后、HStack 结束之前插入:

```swift
            // 本机:CPU/内存(开关开且有采样值时显示;未采样时显示横杠)
            if cpu != nil || memory != nil {
                Spacer().frame(width: 6)
                Text("C").font(.system(size: 8, weight: .semibold)).monospacedDigit().foregroundStyle(.black)
                Text(pctText(cpu)).font(.system(size: 11, weight: .semibold)).monospacedDigit().foregroundStyle(.black)
                Text("·").font(.system(size: 11)).foregroundStyle(.black.opacity(0.5))
                Text("M").font(.system(size: 8, weight: .semibold)).monospacedDigit().foregroundStyle(.black)
                Text(pctText(memory)).font(.system(size: 11, weight: .semibold)).monospacedDigit().foregroundStyle(.black)
            }
```

d) `compactImage` 签名加 `cpu: Int? = nil, memory: Int? = nil`,kimi 行之后追加第四行,**并把 frame 改为 fixedSize**(原 `.frame(width: 48, height: 20, alignment: .trailing)` 内容高度不够容纳 4 行,ImageRenderer 按内容理想尺寸输出;fixedSize 让宽高都随内容,数字对齐由各行内部固定 width 16/30 保证):

```swift
    @MainActor
    private static func compactImage(fiveHour: Int?, oneWeek: Int?, kimiWeekly: Int? = nil,
                                     cpu: Int? = nil, memory: Int? = nil) -> NSImage {
        let content = VStack(alignment: .trailing, spacing: -1) {
            HStack(spacing: 2) {
                Text("5h").font(.system(size: 10, weight: .medium)).monospacedDigit().frame(width: 16, alignment: .leading)
                Text(pctText(fiveHour)).font(.system(size: 10, weight: .medium)).monospacedDigit().frame(width: 30, alignment: .trailing)
            }
            HStack(spacing: 2) {
                Text("7d").font(.system(size: 10, weight: .medium)).monospacedDigit().frame(width: 16, alignment: .leading)
                Text(pctText(oneWeek)).font(.system(size: 10, weight: .medium)).monospacedDigit().frame(width: 30, alignment: .trailing)
            }
            if kimiWeekly != nil {
                HStack(spacing: 2) {
                    Image(systemName: "sparkles").font(.system(size: 9, weight: .bold)).frame(width: 16, alignment: .leading)
                    Text(pctText(kimiWeekly)).font(.system(size: 10, weight: .medium)).monospacedDigit().frame(width: 30, alignment: .trailing)
                }
            }
            if cpu != nil || memory != nil {
                HStack(spacing: 2) {
                    Text("C").font(.system(size: 10, weight: .medium)).monospacedDigit().frame(width: 16, alignment: .leading)
                    Text(pctText(cpu)).font(.system(size: 10, weight: .medium)).monospacedDigit().frame(width: 30, alignment: .trailing)
                    Text("M").font(.system(size: 10, weight: .medium)).monospacedDigit().frame(width: 16, alignment: .leading)
                    Text(pctText(memory)).font(.system(size: 10, weight: .medium)).monospacedDigit().frame(width: 30, alignment: .trailing)
                }
            }
        }
        .foregroundStyle(.black)
        .fixedSize(horizontal: true, vertical: true)
        return render(content)
    }
```

> 若 Task 3 视觉验证发现 4 行在菜单栏裁切,回退方案(二选一,先 A 后 B):
> A) 该行字号降为 9;
> B) 去掉 C/M 前缀,把数值合并进 kimi 行尾部:`✨ 58% · 23% 58%`。
> 回退后必须重跑视觉验证。

e) `singleLineImage` 签名加 `cpu: Int? = nil, memory: Int? = nil`,尾部追加:

```swift
    @MainActor
    private static func singleLineImage(fiveHour: Int?, oneWeek: Int?,
                                        cpu: Int? = nil, memory: Int? = nil) -> NSImage {
        let content = HStack(spacing: 3) {
            Text(pctText(fiveHour)).font(.system(size: 12, weight: .medium)).monospacedDigit()
            Text("·").font(.system(size: 12, weight: .medium))
            Text(pctText(oneWeek)).font(.system(size: 12, weight: .medium)).monospacedDigit()
            if cpu != nil || memory != nil {
                Text("·").font(.system(size: 12, weight: .medium))
                Text("C").font(.system(size: 10, weight: .medium)).monospacedDigit()
                Text(pctText(cpu)).font(.system(size: 12, weight: .medium)).monospacedDigit()
                Text("M").font(.system(size: 10, weight: .medium)).monospacedDigit()
                Text(pctText(memory)).font(.system(size: 12, weight: .medium)).monospacedDigit()
            }
        }
        .foregroundStyle(.black)
        .frame(height: 20)
        .fixedSize(horizontal: true, vertical: false)
        return render(content)
    }
```

f) 新增 `systemStatsImage`(放在 `iconOnlyImage` 之后):

```swift
    /// 仅本机 CPU/内存:C23% · M58%。
    /// 两个参数都 nil(开关关闭或采样未就绪)→ 回退云朵图标。
    @MainActor
    private static func systemStatsImage(cpu: Int?, memory: Int?) -> NSImage {
        let content = HStack(spacing: 4) {
            if cpu == nil && memory == nil {
                cloudShape.fill(Color.black).frame(width: 14, height: 11)
            } else {
                Text("C").font(.system(size: 8, weight: .semibold)).monospacedDigit().foregroundStyle(.black)
                Text(pctText(cpu)).font(.system(size: 11, weight: .semibold)).monospacedDigit().foregroundStyle(.black)
                Text("·").font(.system(size: 11)).foregroundStyle(.black.opacity(0.5))
                Text("M").font(.system(size: 8, weight: .semibold)).monospacedDigit().foregroundStyle(.black)
                Text(pctText(memory)).font(.system(size: 11, weight: .semibold)).monospacedDigit().foregroundStyle(.black)
            }
        }
        .frame(height: 20)
        .fixedSize(horizontal: true, vertical: false)
        return render(content)
    }
```

- [ ] **Step 3: 设置 UI 加开关**

`Sources/AliyunTokenBar/Settings.swift`,外观 Section 的"菜单栏样式" Picker 之后插入:

```swift
                Toggle("显示本机 CPU/内存", isOn: $model.systemStatsEnabled)
```

- [ ] **Step 4: 构建验证**

Run: `swift build`
Expected: 编译成功,零警告。现有 `image(...)` 调用点因默认参数不受影响。

- [ ] **Step 5: Commit**

```bash
git add Sources/AliyunTokenBarCore/TokenPlanModel.swift Sources/AliyunTokenBar/App.swift Sources/AliyunTokenBar/Settings.swift
git commit -m "feat(metrics): 菜单栏 CPU/内存开关 + systemStats 样式 + 五样式渲染适配"
```

---

### Task 3: 接线 — 开关启停采样、采样值触发重渲染、运行验证

**Files:**
- Modify: `Sources/AliyunTokenBar/App.swift`(renderIconSink 闭包传 cpu/memory)
- Modify: `Sources/AliyunTokenBar/AppDelegate.swift`(applicationDidFinishLaunching 加两个订阅)

**Interfaces:**
- Consumes: Task 1 的 `SystemMetricsMonitor.shared.start()/stop()/cpuPercent/memoryPercent`;Task 2 的 `model.systemStatsEnabled`、`image(...cpu:memory:)`。

- [ ] **Step 1: renderIconSink 传 CPU/内存**

`Sources/AliyunTokenBar/App.swift`,renderIconSink 闭包内(现有 `return MenuBarTextRenderer.image(...)` 处)改为:

```swift
            let monitor = SystemMetricsMonitor.shared
            return MenuBarTextRenderer.image(
                scheme: MenuBarStyleManager.shared.scheme,
                fiveHour: model.quota?.usage.fiveHour.percentageInt,
                oneWeek: model.quota?.usage.oneWeek.percentageInt,
                openCodeRolling: ocRolling ?? nil,
                openCodeWeekly: ocWeekly ?? nil,
                kimiWeekly: kimiWeekly ?? nil,
                cpu: model.systemStatsEnabled ? monitor.cpuPercent : nil,
                memory: model.systemStatsEnabled ? monitor.memoryPercent : nil,
                thresholdConfig: model.thresholdConfig
            )
```

- [ ] **Step 2: AppDelegate 启停 + 重渲染订阅**

`Sources/AliyunTokenBar/AppDelegate.swift`,`applicationDidFinishLaunching` 末尾(在 `TokenPlanModel.shared.startTimer()` 之后)追加:

```swift
        // 本机 CPU/内存:开关变化 → 启停采样(@Published 订阅即回放当前值,启动即生效);
        // 采样值变化 → 重渲染图标(renderIconSink 内部读 monitor 现值)。
        TokenPlanModel.shared.$systemStatsEnabled
            .sink { enabled in
                if enabled {
                    SystemMetricsMonitor.shared.start()
                } else {
                    SystemMetricsMonitor.shared.stop()
                }
                TokenPlanModel.shared.prerenderIcon()
            }
            .store(in: &cancellables)
        SystemMetricsMonitor.shared.$cpuPercent
            .combineLatest(SystemMetricsMonitor.shared.$memoryPercent)
            .sink { _ in TokenPlanModel.shared.prerenderIcon() }
            .store(in: &cancellables)
```

- [ ] **Step 3: 构建 + Verify**

Run: `swift build && swift run Verify`
Expected: 编译成功;`ALL PASS`。

- [ ] **Step 4: 运行视觉验证**

Run: `swift run AliyunTokenBar`(app 进程挂起菜单栏,目测;验证完 Cmd+C 退出)。

按 spec 视觉清单逐项确认(每项肉眼可判):

1. **默认开**:启动后第一个 30 秒内菜单栏出现 `C..% M..%`(启动即取基线,数字不晚于 30s 出现)。
2. **compact 样式**(默认):4 行(5h / 7d / kimi / C-M)完整可见、不裁切。
   - 若裁切:按 Task 2 Step 2 d) 的回退方案(先字号 9,再合并进 kimi 行)修改,重新 `swift run AliyunTokenBar` 验证,通过后再继续。
3. **五样式**:设置里切换 云朵+百分比 / 5h7d双行 / 单行 / 仅图标 / 本机CPU内存,确认各自渲染正确(cloudPercent/singleLine 尾部追加、iconOnly 不变、systemStats 只显示 C/M)。
4. **开关关闭**:设置里关掉"显示本机 CPU/内存",图标立即恢复原样(无 C/M);systemStats 样式下显示云朵。
5. **刷新节奏**:数值每 ~30 秒更新一次;CPU 平滑不跳变(±15% 内摆动属正常)。
6. **内存口径**:打开活动监视器对比"已使用内存"百分比,差值 ≤ ±2%。

- [ ] **Step 5: Commit**

```bash
git add Sources/AliyunTokenBar/App.swift Sources/AliyunTokenBar/AppDelegate.swift
git commit -m "feat(metrics): 接线 CPU/内存采样启停与图标重渲染(含视觉验证)"
```

---

### Task 4: 全量回归 + 收尾

**Files:**
- None(仅验证)。

- [ ] **Step 1: 全量验证**

Run: `swift build && swift run Verify`
Expected: 编译成功,`ALL PASS`(含历史全部断言)。

- [ ] **Step 2: 快速回归目测**

`swift run AliyunTokenBar`:确认套餐用量数字仍正常显示、三 Provider 样式、面板打开正常(CPU/内存改动不应影响套餐数据流)。

- [ ] **Step 3: 检查工作区无遗漏**

Run: `git status --short`
Expected: 仅本次任务的改动文件;确认没有把 `.claude/`、`.zcode/` 等无关目录纳入提交。

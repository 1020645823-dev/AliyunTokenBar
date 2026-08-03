# 面板「本机」tab:进程占用 Top 10 + kill Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 面板新增「本机」tab,分段显示 CPU/内存占用前 10 进程(app 名+图标),支持两步确认 kill(SIGKILL)。

**Architecture:** Core 层新增 `ProcessListMonitor`(libproc 直调:全量 PID 采样、CPU ticks 差值、footprint 内存、app 路径识别;快照存全量,排序截断在纯函数);executable 层新增 `SystemProcessesCard`(分段 CPU|内存 + Top 10 列表 + 两步确认 kill),面板 onAppear/onDisappear 驱动 3s 采样。

**Tech Stack:** Swift 5.9 / SwiftUI / Darwin libproc(`proc_listallpids` / `proc_pidinfo` / `proc_pid_rusage` / `proc_pidpath` / `proc_name`),零新依赖;`swift run Verify` 验证。

**Spec:** `docs/superpowers/specs/2026-08-03-process-top10-kill-design.md`

**已校准事实(实施时无需再验证)**:
- Swift Darwin 模块直接可用:`proc_listallpids`、`proc_pidinfo`、`PROC_PIDTASKINFO`、`proc_taskinfo`、`PROC_PIDTBSDINFO`、`proc_bsdinfo`、`proc_pidpath`、`proc_name`、`rusage_info_v4`、`RUSAGE_INFO_V4`、`proc_pid_rusage`。
- `PROC_PIDPATHINFO_MAXSIZE` 宏**不可导入** → 用字面量 `4 * 1024`。
- CPU ticks(`pti_total_user/pti_total_system`)单位是 mach 时基(Apple Silicon 24MHz);换算:`秒 = Double(deltaTicks) × Double(timebase.numer) ÷ Double(timebase.denom) ÷ 1e9`(`mach_timebase_info` 运行时获取)。实测:单线程忙等 2.0s → 99.9% 误差。
- `proc_pid_rusage(pid, RUSAGE_INFO_V4, ptr)` 需 `withMemoryRebound(to: rusage_info_t?.self)`;`ri_phys_footprint` 即活动监视器"内存"口径。
- app 无沙箱(entitlements 为空)→ `kill(pid, SIGKILL)` 用户进程无需额外权限。

## Global Constraints

- 平台 macOS 13+;零新依赖;禁 spawn 进程采样。
- kill 信号 = **SIGKILL**;两步确认(点 kill → 红色"确认?"3 秒超时还原);无一键全杀;root 进程(uid==0)kill 置灰。
- 内存指标 = `ri_phys_footprint`(对齐活动监视器);CPU% 不钳制(可 >100%,多核)。
- 面板打开时采样(3s),关闭即停;不显示 PID;不合并同名子进程;不加设置开关。
- 首采 CPU% = nil → 横杠(项目横杠语义)。
- 不测 Timer/时序、不测 kill 副作用;Verify 只测纯函数;libproc 仅冒烟。
- 每个 Task 结束必须 `git commit`。
- 注释风格:中文,与现有代码一致。

---

### Task 1: 数据层 ProcessListMonitor + 纯函数测试

**Files:**
- Create: `Sources/AliyunTokenBarCore/ProcessMonitorService.swift`
- Test: `Sources/Verify/main.swift`(在 `print(fails == 0 ...)` 行**之前**追加)

**Interfaces:**
- Produces:
  - `public struct ProcessSnapshot: Identifiable, Equatable`(`pid: Int32`、`name: String`、`appName: String`、`appPath: String?`、`cpuPercent: Double?`、`memoryBytes: UInt64`、`isRoot: Bool`;`public var id: Int32 { pid }`;public memberwise init)
  - `@MainActor public final class ProcessListMonitor: ObservableObject`(`public static let shared`;`@Published public private(set) var snapshots: [ProcessSnapshot] = []`;`public func start(interval: TimeInterval = 3)`;`public func stop()`;`public func refreshNow()`;`public static func kill(_ pid: Int32) -> Bool`)
  - 纯函数(均 `public static`):
    - `topByCPU(_ all: [ProcessSnapshot], limit: Int = 10) -> [ProcessSnapshot]`(降序,nil 排最后)
    - `topByMemory(_ all: [ProcessSnapshot], limit: Int = 10) -> [ProcessSnapshot]`(降序)
    - `bytesToHuman(_ bytes: UInt64) -> String`
    - `appBundlePath(fromExecutablePath path: String) -> String?`
    - `cpuPercent(previousTicks: UInt64, currentTicks: UInt64, elapsedSeconds: Double) -> Double?`(内部用 timebase 换算;elapsedSeconds<=0 → nil)
  - Task 2 依赖以上全部类型/签名。

- [ ] **Step 1: 写失败测试**

在 `Sources/Verify/main.swift` 末尾(`print(fails == 0 ...)` 之前)追加:

```swift
// --- ProcessListMonitor:纯函数 ---
func snap(_ pid: Int32, _ name: String, cpu: Double?, mem: UInt64) -> ProcessSnapshot {
    ProcessSnapshot(pid: pid, name: name, appName: name, appPath: nil,
                    cpuPercent: cpu, memoryBytes: mem, isRoot: false)
}
let plist = [snap(1, "a", cpu: 10, mem: 500), snap(2, "b", cpu: 90, mem: 100),
             snap(3, "c", cpu: nil, mem: 900), snap(4, "d", cpu: 50, mem: 700)]
check("topByCPU desc + nil last", ProcessListMonitor.topByCPU(plist).map(\.pid) == [2, 4, 1, 3])
check("topByCPU truncates", ProcessListMonitor.topByCPU(plist, limit: 2).map(\.pid) == [2, 4])
check("topByCPU empty safe", ProcessListMonitor.topByCPU([]).isEmpty)
check("topByMemory desc", ProcessListMonitor.topByMemory(plist).map(\.pid) == [3, 4, 1, 2])

check("bytesToHuman zero", ProcessListMonitor.bytesToHuman(0) == "0 B")
check("bytesToHuman 900", ProcessListMonitor.bytesToHuman(900) == "900 B")
check("bytesToHuman 1024", ProcessListMonitor.bytesToHuman(1024) == "1.0 KB")
check("bytesToHuman MB", ProcessListMonitor.bytesToHuman(350 * 1024 * 1024) == "350.0 MB")
check("bytesToHuman GB", ProcessListMonitor.bytesToHuman(UInt64(1.2 * 1024 * 1024 * 1024)) == "1.2 GB")

check("appBundlePath chrome",
      ProcessListMonitor.appBundlePath(fromExecutablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
      == "/Applications/Google Chrome.app")
check("appBundlePath nested",
      ProcessListMonitor.appBundlePath(fromExecutablePath: "/Users/x/Library/Application Support/Foo.app/Contents/MacOS/helper")
      == "/Users/x/Library/Application Support/Foo.app")
check("appBundlePath non-app nil",
      ProcessListMonitor.appBundlePath(fromExecutablePath: "/usr/sbin/mDNSResponder") == nil)
check("appBundlePath weird safe", ProcessListMonitor.appBundlePath(fromExecutablePath: "no-slash") == nil)

// CPU%:elapsed<=0 → nil
check("cpuPercent zero elapsed nil",
      ProcessListMonitor.cpuPercent(previousTicks: 100, currentTicks: 200, elapsedSeconds: 0) == nil)
// 冒烟:全量采样非空且含本进程
let smokeAll = ProcessListMonitor.sampleAll(previousTicks: [:]).list
check("smoke sampleAll non-empty", !smokeAll.isEmpty)
check("smoke sampleAll contains self", smokeAll.contains { $0.pid == getpid() })
```

- [ ] **Step 2: 运行确认失败**

Run: `swift run Verify`
Expected: 编译失败 `cannot find 'ProcessListMonitor' in scope`。

- [ ] **Step 3: 实现 ProcessMonitorService**

创建 `Sources/AliyunTokenBarCore/ProcessMonitorService.swift`:

```swift
import Foundation
import Combine
import Darwin

/// 进程快照:一行 Top 列表的数据。
public struct ProcessSnapshot: Identifiable, Equatable {
    public let pid: Int32
    public let name: String          // 进程名(如 "Google Chrome Helper (GPU)")
    public let appName: String       // app 显示名(.app 进程取 Bundle displayName;否则 = name)
    public let appPath: String?      // .app 路径(nil → 齿轮占位图标)
    public let cpuPercent: Double?   // nil = 首次采样未就绪(横杠)
    public let memoryBytes: UInt64   // footprint(活动监视器口径)
    public let isRoot: Bool          // uid == 0 → "系统"角标 + kill 置灰

    public init(pid: Int32, name: String, appName: String, appPath: String?,
                cpuPercent: Double?, memoryBytes: UInt64, isRoot: Bool) {
        self.pid = pid; self.name = name; self.appName = appName; self.appPath = appPath
        self.cpuPercent = cpuPercent; self.memoryBytes = memoryBytes; self.isRoot = isRoot
    }
    public var id: Int32 { pid }
}

/// 进程占用采样器。面板打开时每 3 秒采一次(CPU% 两轮差值);面板关闭即停。
/// libproc 直调,零 spawn;排序/格式化/app 识别拆纯函数供 Verify 测试。
/// CPU ticks 单位 = mach 时基(Apple Silicon 24MHz),用 mach_timebase_info 运行时换算(已校准)。
@MainActor
public final class ProcessListMonitor: ObservableObject {
    public static let shared = ProcessListMonitor()

    /// 全量进程快照(排序截断 Top 10 由 UI 侧纯函数执行)。
    @Published public private(set) var snapshots: [ProcessSnapshot] = []

    private var timer: AnyCancellable?
    private var lastTicks: [Int32: UInt64] = [:]   // pid → 上轮 user+system ticks
    private var lastSampleTime: Date?

    /// 启动采样(幂等)。首轮存基线,cpuPercent = nil(横杠)。
    public func start(interval: TimeInterval = 3) {
        guard timer == nil else { return }
        refreshNow()
        timer = Timer.publish(every: interval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refreshNow() }
    }

    /// 停止采样并清状态(面板关闭)。
    public func stop() {
        timer?.cancel()
        timer = nil
        lastTicks = [:]
        lastSampleTime = nil
        snapshots = []
    }

    /// 立即采一次(手动刷新按钮 + Timer)。
    public func refreshNow() {
        let now = Date()
        let elapsed = lastSampleTime.map { now.timeIntervalSince($0) }
        let result = Self.sampleAll(previousTicks: lastTicks, elapsedSeconds: elapsed)
        lastTicks = result.ticks
        lastSampleTime = now
        snapshots = result.list
    }

    /// SIGKILL 强杀(grilling Q7 锁定)。root 进程/不存在的 pid 会失败返回 false,UI 静默处理。
    public static func kill(_ pid: Int32) -> Bool {
        Darwin.kill(pid, SIGKILL) == 0
    }
}

// MARK: - 采样(libproc 直调)

extension ProcessListMonitor {
    /// 取单进程当前 CPU ticks(user + system)。进程已退出返回 nil。
    static func currentTicks(for pid: Int32) -> UInt64? {
        var t = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &t, size) > 0 else { return nil }
        return t.pti_total_user &+ t.pti_total_system
    }

    /// 全量采样:所有存活进程的快照 + 本轮 ticks(供下轮差值)。
    /// previousTicks 为空时 cpuPercent 全 nil(首轮基线)。
    /// elapsedSeconds:距上轮采样的秒数(nil = 首轮)。死进程(采样中途退出)直接跳过。
    public static func sampleAll(previousTicks: [Int32: UInt64],
                                 elapsedSeconds: Double? = nil) -> (list: [ProcessSnapshot], ticks: [Int32: UInt64]) {
        let needed = proc_listallpids(nil, 0)
        guard needed > 0 else { return ([], [:]) }
        var pids = [Int32](repeating: 0, count: Int(needed) + 64)  // 留余量防采样间隙新进程
        let got = proc_listallpids(&pids, Int32(pids.count) * Int32(MemoryLayout<Int32>.size))
        guard got > 0 else { return ([], [:]) }
        var out: [ProcessSnapshot] = []
        var ticks: [Int32: UInt64] = [:]
        out.reserveCapacity(Int(got))
        for i in 0..<Int(got) {
            let pid = pids[i]
            if pid <= 0 { continue }
            if let s = sampleOne(pid: pid, previousTicks: previousTicks,
                                 elapsedSeconds: elapsedSeconds, outTicks: &ticks) {
                out.append(s)
            }
        }
        return (out, ticks)
    }

    /// 单进程采样。proc_pidpath 失败(如内核线程)→ 跳过(无法识别的进程不展示)。
    /// 本轮 ticks 写入 outTicks(与快照同一次 syscall 取,无重复开销)。
    private static func sampleOne(pid: Int32, previousTicks: [Int32: UInt64],
                                  elapsedSeconds: Double?,
                                  outTicks: inout [Int32: UInt64]) -> ProcessSnapshot? {
        // 基本信息:uid + 进程名
        var binfo = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &binfo,
                           Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { return nil }
        let name = withUnsafeBytes(of: binfo.pbi_name) { raw in
            String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
        // 内存 footprint
        var ru = rusage_info_v4()
        let ruOK = withUnsafeMutablePointer(to: &ru) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        } == 0
        // CPU ticks(本轮值同时写入 outTicks,供下轮差值)
        let ticks = currentTicks(for: pid)
        if let t = ticks { outTicks[pid] = t }
        var cpuPct: Double? = nil
        if let cur = ticks, let prev = previousTicks[pid], let elapsed = elapsedSeconds {
            cpuPct = cpuPercent(previousTicks: prev, currentTicks: cur, elapsedSeconds: elapsed)
        }
        // 可执行路径 → app 识别
        var pathBuf = [CChar](repeating: 0, count: 4 * 1024)  // PROC_PIDPATHINFO_MAXSIZE 宏不可导入
        guard proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count)) > 0 else { return nil }
        let execPath = String(cString: pathBuf)
        let bundlePath = appBundlePath(fromExecutablePath: execPath)
        let appName = bundlePath.map { appDisplayName(appPath: $0, fallbackName: name) } ?? name
        return ProcessSnapshot(pid: pid, name: name, appName: appName, appPath: bundlePath,
                               cpuPercent: cpuPct, memoryBytes: ruOK ? ru.ri_phys_footprint : 0,
                               isRoot: binfo.pbi_uid == 0)
    }
}

// MARK: - 纯函数(Verify 目标可测)

extension ProcessListMonitor {
    /// CPU% = ticks 差值(经 mach 时基换算成秒)÷ 经过秒数 × 100。
    /// elapsedSeconds <= 0 → nil;不钳制(多核进程可 >100%)。
    public static func cpuPercent(previousTicks: UInt64, currentTicks: UInt64,
                                  elapsedSeconds: Double) -> Double? {
        guard elapsedSeconds > 0 else { return nil }
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        let deltaTicks = currentTicks &- previousTicks
        let cpuSeconds = Double(deltaTicks) * Double(tb.numer) / Double(tb.denom) / 1e9
        return cpuSeconds / elapsedSeconds * 100
    }

    /// CPU 降序 Top N;cpuPercent 为 nil 的排最后。
    public static func topByCPU(_ all: [ProcessSnapshot], limit: Int = 10) -> [ProcessSnapshot] {
        all.sorted { a, b in
            let av = a.cpuPercent ?? -1
            let bv = b.cpuPercent ?? -1
            return av > bv
        }.prefix(limit).map { $0 }
    }

    /// 内存降序 Top N。
    public static func topByMemory(_ all: [ProcessSnapshot], limit: Int = 10) -> [ProcessSnapshot] {
        all.sorted { $0.memoryBytes > $1.memoryBytes }.prefix(limit).map { $0 }
    }

    /// 人类可读字节:"0 B" / "900 B" / "1.0 KB" / "350.0 MB" / "1.2 GB"。
    public static func bytesToHuman(_ bytes: UInt64) -> String {
        let b = Double(bytes)
        if b < 1024 { return "\(bytes) B" }
        if b < 1024 * 1024 { return String(format: "%.1f KB", b / 1024) }
        if b < 1024 * 1024 * 1024 { return String(format: "%.1f MB", b / (1024 * 1024)) }
        return String(format: "%.1f GB", b / (1024 * 1024 * 1024))
    }

    /// 从可执行文件路径抽取所属 .app 包路径;非 .app 进程返回 nil。
    /// "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" → "/Applications/Google Chrome.app"
    public static func appBundlePath(fromExecutablePath path: String) -> String? {
        let comps = path.components(separatedBy: "/")
        guard let idx = comps.lastIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        let bundle = comps[0...idx].joined(separator: "/")
        return bundle.isEmpty ? nil : bundle
    }

    /// app 显示名:Bundle displayName;取不到时回退进程名。
    public static func appDisplayName(appPath: String, fallbackName: String) -> String {
        Bundle(path: appPath)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle(path: appPath)?.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? fallbackName
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `swift run Verify`
Expected: 末尾 `ALL PASS`,含 `PASS topByCPU desc + nil last`、`PASS appBundlePath chrome`、`PASS smoke sampleAll contains self` 等新断言,既有断言全部 PASS。

- [ ] **Step 5: Commit**

```bash
git add Sources/AliyunTokenBarCore/ProcessMonitorService.swift Sources/Verify/main.swift
git commit -m "feat(processes): ProcessListMonitor 进程采样器(libproc)+ 纯函数测试"
```

---

### Task 2: 面板 UI —「本机」tab + SystemProcessesCard

**Files:**
- Modify: `Sources/AliyunTokenBar/Menu.swift`(ProviderTab 枚举加 case;availableTabs 恒含 system;selectedContent 分发;新增 SystemProcessesCard 视图)

**Interfaces:**
- Consumes: Task 1 的 `ProcessListMonitor.shared.start()/stop()/refreshNow()/kill(_:)`、`snapshots`、`ProcessSnapshot`、`topByCPU/topByMemory/bytesToHuman`。
- Produces: 无(Task 3 仅回归验证)。

- [ ] **Step 1: ProviderTab 加 case**

`Sources/AliyunTokenBar/Menu.swift`,`ProviderTab` 枚举改为:

```swift
enum ProviderTab: String, CaseIterable, Identifiable {
    case aliyun
    case opencode
    case kimi
    case system
    var id: String { rawValue }
    var title: String {
        switch self {
        case .aliyun: return "阿里云"
        case .opencode: return "OpenCode"
        case .kimi: return "Kimi"
        case .system: return "本机"
        }
    }
    var icon: String {
        switch self {
        case .aliyun: return "cloud.fill"
        case .opencode: return "bolt.fill"
        case .kimi: return "sparkles"
        case .system: return "cpu"
        }
    }
}
```

`availableTabs` 改为(恒含 system,第 4 位):

```swift
    private var availableTabs: [ProviderTab] {
        var tabs: [ProviderTab] = [.aliyun]
        if model.openCodeConfigured { tabs.append(.opencode) }
        if model.kimiConfigured { tabs.append(.kimi) }
        tabs.append(.system)
        return tabs
    }
```

`selectedContent` 的 switch 加:

```swift
        case .system: SystemProcessesCard()
```

- [ ] **Step 2: SystemProcessesCard 视图**

`Sources/AliyunTokenBar/Menu.swift` 文件末尾(`LoadingRing` 之后)追加:

```swift
// MARK: - 本机进程(CPU/内存 Top 10 + kill)

/// 面板「本机」tab:分段显示 CPU/内存占用前 10 进程,可两步确认 kill(SIGKILL)。
/// 数据源:ProcessListMonitor(libproc,3s 采样,面板关闭即停)。
struct SystemProcessesCard: View {
    enum SubTab: String, CaseIterable, Identifiable {
        case cpu, memory
        var id: String { rawValue }
        var title: String { self == .cpu ? "CPU" : "内存" }
    }

    @State private var subTab: SubTab = .cpu
    /// 两步确认 kill:确认中的 pid + 到期时间(3 秒未二次点击自动还原)。
    @State private var confirmingPid: Int32?
    @State private var confirmDeadline: Date = .distantPast

    private var monitor: ProcessListMonitor { ProcessListMonitor.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            subTabPicker
            processList
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.atbPanelBackground)
        .onAppear { monitor.start() }
        .onDisappear {
            monitor.stop()
            confirmingPid = nil
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "cpu").font(.system(size: 13, weight: .bold)).foregroundStyle(.green)
            Text("本机进程").font(.system(size: 13, weight: .medium)).foregroundStyle(.atbTextPrimary)
            Spacer()
            Button { monitor.refreshNow() } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 12)).foregroundStyle(.atbTextTertiary)
            }.buttonStyle(.plain)
        }
    }

    private var subTabPicker: some View {
        HStack(spacing: 4) {
            ForEach(SubTab.allCases) { t in
                Button {
                    subTab = t
                } label: {
                    Text(t.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(subTab == t ? .white : .atbTextSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(subTab == t ? Color.atbBlue : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Color.atbCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// 当前子页签的 Top 10 列表。
    private var topList: [ProcessSnapshot] {
        switch subTab {
        case .cpu: return ProcessListMonitor.topByCPU(monitor.snapshots)
        case .memory: return ProcessListMonitor.topByMemory(monitor.snapshots)
        }
    }

    private var processList: some View {
        let list = topList
        let maxValue: Double = {
            switch subTab {
            case .cpu: return list.compactMap(\.cpuPercent).max() ?? 1
            case .memory: return Double(list.map(\.memoryBytes).max() ?? 1)
            }
        }()
        return VStack(spacing: 6) {
            if list.isEmpty {
                HStack { Spacer(); LoadingRing().frame(width: 18, height: 18); Spacer() }
                    .padding(14)
                    .background(Color.atbCardBackground)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.black.opacity(0.08)))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                ForEach(list) { p in
                    ProcessRow(snapshot: p, subTab: subTab, maxValue: maxValue,
                               isConfirming: confirmingPid == p.pid && Date() < confirmDeadline,
                               onKill: { killTapped(p) })
                }
            }
        }
    }

    /// kill 两步确认:第一次点 → 进入确认态;3 秒内第二次点 → SIGKILL;root 进程不可点。
    /// 超时还原:asyncAfter 到期后若仍处于确认态则清除(二次点击已杀成功时 confirmingPid 已置 nil,不会误清)。
    private func killTapped(_ p: ProcessSnapshot) {
        guard !p.isRoot else { return }
        if confirmingPid == p.pid, Date() < confirmDeadline {
            _ = ProcessListMonitor.kill(p.pid)   // 失败静默:下轮刷新该行自然消失
            confirmingPid = nil
        } else {
            confirmingPid = p.pid
            confirmDeadline = Date().addingTimeInterval(3)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                if confirmingPid == p.pid { confirmingPid = nil }
            }
        }
    }
}

/// 进程行:app 图标 + 名称(副行进程名)+ 数值 + 迷你进度条 + kill 按钮。
private struct ProcessRow: View {
    let snapshot: ProcessSnapshot
    let subTab: SystemProcessesCard.SubTab
    let maxValue: Double
    let isConfirming: Bool
    let onKill: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            procIcon
            VStack(alignment: .leading, spacing: 1) {
                Text(snapshot.appName)
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.atbTextPrimary)
                    .lineLimit(1)
                if snapshot.name != snapshot.appName {
                    Text(snapshot.name)
                        .font(.system(size: 9)).foregroundStyle(.atbTextTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 4) {
                    Text(valueText)
                        .font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(.atbTextPrimary)
                    if snapshot.isRoot {
                        Text("系统")
                            .font(.system(size: 8, weight: .medium)).foregroundStyle(.atbTextTertiary)
                            .padding(.horizontal, 3).padding(.vertical, 1)
                            .background(Color.atbTextTertiary.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                }
                miniBar
            }
            killButton
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Color.atbCardBackground)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.black.opacity(0.08)))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// app 图标(.app 进程)或齿轮占位。
    @ViewBuilder
    private var procIcon: some View {
        if let appPath = snapshot.appPath {
            Image(nsImage: NSWorkspace.shared.icon(forFile: appPath))
                .resizable().frame(width: 20, height: 20)
        } else {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 14)).foregroundStyle(.atbTextTertiary)
                .frame(width: 20, height: 20)
        }
    }

    /// 数值:CPU 不钳制可 >100%,首采 nil → 横杠;内存人类可读。
    private var valueText: String {
        switch subTab {
        case .cpu:
            guard let pct = snapshot.cpuPercent else { return "—" }
            return String(format: "%.1f%%", pct)
        case .memory:
            return ProcessListMonitor.bytesToHuman(snapshot.memoryBytes)
        }
    }

    /// 迷你进度条:相对本列表最大值(视觉参考,非 100% 上限)。
    private var miniBar: some View {
        let value: Double = {
            switch subTab {
            case .cpu: return snapshot.cpuPercent ?? 0
            case .memory: return Double(snapshot.memoryBytes)
            }
        }()
        let ratio = maxValue > 0 ? min(value / maxValue, 1) : 0
        return GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().frame(height: 3).foregroundStyle(Color.black.opacity(0.08))
                Capsule().frame(width: proxy.size.width * CGFloat(ratio), height: 3)
                    .foregroundStyle(Color.atbBlue.opacity(0.7))
            }
        }
        .frame(width: 64, height: 3)
    }

    /// kill 按钮:root 置灰;确认态红色文字"确认?";常态 xmark.circle。
    private var killButton: some View {
        Button(action: onKill) {
            if isConfirming {
                Text("确认?")
                    .font(.system(size: 10, weight: .bold)).foregroundStyle(Color(red: 0.92, green: 0.23, blue: 0.21))
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Color(red: 0.92, green: 0.23, blue: 0.21).opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            } else {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(snapshot.isRoot ? Color.atbTextTertiary.opacity(0.35) : .atbTextSecondary)
            }
        }
        .buttonStyle(.plain)
        .disabled(snapshot.isRoot)
    }
}
```

- [ ] **Step 3: 构建验证**

Run: `swift build`
Expected: 编译成功,零警告。

- [ ] **Step 4: Commit**

```bash
git add Sources/AliyunTokenBar/Menu.swift
git commit -m "feat(processes): 面板「本机」tab — CPU/内存 Top 10 列表 + 两步确认 kill"
```

---

### Task 3: 全量回归 + 手工验证 + 打包

**Files:**
- None(验证与发布)。

- [ ] **Step 1: 全量构建 + Verify**

Run: `swift build && swift run Verify`
Expected: 编译成功;`ALL PASS`(历史 + 新断言)。

- [ ] **Step 2: kill 活体验证(安全测试进程)**

```bash
sleep 300 & echo $!   # 记下一个用户态测试进程 PID
swift run AliyunTokenBar &   # 或打包后 open;面板打开→「本机」tab
```

人工确认清单(逐项肉眼可判):
1. 「本机」tab 恒显示(第 4 位,icon `cpu`);
2. CPU 子页签首采横杠、~3 秒后出值;Top 10 排序与活动监视器大体一致(允许 ±1 名抖动);
3. 内存子页签数值与活动监视器"内存"列大体一致(footprint 口径);
4. 找到 `sleep` 测试进程 → 点 kill → 变红色"确认?"→ 3 秒内再点 → `ps -p <PID>` 确认进程消失;
5. root 进程(如 WindowServer)有"系统"角标且 kill 置灰;
6. 关闭面板等 10 秒,重开面板数字继续更新(采样恢复);不采样期间无异常日志。
7. kill 测试完成后 kill 掉 AliyunTokenBar 自身进程。

- [ ] **Step 3: 打包发布**

```bash
pkill -f "AliyunTokenBar" 2>/dev/null; sleep 1
VERSION=1.0.25 ./packaging/build-package.sh
open dist/AliyunTokenBar.app
pgrep -fl "AliyunTokenBar.app/Contents/MacOS"   # 确认进程存活
```

- [ ] **Step 4: Commit(如有验证中发现的小修)**

若 Step 2 发现问题并修复,修复后重新跑 Step 1-3,然后:

```bash
git add <修复文件>
git commit -m "fix(processes): <具体修复内容>"
```

无修复则跳过本步。

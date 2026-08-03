# 面板「本机」tab:进程占用 Top 10 + kill — 设计文档

日期:2026-08-03
状态:已确认(grilling Q1-Q11 锁定 + 分节评审通过)

## 目标

在面板新增第 4 个 tab「本机」:分段切换显示 CPU / 内存占用前 10 的进程,识别对应 app(名称+图标),支持面板内两步确认 kill(SIGKILL)。

## grilling 锁定的需求决策(Q1-Q11)

| # | 决策点 | 共识 |
|---|---|---|
| Q1 | 布局 | tab 内分段切换 CPU / 内存,一次显示一个列表 |
| Q2 | 范围 | 所有进程上榜;root 进程标"系统"灰角标,kill 按钮置灰 |
| Q3 | 识别 | libproc 取路径 → .app 进程显示 app 名+图标;非 app 显示进程名+齿轮;**不合并**同名子进程 |
| Q4 | kill 确认 | 两步确认:点 kill → 按钮原地变红"确认?"(3 秒超时还原);无一键全杀 |
| Q5 | 刷新 | 开面板即采一次;打开期间每 3 秒自动刷新;手动刷新按钮;关面板停止采样 |
| Q6 | 内存指标 | footprint(`ri_phys_footprint`,对齐活动监视器),人类可读单位 |
| Q7 | kill 信号 | SIGKILL(强杀,不做 SIGTERM 升级) |
| Q8 | 行内容 | 图标+app 名 / 副行进程名(仅当≠app 名)/ 数值+迷你进度条(相对本列表最大值)/ kill 按钮;**不显示 PID** |
| Q9 | tab | 恒显示,标题"本机",图标 `cpu`;不加设置开关 |
| Q10 | 自身 | 包含本 app 进程 |
| Q11 | 首采 | CPU% 首次显示横杠,3 秒后出真值 |

另定(非争议项):每 3 秒重排序行会跳动(不做动画稳定);kill 失败不弹错(下轮刷新自然消失)。

## 架构

```
ProcessListMonitor (Core, 新增)
  ├─ start(3s)/stop()  ← 面板 onAppear/onDisappear
  ├─ proc_listallpids + proc_pidinfo(PROC_PIDTASKINFO) CPU ticks 差值
  ├─ proc_pid_rusage → ri_phys_footprint(活动监视器口径)
  ├─ proc_pidpath → .app 段提取 → appName/图标路径
  └─ @Published snapshots: [ProcessSnapshot]
        │
        ▼ (面板订阅)
SystemProcessesCard (executable, 新增) — 分段 CPU|内存 + Top10 列表 + kill
```

与 SystemMetricsMonitor 同层同模式;纯函数(排序/格式化/路径解析/CPU 差值)拆出供 Verify 测试。

## 数据层: ProcessMonitorService

新文件 `Sources/AliyunTokenBarCore/ProcessMonitorService.swift`:

```swift
public struct ProcessSnapshot: Identifiable, Equatable {
    public let pid: Int32
    public let name: String          // 进程名
    public let appName: String       // app 显示名(.app 进程取 Bundle displayName;否则 = name)
    public let appPath: String?      // .app 路径(nil → 齿轮占位图标)
    public let cpuPercent: Double?   // nil = 首次采样未就绪(横杠)
    public let memoryBytes: UInt64   // footprint
    public let isRoot: Bool          // uid == 0
    public var id: Int32 { pid }
}

@MainActor
public final class ProcessListMonitor: ObservableObject {
    public static let shared = ProcessListMonitor()
    @Published public private(set) var snapshots: [ProcessSnapshot] = []
    public func start(interval: TimeInterval = 3)  // 幂等;首轮存基线,cpuPercent=nil
    public func stop()                              // 停 Timer + 清 snapshots 与基线
    public func refreshNow()                        // 手动刷新(立即采一次)
    public static func kill(_ pid: Int32) -> Bool   // Darwin.kill(pid, SIGKILL)
}
```

### 采样实现

- `proc_listallpids()` 取全部 PID;逐个:
  - `proc_pidinfo(PROC_PIDTASKINFO)` → `pti_total_user + pti_total_system`(CPU ticks);
  - `proc_pid_rusage` → `ri_phys_footprint`(内存,活动监视器口径);
  - `proc_pidinfo(PROC_PIDTBSDINFO)` → `pbi_uid`(0 = root)、`pbi_name`(进程名);
  - `proc_pidpath` → 可执行路径。
- 死进程(采样中途退出、返回错误)跳过,不报错。
- CPU% = (本轮 ticks - 上轮 ticks) ÷ 经过秒数(换算系数见下);首轮只存基线,`cpuPercent = nil`。
- **CPU ticks 单位校准**:`pti_total_user` 的时间单位需在实施时用 `top`/活动监视器对照校准一次(计划含校准步骤),换算系数以实测为准。
- `snapshots` 存**全量**进程快照;Top 10 的排序截断由纯函数(`topByCPU`/`topByMemory`)在 UI 侧按需执行。

### 纯函数(可测)

```swift
static func topByCPU(_ all: [ProcessSnapshot], limit: Int = 10) -> [ProcessSnapshot]   // 降序,nil 排最后
static func topByMemory(_ all: [ProcessSnapshot], limit: Int = 10) -> [ProcessSnapshot] // 降序
static func bytesToHuman(_ bytes: UInt64) -> String   // "1.2 GB" / "350 MB" / "0 B"
static func appBundlePath(fromExecutablePath path: String) -> String?  // 抽 ".app" 段;非 .app → nil
static func appDisplayName(appPath: String, fallbackName: String) -> String  // Bundle displayName ?? fallback
static func cpuPercent(previousTicks: UInt64, currentTicks: UInt64,
                       elapsedSeconds: Double, ticksPerSecond: Double) -> Double?  // elapsed<=0 → nil
```

依赖:零新依赖,纯 Darwin/libproc。

## 面板 UI: SystemProcessesCard

**Tab 接入**:`ProviderTab` 加 `case system`(title "本机",icon "cpu");`availableTabs` 恒包含(第 4 位);`selectedContent` 分发。

**结构**(与 OpenCodeCard/KimiCodeCard 同款骨架):
- 头部行:`cpu` 图标 + "本机进程" + 手动刷新按钮(`arrow.clockwise`);
- 分段切换:CPU | 内存(现有分段控件样式,`@State` 记录);
- 列表(当前子页签 Top 10),每行:
  - app 图标 20×20(`appPath` 非 nil → `NSWorkspace.shared.icon(forFile:)`;否则 `gearshape`);
  - 主行 appName(12pt);副行进程名(9pt 灰,**仅当 ≠ appName**);
  - 右侧数值(CPU `%.1f%%` 不钳制可 >100%;内存 `bytesToHuman`)+ 迷你进度条(相对**本列表最大值**);
  - root 进程:数值旁灰角标"系统",kill 按钮置灰禁用;
  - kill 按钮:常态灰色 `xmark.circle`;点击 → 该行变红色文字"确认?"(3 秒超时还原;`@State` 记录确认中 pid + 到期时间);二次点击执行 `ProcessListMonitor.kill(pid)`。
- 首次采样:CPU 子页签数值横杠,内存立即可用。
- 生命周期:`onAppear { ProcessListMonitor.shared.start() }` / `onDisappear { .stop() }`;列表订阅 `snapshots`。

## 测试(Verify 目标)

`Sources/Verify/main.swift` 追加断言:

1. **Top 10 排序**:CPU 降序 + nil 最后;内存降序;>10 截断;空列表安全;
2. **bytesToHuman**:0 / KB / 350 MB / 1.2 GB 边界;
3. **app 路径识别**:标准 Chrome 路径 → .app 段;`/usr/sbin/mDNSResponder` → nil;畸形路径安全;
4. **CPU% 差值**:差值计算、elapsed<=0 → nil、钳制/不钳制语义。

不测:kill(副作用)、Timer 时序;libproc 仅冒烟(返回列表非空)。

### 手工验证清单(实施后)

- 面板打开,「本机」tab 出现;CPU 首采横杠、3s 后出值;
- Top 10 与活动监视器排序大体一致(允许 ±1 名抖动);
- kill 安全测试进程(后台 `sleep 300`)→ 面板确认后进程消失;
- root 进程(WindowServer 等)角标 + 按钮置灰;
- 面板关闭后无后台采样。

## 排除项(YAGNI)

- 不合并同名子进程(Q3 锁定);不显示 PID(Q8);无一键全杀(Q4);
- SIGTERM 升级路径不做(Q7);行排序动画不做;kill 失败提示不做(刷新自然消失);
- 设置开关不加(Q9);菜单栏图标与本功能不耦合。

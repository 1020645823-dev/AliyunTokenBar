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
        // pid 复用/基线错位时 current < previous,&- 回绕会产生天文数字假值 → 视为新基线返回 nil(下轮自愈)
        guard elapsedSeconds > 0, currentTicks >= previousTicks else { return nil }
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

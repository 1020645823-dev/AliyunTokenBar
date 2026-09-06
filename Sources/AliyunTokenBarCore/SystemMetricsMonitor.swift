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
    /// 内存已用 GB(用于面板显示具体值)。stop()/未采样为 nil。
    @Published public private(set) var memoryUsedGB: Double?
    /// 内存总量 GB(用于面板显示具体值)。stop() 后为 nil(物理内存恒定但保留语义化)。
    @Published public private(set) var memoryTotalGB: Double?

    /// 采样间隔(秒)
    public static let sampleInterval: TimeInterval = 30

    private var timer: AnyCancellable?
    private var lastTicks: CPUTicks?

    /// 启动采样:立即取 CPU 基线 + 内存值;CPU 首个真实值在 30 秒后第一个周期出现,
    /// 期间 cpuPercent 为 nil(菜单栏显示横杠)。幂等:已在运行则 no-op。
    public func start() {
        guard timer == nil else { return }
        lastTicks = Self.sampleCPUTicks()
        if let pair = Self.sampleMemoryBytes() {
            memoryPercent = Self.memoryUsedPercent(active: pair.active,
                                                   wired: pair.wired,
                                                   compressed: pair.compressed,
                                                   pageSize: pair.pageSize,
                                                   totalBytes: pair.totalBytes)
            memoryUsedGB = Double(pair.usedBytes) / 1024.0 / 1024.0 / 1024.0
            memoryTotalGB = Double(pair.totalBytes) / 1024.0 / 1024.0 / 1024.0
        }
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
        memoryUsedGB = nil
        memoryTotalGB = nil
    }

    private func tick() {
        if let cur = Self.sampleCPUTicks() {
            if let prev = lastTicks {
                cpuPercent = Self.cpuPercent(previous: prev, current: cur)
            }
            lastTicks = cur
        }
        if let pair = Self.sampleMemoryBytes() {
            memoryPercent = Self.memoryUsedPercent(active: pair.active,
                                                   wired: pair.wired,
                                                   compressed: pair.compressed,
                                                   pageSize: pair.pageSize,
                                                   totalBytes: pair.totalBytes)
            memoryUsedGB = Double(pair.usedBytes) / 1024.0 / 1024.0 / 1024.0
            memoryTotalGB = Double(pair.totalBytes) / 1024.0 / 1024.0 / 1024.0
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
        guard buf.count % Int(CPU_STATE_MAX) == 0 else { return nil }
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
    /// totalBytes=0 或 pageSize=0 → nil;结果钳制 0-100。
    public static func memoryUsedPercent(active: UInt64, wired: UInt64, compressed: UInt64,
                                         pageSize: UInt64, totalBytes: UInt64) -> Int? {
        guard totalBytes > 0 else { return nil }
        guard pageSize > 0 else { return nil }
        let used = (active + wired + compressed) * pageSize
        let pct = Double(used) / Double(totalBytes) * 100
        return min(max(Int(pct.rounded()), 0), 100)
    }

    /// 一次采样 → 返回原始字节采样。host_statistics64 失败返回 nil。
    /// totalBytes = 物理内存(ProcessInfo)。
    /// 用例:面板"已用 / 总量 GB"展示。
    public struct MemorySample {
        public let active: UInt64
        public let wired: UInt64
        public let compressed: UInt64
        public let pageSize: UInt64
        public let totalBytes: UInt64
        public let usedBytes: UInt64
    }

    public static func sampleMemoryBytes() -> MemorySample? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let active = UInt64(stats.active_count)
        let wired = UInt64(stats.wire_count)
        let compressed = UInt64(stats.compressor_page_count)
        let pageSize = UInt64(vm_kernel_page_size)
        let totalBytes = ProcessInfo.processInfo.physicalMemory
        let usedBytes = (active + wired + compressed) &* pageSize
        return MemorySample(active: active, wired: wired, compressed: compressed,
                           pageSize: pageSize, totalBytes: totalBytes, usedBytes: usedBytes)
    }
}

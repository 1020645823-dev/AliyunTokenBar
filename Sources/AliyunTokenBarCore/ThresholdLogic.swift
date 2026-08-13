import Foundation

// MARK: - 用量阈值分段

/// 用量百分比所属的风险分段(用于颜色与通知)。
///
/// 与 Provider 品牌色正交:品牌色用图标形状/前缀编码「是哪家」,
/// `UsageBand` 编码「风险多高」——同一个数字承载不同语义维度,
/// 避免早期「95% 与 30% 视觉无差异」的仪表盘失效问题。
public enum UsageBand: Int, Comparable, Equatable {
    case safe = 0      // < warning
    case warning = 1   // warning ..< critical
    case critical = 2  // >= critical

    public static func < (lhs: UsageBand, rhs: UsageBand) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// 阈值配置:默认 warning 80 / critical 90(对齐 CursorMeter 80/90、
/// ClaudeMeter 70/90、coding-plan-monitor 90 的中位实践)。
/// 用户可在设置改;约束:0 < warning < critical <= 100。
public struct ThresholdConfig: Equatable {
    public let warning: Int
    public let critical: Int

    public init(warning: Int = 80, critical: Int = 90) {
        // 钳制:保证不变式 warning < critical,warn 至少 1,critical 不超 100
        let w = max(1, min(warning, 99))
        self.warning = w
        self.critical = max(w + 1, min(critical, 100))
    }

    public func band(for pct: Int) -> UsageBand {
        if pct >= critical { return .critical }
        if pct >= warning { return .warning }
        return .safe
    }
}

// MARK: - 通知状态机(带迟滞,避免抖动)

/// 跟踪每个被监听窗口(如「阿里云-5h」「OpenCode-rolling」)当前所处 band,
/// 仅在**上行跨越**到更高级别时判定应发通知;回落/同级不重复打扰。
///
/// 纯值类型 + 可注入时钟:逻辑层零依赖,Verify 可全覆盖;
/// 真正弹通知的副作用由调用方经 `shouldNotify` 结果决定(见 executable 层 NotificationManager)。
public struct NotificationState: Equatable {
    /// 单个被监听窗口的最新已知 band;未见过则为 nil。
    public private(set) var lastBand: UsageBand?

    public init(lastBand: UsageBand? = nil) {
        self.lastBand = lastBand
    }

    /// 用新百分比更新状态。
    /// - Returns: 若应弹通知(上行跨越到更高级别),返回新 band;否则 nil。
    @discardableResult
    public mutating func update(percentage pct: Int, config: ThresholdConfig) -> UsageBand? {
        let band = config.band(for: pct)
        // 仅「严格高于上次」才通知:回落(95→60)不弹、同级(82→85)不弹、首次(none→any)弹
        if lastBand == nil || band > lastBand! {
            lastBand = band
            return band
        }
        lastBand = band
        return nil
    }
}

/// 窗口标识(Provider + 窗口名),作为通知状态 map 的 key。
/// 用结构体而非拼字符串,避免 "a-bc" / "ab-c" 歧义。
public struct WatchKey: Hashable, Equatable {
    public let provider: String   // "aliyun" / "opencode"
    public let window: String     // "5h" / "7d" / "rolling" / "weekly" / "monthly"
    public init(provider: String, window: String) {
        self.provider = provider; self.window = window
    }
}

/// 多窗口通知状态集合:key → band 状态。
/// `TokenPlanModel` 持有一个实例,每次刷新后喂入各窗口百分比。
///
/// 首刷静默种子(P0-D3):App 启动后第一轮评估只记录各窗口当前 band,
/// **不弹任何通知**——否则空态"首见即弹"会让 3 Provider × 8 窗口一次
/// 弹满 8 条通知(通知风暴,直接摧毁用户信任)。种子后的正常迟滞语义不变。
public struct NotificationTracker: Equatable {
    public private(set) var states: [WatchKey: NotificationState] = [:]
    /// 是否已完成首轮种子(私有:Equatable 合成时随 states 一起比对)
    private var primed = false
    public init() {}

    /// 更新一个窗口,返回应触发的 band(如有)。nil = 不打扰。
    /// 未完成种子时只记录不返回触发(静默)。
    @discardableResult
    public mutating func update(
        key: WatchKey, percentage pct: Int, config: ThresholdConfig
    ) -> UsageBand? {
        var st = states[key] ?? NotificationState()
        let fired = st.update(percentage: pct, config: config)
        states[key] = st
        return primed ? fired : nil
    }

    /// 一次性评估多个窗口,返回应通知的 (key, band) 列表(顺序与输入一致)。
    /// 首轮为静默种子(返回空),其后按迟滞语义正常触发。
    public mutating func evaluate(
        _ entries: [(key: WatchKey, pct: Int)], config: ThresholdConfig
    ) -> [(WatchKey, UsageBand)] {
        var out: [(WatchKey, UsageBand)] = []
        for e in entries {
            if let band = update(key: e.key, percentage: e.pct, config: config) {
                out.append((e.key, band))
            }
        }
        primed = true
        return out
    }

    /// 重置(切账号/登出时清空,避免下次登录沿用旧 band)。重置后重新进入静默种子期。
    public mutating func reset() {
        states.removeAll()
        primed = false
    }

    /// 清除某 Provider 的所有窗口记忆(登出时用)。
    public mutating func clear(provider: String) {
        states = states.filter { $0.key.provider != provider }
    }
}

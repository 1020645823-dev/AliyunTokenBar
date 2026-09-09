import Foundation

// MARK: - 菜单栏迷你表格(纯数据模型)
//
// 列过滤/横杠/tooltip 文案全部在此,Verify 无 UI 全覆盖;
// 渲染层(App 目标 miniTableImage)只负责把 [MenuBarTableColumn] 画出来。

/// 单个值:展示文本 + 原始百分比(pct 供阈值变色;nil = 横杠,不着色)。
public struct MenuBarTableValue: Equatable {
    public let text: String
    public let pct: Int?
    public init(text: String, pct: Int?) {
        self.text = text
        self.pct = pct
    }
}

/// 列身份:固定顺序即 CaseIterable 声明顺序 ☁→✨→⚡→🧠→∞→▣(本机恒最后)。
public enum MenuBarColumnKind: String, CaseIterable, Equatable {
    case aliyun, kimi, openCode, deepSeek, minimax, system

    public var symbolName: String {
        switch self {
        case .aliyun: return "cloud.fill"
        case .kimi: return "sparkles"
        case .openCode: return "bolt.fill"
        case .deepSeek: return "brain.head.profile"
        case .minimax: return "infinity"
        case .system: return "desktopcomputer"
        }
    }
    public var displayName: String {
        switch self {
        case .aliyun: return "阿里云"
        case .kimi: return "Kimi"
        case .openCode: return "OpenCode"
        case .deepSeek: return "DeepSeek"
        case .minimax: return "MiniMax"
        case .system: return "本机"
        }
    }
    /// 上行(主窗口)tooltip 标签
    public var primaryLabel: String {
        switch self {
        case .aliyun, .kimi: return "5小时"
        case .openCode: return "滚动"
        case .deepSeek: return "今日"
        case .minimax: return "本窗"
        case .system: return "CPU"
        }
    }
    /// 下行(次窗口)tooltip 标签
    public var secondaryLabel: String {
        switch self {
        case .aliyun: return "7天"
        case .kimi, .openCode, .minimax: return "周"
        case .deepSeek: return "余额"
        case .system: return "内存"
        }
    }
}

public struct MenuBarTableColumn: Equatable {
    public let kind: MenuBarColumnKind
    public let primary: MenuBarTableValue    // 上行:5h/5h/滚/CPU
    public let secondary: MenuBarTableValue  // 下行:7d/周/周/内存
    /// 上行 tooltip 标签(默认取 kind.primaryLabel)。
    public let primaryLabel: String
    /// 下行 tooltip 标签(默认取 kind.secondaryLabel);nil = 单值列,tooltip 省略下行。
    public let secondaryLabel: String?
    public init(kind: MenuBarColumnKind, primary: MenuBarTableValue, secondary: MenuBarTableValue) {
        self.kind = kind
        self.primary = primary
        self.secondary = secondary
        self.primaryLabel = kind.primaryLabel
        self.secondaryLabel = kind.secondaryLabel
    }
    /// 单值列:仅上行有指标(如阿里云 5h 窗口取消后只显 7d);次行仍给值(横杠)保持网格对齐。
    public init(singleValueKind kind: MenuBarColumnKind, primary: MenuBarTableValue,
                primaryLabel: String, secondary: MenuBarTableValue) {
        self.kind = kind
        self.primary = primary
        self.secondary = secondary
        self.primaryLabel = primaryLabel
        self.secondaryLabel = nil
    }
}

public enum MenuBarTable {
    /// 值 → 展示文本:nil → 横杠(沿用菜单栏既有约定)。
    static func value(_ pct: Int?) -> MenuBarTableValue {
        MenuBarTableValue(text: pct.map { "\($0)%" } ?? "—", pct: pct)
    }

    /// 金额 → 展示文本(DeepSeek 列专用):nil → 横杠;紧凑格式 ≤7 字符。
    /// pct 恒为 nil(金额不做阈值变色)。
    static func moneyValue(_ v: Double?) -> MenuBarTableValue {
        MenuBarTableValue(text: v.map { DeepSeekMoneyFormat.compact($0) } ?? "—", pct: nil)
    }

    /// 计算可见列(输出顺序恒为 ☁→✨→⚡→🧠→∞→▣,与配置无关;本机恒最后)。
    /// disabled(ProviderKind.rawValue 集合,设置页「数据源」开关)中的列一律不出,
    /// 含阿里云(不再恒显示);全部停用时返回空数组,渲染层降级仅图标。
    /// 启用列中:阿里云直接出列;Kimi/OpenCode/DeepSeek/MiniMax 已配置且(有数据或出错)时显示,
    /// 出错→横杠;本机启用时显示,采样未就绪→横杠。
    public static func columns(
        aliyunFiveHour: Int?, aliyunOneWeek: Int?,
        kimiConfigured: Bool, kimiHasError: Bool, kimiFiveHour: Int?, kimiWeekly: Int?,
        openCodeConfigured: Bool, openCodeHasError: Bool, openCodeRolling: Int?, openCodeWeekly: Int?,
        deepSeekConfigured: Bool, deepSeekHasError: Bool, deepSeekTodayCost: Double?, deepSeekBalance: Double?,
        minimaxConfigured: Bool, minimaxHasError: Bool, minimaxInterval: Int?, minimaxWeekly: Int?,
        systemEnabled: Bool, cpu: Int?, memory: Int?,
        disabled: Set<String> = []
    ) -> [MenuBarTableColumn] {
        func off(_ kind: MenuBarColumnKind) -> Bool {
            disabled.contains(ProviderKind.from(menuBarColumnKind: kind).rawValue)
        }
        var cols: [MenuBarTableColumn] = []
        if !off(.aliyun) {
            cols.append(aliyunColumn(fiveHour: aliyunFiveHour, oneWeek: aliyunOneWeek))
        }
        if !off(.kimi) && kimiConfigured && (kimiHasError || kimiFiveHour != nil || kimiWeekly != nil) {
            cols.append(MenuBarTableColumn(kind: .kimi,
                                           primary: value(kimiFiveHour), secondary: value(kimiWeekly)))
        }
        if !off(.openCode) && openCodeConfigured && (openCodeHasError || openCodeRolling != nil || openCodeWeekly != nil) {
            cols.append(MenuBarTableColumn(kind: .openCode,
                                           primary: value(openCodeRolling), secondary: value(openCodeWeekly)))
        }
        if !off(.deepSeek) && deepSeekConfigured && (deepSeekHasError || deepSeekTodayCost != nil || deepSeekBalance != nil) {
            cols.append(MenuBarTableColumn(kind: .deepSeek,
                                           primary: moneyValue(deepSeekTodayCost), secondary: moneyValue(deepSeekBalance)))
        }
        if !off(.minimax) && minimaxConfigured && (minimaxHasError || minimaxInterval != nil || minimaxWeekly != nil) {
            cols.append(MenuBarTableColumn(kind: .minimax,
                                           primary: value(minimaxInterval), secondary: value(minimaxWeekly)))
        }
        if !off(.system) && systemEnabled {
            cols.append(MenuBarTableColumn(kind: .system,
                                           primary: value(cpu), secondary: value(memory)))
        }
        return cols
    }

    /// 阿里云列:5h 窗口存在 → 主=5h/次=7d;窗口缺失(2026-08-15 官方限时取消 5h 限额,
    /// 服务端不再返回 per5Hour 字段)→ 单值列,主行直接显示 7d,次行横杠保持网格对齐。
    /// 完全无数据(主行也横杠)同样走单值形态,标签仍标 7d。
    static func aliyunColumn(fiveHour: Int?, oneWeek: Int?) -> MenuBarTableColumn {
        guard let f5 = fiveHour else {
            return MenuBarTableColumn(singleValueKind: .aliyun,
                                      primary: value(oneWeek), primaryLabel: "7天",
                                      secondary: value(nil))
        }
        return MenuBarTableColumn(kind: .aliyun, primary: value(f5), secondary: value(oneWeek))
    }

    /// 悬停 tooltip:每列「名称 主标签 值 · 次标签 值」,列间「 | 」分隔;
    /// 单值列(secondaryLabel == nil)省略次段。
    public static func tooltip(columns: [MenuBarTableColumn]) -> String {
        columns.map { col -> String in
            var text = "\(col.kind.displayName) \(col.primaryLabel) \(col.primary.text)"
            if let secondaryLabel = col.secondaryLabel {
                text += " · \(secondaryLabel) \(col.secondary.text)"
            }
            return text
        }.joined(separator: " | ")
    }
}

extension TokenPlanModel {
    /// 从模型现值计算迷你表格列(菜单栏渲染与 tooltip 共用这一个映射)。
    /// 可见性语义与原 renderIconSink 内联逻辑一致:
    /// Kimi/OpenCode = 有数据,或已配置且出错(→横杠列);本机 = 开关开。
    public func menuBarColumns() -> [MenuBarTableColumn] {
        let monitor = SystemMetricsMonitor.shared
        return MenuBarTable.columns(
            aliyunFiveHour: quota?.usage.fiveHour?.percentageInt,
            aliyunOneWeek: quota?.usage.oneWeek.percentageInt,
            kimiConfigured: kimiConfigured, kimiHasError: kimiError != nil,
            kimiFiveHour: kimiQuota?.fiveHour.pctInt, kimiWeekly: kimiQuota?.weekly.pctInt,
            openCodeConfigured: openCodeConfigured, openCodeHasError: openCodeError != nil,
            openCodeRolling: openCodeQuota?.rolling.pct, openCodeWeekly: openCodeQuota?.weekly.pct,
            deepSeekConfigured: deepSeekConfigured, deepSeekHasError: deepSeekError != nil,
            deepSeekTodayCost: deepSeekTodayCost?.cost, deepSeekBalance: deepSeekBalance?.totalBalance,
            minimaxConfigured: minimaxConfigured, minimaxHasError: minimaxError != nil,
            minimaxInterval: minimaxQuota?.interval?.pctInt, minimaxWeekly: minimaxQuota?.weekly?.pctInt,
            systemEnabled: systemStatsEnabled && isEnabled(.system),
            cpu: monitor.cpuPercent, memory: monitor.memoryPercent,
            disabled: disabledProviders)
    }
}

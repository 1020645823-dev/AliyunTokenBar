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

/// 列身份:固定顺序即 CaseIterable 声明顺序 ☁→✨→⚡→▣。
public enum MenuBarColumnKind: String, CaseIterable, Equatable {
    case aliyun, kimi, openCode, system

    public var symbolName: String {
        switch self {
        case .aliyun: return "cloud.fill"
        case .kimi: return "sparkles"
        case .openCode: return "bolt.fill"
        case .system: return "desktopcomputer"
        }
    }
    public var displayName: String {
        switch self {
        case .aliyun: return "阿里云"
        case .kimi: return "Kimi"
        case .openCode: return "OpenCode"
        case .system: return "本机"
        }
    }
    /// 上行(主窗口)tooltip 标签
    public var primaryLabel: String {
        switch self {
        case .aliyun, .kimi: return "5小时"
        case .openCode: return "滚动"
        case .system: return "CPU"
        }
    }
    /// 下行(次窗口)tooltip 标签
    public var secondaryLabel: String {
        switch self {
        case .aliyun: return "7天"
        case .kimi, .openCode: return "周"
        case .system: return "内存"
        }
    }
}

public struct MenuBarTableColumn: Equatable {
    public let kind: MenuBarColumnKind
    public let primary: MenuBarTableValue    // 上行:5h/5h/滚/CPU
    public let secondary: MenuBarTableValue  // 下行:7d/周/周/内存
    public init(kind: MenuBarColumnKind, primary: MenuBarTableValue, secondary: MenuBarTableValue) {
        self.kind = kind
        self.primary = primary
        self.secondary = secondary
    }
}

public enum MenuBarTable {
    /// 值 → 展示文本:nil → 横杠(沿用菜单栏既有约定)。
    static func value(_ pct: Int?) -> MenuBarTableValue {
        MenuBarTableValue(text: pct.map { "\($0)%" } ?? "—", pct: pct)
    }

    /// 计算可见列(输出顺序恒为 ☁→✨→⚡→▣,与配置无关)。
    /// 阿里云恒显示;Kimi/OpenCode 已配置且(有数据或出错)时显示,出错→横杠;
    /// 本机开关开时显示,采样未就绪→横杠。
    public static func columns(
        aliyunFiveHour: Int?, aliyunOneWeek: Int?,
        kimiConfigured: Bool, kimiHasError: Bool, kimiFiveHour: Int?, kimiWeekly: Int?,
        openCodeConfigured: Bool, openCodeHasError: Bool, openCodeRolling: Int?, openCodeWeekly: Int?,
        systemEnabled: Bool, cpu: Int?, memory: Int?
    ) -> [MenuBarTableColumn] {
        var cols: [MenuBarTableColumn] = [
            MenuBarTableColumn(kind: .aliyun,
                               primary: value(aliyunFiveHour), secondary: value(aliyunOneWeek))
        ]
        if kimiConfigured && (kimiHasError || kimiFiveHour != nil || kimiWeekly != nil) {
            cols.append(MenuBarTableColumn(kind: .kimi,
                                           primary: value(kimiFiveHour), secondary: value(kimiWeekly)))
        }
        if openCodeConfigured && (openCodeHasError || openCodeRolling != nil || openCodeWeekly != nil) {
            cols.append(MenuBarTableColumn(kind: .openCode,
                                           primary: value(openCodeRolling), secondary: value(openCodeWeekly)))
        }
        if systemEnabled {
            cols.append(MenuBarTableColumn(kind: .system,
                                           primary: value(cpu), secondary: value(memory)))
        }
        return cols
    }

    /// 悬停 tooltip:每列「名称 主标签 值 · 次标签 值」,列间「 | 」分隔。
    public static func tooltip(columns: [MenuBarTableColumn]) -> String {
        columns.map { col in
            "\(col.kind.displayName) \(col.kind.primaryLabel) \(col.primary.text) · \(col.kind.secondaryLabel) \(col.secondary.text)"
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
            aliyunFiveHour: quota?.usage.fiveHour.percentageInt,
            aliyunOneWeek: quota?.usage.oneWeek.percentageInt,
            kimiConfigured: kimiConfigured, kimiHasError: kimiError != nil,
            kimiFiveHour: kimiQuota?.fiveHour.pctInt, kimiWeekly: kimiQuota?.weekly.pctInt,
            openCodeConfigured: openCodeConfigured, openCodeHasError: openCodeError != nil,
            openCodeRolling: openCodeQuota?.rolling.pct, openCodeWeekly: openCodeQuota?.weekly.pct,
            systemEnabled: systemStatsEnabled,
            cpu: monitor.cpuPercent, memory: monitor.memoryPercent)
    }
}

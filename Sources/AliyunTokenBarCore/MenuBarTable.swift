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

/// 列身份:固定顺序即 CaseIterable 声明顺序 ☁→✨→⚡→→⚛→〜→∞→🪜→▣(本机恒最后)。
public enum MenuBarColumnKind: String, CaseIterable, Equatable {
    case aliyun, kimi, openCode, deepSeek, zhipu, mimo, minimax, ollama, stepfun, system

    public var symbolName: String {
        switch self {
        case .aliyun: return "cloud.fill"
        case .kimi: return "sparkles"
        case .openCode: return "bolt.fill"
        case .deepSeek: return "brain.head.profile"
        case .zhipu: return "atom"
        case .mimo: return "waveform"
        case .minimax: return "infinity"
        case .ollama: return "hare.fill"
        case .stepfun: return "stairs"
        case .system: return "desktopcomputer"
        }
    }
    public var displayName: String {
        switch self {
        case .aliyun: return "阿里云"
        case .kimi: return "Kimi"
        case .openCode: return "OpenCode"
        case .deepSeek: return "DeepSeek"
        case .zhipu: return "智谱"
        case .mimo: return "MiMo"
        case .minimax: return "MiniMax"
        case .ollama: return "Ollama"
        case .stepfun: return "阶跃"
        case .system: return "本机"
        }
    }
    /// 上行(主窗口)tooltip 标签
    public var primaryLabel: String {
        switch self {
        case .aliyun, .kimi, .zhipu: return "5小时"
        case .openCode: return "滚动"
        case .deepSeek: return "今日"
        case .minimax: return "本窗"
        case .mimo: return "套餐"
        case .ollama: return "30天"
        case .stepfun: return "月池"
        case .system: return "CPU"
        }
    }
    /// 下行(次窗口)tooltip 标签
    public var secondaryLabel: String {
        switch self {
        case .aliyun: return "7天"
        case .kimi, .openCode, .minimax, .zhipu: return "周"
        case .deepSeek: return "余额"
        case .mimo: return "余额"
        case .ollama: return "周"
        case .stepfun: return "加油包"
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
    /// 双值列 + 显式标签:同一 provider 的主窗口标签随数据形态变化时用
    /// (Ollama 新计费=月度单值列,旧计费=5小时+周双值列,而 kind 默认标签只有一个)。
    public init(kind: MenuBarColumnKind, primary: MenuBarTableValue, secondary: MenuBarTableValue,
                primaryLabel: String, secondaryLabel: String?) {
        self.kind = kind
        self.primary = primary
        self.secondary = secondary
        self.primaryLabel = primaryLabel
        self.secondaryLabel = secondaryLabel
    }
}

public enum MenuBarTable {
    /// 值 → 展示文本:nil → 横杠(沿用菜单栏既有约定)。
    static func value(_ pct: Int?) -> MenuBarTableValue {
        MenuBarTableValue(text: pct.map { "\($0)%" } ?? "—", pct: pct)
    }

    /// 金额 → 展示文本(DeepSeek 列专用):nil → 横杠;紧凑格式 ≤5 字符(无币种符号,值域 34pt 与百分比列统一)。
    /// pct 恒为 nil(金额不做阈值变色)。
    static func moneyValue(_ v: Double?) -> MenuBarTableValue {
        MenuBarTableValue(text: v.map { DeepSeekMoneyFormat.compactDigits($0) } ?? "—", pct: nil)
    }

    /// 金额 → 展示文本(MiMo 余额行专用):nil → 横杠;紧凑格式 ≤5 字符(同 DeepSeek 契约,菜单栏省币种符号)。
    static func mimoMoney(_ v: Double?) -> MenuBarTableValue {
        MenuBarTableValue(text: v.map { MiMoMoneyFormat.compactDigits($0) } ?? "—", pct: nil)
    }

    /// 计算可见列(输出顺序恒为 ☁→✨→⚡→🧠→∞→▣,与配置无关;本机恒最后)。
    /// disabled(ProviderKind.rawValue 集合,设置页「数据源」开关)中的列一律不出,
    /// 含阿里云(不再恒显示);全部停用时返回空数组,渲染层降级仅图标。
    /// 启用列中:阿里云直接出列;Kimi/OpenCode/DeepSeek/智谱/MiniMax 已配置且(有数据或出错)时显示,
    /// 出错→横杠;MiMo 同规则(主行套餐% 可为横杠,次行余额);本机启用时显示,采样未就绪→横杠。
    public static func columns(
        aliyunFiveHour: Int?, aliyunOneWeek: Int?, aliyunOneMonth: Int?,
        kimiConfigured: Bool, kimiHasError: Bool, kimiFiveHour: Int?, kimiWeekly: Int?,
        openCodeConfigured: Bool, openCodeHasError: Bool, openCodeRolling: Int?, openCodeWeekly: Int?,
        deepSeekConfigured: Bool, deepSeekHasError: Bool, deepSeekTodayCost: Double?, deepSeekBalance: Double?,
        zhipuConfigured: Bool, zhipuHasError: Bool, zhipuFiveHour: Int?, zhipuWeekly: Int?,
        mimoConfigured: Bool, mimoHasError: Bool, mimoPlanPct: Int?, mimoBalance: Double?,
        minimaxConfigured: Bool, minimaxHasError: Bool, minimaxInterval: Int?, minimaxWeekly: Int?,
        ollamaConfigured: Bool, ollamaHasError: Bool, ollamaPrimary: Int?, ollamaSecondary: Int?,
        stepfunConfigured: Bool, stepfunHasError: Bool, stepfunPrimary: Int?, stepfunPrimaryLabel: String?,
        stepfunSecondary: Int?, stepfunSecondaryLabel: String?,
        systemEnabled: Bool, cpu: Int?, memory: Int?,
        disabled: Set<String> = []
    ) -> [MenuBarTableColumn] {
        func off(_ kind: MenuBarColumnKind) -> Bool {
            disabled.contains(ProviderKind.from(menuBarColumnKind: kind).rawValue)
        }
        var cols: [MenuBarTableColumn] = []
        if !off(.aliyun) {
            cols.append(aliyunColumn(fiveHour: aliyunFiveHour, oneWeek: aliyunOneWeek, oneMonth: aliyunOneMonth))
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
        if !off(.zhipu) && zhipuConfigured && (zhipuHasError || zhipuFiveHour != nil || zhipuWeekly != nil) {
            cols.append(MenuBarTableColumn(kind: .zhipu,
                                           primary: value(zhipuFiveHour), secondary: value(zhipuWeekly)))
        }
        // MiMo:主行=Token 套餐已用%(无套餐→横杠),次行=余额紧凑金额(无币种符号,同 DeepSeek 列宽契约)。
        if !off(.mimo) && mimoConfigured && (mimoHasError || mimoPlanPct != nil || mimoBalance != nil) {
            cols.append(MenuBarTableColumn(kind: .mimo,
                                           primary: value(mimoPlanPct),
                                           secondary: mimoMoney(mimoBalance)))
        }
        if !off(.minimax) && minimaxConfigured && (minimaxHasError || minimaxInterval != nil || minimaxWeekly != nil) {
            cols.append(MenuBarTableColumn(kind: .minimax,
                                           primary: value(minimaxInterval), secondary: value(minimaxWeekly)))
        }
        // Ollama:新计费只有月度窗口 → 单值列(主=月度,标签改「月度」,次行横杠);
        // 旧计费套餐返回 session+weekly → 双值列(主=5h,次=周)。窗口子集由数据决定。
        if !off(.ollama) && ollamaConfigured && (ollamaHasError || ollamaPrimary != nil || ollamaSecondary != nil) {
            cols.append(ollamaColumn(primary: ollamaPrimary, secondary: ollamaSecondary))
        }
        // 阶跃 Step Plan:标签随计费形态(月池/加油包 或 5小时/周),由调用方按数据传入;
        // 无次窗口(仅订阅月池)→ 单值列。
        if !off(.stepfun) && stepfunConfigured && (stepfunHasError || stepfunPrimary != nil || stepfunSecondary != nil) {
            cols.append(stepfunColumn(primary: stepfunPrimary, primaryLabel: stepfunPrimaryLabel,
                                      secondary: stepfunSecondary, secondaryLabel: stepfunSecondaryLabel))
        }
        if !off(.system) && systemEnabled {
            cols.append(MenuBarTableColumn(kind: .system,
                                           primary: value(cpu), secondary: value(memory)))
        }
        return cols
    }

    /// 阿里云列(三窗口按数据形态变形):
    /// - 5h + 主窗(周/月)→ 双值列:主=5h,次=主窗(标签随实际窗口 7天/30天);
    /// - 仅主窗(2026-08-15 官方取消 5h 后常态)→ 单值列,主行显示主窗,次行横杠;
    /// - 完全无数据(主行也横杠)同样走单值形态,标签跟随主窗。
    /// 主窗取 oneMonth ?? oneWeek(2026-09 官方取消周限改月限;两者现实中不同时返回)。
    static func aliyunColumn(fiveHour: Int?, oneWeek: Int?, oneMonth: Int?) -> MenuBarTableColumn {
        let mainPct = oneMonth ?? oneWeek
        let mainLabel = oneMonth != nil ? "30天" : "7天"
        guard let f5 = fiveHour else {
            return MenuBarTableColumn(singleValueKind: .aliyun,
                                      primary: value(mainPct), primaryLabel: mainLabel,
                                      secondary: value(nil))
        }
        return MenuBarTableColumn(kind: .aliyun,
                                  primary: value(f5), secondary: value(mainPct),
                                  primaryLabel: "5小时", secondaryLabel: mainLabel)
    }

    /// Ollama 列:2026-10-09 起 /api/usage 只回报近 30 天美元报表,**只有
    /// 月度(滚动 30 天 vs 套餐额度)一个口径** → 单值列,主行显示占比、
    /// 标签「30天」,次行横杠保持网格对齐。
    /// 次窗口分支是防御性保留:旧结构(session+weekly)已从服务端消失,
    /// 万一回退也能按 5小时/周 双值列展示。
    static func ollamaColumn(primary: Int?, secondary: Int?) -> MenuBarTableColumn {
        guard secondary != nil else {
            return MenuBarTableColumn(singleValueKind: .ollama,
                                      primary: value(primary), primaryLabel: "30天",
                                      secondary: value(nil))
        }
        // 旧套餐:primary 实为 session(5h) → 显式标签「5小时/周」
        // (kind 默认标签是「30天」,对新计费正确、对旧计费错误,故此处显式覆盖)。
        return MenuBarTableColumn(kind: .ollama,
                                  primary: value(primary), secondary: value(secondary),
                                  primaryLabel: "5小时", secondaryLabel: "周")
    }

    /// 阶跃 Step Plan 列:标签显式传入(新计费=月池/加油包;旧计费=5小时/周),
    /// 因为仅凭「次窗口有无值」无法区分两种形态(月池+加油包 与 5h+周 都是双值)。
    /// 无次窗口 → 单值列(kind 默认主标签「月池」,次行横杠)。
    static func stepfunColumn(primary: Int?, primaryLabel: String?,
                              secondary: Int?, secondaryLabel: String?) -> MenuBarTableColumn {
        guard let secondary, let secondaryLabel else {
            return MenuBarTableColumn(singleValueKind: .stepfun,
                                      primary: value(primary),
                                      primaryLabel: primaryLabel ?? MenuBarColumnKind.stepfun.primaryLabel,
                                      secondary: value(nil))
        }
        return MenuBarTableColumn(kind: .stepfun,
                                  primary: value(primary), secondary: value(secondary),
                                  primaryLabel: primaryLabel ?? MenuBarColumnKind.stepfun.primaryLabel,
                                  secondaryLabel: secondaryLabel)
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
            aliyunOneWeek: quota?.usage.oneWeek?.percentageInt,
            aliyunOneMonth: quota?.usage.oneMonth?.percentageInt,
            kimiConfigured: kimiConfigured, kimiHasError: kimiError != nil,
            kimiFiveHour: kimiQuota?.fiveHour.pctInt, kimiWeekly: kimiQuota?.weekly.pctInt,
            openCodeConfigured: openCodeConfigured, openCodeHasError: openCodeError != nil,
            openCodeRolling: openCodeQuota?.rolling.pct, openCodeWeekly: openCodeQuota?.weekly.pct,
            deepSeekConfigured: deepSeekConfigured, deepSeekHasError: deepSeekError != nil,
            deepSeekTodayCost: deepSeekTodayCost?.cost, deepSeekBalance: deepSeekBalance?.totalBalance,
            zhipuConfigured: zhipuConfigured, zhipuHasError: zhipuError != nil,
            zhipuFiveHour: zhipuQuota?.fiveHour?.pctInt, zhipuWeekly: zhipuQuota?.weekly?.pctInt,
            mimoConfigured: mimoConfigured, mimoHasError: mimoError != nil,
            mimoPlanPct: mimoUsage?.plan.map { Int($0.usedPct.rounded()) },
            mimoBalance: mimoUsage?.balance.balance,
            minimaxConfigured: minimaxConfigured, minimaxHasError: minimaxError != nil,
            minimaxInterval: minimaxQuota?.interval?.pctInt, minimaxWeekly: minimaxQuota?.weekly?.pctInt,
            ollamaConfigured: ollamaConfigured, ollamaHasError: ollamaError != nil,
            ollamaPrimary: ollamaQuota?.primary.map { Int($0.pct.rounded()) },
            ollamaSecondary: ollamaQuota?.secondary.map { Int($0.pct.rounded()) },
            stepfunConfigured: stepfunConfigured, stepfunHasError: stepfunError != nil,
            stepfunPrimary: stepfunQuota?.primaryPct, stepfunPrimaryLabel: stepfunQuota?.primaryLabel,
            stepfunSecondary: stepfunQuota?.secondaryPct, stepfunSecondaryLabel: stepfunQuota?.secondaryLabel,
            systemEnabled: systemStatsEnabled && isEnabled(.system),
            cpu: monitor.cpuPercent, memory: monitor.memoryPercent,
            disabled: disabledProviders)
    }
}

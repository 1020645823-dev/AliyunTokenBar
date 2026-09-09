import Foundation

// MARK: - 统一 Provider Registry
//
// 此前有三套并行枚举/标志:面板 ProviderTab(App 层 8 case)、菜单栏
// MenuBarColumnKind(6 case,缺智谱/MiMo)、模型上的 xxxConfigured 计算属性;
// provider 数量还硬编码散落在 refreshAll、面板刷新按钮、通知聚合、每日摘要
// (各处"数 7")。本文件用单一 ProviderKind 收口「有哪些数据源」:
// 显示开关、configured 判定、刷新调度、tab/列过滤全部由它驱动。
//
// 两套顺序刻意不同,各自维持现状:
// - 面板 tab 顺序 = ProviderKind.allCases 声明顺序(同旧 ProviderTab);
// - 菜单栏列顺序 = MenuBarColumnKind 声明顺序(☁→✨→⚡→🧠→∞→▣,本机恒最后)。

/// 全部数据源(7 个订阅商 + 本机伪 provider)。
public enum ProviderKind: String, CaseIterable, Identifiable, Codable {
    case aliyun, openCode, kimi, deepSeek, zhipu, mimo, minimax, system
    public var id: String { rawValue }

    /// 设置页/摘要用展示名。
    public var displayName: String {
        switch self {
        case .aliyun: return "阿里云"
        case .openCode: return "OpenCode"
        case .kimi: return "Kimi"
        case .deepSeek: return "DeepSeek"
        case .zhipu: return "智谱 GLM"
        case .mimo: return "MiMo"
        case .minimax: return "MiniMax"
        case .system: return "本机"
        }
    }

    /// 设置页/通用图标名(SF Symbol,与面板 tab 图标一致)。
    public var settingsIconName: String {
        switch self {
        case .aliyun: return "cloud.fill"
        case .openCode: return "bolt.fill"
        case .kimi: return "sparkles"
        case .deepSeek: return "brain.head.profile"
        case .zhipu: return "atom"
        case .mimo: return "waveform"
        case .minimax: return "infinity"
        case .system: return "cpu"
        }
    }

    /// 菜单栏列身份映射;智谱/MiMo 暂无菜单栏列(nil,见 roadmap)。
    /// 注意:本属性只做身份映射,列的可见顺序仍由 MenuBarColumnKind.allCases 决定。
    public var menuBarColumnKind: MenuBarColumnKind? {
        switch self {
        case .aliyun: return .aliyun
        case .openCode: return .openCode
        case .kimi: return .kimi
        case .deepSeek: return .deepSeek
        case .zhipu: return nil
        case .mimo: return nil
        case .minimax: return .minimax
        case .system: return .system
        }
    }

    /// 反向映射:菜单栏列 → provider。
    public static func from(menuBarColumnKind kind: MenuBarColumnKind) -> ProviderKind {
        switch kind {
        case .aliyun: return .aliyun
        case .kimi: return .kimi
        case .openCode: return .openCode
        case .deepSeek: return .deepSeek
        case .minimax: return .minimax
        case .system: return .system
        }
    }

    /// 面板 tab 是否恒在(未配置也显示,卡内自带引导/重登):
    /// 阿里云(登录态卡)、DeepSeek(配置引导卡)、本机(恒在)。
    public var panelTabAlwaysListed: Bool {
        switch self {
        case .aliyun, .deepSeek, .system: return true
        default: return false
        }
    }
}

// MARK: - 停用集合一次性迁移(纯函数,Verify 覆盖)

public enum ProviderVisibilityMigration {
    /// 首启迁移:新键 disabledProviders 缺失(existing == nil)且旧键
    /// systemStatsEnabled 显式为 false 时,把 "system" 并入停用集;
    /// 新键已存在则旧键不再参与(避免双写漂移)。
    public static func initialDisabledSet(existing: [String]?,
                                          legacySystemStatsEnabled: Bool?) -> Set<String> {
        var disabled = Set(existing ?? [])
        if existing == nil, legacySystemStatsEnabled == false {
            disabled.insert(ProviderKind.system.rawValue)
        }
        return disabled
    }
}

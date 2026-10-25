import Foundation

/// 设置页的纯展示契约:SwiftUI 只负责渲染,Verify 可对标题/副标题/布局覆盖。
public struct SettingsPagePresentation: Equatable {
    public let title: String
    public let subtitle: String
    public let icon: String
    public let detailGridColumns: Int

    public init(title: String, subtitle: String, icon: String, detailGridColumns: Int) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.detailGridColumns = detailGridColumns
    }
}

public struct ThemeOptionPresentation: Equatable {
    public let theme: AppTheme
    public let label: String
    public let previewIsDark: Bool
    public let footerLabel: String

    public init(theme: AppTheme, label: String, previewIsDark: Bool, footerLabel: String) {
        self.theme = theme
        self.label = label
        self.previewIsDark = previewIsDark
        self.footerLabel = footerLabel
    }
}

public enum SettingsPresentation {
    /// 内容两列内最宽不拥挤的最小窗口宽度;低于它会挤压长文案与输入行。
    public static let minimumWindowWidth: Int = 860
    public static let minimumWindowHeight: Int = 620

    /// AppTheme.system 的文案:该页用「跟随系统」而非旧文案「跟随系统外观」。
    public static let themeSystemDisplayName = "跟随系统"

    public static func page(_ id: String) -> SettingsPagePresentation {
        switch id {
        case "general":
            return SettingsPagePresentation(title: "通用",
                                            subtitle: "启动、刷新节奏与版本状态",
                                            icon: "gearshape", detailGridColumns: 2)
        case "appearance":
            return SettingsPagePresentation(title: "外观",
                                            subtitle: "主题、菜单栏形态、数据源与面板细节",
                                            icon: "paintpalette", detailGridColumns: 2)
        case "notifications":
            return SettingsPagePresentation(title: "通知",
                                            subtitle: "系统授权、告警提醒与每日摘要",
                                            icon: "bell", detailGridColumns: 2)
        case "services":
            return SettingsPagePresentation(title: "服务",
                                            subtitle: "账号登录、凭证维护与数据源配置",
                                            icon: "cloud", detailGridColumns: 2)
        case "history":
            return SettingsPagePresentation(title: "历史",
                                            subtitle: "用量趋势、每日汇总与数据导出",
                                            icon: "chart.xyaxis.line", detailGridColumns: 2)
        default:
            return SettingsPagePresentation(title: "设置", subtitle: "", icon: "gearshape",
                                            detailGridColumns: 1)
        }
    }

    /// 主题预览卡:预览格本身按「视觉结果」出明暗;跟随系统用空场景兜底。
    public static func themeOptions() -> [ThemeOptionPresentation] {
        [
            ThemeOptionPresentation(theme: .system, label: themeSystemDisplayName,
                                    previewIsDark: false, footerLabel: "跟随系统"),
            ThemeOptionPresentation(theme: .light, label: "浅色",
                                    previewIsDark: false, footerLabel: "明亮界面"),
            ThemeOptionPresentation(theme: .dark, label: "深色",
                                    previewIsDark: true, footerLabel: "深色界面"),
        ]
    }
}

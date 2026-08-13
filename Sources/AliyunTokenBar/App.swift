import SwiftUI
import AppKit
import AliyunTokenBarCore

// MARK: - 配色 token(macOS 语义色,自动跟随系统明暗)

extension ShapeStyle where Self == Color {
    /// 面板背景:系统窗口色(浅色=纯白,暗色=系统深灰)。
    static var atbPanelBackground: Color { Color(NSColor.windowBackgroundColor) }
    /// 卡片背景:比面板略深一级(系统控件底色)。
    static var atbCardBackground: Color { Color(NSColor.controlBackgroundColor) }
    /// 品牌蓝(固定,不随明暗变;白底/深底都清晰)。
    static var atbBlue: Color { Color(red: 0.16, green: 0.42, blue: 0.87) }
    /// 主文字:系统 label 色(浅色 ~19:1,暗色 ~14:1)。
    static var atbTextPrimary: Color { Color(NSColor.labelColor) }
    /// 次级文字:系统二级 label(~8:1 双模)。
    static var atbTextSecondary: Color { Color(NSColor.secondaryLabelColor) }
    /// 三级文字:系统三级 label(~4.6:1 双模,达标)。
    static var atbTextTertiary: Color { Color(NSColor.tertiaryLabelColor) }
    /// 分隔线/描边:系统分隔色(自动适配明暗)。
    static var atbSeparator: Color { Color(NSColor.separatorColor) }
    static var atbCritical: Color { Color(red: 0.92, green: 0.23, blue: 0.21) }
    static var atbSuccess: Color { Color(red: 0.16, green: 0.58, blue: 0.32) }
}

// MARK: - 设计 token(间距/圆角/描边统一)

enum DesignTokens {
    /// 间距阶梯(4pt 基准)
    static let spacingXS: CGFloat = 4
    static let spacingS: CGFloat = 8
    static let spacingM: CGFloat = 12
    static let spacingL: CGFloat = 16
    static let spacingXL: CGFloat = 24
    /// 圆角阶梯
    static let radiusS: CGFloat = 6   // tag、小按钮
    static let radiusM: CGFloat = 10  // 用量卡、主按钮
    static let radiusL: CGFloat = 14  // 容器卡
}

// MARK: - 阈值色(与 Provider 品牌色正交)

/// 按用量 band 选颜色:< warning 用品牌基础色(区分 Provider),
/// warning → 橙、critical → 红(区分风险)。与 Provider 品牌色正交:
/// 图标形状/前缀编码「是谁」,数字颜色编码「多险」。
@MainActor
func thresholdColor(_ pct: Int, config: ThresholdConfig, base: Color) -> Color {
    switch config.band(for: pct) {
    case .safe: return base
    case .warning: return Color(red: 0.95, green: 0.55, blue: 0.10)   // 橙
    case .critical: return Color(red: 0.92, green: 0.23, blue: 0.21)  // 红
    }
}

// MARK: - 主题(跟随系统 / 浅色 / 深色)

enum AppTheme: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }
    var iconName: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        }
    }
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

@MainActor
final class ThemeManager: ObservableObject {
    static let shared = ThemeManager()
    @Published var theme: AppTheme {
        didSet {
            UserDefaults.standard.set(theme.rawValue, forKey: UserDefaultsKeys.appTheme)
            NSApplication.shared.appearance = theme.nsAppearance
        }
    }
    private init() {
        let raw = UserDefaults.standard.string(forKey: UserDefaultsKeys.appTheme) ?? ""
        theme = AppTheme(rawValue: raw) ?? .system
    }
}

// MARK: - 菜单栏图标样式

enum MenuBarDisplayScheme: String, CaseIterable, Identifiable {
    case cloudPercent  // 默认:云朵 + 7天百分比
    case compact       // 默认:迷你表格(列=数据源,行=主/次指标)
    case singleLine    // 单行:35%·61%
    case iconOnly      // 仅图标(进度环)
    case systemStats   // 仅本机 CPU/内存

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .cloudPercent: return "云朵 + 百分比(默认)"
        case .compact: return "迷你表格(默认)"
        case .singleLine: return "单行(35%·61%)"
        case .iconOnly: return "仅图标"
        case .systemStats: return "本机 CPU/内存"
        }
    }
}

@MainActor
final class MenuBarStyleManager: ObservableObject {
    static let shared = MenuBarStyleManager()
    @Published var scheme: MenuBarDisplayScheme {
        didSet { UserDefaults.standard.set(scheme.rawValue, forKey: UserDefaultsKeys.menuBarScheme) }
    }
    private init() {
        let raw = UserDefaults.standard.string(forKey: UserDefaultsKeys.menuBarScheme) ?? ""
        scheme = MenuBarDisplayScheme(rawValue: raw) ?? .compact
    }
}

// MARK: - 菜单栏图标渲染

/// 菜单栏明暗状态:AppDelegate 从系统全局域 AppleInterfaceStyle 读取并写入
/// (不用 button.effectiveAppearance——app 强制主题会污染它)。
/// 非模板渲染(miniTableImage)读它选基底色——深菜单栏→白,浅菜单栏→黑。
@MainActor
final class MenuBarAppearance {
    static let shared = MenuBarAppearance()
    var isDark = false
    private init() {}
}

enum MenuBarTextRenderer {
    /// 按 scheme 渲染菜单栏图标(模板图,系统按明暗自动染色)。
    /// compact 迷你表格为非模板(基底色按菜单栏明暗手选,数字阈值变色);其余 scheme 为模板图。
    /// 百分比参数为 nil 时表示服务/网络不可用,显示横杠(—)。
    /// openCodeRolling/openCodeWeekly 为 nil 时不显示 OpenCode 部分。
    /// kimiFiveHour/kimiWeekly 为 nil 时不显示 Kimi 部分。
    /// cpu/memory 均为 nil(开关关闭)时各样式整段隐藏、systemStats 回退云朵;仅一个为 nil(采样未就绪)时该数值显示横杠(—)。
    /// thresholdConfig:控制百分比数字的阈值变色(品牌色保留于图标前缀)。
    @MainActor
    static func image(scheme: MenuBarDisplayScheme, fiveHour: Int?, oneWeek: Int?,
                      openCodeRolling: Int? = nil, openCodeWeekly: Int? = nil,
                      kimiFiveHour: Int? = nil, kimiWeekly: Int? = nil,
                      cpu: Int? = nil, memory: Int? = nil,
                      columns: [MenuBarTableColumn]? = nil, isDark: Bool = false,
                      thresholdConfig: ThresholdConfig = ThresholdConfig()) -> NSImage {
        switch scheme {
        case .cloudPercent: return cloudPercentImage(fiveHour: fiveHour, oneWeek: oneWeek,
                                                      openCodeRolling: openCodeRolling, openCodeWeekly: openCodeWeekly,
                                                      kimiWeekly: kimiWeekly, cpu: cpu, memory: memory,
                                                      thresholdConfig: thresholdConfig)
        case .compact: return miniTableImage(columns: columns ?? [], isDark: isDark,
                                             thresholdConfig: thresholdConfig)
        case .singleLine: return singleLineImage(fiveHour: fiveHour, oneWeek: oneWeek, cpu: cpu, memory: memory)
        case .iconOnly: return iconOnlyImage(fiveHour: fiveHour ?? 0, oneWeek: oneWeek ?? 0,
                                              thresholdConfig: thresholdConfig)
        case .systemStats: return systemStatsImage(cpu: cpu, memory: memory)
        }
    }

    /// 格式化百分比或横杠:nil → "—"。
    private static func pctText(_ v: Int?) -> String {
        v.map { "\($0)%" } ?? "—"
    }

    /// 云朵 + 阿里云双百分比 + OpenCode 双百分比 + Kimi 周百分比:
    /// ☁ 5h 35% · 7d 61%  ⚡ 22% · 43%  ✨ 58%
    /// 用**模板图**(系统自动适配明暗:深色菜单栏自动染白)。
    /// 三 Provider 区分靠**形状**(云朵 vs 闪电 vs 星星)而非颜色——符合 macOS 菜单栏规范。
    /// 阈值变色:百分比数字按风险变色(safe→黑/白 / warning→橙 / critical→红)。
    /// 服务不可用(nil)时数值显示为横杠(—)。
    @MainActor
    private static func cloudPercentImage(fiveHour: Int?, oneWeek: Int?,
                                          openCodeRolling: Int? = nil, openCodeWeekly: Int? = nil,
                                          kimiWeekly: Int? = nil,
                                          cpu: Int? = nil, memory: Int? = nil,
                                          thresholdConfig: ThresholdConfig = ThresholdConfig()) -> NSImage {
        // 模板图:SwiftUI 的 Color.black 在 ImageRenderer 里会被系统染成菜单栏适配色
        // (深色背景自动白)。形状用 .black 填充,系统只取 alpha 通道。
        let content = HStack(spacing: 4) {
            // 阿里云:云朵 + 双百分比
            cloudShape.fill(Color.black).frame(width: 14, height: 11)
            Text("5h").font(.system(size: 8, weight: .semibold)).monospacedDigit().foregroundStyle(.black)
            Text(pctText(fiveHour)).font(.system(size: 11, weight: .semibold)).monospacedDigit()
                .foregroundStyle(fiveHour.map { thresholdColor($0, config: thresholdConfig, base: .black) } ?? .black)
            Text("·").font(.system(size: 11)).foregroundStyle(.black.opacity(0.5))
            Text("7d").font(.system(size: 8, weight: .semibold)).monospacedDigit().foregroundStyle(.black)
            Text(pctText(oneWeek)).font(.system(size: 11, weight: .semibold)).monospacedDigit()
                .foregroundStyle(oneWeek.map { thresholdColor($0, config: thresholdConfig, base: .black) } ?? .black)
            // OpenCode:闪电 + 双百分比(配置了才显示;服务不可用时也显示横杠)
            if openCodeRolling != nil || openCodeWeekly != nil {
                Spacer().frame(width: 6)
                Image(systemName: "bolt.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(.black)
                Text(pctText(openCodeRolling)).font(.system(size: 11, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(openCodeRolling.map { thresholdColor($0, config: thresholdConfig, base: .black) } ?? .black)
                Text("·").font(.system(size: 11)).foregroundStyle(.black.opacity(0.5))
                Text(pctText(openCodeWeekly)).font(.system(size: 11, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(openCodeWeekly.map { thresholdColor($0, config: thresholdConfig, base: .black) } ?? .black)
            }
            // Kimi:星星 + 周百分比(配置了才显示;服务不可用时显示横杠)
            if kimiWeekly != nil {
                Spacer().frame(width: 6)
                Image(systemName: "sparkles").font(.system(size: 10, weight: .bold)).foregroundStyle(.black)
                Text(pctText(kimiWeekly)).font(.system(size: 11, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(kimiWeekly.map { thresholdColor($0, config: thresholdConfig, base: .black) } ?? .black)
            }
            // 本机:CPU/内存(开关开且有采样值时显示;未采样时显示横杠)
            if cpu != nil || memory != nil {
                Spacer().frame(width: 6)
                Text("C").font(.system(size: 8, weight: .semibold)).monospacedDigit().foregroundStyle(.black)
                Text(pctText(cpu)).font(.system(size: 11, weight: .semibold)).monospacedDigit().foregroundStyle(.black)
                Text("·").font(.system(size: 11)).foregroundStyle(.black.opacity(0.5))
                Text("M").font(.system(size: 8, weight: .semibold)).monospacedDigit().foregroundStyle(.black)
                Text(pctText(memory)).font(.system(size: 11, weight: .semibold)).monospacedDigit().foregroundStyle(.black)
            }
        }
        .frame(height: 20)
        .fixedSize(horizontal: true, vertical: false)
        return render(content)
    }

    /// 可复用的云朵 Shape(阿里云风格三隆起)
    private static var cloudShape: some Shape {
        struct CloudShape: Shape {
            func path(in rect: CGRect) -> Path {
                let w = rect.width, h = rect.height
                var p = Path()
                p.move(to: CGPoint(x: w*0.10, y: h*0.70))
                p.addQuadCurve(to: CGPoint(x: w*0.22, y: h*0.42), control: CGPoint(x: w*0.04, y: h*0.45))
                p.addQuadCurve(to: CGPoint(x: w*0.38, y: h*0.28), control: CGPoint(x: w*0.24, y: h*0.22))
                p.addQuadCurve(to: CGPoint(x: w*0.55, y: h*0.18), control: CGPoint(x: w*0.44, y: h*0.12))
                p.addQuadCurve(to: CGPoint(x: w*0.70, y: h*0.28), control: CGPoint(x: w*0.66, y: h*0.14))
                p.addQuadCurve(to: CGPoint(x: w*0.85, y: h*0.40), control: CGPoint(x: w*0.86, y: h*0.22))
                p.addQuadCurve(to: CGPoint(x: w*0.90, y: h*0.70), control: CGPoint(x: w*1.00, y: h*0.50))
                p.addLine(to: CGPoint(x: w*0.10, y: h*0.70))
                p.closeSubpath()
                return p
            }
        }
        return CloudShape()
    }

    /// 默认紧凑:迷你表格——列=数据源(☁✨⚡🧠▣,顺序固定),行=主/次指标。
    /// 每列固定宽:图标位 10pt + 值域 34pt("100%" @11pt 等宽数字实测 33pt,留 1pt 余量;过窄会换行破网格),值右对齐;
    /// DeepSeek 列为金额(≤7 字符),值域加宽到 48pt。下行缩进图标位宽度,8 个数字严格成网格。
    /// 非模板渲染:基底色按菜单栏明暗手选;数字独立按阈值 band 变色
    /// (safe→基底 / warning→橙 / critical→红),图标恒基底色——颜色只编码风险。
    /// 横杠(pct=nil)与金额不着色。总高 ≈21pt;若视觉验收发现溢出/挤压,先把 11pt 降 10.5pt 再调 valueWidth。
    @MainActor
    private static func miniTableImage(columns: [MenuBarTableColumn], isDark: Bool,
                                       thresholdConfig: ThresholdConfig) -> NSImage {
        let base: Color = isDark ? .white : .black
        let iconWidth: CGFloat = 10
        let content = HStack(alignment: .top, spacing: 7) {
            ForEach(columns, id: \.kind) { col in
                // DeepSeek 金额列值域更宽(¥99.99 / ¥9999 / ¥12.3万,契约 ≤7 字符)
                let valueWidth: CGFloat = col.kind == .deepSeek ? 48 : 34
                VStack(spacing: -1) {
                    HStack(spacing: 2) {
                        Image(systemName: col.kind.symbolName)
                            .font(.system(size: 9, weight: .bold))
                            .frame(width: iconWidth, alignment: .leading)
                        Text(col.primary.text)
                            .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                            .frame(width: valueWidth, alignment: .trailing)
                            .foregroundStyle(col.primary.pct.map { thresholdColor($0, config: thresholdConfig, base: base) } ?? base)
                    }
                    Text(col.secondary.text)
                        .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                        .frame(width: iconWidth + 2 + valueWidth, alignment: .trailing)
                        .foregroundStyle(col.secondary.pct.map { thresholdColor($0, config: thresholdConfig, base: base) } ?? base)
                }
            }
        }
        .foregroundStyle(base)   // 图标继承;Text 各自显式覆盖
        .fixedSize(horizontal: true, vertical: true)
        return render(content, isTemplate: false)
    }

    /// 单行:35%·61%(nil 时显示横杠);尾部追加 C/M 段
    @MainActor
    private static func singleLineImage(fiveHour: Int?, oneWeek: Int?,
                                        cpu: Int? = nil, memory: Int? = nil) -> NSImage {
        let content = HStack(spacing: 3) {
            Text(pctText(fiveHour)).font(.system(size: 12, weight: .medium)).monospacedDigit()
            Text("·").font(.system(size: 12, weight: .medium))
            Text(pctText(oneWeek)).font(.system(size: 12, weight: .medium)).monospacedDigit()
            if cpu != nil || memory != nil {
                Text("·").font(.system(size: 12, weight: .medium))
                Text("C").font(.system(size: 10, weight: .medium)).monospacedDigit()
                Text(pctText(cpu)).font(.system(size: 12, weight: .medium)).monospacedDigit()
                Text("M").font(.system(size: 10, weight: .medium)).monospacedDigit()
                Text(pctText(memory)).font(.system(size: 12, weight: .medium)).monospacedDigit()
            }
        }
        .foregroundStyle(.black)
        .frame(height: 20)
        .fixedSize(horizontal: true, vertical: false)
        return render(content)
    }

    /// 仅图标:小圆环(外环=7d,内环=5h 的填充比例)。
    /// 取两窗口较高 band 作为整体风险色:warning 橙、critical 红(模板图仍自动适配明暗)。
    @MainActor
    private static func iconOnlyImage(fiveHour: Int, oneWeek: Int,
                                      thresholdConfig: ThresholdConfig = ThresholdConfig()) -> NSImage {
        let size: CGFloat = 18
        let worseBand = max(thresholdConfig.band(for: fiveHour), thresholdConfig.band(for: oneWeek))
        let ringColor: Color = {
            switch worseBand {
            case .safe: return .black
            case .warning: return Color(red: 0.95, green: 0.55, blue: 0.10)
            case .critical: return Color(red: 0.92, green: 0.23, blue: 0.21)
            }
        }()
        // 用 Canvas 画双环
        let content = Canvas { ctx, sz in
            let center = CGPoint(x: sz.width/2, y: sz.height/2)
            let outerR: CGFloat = 7
            let innerR: CGFloat = 4
            // 外环底
            ctx.stroke(Path(ellipseIn: CGRect(x: center.x-outerR, y: center.y-outerR, width: outerR*2, height: outerR*2)),
                       with: .color(ringColor.opacity(0.25)), lineWidth: 1.5)
            // 外环进度(7d)
            drawArc(ctx: ctx, center: center, radius: outerR, pct: Double(oneWeek)/100, color: ringColor, width: 1.5)
            // 内环底
            ctx.stroke(Path(ellipseIn: CGRect(x: center.x-innerR, y: center.y-innerR, width: innerR*2, height: innerR*2)),
                       with: .color(ringColor.opacity(0.25)), lineWidth: 1.5)
            // 内环进度(5h)
            drawArc(ctx: ctx, center: center, radius: innerR, pct: Double(fiveHour)/100, color: ringColor, width: 1.5)
        }
        .frame(width: size, height: size)
        return render(content)
    }

    /// 仅本机 CPU/内存:C23% · M58%。
    /// 两个参数都 nil(开关关闭或采样未就绪)→ 回退云朵图标。
    @MainActor
    private static func systemStatsImage(cpu: Int?, memory: Int?) -> NSImage {
        let content = HStack(spacing: 4) {
            if cpu == nil && memory == nil {
                cloudShape.fill(Color.black).frame(width: 14, height: 11)
            } else {
                Text("C").font(.system(size: 8, weight: .semibold)).monospacedDigit().foregroundStyle(.black)
                Text(pctText(cpu)).font(.system(size: 11, weight: .semibold)).monospacedDigit().foregroundStyle(.black)
                Text("·").font(.system(size: 11)).foregroundStyle(.black.opacity(0.5))
                Text("M").font(.system(size: 8, weight: .semibold)).monospacedDigit().foregroundStyle(.black)
                Text(pctText(memory)).font(.system(size: 11, weight: .semibold)).monospacedDigit().foregroundStyle(.black)
            }
        }
        .frame(height: 20)
        .fixedSize(horizontal: true, vertical: false)
        return render(content)
    }

    @MainActor
    private static func drawArc(ctx: GraphicsContext, center: CGPoint, radius: CGFloat, pct: Double, color: Color, width: CGFloat) {
        guard pct > 0 else { return }
        var path = Path()
        let start = Angle.degrees(-90)
        let end = Angle.degrees(-90 + 360 * pct)
        path.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: false)
        ctx.stroke(path, with: .color(color), lineWidth: width)
    }

    @MainActor
    private static func render<V: View>(_ content: V, isTemplate: Bool = true) -> NSImage {
        let renderer = ImageRenderer(content: content)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2.0
        guard let img = renderer.nsImage, img.size.width > 0, img.size.height > 0 else {
            // 渲染失败:返回固定云朵图标(确保 label 非空,避免系统自动终止)
            return NSImage(systemSymbolName: "cloud.fill", accessibilityDescription: "CodingTokenBar") ?? NSImage(size: NSSize(width: 48, height: 20))
        }
        img.isTemplate = isTemplate   // 迷你表格传 false:保留风险变色;其余 scheme 维持模板
        return img
    }
}

// MARK: - App 入口

@main
struct AliyunTokenBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = TokenPlanModel.shared
    @StateObject private var themeManager = ThemeManager.shared
    @StateObject private var menuBarStyle = MenuBarStyleManager.shared
    @StateObject private var notifier = NotificationManager.shared

    init() {
        // 注入图标渲染闭包:数据更新时 Core 预渲染缓存,NSStatusItem 按钮只读缓存
        // (避免每次渲染都走 ImageRenderer,保持菜单栏响应)。
        TokenPlanModel.shared.renderIconSink = { model in
            // OpenCode:已配置但出错时传 Optional(nil) → 菜单栏显示横杠;
            // 未配置时整个 OpenCode 部分不显示。
            let ocRolling: Int?? = model.openCodeQuota.map { .some($0.rolling.pct) }
                ?? (model.openCodeConfigured && model.openCodeError != nil ? .some(nil) : nil)
            let ocWeekly: Int?? = model.openCodeQuota.map { .some($0.weekly.pct) }
                ?? (model.openCodeConfigured && model.openCodeError != nil ? .some(nil) : nil)
            // Kimi:已配置但出错时显示横杠;未配置时整个 Kimi 部分不显示。
            let kimiFiveHour: Int?? = model.kimiQuota.map { .some($0.fiveHour.pctInt) }
                ?? (model.kimiConfigured && model.kimiError != nil ? .some(nil) : nil)
            let kimiWeekly: Int?? = model.kimiQuota.map { .some($0.weekly.pctInt) }
                ?? (model.kimiConfigured && model.kimiError != nil ? .some(nil) : nil)
            let monitor = SystemMetricsMonitor.shared
            return MenuBarTextRenderer.image(
                scheme: MenuBarStyleManager.shared.scheme,
                fiveHour: model.quota?.usage.fiveHour.percentageInt,
                oneWeek: model.quota?.usage.oneWeek.percentageInt,
                openCodeRolling: ocRolling ?? nil,
                openCodeWeekly: ocWeekly ?? nil,
                kimiFiveHour: kimiFiveHour ?? nil,
                kimiWeekly: kimiWeekly ?? nil,
                cpu: model.systemStatsEnabled ? monitor.cpuPercent : nil,
                memory: model.systemStatsEnabled ? monitor.memoryPercent : nil,
                columns: model.menuBarColumns(),
                isDark: MenuBarAppearance.shared.isDark,
                thresholdConfig: model.thresholdConfig
            )
        }
        TokenPlanModel.shared.renderTooltipSink = { model in
            MenuBarTable.tooltip(columns: model.menuBarColumns())
        }
        // 应用保存的主题
        NSApplication.shared.appearance = ThemeManager.shared.theme.nsAppearance
    }

    var body: some Scene {
        // 注意:不再用 MenuBarExtra——macOS 26 会因系统隐藏状态项而回收进程。
        // 状态项由 AppDelegate 手动管理(NSStatusItem + NSPopover)。
        // 设置窗口走自定义 NSPanel(SettingsWindowManager),不再挂 SwiftUI Settings scene(避免重复入口)。
        Settings { EmptyView() }
    }
}

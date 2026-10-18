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
//
// 「Hyperion v2」设计语言(v1:中性灰卡 + 微阴影;v2:叠加 Hero 层 + 品牌竖纹):
//   - spacing:扩展 6/20 节点;Hero 卡用更大内边距
//   - radiusXL 用于外层容器(分组卡);radiusM/S 保持原节奏
//   - 新增 strokeHairline:卡片内描边,使卡与材质底产生微弱边界
enum DesignTokens {
    /// 间距阶梯(4pt 基准)+ XL/XXL 用于 Hero 大卡
    static let spacingXXS: CGFloat = 2
    static let spacingXS: CGFloat = 4
    static let spacingS: CGFloat = 8
    static let spacingM: CGFloat = 12
    static let spacingL: CGFloat = 16
    static let spacingXL: CGFloat = 20   // Hero 卡水平内边距
    static let spacingXXL: CGFloat = 24
    /// 圆角阶梯
    static let radiusS: CGFloat = 6   // tag、小按钮
    static let radiusM: CGFloat = 10  // 用量卡、主按钮
    static let radiusL: CGFloat = 14  // 容器卡
    static let radiusXL: CGFloat = 18 // Hero 卡、分组卡
    /// 发丝描边(卡片内描边,提供视觉边界感而不靠阴影)
    static let strokeHairline: CGFloat = 0.5
    /// 品牌竖纹宽度(卡左侧 3pt 色条)
    static let stripeWidth: CGFloat = 3
    /// 细条行进度条固定宽度(ATBThinMeterRow):多行列表里各行条必须等长对齐,
    /// 弹性宽度会被可变长尾注(重置倒计时有/无/长/短)挤成长短不齐。
    /// 56pt 是给紧凑尾注(ATBResetText.compact,≈69pt)留够空间的上限
    /// (行内容 312pt = 面板360−内容边距24−卡片内边距24)
    static let meterWidth: CGFloat = 56
    /// 细条行标签固定宽度(ATBThinMeterRow):标签若留弹性区间,HStack 会把
    /// 各行的剩余空间按比例分配进去,尾注长短不同的行被拉伸到不同宽度,
    /// 把后面的百分比/进度条挤成错位;固定后各行列严丝合缝
    static let meterLabelWidth: CGFloat = 64
}

// MARK: - 统一卡片外观修饰符

extension View {
    /// 通用卡片外观:内边距 + 卡片底色 + 圆角 + 发丝描边。
    /// v2 改进:取代 v1 的微阴影——阴影在 .regularMaterial 上常显得脏,
    /// 改用内描边产生「卡片漂在材质底上」的层次感。
    /// alignment 只影响 maxWidth 填充时的内容对齐(加载环等居中场景传 .center)。
    func atbCard(corner: CGFloat = DesignTokens.radiusM,
                 paddingH: CGFloat = DesignTokens.spacingM,
                 paddingV: CGFloat = DesignTokens.spacingS + 2,
                 alignment: Alignment = .leading) -> some View {
        self
            .padding(.horizontal, paddingH)
            .padding(.vertical, paddingV)
            .frame(maxWidth: .infinity, alignment: alignment)
            .background(Color.atbCardBackground)
            .overlay(
                RoundedRectangle(cornerRadius: corner)
                    .strokeBorder(Color.atbSeparator.opacity(0.5),
                                  lineWidth: DesignTokens.strokeHairline)
            )
            .clipShape(RoundedRectangle(cornerRadius: corner))
    }
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
    case island        // 灵动岛:黑色胶囊,悬停展开实时卡片

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .cloudPercent: return "云朵 + 百分比(默认)"
        case .compact: return "迷你表格(默认)"
        case .singleLine: return "单行(35%·61%)"
        case .iconOnly: return "仅图标"
        case .systemStats: return "本机 CPU/内存"
        case .island: return "灵动岛(悬停展开)"
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
    /// aliyunVisible:阿里云数据源开关;关闭时云朵/单行样式不渲染云朵图标与阿里云段。
    /// 阿里云主窗口 = oneMonth ?? oneWeek(2026-09 官方取消周限改月限;标签随之 30d/7d)。
    @MainActor
    static func image(scheme: MenuBarDisplayScheme, fiveHour: Int?, oneWeek: Int?,
                      oneMonth: Int? = nil,
                      openCodeRolling: Int? = nil, openCodeWeekly: Int? = nil,
                      kimiFiveHour: Int? = nil, kimiWeekly: Int? = nil,
                      cpu: Int? = nil, memory: Int? = nil,
                      columns: [MenuBarTableColumn]? = nil, isDark: Bool = false,
                      thresholdConfig: ThresholdConfig = ThresholdConfig(),
                      aliyunVisible: Bool = true,
                      moneyFloor: Double = 0) -> NSImage {
        let mainWindow = oneMonth ?? oneWeek
        let mainWindowLabel = oneMonth != nil ? "30d" : "7d"
        switch scheme {
        case .cloudPercent: return cloudPercentImage(fiveHour: fiveHour, mainWindow: mainWindow,
                                                      mainWindowLabel: mainWindowLabel,
                                                      openCodeRolling: openCodeRolling, openCodeWeekly: openCodeWeekly,
                                                      kimiWeekly: kimiWeekly, cpu: cpu, memory: memory,
                                                      thresholdConfig: thresholdConfig,
                                                      aliyunVisible: aliyunVisible)
        case .compact: return miniTableImage(columns: columns ?? [], isDark: isDark,
                                             thresholdConfig: thresholdConfig)
        case .singleLine: return singleLineImage(fiveHour: fiveHour, mainWindow: mainWindow, cpu: cpu, memory: memory,
                                                 aliyunVisible: aliyunVisible)
        case .iconOnly: return iconOnlyImage(fiveHour: fiveHour ?? 0, mainWindow: mainWindow ?? 0,
                                              thresholdConfig: thresholdConfig)
        case .systemStats: return systemStatsImage(cpu: cpu, memory: memory)
        case .island: return islandPillImage(columns: columns ?? [], isDark: isDark,
                                             thresholdConfig: thresholdConfig, moneyFloor: moneyFloor)
        }
    }

    /// 格式化百分比或横杠:nil → "—"。
    private static func pctText(_ v: Int?) -> String {
        v.map { "\($0)%" } ?? "—"
    }

    /// 真实品牌 logo 剪影 + 阿里云双百分比 + OpenCode 双百分比 + Kimi 周百分比:
    /// 〔阿里云标〕 5h 35% · 30d 61%  〔OpenCode 标〕 22% · 43%  〔Kimi 标〕 58%
    /// 用**模板图**(系统自动适配明暗:深色菜单栏自动染白)。
    /// 三 Provider 区分靠**真实 logo 形状**(阿里云括号 vs OpenCode 方框 vs Kimi K)而非颜色——符合 macOS 菜单栏规范。
    /// 阈值变色:百分比数字按风险变色(safe→黑/白 / warning→橙 / critical→红)。
    /// 服务不可用(nil)时数值显示为横杠(—)。
    @MainActor
    private static func cloudPercentImage(fiveHour: Int?, mainWindow: Int?, mainWindowLabel: String,
                                          openCodeRolling: Int? = nil, openCodeWeekly: Int? = nil,
                                          kimiWeekly: Int? = nil,
                                          cpu: Int? = nil, memory: Int? = nil,
                                          thresholdConfig: ThresholdConfig = ThresholdConfig(),
                                          aliyunVisible: Bool = true) -> NSImage {
        // 模板图:SwiftUI 的 Color.black 在 ImageRenderer 里会被系统染成菜单栏适配色
        // (深色背景自动白)。形状用 .black 填充,系统只取 alpha 通道。
        let content = HStack(spacing: 4) {
            // 阿里云:真实品牌标(阿里云括号标,剪影模板)+ 双百分比
            // (5h 窗口被官方取消时只显主窗段;数据源停用时整段隐藏)
            if aliyunVisible {
                BrandMark.aliyun.silhouette(in: CGRect(x: 0, y: 0, width: 13, height: 13), tint: .black)
                if fiveHour != nil || mainWindow == nil {
                    Text("5h").font(.system(size: 8, weight: .semibold)).monospacedDigit().foregroundStyle(.black)
                    Text(pctText(fiveHour)).font(.system(size: 11, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(fiveHour.map { thresholdColor($0, config: thresholdConfig, base: .black) } ?? .black)
                    Text("·").font(.system(size: 11)).foregroundStyle(.black.opacity(0.5))
                }
                Text(mainWindowLabel).font(.system(size: 8, weight: .semibold)).monospacedDigit().foregroundStyle(.black)
                Text(pctText(mainWindow)).font(.system(size: 11, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(mainWindow.map { thresholdColor($0, config: thresholdConfig, base: .black) } ?? .black)
            }
            // OpenCode:真实品牌标(官方标记:方框环+内方块)+ 双百分比(配置了才显示;服务不可用时也显示横杠)
            if openCodeRolling != nil || openCodeWeekly != nil {
                if aliyunVisible { Spacer().frame(width: 6) }
                BrandMark.openCode.silhouette(in: CGRect(x: 0, y: 0, width: 11, height: 11), tint: .black)
                Text(pctText(openCodeRolling)).font(.system(size: 11, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(openCodeRolling.map { thresholdColor($0, config: thresholdConfig, base: .black) } ?? .black)
                Text("·").font(.system(size: 11)).foregroundStyle(.black.opacity(0.5))
                Text(pctText(openCodeWeekly)).font(.system(size: 11, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(openCodeWeekly.map { thresholdColor($0, config: thresholdConfig, base: .black) } ?? .black)
            }
            // Kimi:真实品牌标(白 K 剪影)+ 周百分比(配置了才显示;服务不可用时显示横杠)
            if kimiWeekly != nil {
                Spacer().frame(width: 6)
                BrandMark.kimi.silhouette(in: CGRect(x: 0, y: 0, width: 11, height: 11), tint: .black)
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

    /// 默认紧凑:迷你表格——列=数据源(真实品牌 logo 剪影,顺序固定),行=主/次指标。
    /// 每列固定宽:图标位 10pt + 图标-值距 1pt + 值域 34pt("100%" @11pt 等宽数字实测 33pt、
    /// 金额无符号后 "12.3万" ≈34pt;过窄会截断破网格),值右对齐;金额列不再单独加宽(v1.0.48 去 ¥)。
    /// 下行宽=图标位+1+值域,8 个数字严格成网格。列间 4pt。
    /// 非模板渲染:基底色按菜单栏明暗手选;数字独立按阈值 band 变色
    /// (safe→基底 / warning→橙 / critical→红),图标恒基底色——颜色只编码风险。
    /// 横杠(pct=nil)与金额不着色。总高 ≈21pt;若视觉验收发现溢出/挤压,先把 11pt 降 10.5pt 再调 valueWidth。
    @MainActor
    private static func miniTableImage(columns: [MenuBarTableColumn], isDark: Bool,
                                       thresholdConfig: ThresholdConfig) -> NSImage {
        let base: Color = isDark ? .white : .black
        let iconWidth: CGFloat = 10
        let valueWidth: CGFloat = 34
        let content = HStack(alignment: .top, spacing: 4) {
            ForEach(columns, id: \.kind) { col in
                VStack(spacing: -1) {
                    HStack(spacing: 1) {
                        // 真实品牌 logo 剪影(单色,随菜单栏明暗);「本机」回落 SF Symbol
                        if let mark = col.kind.brandMark {
                            mark.silhouette(in: CGRect(x: 0, y: 0, width: 10, height: 10), tint: base)
                                .frame(width: iconWidth, alignment: .leading)
                        } else {
                            Image(systemName: col.kind.symbolName)
                                .font(.system(size: 9, weight: .bold))
                                .frame(width: iconWidth, alignment: .leading)
                        }
                        Text(col.primary.text)
                            .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                            .frame(width: valueWidth, alignment: .trailing)
                            .foregroundStyle(col.primary.pct.map { thresholdColor($0, config: thresholdConfig, base: base) } ?? base)
                    }
                    Text(col.secondary.text)
                        .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                        .frame(width: iconWidth + 1 + valueWidth, alignment: .trailing)
                        .foregroundStyle(col.secondary.pct.map { thresholdColor($0, config: thresholdConfig, base: base) } ?? base)
                }
            }
        }
        .foregroundStyle(base)   // 图标继承;Text 各自显式覆盖
        .fixedSize(horizontal: true, vertical: true)
        return render(content, isTemplate: false)
    }

    /// 单行:35%·61%(nil 时显示横杠;5h 窗口取消时只显主窗段);尾部追加 C/M 段。
    /// aliyunVisible=false(数据源停用)时不渲染阿里云段与多余分隔点。
    @MainActor
    private static func singleLineImage(fiveHour: Int?, mainWindow: Int?,
                                        cpu: Int? = nil, memory: Int? = nil,
                                        aliyunVisible: Bool = true) -> NSImage {
        let content = HStack(spacing: 3) {
            if aliyunVisible {
                if fiveHour != nil || mainWindow == nil {
                    Text(pctText(fiveHour)).font(.system(size: 12, weight: .medium)).monospacedDigit()
                    Text("·").font(.system(size: 12, weight: .medium))
                }
                Text(pctText(mainWindow)).font(.system(size: 12, weight: .medium)).monospacedDigit()
            }
            if cpu != nil || memory != nil {
                if aliyunVisible {
                    Text("·").font(.system(size: 12, weight: .medium))
                }
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

    /// 仅图标:小圆环(外环=主窗 30d/7d,内环=5h 的填充比例)。
    /// 取两窗口较高 band 作为整体风险色:warning 橙、critical 红(模板图仍自动适配明暗)。
    @MainActor
    private static func iconOnlyImage(fiveHour: Int, mainWindow: Int,
                                      thresholdConfig: ThresholdConfig = ThresholdConfig()) -> NSImage {
        let size: CGFloat = 18
        let worseBand = max(thresholdConfig.band(for: fiveHour), thresholdConfig.band(for: mainWindow))
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
            // 外环进度(主窗:30d/7d)
            drawArc(ctx: ctx, center: center, radius: outerR, pct: Double(mainWindow)/100, color: ringColor, width: 1.5)
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
                // 采样未就绪:占位图标用本机语义(不再用云朵——阿里云数据源可能已停用)
                Image(systemName: "desktopcomputer").font(.system(size: 11, weight: .semibold)).foregroundStyle(.black)
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

    /// 灵动岛收起态:黑色胶囊(非模板,明暗菜单栏下都是黑底白字——动态岛语义),
    /// 内容 = **全源健康度汇总**(需处理/告急/预警计数;全正常=「一切正常」)。
    /// 判定见 MenuBarTable.islandHealth(鉴权类失败优先,余额按设置的下限)。
    /// 全正常时文字保持白色、只有圆点是绿的——避免菜单栏常年挂一条绿字。
    @MainActor
    private static func islandPillImage(columns: [MenuBarTableColumn], isDark: Bool,
                                        thresholdConfig: ThresholdConfig, moneyFloor: Double) -> NSImage {
        let health = MenuBarTable.islandHealth(columns: columns, config: thresholdConfig, moneyFloor: moneyFloor)
        let tint = IslandStateColor.color(health.worst)
        let content = HStack(spacing: 4) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text(MenuBarTable.islandHealthText(health))
                .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                .foregroundStyle(health.total == 0 ? Color.white : tint)
        }
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background(
            Capsule().fill(.black)
                .overlay(Capsule().strokeBorder(.white.opacity(isDark ? 0.16 : 0.08),
                                                lineWidth: 0.5))
        )
        .fixedSize(horizontal: true, vertical: false)
        return render(content, isTemplate: false)
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
        TokenPlanModel.shared.stepfunConsoleFetchSink = { accountID in
            await StepFunSessionController.shared.fetchQuota(accountID: accountID)
        }
        // 阶跃鉴权自愈通道:401 时重载会话页(SPA 用 refresh token 换发新 access)
        TokenPlanModel.shared.stepfunSessionReload = { accountID in
            StepFunSessionController.shared.reloadSessionPage(accountID: accountID)
        }
        // 阶跃账户身份通道:读会话 cookie 的 oasis_id(多账户去重/防重复登录)
        TokenPlanModel.shared.stepfunIdentitySink = { accountID in
            await StepFunSessionController.shared.currentOasisID(accountID: accountID)
        }
        // 阶跃账户手机号通道:账户中心 GetAccountBinding(面板身份展示优先手机号尾号)
        TokenPlanModel.shared.stepfunPhoneSink = { accountID in
            await StepFunSessionController.shared.currentPhoneTail(accountID: accountID)
        }
        // 冷启动:阶跃已登记账户全部预载常驻会话页(WebView 保持 Cookie 轮换)
        StepFunSessionController.shared.warmUpIfConfigured()
        TokenPlanModel.shared.renderIconSink = { model in
            // 当前可见的菜单栏列(已统一过滤停用/未配置/无数据);
            // 非 compact 样式同样遵循「数据源停用」语义,以可见列集合为准。
            let columns = model.menuBarColumns()
            let visible = Set(columns.map(\.kind))
            let aliyunOn = visible.contains(.aliyun)
            let ocOn = visible.contains(.openCode)
            let kimiOn = visible.contains(.kimi)
            let sysOn = visible.contains(.system)
            // 全部数据源停用 → 降级仅图标(进度环),避免菜单栏空白
            // (iconOnly 读阿里云双窗口,停用时按 0 渲染空环)。
            var scheme = MenuBarStyleManager.shared.scheme
            if visible.isEmpty {
                scheme = .iconOnly
            } else if scheme == .systemStats && !sysOn {
                scheme = .cloudPercent   // 本机列停用 → 云朵样式回退(阿里云段自行按开关显隐)
            }
            let fiveHour: Int? = aliyunOn ? model.quota?.usage.fiveHour?.percentageInt : nil
            let oneWeek: Int? = aliyunOn ? model.quota?.usage.oneWeek?.percentageInt : nil
            let oneMonth: Int? = aliyunOn ? model.quota?.usage.oneMonth?.percentageInt : nil
            // OpenCode:已配置但出错时传 Optional(nil) → 菜单栏显示横杠;
            // 未配置/停用(不可见)时整个 OpenCode 部分不显示。
            let ocRolling: Int?? = ocOn
                ? (model.openCodeQuota.map { .some($0.rolling.pct) } ?? .some(nil))
                : nil
            let ocWeekly: Int?? = ocOn
                ? (model.openCodeQuota.map { .some($0.weekly.pct) } ?? .some(nil))
                : nil
            // Kimi:已配置但出错时显示横杠;未配置/停用(不可见)时整个 Kimi 部分不显示。
            let kimiFiveHour: Int?? = kimiOn
                ? (model.kimiQuota.map { .some($0.fiveHour.pctInt) } ?? .some(nil))
                : nil
            let kimiWeekly: Int?? = kimiOn
                ? (model.kimiQuota.map { .some($0.weekly.pctInt) } ?? .some(nil))
                : nil
            let monitor = SystemMetricsMonitor.shared
            return MenuBarTextRenderer.image(
                scheme: scheme,
                fiveHour: fiveHour,
                oneWeek: oneWeek,
                oneMonth: oneMonth,
                openCodeRolling: ocRolling ?? nil,
                openCodeWeekly: ocWeekly ?? nil,
                kimiFiveHour: kimiFiveHour ?? nil,
                kimiWeekly: kimiWeekly ?? nil,
                cpu: sysOn ? monitor.cpuPercent : nil,
                memory: sysOn ? monitor.memoryPercent : nil,
                columns: columns,
                isDark: MenuBarAppearance.shared.isDark,
                thresholdConfig: model.thresholdConfig,
                aliyunVisible: aliyunOn,
                moneyFloor: model.moneyFloor
            )
        }
        TokenPlanModel.shared.renderTooltipSink = { model in
            MenuBarTable.tooltip(columns: model.menuBarColumns())
        }
        // 灵动岛点行 → 打开面板并落在对应 tab(岛活在独立覆盖面板里,拿不到 AppDelegate)
        IslandOverlayController.shared.openPanelSink = { kind in
            guard let tab = ProviderTab(kind: ProviderKind.from(menuBarColumnKind: kind)) else { return }
            (NSApp.delegate as? AppDelegate)?.openPanel(tab: tab)
        }
        // 应用保存的主题
        NSApplication.shared.appearance = ThemeManager.shared.theme.nsAppearance
    }

    var body: some Scene {
        // 注意:不再用 MenuBarExtra——macOS 26 会因系统隐藏状态项而回收进程。
        // 状态项由 AppDelegate 手动管理(NSStatusItem + NSPopover)。
        //
        // Settings scene 只作占位(App 至少需要一个 Scene):设置实体走自定义
        // NSPanel(SettingsWindowManager)。曾经 scene 里放 bridge(onAppear 转发
        // 真面板 + 关占位窗),但 macOS 26 上经 Apple 'oapp' 事件启动时,SwiftUI 会在
        // applicationDidFinishLaunching 期间**主动求值 Settings scene 的 body**
        // (调用栈:SwiftUI AppDelegate.applicationDidFinishLaunching →
        // Update.dispatchActions → bridge onAppear),bridge 每次启动都把真设置窗
        // 弹出来——`open` 启动(install-update.sh 即如此)必中。改为空内容:
        // 求值只会造出不可见的占位窗(实测不可见),「设置…」(⌘,)由 CommandGroup
        // 替换项直接打开真面板,scene 本身永不激活。
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button("设置…") { SettingsWindowManager.shared.show() }
                        .keyboardShortcut(",", modifiers: .command)
                }
            }
    }
}

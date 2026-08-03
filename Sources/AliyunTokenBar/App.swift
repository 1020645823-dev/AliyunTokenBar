import SwiftUI
import AppKit
import AliyunTokenBarCore

// MARK: - 配色 token(复刻 KimiCodeBar 动态色)

private func dynamicColor(light: NSColor, dark: NSColor) -> Color {
    Color(NSColor(name: nil, dynamicProvider: { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark ? dark : light
    }))
}

extension ShapeStyle where Self == Color {
    // 固定白色系(不随明暗变化):用户明确要求白色背景。
    // 菜单栏面板的 appearance 判定不可靠,dynamicColor 曾导致浅灰字看不清,
    // 改为固定色保证对比度稳定(WCAG 目标:正文 ≥4.5:1)。
    static var atbPanelBackground: Color { Color(white: 1.0) }            // 纯白
    static var atbCardBackground: Color { Color(white: 0.955) }           // 微灰,与面板区分
    static var atbBlue: Color { Color(red: 0.16, green: 0.42, blue: 0.87) }  // 深蓝(白底更清晰)
    /// 主文字:深黑(对比度 ~19:1)
    static var atbTextPrimary: Color { Color(white: 0.10) }
    /// 次级文字:中深灰(对比度 ~8:1)
    static var atbTextSecondary: Color { Color(white: 0.30) }
    /// 三级文字:中灰(对比度 ~4.6:1,达标)
    static var atbTextTertiary: Color { Color(white: 0.45) }
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
            UserDefaults.standard.set(theme.rawValue, forKey: "appTheme")
            NSApplication.shared.appearance = theme.nsAppearance
        }
    }
    private init() {
        let raw = UserDefaults.standard.string(forKey: "appTheme") ?? ""
        theme = AppTheme(rawValue: raw) ?? .system
    }
}

// MARK: - 菜单栏图标样式

enum MenuBarDisplayScheme: String, CaseIterable, Identifiable {
    case cloudPercent  // 默认:云朵 + 7天百分比
    case compact       // 紧凑:5h/7d 双行
    case singleLine    // 单行:35%·61%
    case iconOnly      // 仅图标(进度环)
    case systemStats   // 仅本机 CPU/内存

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .cloudPercent: return "云朵 + 百分比(默认)"
        case .compact: return "5h/7d 双行"
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
        didSet { UserDefaults.standard.set(scheme.rawValue, forKey: "menuBarScheme") }
    }
    private init() {
        let raw = UserDefaults.standard.string(forKey: "menuBarScheme") ?? ""
        scheme = MenuBarDisplayScheme(rawValue: raw) ?? .compact
    }
}

// MARK: - 菜单栏图标渲染

enum MenuBarTextRenderer {
    /// 按 scheme 渲染菜单栏图标(模板图,系统按明暗自动染色)。
    /// 百分比参数为 nil 时表示服务/网络不可用,显示横杠(—)。
    /// openCodeRolling/openCodeWeekly 为 nil 时不显示 OpenCode 部分。
    /// kimiWeekly 为 nil 时不显示 Kimi 部分。
    /// cpu/memory 均为 nil(开关关闭)时各样式整段隐藏、systemStats 回退云朵;仅一个为 nil(采样未就绪)时该数值显示横杠(—)。
    /// thresholdConfig:控制百分比数字的阈值变色(品牌色保留于图标前缀)。
    @MainActor
    static func image(scheme: MenuBarDisplayScheme, fiveHour: Int?, oneWeek: Int?,
                      openCodeRolling: Int? = nil, openCodeWeekly: Int? = nil,
                      kimiWeekly: Int? = nil,
                      cpu: Int? = nil, memory: Int? = nil,
                      thresholdConfig: ThresholdConfig = ThresholdConfig()) -> NSImage {
        switch scheme {
        case .cloudPercent: return cloudPercentImage(fiveHour: fiveHour, oneWeek: oneWeek,
                                                      openCodeRolling: openCodeRolling, openCodeWeekly: openCodeWeekly,
                                                      kimiWeekly: kimiWeekly, cpu: cpu, memory: memory,
                                                      thresholdConfig: thresholdConfig)
        case .compact: return compactImage(fiveHour: fiveHour, oneWeek: oneWeek,
                                           kimiWeekly: kimiWeekly, cpu: cpu, memory: memory)
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

    /// 默认紧凑:5h/7d 双行 + Kimi 周百分比行(nil 时显示横杠)+ 本机 C/M 行
    @MainActor
    private static func compactImage(fiveHour: Int?, oneWeek: Int?, kimiWeekly: Int? = nil,
                                     cpu: Int? = nil, memory: Int? = nil) -> NSImage {
        let content = VStack(alignment: .trailing, spacing: -1) {
            HStack(spacing: 2) {
                Text("5h").font(.system(size: 10, weight: .medium)).monospacedDigit().frame(width: 16, alignment: .leading)
                Text(pctText(fiveHour)).font(.system(size: 10, weight: .medium)).monospacedDigit().frame(width: 30, alignment: .trailing)
            }
            HStack(spacing: 2) {
                Text("7d").font(.system(size: 10, weight: .medium)).monospacedDigit().frame(width: 16, alignment: .leading)
                Text(pctText(oneWeek)).font(.system(size: 10, weight: .medium)).monospacedDigit().frame(width: 30, alignment: .trailing)
            }
            if kimiWeekly != nil {
                HStack(spacing: 2) {
                    Image(systemName: "sparkles").font(.system(size: 9, weight: .bold)).frame(width: 16, alignment: .leading)
                    Text(pctText(kimiWeekly)).font(.system(size: 10, weight: .medium)).monospacedDigit().frame(width: 30, alignment: .trailing)
                }
            }
            if cpu != nil || memory != nil {
                HStack(spacing: 2) {
                    Text("C").font(.system(size: 10, weight: .medium)).monospacedDigit().frame(width: 16, alignment: .leading)
                    Text(pctText(cpu)).font(.system(size: 10, weight: .medium)).monospacedDigit().frame(width: 30, alignment: .trailing)
                    Text("M").font(.system(size: 10, weight: .medium)).monospacedDigit().frame(width: 16, alignment: .leading)
                    Text(pctText(memory)).font(.system(size: 10, weight: .medium)).monospacedDigit().frame(width: 30, alignment: .trailing)
                }
            }
        }
        .foregroundStyle(.black)
        .fixedSize(horizontal: true, vertical: true)
        return render(content)
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
    private static func render<V: View>(_ content: V) -> NSImage {
        let renderer = ImageRenderer(content: content)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2.0
        guard let img = renderer.nsImage, img.size.width > 0, img.size.height > 0 else {
            // 渲染失败:返回固定云朵图标(确保 label 非空,避免系统自动终止)
            return NSImage(systemSymbolName: "cloud.fill", accessibilityDescription: "AliyunTokenBar") ?? NSImage(size: NSSize(width: 48, height: 20))
        }
        img.isTemplate = true   // 模板图,菜单栏自动适配明暗
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
            let kimiWeekly: Int?? = model.kimiQuota.map { .some($0.weekly.pctInt) }
                ?? (model.kimiConfigured && model.kimiError != nil ? .some(nil) : nil)
            let monitor = SystemMetricsMonitor.shared
            return MenuBarTextRenderer.image(
                scheme: MenuBarStyleManager.shared.scheme,
                fiveHour: model.quota?.usage.fiveHour.percentageInt,
                oneWeek: model.quota?.usage.oneWeek.percentageInt,
                openCodeRolling: ocRolling ?? nil,
                openCodeWeekly: ocWeekly ?? nil,
                kimiWeekly: kimiWeekly ?? nil,
                cpu: model.systemStatsEnabled ? monitor.cpuPercent : nil,
                memory: model.systemStatsEnabled ? monitor.memoryPercent : nil,
                thresholdConfig: model.thresholdConfig
            )
        }
        // 应用保存的主题
        NSApplication.shared.appearance = ThemeManager.shared.theme.nsAppearance
    }

    var body: some Scene {
        // 注意:不再用 MenuBarExtra——macOS 26 会因系统隐藏状态项而回收进程。
        // 状态项由 AppDelegate 手动管理(NSStatusItem + NSPopover)。
        // 设置窗口走自定义 NSPanel(SettingsWindowManager),故此处无 Settings scene。
        Settings {
            SettingsView()
        }
    }
}

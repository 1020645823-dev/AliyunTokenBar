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
    static var atbPanelBackground: Color {
        dynamicColor(
            light: NSColor(red: 0.91, green: 0.91, blue: 0.93, alpha: 1.0),
            dark: NSColor(red: 0.06, green: 0.08, blue: 0.13, alpha: 1.0)
        )
    }
    static var atbCardBackground: Color {
        dynamicColor(
            light: NSColor(white: 0.99, alpha: 1.0),
            dark: NSColor(red: 0.11, green: 0.14, blue: 0.21, alpha: 1.0)
        )
    }
    static var atbBlue: Color { Color(red: 0.23, green: 0.51, blue: 0.96) }
    static var atbTextPrimary: Color {
        dynamicColor(light: NSColor(white: 0.12, alpha: 1.0), dark: NSColor(white: 1.0, alpha: 1.0))
    }
    static var atbTextSecondary: Color {
        dynamicColor(light: NSColor(white: 0.35, alpha: 1.0), dark: NSColor(white: 1.0, alpha: 0.55))
    }
    static var atbTextTertiary: Color {
        dynamicColor(light: NSColor(white: 0.50, alpha: 1.0), dark: NSColor(white: 1.0, alpha: 0.40))
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

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .cloudPercent: return "云朵 + 百分比(默认)"
        case .compact: return "5h/7d 双行"
        case .singleLine: return "单行(35%·61%)"
        case .iconOnly: return "仅图标"
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
        scheme = MenuBarDisplayScheme(rawValue: raw) ?? .cloudPercent
    }
}

// MARK: - 菜单栏图标渲染

enum MenuBarTextRenderer {
    /// 按 scheme 渲染菜单栏图标(模板图,系统按明暗自动染色)。
    /// openCodeRolling/openCodeWeekly 为 nil 时不显示 OpenCode 部分。
    @MainActor
    static func image(scheme: MenuBarDisplayScheme, fiveHour: Int, oneWeek: Int,
                      openCodeRolling: Int? = nil, openCodeWeekly: Int? = nil) -> NSImage {
        switch scheme {
        case .cloudPercent: return cloudPercentImage(fiveHour: fiveHour, oneWeek: oneWeek,
                                                      openCodeRolling: openCodeRolling, openCodeWeekly: openCodeWeekly)
        case .compact: return compactImage(fiveHour: fiveHour, oneWeek: oneWeek)
        case .singleLine: return singleLineImage(fiveHour: fiveHour, oneWeek: oneWeek)
        case .iconOnly: return iconOnlyImage(fiveHour: fiveHour, oneWeek: oneWeek)
        }
    }

    /// 云朵 + 阿里云双百分比 + (可选)OpenCode 双百分比:
    /// ☁ 5h 35% · 7d 61%  ⚡ 22% · 43%
    /// 用颜色区分:阿里云橙色、OpenCode 紫色。非模板彩色图(放弃明暗自动适配换取区分度)。
    @MainActor
    private static func cloudPercentImage(fiveHour: Int, oneWeek: Int,
                                          openCodeRolling: Int? = nil, openCodeWeekly: Int? = nil) -> NSImage {
        let aliyunOrange = Color(red: 1.0, green: 0.42, blue: 0.0)
        let openCodePurple = Color(red: 0.55, green: 0.35, blue: 0.85)
        let content = HStack(spacing: 4) {
            // 阿里云:橙色云朵 + 橙色百分比
            cloudShape.fill(aliyunOrange).frame(width: 14, height: 11)
            Text("5h").font(.system(size: 8, weight: .semibold)).monospacedDigit().foregroundStyle(aliyunOrange.opacity(0.8))
            Text("\(fiveHour)%").font(.system(size: 11, weight: .semibold)).monospacedDigit().foregroundStyle(aliyunOrange)
            Text("·").font(.system(size: 11)).foregroundStyle(aliyunOrange.opacity(0.5))
            Text("7d").font(.system(size: 8, weight: .semibold)).monospacedDigit().foregroundStyle(aliyunOrange.opacity(0.8))
            Text("\(oneWeek)%").font(.system(size: 11, weight: .semibold)).monospacedDigit().foregroundStyle(aliyunOrange)
            // OpenCode:紫色闪电 + 紫色百分比(配置了才显示)
            if let rolling = openCodeRolling, let weekly = openCodeWeekly {
                // 留白分隔(不用 |,靠间距+颜色切换区分)
                Spacer().frame(width: 6)
                Image(systemName: "bolt.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(openCodePurple)
                Text("\(rolling)%").font(.system(size: 11, weight: .semibold)).monospacedDigit().foregroundStyle(openCodePurple)
                Text("·").font(.system(size: 11)).foregroundStyle(openCodePurple.opacity(0.5))
                Text("\(weekly)%").font(.system(size: 11, weight: .semibold)).monospacedDigit().foregroundStyle(openCodePurple)
            }
        }
        .frame(height: 20)
        .fixedSize(horizontal: true, vertical: false)
        return renderColored(content)
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

    /// 默认紧凑:5h/7d 双行
    @MainActor
    private static func compactImage(fiveHour: Int, oneWeek: Int) -> NSImage {
        let content = VStack(alignment: .trailing, spacing: -1) {
            HStack(spacing: 2) {
                Text("5h").font(.system(size: 10, weight: .medium)).monospacedDigit().frame(width: 16, alignment: .leading)
                Text("\(fiveHour)%").font(.system(size: 10, weight: .medium)).monospacedDigit().frame(width: 30, alignment: .trailing)
            }
            HStack(spacing: 2) {
                Text("7d").font(.system(size: 10, weight: .medium)).monospacedDigit().frame(width: 16, alignment: .leading)
                Text("\(oneWeek)%").font(.system(size: 10, weight: .medium)).monospacedDigit().frame(width: 30, alignment: .trailing)
            }
        }
        .foregroundStyle(.black)
        .frame(width: 48, height: 20, alignment: .trailing)
        return render(content)
    }

    /// 单行:35%·61%
    @MainActor
    private static func singleLineImage(fiveHour: Int, oneWeek: Int) -> NSImage {
        let content = HStack(spacing: 3) {
            Text("\(fiveHour)%").font(.system(size: 12, weight: .medium)).monospacedDigit()
            Text("·").font(.system(size: 12, weight: .medium))
            Text("\(oneWeek)%").font(.system(size: 12, weight: .medium)).monospacedDigit()
        }
        .foregroundStyle(.black)
        .frame(height: 20)
        .fixedSize(horizontal: true, vertical: false)
        return render(content)
    }

    /// 仅图标:小圆环(外环=7d,内环=5h 的填充比例)
    @MainActor
    private static func iconOnlyImage(fiveHour: Int, oneWeek: Int) -> NSImage {
        let size: CGFloat = 18
        // 用 Canvas 画双环
        let content = Canvas { ctx, sz in
            let center = CGPoint(x: sz.width/2, y: sz.height/2)
            let outerR: CGFloat = 7
            let innerR: CGFloat = 4
            // 外环底
            ctx.stroke(Path(ellipseIn: CGRect(x: center.x-outerR, y: center.y-outerR, width: outerR*2, height: outerR*2)),
                       with: .color(.black.opacity(0.25)), lineWidth: 1.5)
            // 外环进度(7d)
            drawArc(ctx: ctx, center: center, radius: outerR, pct: Double(oneWeek)/100, color: .black, width: 1.5)
            // 内环底
            ctx.stroke(Path(ellipseIn: CGRect(x: center.x-innerR, y: center.y-innerR, width: innerR*2, height: innerR*2)),
                       with: .color(.black.opacity(0.25)), lineWidth: 1.5)
            // 内环进度(5h)
            drawArc(ctx: ctx, center: center, radius: innerR, pct: Double(fiveHour)/100, color: .black, width: 1.5)
        }
        .frame(width: size, height: size)
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
        guard let img = renderer.nsImage else { return NSImage(size: NSSize(width: 48, height: 20)) }
        img.isTemplate = true   // 模板图,菜单栏自动适配明暗
        return img
    }

    /// 渲染彩色图(非模板):保留颜色用于区分多个套餐。代价:不随菜单栏明暗自动变色。
    @MainActor
    private static func renderColored<V: View>(_ content: V) -> NSImage {
        let renderer = ImageRenderer(content: content)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2.0
        guard let img = renderer.nsImage else { return NSImage(size: NSSize(width: 48, height: 20)) }
        img.isTemplate = false   // 彩色,保留橙/紫区分度
        return img
    }
}

// MARK: - App 入口

@main
struct AliyunTokenBarApp: App {
    @StateObject private var model = TokenPlanModel.shared
    @StateObject private var themeManager = ThemeManager.shared
    @StateObject private var menuBarStyle = MenuBarStyleManager.shared

    init() {
        Task { @MainActor in
            TokenPlanModel.shared.startTimer()
        }
        // 应用保存的主题
        NSApplication.shared.appearance = ThemeManager.shared.theme.nsAppearance
    }

    var body: some Scene {
        MenuBarExtra {
            TokenPlanMenu()
        } label: {
            if model.quota != nil {
                Image(nsImage: MenuBarTextRenderer.image(
                    scheme: menuBarStyle.scheme,
                    fiveHour: model.quota?.usage.fiveHour.percentage ?? 0,
                    oneWeek: model.quota?.usage.oneWeek.percentage ?? 0,
                    openCodeRolling: model.openCodeQuota?.rolling.pct,
                    openCodeWeekly: model.openCodeQuota?.weekly.pct
                ))
            } else {
                Image(systemName: "speedometer")
            }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
    }
}

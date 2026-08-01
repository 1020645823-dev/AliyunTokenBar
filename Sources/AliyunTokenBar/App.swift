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

// MARK: - 菜单栏图标渲染

enum MenuBarTextRenderer {
    /// 渲染 "5h/7d" 双行百分比(模板图,系统按明暗自动染色)。
    /// ImageRenderer 的 init/content/nsImage 均为 @MainActor 隔离,故此方法亦标注 @MainActor。
    @MainActor
    static func image(fiveHour: Int, oneWeek: Int) -> NSImage {
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

        let renderer = ImageRenderer(content: content)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2.0
        guard let img = renderer.nsImage else { return NSImage(size: NSSize(width: 48, height: 20)) }
        img.isTemplate = true   // 关键:模板图,菜单栏自动适配明暗
        return img
    }
}

// MARK: - App 入口

@main
struct AliyunTokenBarApp: App {
    @StateObject private var model = TokenPlanModel.shared
    @StateObject private var sparkle = SparkleUpdater.shared

    init() {
        // 启动即检测登录态并拉数据(MenuBarExtra 的内容只在面板打开时实例化,
        // 不能依赖 onAppear 触发首拉,否则图标一直停在占位符)
        Task { @MainActor in
            TokenPlanModel.shared.startTimer()
        }
        // SparkleUpdater.shared 在首次访问时启动定时更新检查(见 SUScheduledCheckInterval)
        _ = SparkleUpdater.shared
    }

    var body: some Scene {
        MenuBarExtra {
            TokenPlanMenu()
        } label: {
            if let q = model.quota {
                Image(nsImage: MenuBarTextRenderer.image(fiveHour: q.usage.fiveHour.percentage,
                                                         oneWeek: q.usage.oneWeek.percentage))
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

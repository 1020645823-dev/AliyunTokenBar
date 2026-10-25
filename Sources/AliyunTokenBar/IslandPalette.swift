import SwiftUI
import AliyunTokenBarCore

/// 岛专用双主题调色板。信息文字不通过简单反色生成,浅/深分别取值。
struct IslandPalette {
    let isDark: Bool

    var textPrimary: Color {
        isDark ? .white.opacity(0.96) : Color(red: 0.07, green: 0.10, blue: 0.17)
    }
    var textSecondary: Color {
        isDark ? .white.opacity(0.80) : Color(red: 0.20, green: 0.26, blue: 0.36)
    }
    var textTertiary: Color {
        isDark ? .white.opacity(0.68) : Color(red: 0.27, green: 0.34, blue: 0.43)
    }
    var textFaint: Color {
        isDark ? .white.opacity(0.56) : Color(red: 0.40, green: 0.46, blue: 0.55)
    }

    var surfaceBase: Color {
        isDark ? Color(red: 0.14, green: 0.18, blue: 0.26).opacity(0.96)
               : Color(red: 0.88, green: 0.92, blue: 0.97).opacity(0.97)
    }
    var surfaceSheen: Color { isDark ? .white.opacity(0.08) : .white.opacity(0.70) }
    var surfaceBlue: Color { .blue.opacity(isDark ? 0.06 : 0.08) }
    var auroraBlue: Double { isDark ? 0.18 : 0.10 }
    var auroraPurple: Double { isDark ? 0.11 : 0.06 }

    var borderStrong: Color { isDark ? .white.opacity(0.24) : .white.opacity(0.90) }
    var borderAccent: Color { isDark ? .cyan.opacity(0.10) : .blue.opacity(0.18) }
    var borderWeak: Color { isDark ? .white.opacity(0.055) : .black.opacity(0.08) }
    var shadowOpacity: Double { isDark ? 0.46 : 0.18 }

    var pillTop: Color {
        isDark ? Color(red: 0.075, green: 0.085, blue: 0.11)
               : Color(red: 0.94, green: 0.96, blue: 0.99)
    }
    var pillBottom: Color {
        isDark ? .black : Color(red: 0.82, green: 0.87, blue: 0.93)
    }

    var track: Color {
        isDark ? .white.opacity(0.09) : Color(red: 0.15, green: 0.22, blue: 0.32).opacity(0.12)
    }
    var tileStroke: Color {
        isDark ? .white.opacity(0.055) : Color(red: 0.20, green: 0.28, blue: 0.40).opacity(0.12)
    }
    /// 叠加在品牌底色之上;浅色皮肤用黑色微弱压暗,深色用白色提亮。
    var tileOverlay: Color { isDark ? .white : .black }
    var detailBase: Color { isDark ? .white.opacity(0.025) : .white.opacity(0.38) }

    func stateColor(_ state: ColumnState) -> Color {
        IslandStateColor.color(state, isDark: isDark)
    }
}

private struct IslandPaletteEnvironmentKey: EnvironmentKey {
    static let defaultValue = IslandPalette(isDark: true)
}

extension EnvironmentValues {
    var islandPalette: IslandPalette {
        get { self[IslandPaletteEnvironmentKey.self] }
        set { self[IslandPaletteEnvironmentKey.self] = newValue }
    }
}

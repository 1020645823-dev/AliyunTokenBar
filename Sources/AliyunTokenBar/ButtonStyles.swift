import SwiftUI

// MARK: - 统一按钮样式(三档:Primary / Secondary / Text,含 hover 反馈)

/// 主按钮:品牌蓝填充,白字;hover 微亮、按下微压。
/// 用于「重新登录」「保存并验证」「登录 OpenCode」等关键操作。
struct ATBPrimaryButtonStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, DesignTokens.spacingL)
            .padding(.vertical, DesignTokens.spacingS)
            .background(hovering ? Color.atbBlue.opacity(0.85) : Color.atbBlue)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radiusM))
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .onHover { hovering = $0 }
    }
}

/// 次按钮:系统控件底色 + 描边;hover 微亮、按下微暗。
/// 用于「刷新」「控制台」「设置」「退出」等面板操作。
struct ATBSecondaryButtonStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.atbTextSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, DesignTokens.spacingS)
            .background(hovering ? Color.atbTextPrimary.opacity(0.06) : Color.atbCardBackground)
            .overlay(RoundedRectangle(cornerRadius: DesignTokens.radiusM).stroke(Color.atbSeparator))
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radiusM))
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .onHover { hovering = $0 }
    }
}

/// 紧凑按钮:单行图标+文字,卡片底色 + 描边;hover 微亮、按下微暗。
/// 用于面板底部操作栏(刷新/控制台/设置/退出),比竖排图标按钮省约一半高度。
struct ATBCompactButtonStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.atbTextSecondary)
            .padding(.horizontal, DesignTokens.spacingS + 1)
            .padding(.vertical, 5)
            .background(hovering ? Color.atbTextPrimary.opacity(0.06) : Color.atbCardBackground)
            .overlay(RoundedRectangle(cornerRadius: DesignTokens.radiusS + 2).stroke(Color.atbSeparator))
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radiusS + 2))
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .onHover { hovering = $0 }
    }
}

/// 文字按钮:无背景,蓝色文字;hover 加深、按下微暗。用于「取消」「清除」等低权重操作。
struct ATBTextButtonStyle: ButtonStyle {
    var color: Color = .atbBlue
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(hovering ? color.opacity(0.75) : color)
            .opacity(configuration.isPressed ? 0.6 : 1.0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .onHover { hovering = $0 }
    }
}

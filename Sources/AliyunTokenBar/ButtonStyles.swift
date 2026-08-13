import SwiftUI

// MARK: - 统一按钮样式(三档:Primary / Secondary / Text)

/// 主按钮:品牌蓝填充,白字,按下时微压效果。
/// 用于「重新登录」「保存并验证」「登录 OpenCode」等关键操作。
struct ATBPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, DesignTokens.spacingL)
            .padding(.vertical, DesignTokens.spacingS)
            .background(Color.atbBlue)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radiusM))
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// 次按钮:系统控件底色 + 描边,按下微暗。
/// 用于「刷新」「控制台」「设置」「退出」等面板操作。
struct ATBSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.atbTextSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, DesignTokens.spacingS)
            .background(Color.atbCardBackground)
            .overlay(RoundedRectangle(cornerRadius: DesignTokens.radiusM).stroke(Color.atbSeparator))
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radiusM))
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// 文字按钮:无背景,蓝色文字,按下微暗。用于「取消」「清除」等低权重操作。
struct ATBTextButtonStyle: ButtonStyle {
    var color: Color = .atbBlue

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(color)
            .opacity(configuration.isPressed ? 0.6 : 1.0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

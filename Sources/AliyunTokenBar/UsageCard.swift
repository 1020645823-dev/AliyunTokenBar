import SwiftUI
import AppKit
import AliyunTokenBarCore

// MARK: - 用量卡片(统一视觉 token:阿里云 5h/7d + OpenCode/Kimi 各窗口共用)
//
// v2 视觉语言:
// - 卡左侧 **3pt 品牌色竖纹**(Provider 身份第一识别)
// - 主行:左标题 + 右**大数字 + 填充环**(环在数字右侧,视觉承担 60% 注意力)
// - 副行:重置倒计时(品牌色胶囊)+ 耗尽预测(警告色)+ 提供商标识
// - 末行:Canvas 趋势(品牌色辉光 + 阈值虚线)
// - 卡底:solid atbCardBackground,品牌色 5% 透明叠加(只在 Hero 卡启用)

struct UsageCard: View {
    let title: String
    /// 百分比值(0–100 浮点,2 位小数精度)。nil = 加载中或未到位。
    let percentage: Double?
    /// 重置倒计时("3小时12分钟后重置");nil 时隐藏重置行。
    let resetText: String?
    let brand: Color
    let isLoading: Bool
    /// 阈值配置:数字/环按风险变色(safe→brand / warning→橙 / critical→红)。
    var threshold: ThresholdConfig = ThresholdConfig()
    /// 是否显示 sparkline(由面板按全局开关传入)。
    var showSparkline: Bool = false
    /// sparkline 数据序列标识。
    var sparklineProvider: String = "aliyun"
    var sparklineWindow: String = "7d"
    /// 紧凑模式:true 单行高密度(默认);false 跨行大字号。
    var compact: Bool = true
    /// 数据不可用(服务/网络故障):显示横杠而非数值。
    var dataUnavailable: Bool = false
    /// 重置时间的悬停补充(完整时间戳);nil 时悬停显示 resetText 本身。
    var resetTooltip: String? = nil
    /// 是否为 Hero 卡(品牌色铺底 + 双层填充 + 描边强化)。
    var hero: Bool = false

    var body: some View {
        Group {
            if compact { compactBody } else { fullBody }
        }
        .modifier(UsageCardContainer(brand: brand, hero: hero))
    }

    // MARK: 数据展示文本

    private var pctDisplayText: String {
        guard let pct = percentage else { return "—" }
        return String(format: "%.2f%%", pct)
    }

    private var thresholdPctInt: Int { Int((percentage ?? 0).rounded()) }

    // MARK: 紧凑卡

    private var compactBody: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingS) {
            // 行 1:标题 + 大数字 + 填充环
            HStack(alignment: .center, spacing: DesignTokens.spacingS) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.atbTextPrimary)
                    .fixedSize()          // 标题永远完整,不被 Spacer 挤压成省略号
                    .layoutPriority(1)    // 首帧面板宽度未稳时优先保标题(2026-08-15 占位不齐修复)
                Spacer(minLength: DesignTokens.spacingS)
                heroNumberBlock
                ringBlock
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // 行 2:重置倒计时 + 耗尽预测(同一行两端)
            HStack(spacing: DesignTokens.spacingS) {
                if dataUnavailable {
                    Text("服务/网络不可用,数值待恢复")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.atbTextTertiary)
                } else if let reset = resetText {
                    ATBCountdownPill(text: reset, brand: brand)
                        .help(resetTooltip ?? reset)
                        .accessibilityLabel("重置时间:\(resetTooltip ?? reset)")
                }
                Spacer(minLength: 0)
                if showSparkline && !dataUnavailable && !isLoading {
                    LimitEstimateLabel(provider: sparklineProvider, window: sparklineWindow)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // 行 3:sparkline(开关开启且数据可用时)
            if showSparkline && !dataUnavailable && !isLoading {
                UsageSparkline(provider: sparklineProvider, window: sparklineWindow,
                               brand: brand, height: 20, threshold: threshold)
                    .frame(maxWidth: .infinity)   // 填满卡宽,Canvas 惰性内容不拖窄布局
            }
        }
        // 关键:卡内容区整体声明下限宽度。面板每次点击重建、@Published 数据异步到达,
        // 首帧 SwiftUI 解算宽度时 Spacer(minLength:0) 会把内容压到最窄,造成
        // 「标题行窄、数字环偏右、下一张卡片才顶到宽」的不均匀感(2026-08-15 用户反馈)。
        // 由 UsageCardContainer 的 frame(maxWidth:.infinity) 保证卡片横向撑满,
        // 这里补一层,确保内部任何惰性视图(Canvas/Async 数据)不破坏外圈宽度。
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 大数字块(loading/unavailable 替换为环)
    @ViewBuilder
    private var heroNumberBlock: some View {
        if isLoading {
            LoadingRing().frame(width: 18, height: 18)
                .padding(.trailing, 2)
        } else if dataUnavailable {
            Text("—")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color.atbTextTertiary)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(pctDisplayText)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(thresholdBrand(thresholdPctInt, config: threshold, brand: brand))
                Text("已用")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.atbTextTertiary)
                    .textCase(.uppercase)
                    .tracking(0.5)
            }
            .atbHeroGlow(brand)
        }
    }

    /// 环(loading/dataUnavailable 也照常显示,只是填充为 0% 灰色)
    private var ringBlock: some View {
        ATBFillRing(
            percentage: percentage ?? 0,
            brand: brand,
            diameter: 28,
            lineWidth: 4,
            threshold: dataUnavailable || isLoading ? nil : threshold
        )
    }

    // MARK: 全尺寸卡(预留)

    private var fullBody: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingM) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.atbTextPrimary)
            HStack(alignment: .firstTextBaseline) {
                if isLoading {
                    LoadingRing().frame(width: 22, height: 22)
                } else if dataUnavailable {
                    Text("—")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Color.atbTextTertiary)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: DesignTokens.spacingXS) {
                        Text(pctDisplayText)
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(thresholdBrand(thresholdPctInt, config: threshold, brand: brand))
                        Text("已用")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.atbTextTertiary)
                    }
                }
                Spacer(minLength: 0)
                ATBFillRing(percentage: percentage ?? 0,
                            brand: brand, diameter: 46, lineWidth: 5,
                            threshold: dataUnavailable || isLoading ? nil : threshold)
            }
            if dataUnavailable {
                Text("—").font(.system(size: 11)).foregroundStyle(Color.atbTextTertiary)
            } else if let reset = resetText {
                Text(reset)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.atbTextTertiary)
                    .help(resetTooltip ?? reset)
            }
            if showSparkline && !dataUnavailable {
                UsageSparkline(provider: sparklineProvider, window: sparklineWindow,
                               brand: brand, threshold: threshold)
            }
        }
    }
}

// MARK: - 卡容器修饰符(HStack:左竖纹 + 内容)

private struct UsageCardContainer: ViewModifier {
    let brand: Color
    let hero: Bool

    func body(content: Content) -> some View {
        // 品牌竖纹:画进内容的 background 里,高度永远=内容自身高,
        // 不再参与 HStack 纵向尺寸协商。HStack 被兄弟视图拉伸时(如 planCard 高、VStack spacing)
        // 竖纹不会穿出卡片(2026-08-15 截图:橙条从 7d 卡贯穿到 Pro 套餐卡的根因)。
        content
            .padding(.leading, DesignTokens.stripeWidth)   // 给竖纹留位
            .background(alignment: .leading) {
                Rectangle()
                    .fill(brand)
                    .frame(width: DesignTokens.stripeWidth)
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radiusM + 2))
                    .padding(.vertical, 1)  // 微缩放让竖纹被卡圆角包住
            }
            .padding(.horizontal, DesignTokens.spacingM - DesignTokens.stripeWidth)
            .padding(.vertical, DesignTokens.spacingS + 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                ZStack {
                    Color.atbCardBackground
                    if hero { brand.opacity(0.05) }
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.radiusM + 2)
                    .strokeBorder(
                        (hero ? brand.opacity(0.18) : Color.atbSeparator.opacity(0.5)),
                        lineWidth: DesignTokens.strokeHairline
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radiusM + 2))
    }
}

// MARK: - 加载转圈

struct LoadingRing: View {
    @State private var rotate = false
    var body: some View {
        Image(systemName: "circle.dashed")
            .rotationEffect(.degrees(rotate ? 360 : 0))
            .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: rotate)
            .onAppear { rotate = true }
    }
}

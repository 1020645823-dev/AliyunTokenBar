import SwiftUI
import AppKit
import AliyunTokenBarCore

// MARK: - 用量卡片(统一视觉 token:阿里云 5h/7d + OpenCode 三窗口共用)

/// 用量卡片。**所有用量窗口共用此组件**,保证设计 token 完全一致。
/// 数据源与视觉解耦:`percentage`/`resetText` 由调用方从
/// UsageDetail(阿里云)或 OpenCodeWindow(OpenCode)提取。
/// 对齐官方控制台:2 位小数精度 + 带刻度进度条(0/50/90/100) + 完整重置时间。
/// 当 `dataUnavailable` 为 true 时,数值显示为横杠(—),表示服务/网络不可用。
struct UsageCard: View {
    let title: String
    /// 百分比值(0–100 浮点,2 位小数精度)。nil = 加载中。
    let percentage: Double?
    let resetText: String?
    let color: Color
    let isLoading: Bool
    /// 阈值配置:进度条按风险变色(safe→color / warning→橙 / critical→红)。
    var thresholdConfig: ThresholdConfig = ThresholdConfig()
    /// 是否显示 sparkline(由面板按全局开关传入)。
    var showSparkline: Bool = false
    /// sparkline 数据序列标识(aliyun 5h/7d、opencode rolling/weekly/monthly)。
    var sparklineProvider: String = "aliyun"
    var sparklineWindow: String = "7d"
    /// 紧凑模式:true 单行高密度(推荐,默认);false 全尺寸展开(大字号)。
    var compact: Bool = true
    /// 数据不可用(服务/网络故障):显示横杠而非数值。
    var dataUnavailable: Bool = false

    var body: some View {
        if compact { compactBody } else { fullBody }
    }

    /// 百分比显示文本:2 位小数,对齐官方。
    private var pctDisplayText: String {
        guard let pct = percentage else { return "—" }
        return String(format: "%.2f%%", pct)
    }

    /// 阈值色(用整数部分判定 band,避免 0.26% 误触 warning)。
    private var thresholdPctInt: Int { Int((percentage ?? 0).rounded()) }

    /// 紧凑卡:对齐官方控制台布局——标题+重置时间 / 百分比已用 / 带刻度进度条。
    private var compactBody: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingS) {
            // 上层:标题 + 重置时间
            HStack {
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.atbTextPrimary)
                Spacer()
                if dataUnavailable {
                    Text("—").font(.system(size: 10)).foregroundStyle(.atbTextTertiary)
                } else if let reset = resetText {
                    Text("将于 \(reset) 重置刷新")
                        .font(.system(size: 9)).foregroundStyle(.atbTextTertiary)
                        .lineLimit(1)
                }
            }
            // 中层:百分比数值 + "已用" 标签
            HStack(spacing: DesignTokens.spacingXS) {
                if isLoading {
                    LoadingRing().frame(width: 14, height: 14)
                } else if dataUnavailable {
                    Text("—").font(.system(size: 15, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.atbTextTertiary)
                } else {
                    Text(pctDisplayText)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(thresholdColor(thresholdPctInt, config: thresholdConfig, base: .atbTextPrimary))
                    Text("已用").font(.system(size: 10)).foregroundStyle(.atbTextTertiary)
                }
            }
            // 下层:带刻度进度条(0% / 50% / 90% / 100%)
            scaledProgressBar
            if showSparkline && !dataUnavailable {
                UsageSparkline(provider: sparklineProvider, window: sparklineWindow, color: color, height: 16)
                LimitEstimateLabel(provider: sparklineProvider, window: sparklineWindow)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, DesignTokens.spacingM).padding(.vertical, DesignTokens.spacingS + 2)
        .frame(maxWidth: .infinity)
        .background(Color.atbCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radiusM))
        .shadow(color: Color.black.opacity(0.04), radius: 2, y: 1)
    }

    /// 全尺寸卡:大数字 + 带刻度进度条 + 重置时间 + sparkline。
    private var fullBody: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingS + 2) {
            Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(.atbTextPrimary)
            // 百分比数值
            ZStack(alignment: .leading) {
                if isLoading {
                    LoadingRing().frame(width: 24, height: 24)
                } else if dataUnavailable {
                    Text("—").font(.system(size: 32, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.atbTextTertiary)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: DesignTokens.spacingXS) {
                        Text(pctDisplayText)
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(thresholdColor(thresholdPctInt, config: thresholdConfig, base: .atbTextPrimary))
                        Text("已用").font(.system(size: 12)).foregroundStyle(.atbTextTertiary)
                    }
                }
            }.frame(height: 38)
            // 带刻度进度条
            scaledProgressBar
            // 重置时间
            if dataUnavailable {
                Text("—").font(.system(size: 11)).foregroundStyle(.atbTextTertiary)
            } else if let reset = resetText {
                Text("将于 \(reset) 重置刷新").font(.system(size: 10)).foregroundStyle(.atbTextTertiary)
            }
            if showSparkline && !dataUnavailable {
                UsageSparkline(provider: sparklineProvider, window: sparklineWindow, color: color)
            }
        }
        .padding(DesignTokens.spacingL).frame(maxWidth: .infinity)
        .background(Color.atbCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radiusL))
        .shadow(color: Color.black.opacity(0.04), radius: 2, y: 1)
    }

    /// 带刻度标记的进度条:对齐官方 0% / 50% / 90% / 100% 四档刻度线。
    private var scaledProgressBar: some View {
        VStack(spacing: 2) {
            GeometryReader { proxy in
                let w = proxy.size.width
                ZStack(alignment: .leading) {
                    // 底轨
                    Capsule().frame(height: 6).foregroundStyle(Color.primary.opacity(0.10))
                    // 填充
                    if !dataUnavailable, let pct = percentage {
                        Capsule()
                            .frame(width: w * CGFloat(min(pct, 100)) / 100, height: 6)
                            .foregroundStyle(thresholdColor(thresholdPctInt, config: thresholdConfig, base: color))
                    }
                    // 刻度线:50% / 90%(0% 和 100% 在两端不需要额外标记)
                    ForEach([50, 90], id: \.self) { tick in
                        Rectangle()
                            .frame(width: 1, height: 10)
                            .foregroundStyle(Color.primary.opacity(0.25))
                            .offset(x: w * CGFloat(tick) / 100 - 0.5)
                    }
                }
            }.frame(height: 10)
            // 刻度标签
            HStack(spacing: 0) {
                Text("0%").font(.system(size: 8)).foregroundStyle(.atbTextSecondary)
                Spacer()
                Text("50%").font(.system(size: 8)).foregroundStyle(.atbTextSecondary)
                Spacer()
                Text("90%").font(.system(size: 8)).foregroundStyle(.atbTextSecondary)
                Spacer()
                Text("100%").font(.system(size: 8)).foregroundStyle(.atbTextSecondary)
            }
        }
    }
}

// MARK: - 复用小组件

struct ActionButton: View {
    let title: String; let icon: String; let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: DesignTokens.spacingXS) {
                Image(systemName: icon).font(.system(size: 16))
                Text(title).font(.system(size: 11))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, DesignTokens.spacingS)
        }
        .buttonStyle(ATBSecondaryButtonStyle())
    }
}

struct LoadingRing: View {
    @State private var rotate = false
    var body: some View {
        Image(systemName: "circle.dashed")
            .rotationEffect(.degrees(rotate ? 360 : 0))
            .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: rotate)
            .onAppear { rotate = true }
    }
}


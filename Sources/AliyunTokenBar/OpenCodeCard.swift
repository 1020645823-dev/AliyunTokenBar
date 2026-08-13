import SwiftUI
import AppKit
import AliyunTokenBarCore

// MARK: - OpenCode Go 用量卡

/// OpenCode Go 套餐用量(rolling/weekly/monthly 三窗口)。
/// 与阿里云区域共用 UsageCard——同一套设计 token(紧凑卡/进度条/sparkline)。
/// 仅在用户配置了 cookie+workspace 后显示。
struct OpenCodeCard: View {
    @StateObject private var model = TokenPlanModel.shared
    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingM) {
            // 品牌头部行:紫色闪电 + 刷新(OpenCode 专属)
            HStack(spacing: DesignTokens.spacingS) {
                Image(systemName: "bolt.fill").font(.system(size: 13, weight: .bold)).foregroundStyle(.purple)
                Text("OpenCode Go").font(.system(size: 13, weight: .medium)).foregroundStyle(.atbTextPrimary)
                Spacer()
                Button { Task { await model.refreshOpenCode() } } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 12)).foregroundStyle(.atbTextTertiary)
                }
                .buttonStyle(.plain)
                .help("刷新 OpenCode 用量")
                .accessibilityLabel("刷新 OpenCode 用量")
            }
            if let q = model.openCodeQuota {
                // 三窗口各一张卡片,视觉 token 与阿里云 5h/7d 完全一致
                UsageCard(title: "滚动限额",
                          percentage: Double(q.rolling.pct), resetText: q.rolling.rollingResetText,
                          color: .purple, isLoading: model.isLoading, thresholdConfig: model.thresholdConfig,
                          showSparkline: model.sparklineEnabled,
                          sparklineProvider: "opencode", sparklineWindow: "rolling")
                UsageCard(title: "每周限额",
                          percentage: Double(q.weekly.pct), resetText: q.weekly.timeUntilReset,
                          color: .atbBlue, isLoading: model.isLoading, thresholdConfig: model.thresholdConfig,
                          showSparkline: model.sparklineEnabled,
                          sparklineProvider: "opencode", sparklineWindow: "weekly")
                UsageCard(title: "每月限额",
                          percentage: Double(q.monthly.pct), resetText: q.monthly.timeUntilReset,
                          color: .orange, isLoading: model.isLoading, thresholdConfig: model.thresholdConfig,
                          showSparkline: model.sparklineEnabled,
                          sparklineProvider: "opencode", sparklineWindow: "monthly")
            } else if let err = model.openCodeError {
                // 网络/服务故障:卡片显示横杠(—),表示数值不可用
                let isNetworkError = err.contains("网络") || err.contains("响应") || err.contains("解析")
                if isNetworkError {
                    UsageCard(title: "滚动限额", percentage: nil, resetText: nil,
                              color: .purple, isLoading: false, thresholdConfig: model.thresholdConfig,
                              dataUnavailable: true)
                    UsageCard(title: "每周限额", percentage: nil, resetText: nil,
                              color: .atbBlue, isLoading: false, thresholdConfig: model.thresholdConfig,
                              dataUnavailable: true)
                    UsageCard(title: "每月限额", percentage: nil, resetText: nil,
                              color: .orange, isLoading: false, thresholdConfig: model.thresholdConfig,
                              dataUnavailable: true)
                } else {
                    // 非网络错误(cookie 过期等):保留文本提示
                    Text(err).font(.system(size: 11)).foregroundStyle(.atbTextTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(DesignTokens.spacingL)
                        .background(Color.atbCardBackground)
                        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radiusL))
                        .shadow(color: Color.black.opacity(0.04), radius: 2, y: 1)
                }
            } else {
                // 加载态:与阿里云一致的加载环
                HStack { Spacer(); LoadingRing().frame(width: 18, height: 18); Spacer() }
                    .padding(DesignTokens.spacingL)
                    .frame(maxWidth: .infinity)
                    .background(Color.atbCardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radiusL))
                    .shadow(color: Color.black.opacity(0.04), radius: 2, y: 1)
            }
        }
        .padding(DesignTokens.spacingL)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}


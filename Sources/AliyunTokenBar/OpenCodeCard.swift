import SwiftUI
import AppKit
import AliyunTokenBarCore

// MARK: - OpenCode Go 用量卡(三窗口 · 紧凑)
//
// v3 视觉语言:
// - 顶部品牌行:紫底双圆点 + OpenCode Go 名称 + 刷新按钮
// - 三窗口改为**一张卡内三环+数字**:每个 slot 显示环 + 大百分比 + 标题 + 倒计时
// - 错误卡保留,配色用品牌紫

struct OpenCodeCard: View {
    @StateObject private var model = TokenPlanModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingM) {
            providerHeader
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 品牌行

    private var providerHeader: some View {
        HStack(spacing: DesignTokens.spacingS) {
            ATBProviderMark(tab: .opencode, size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text("OpenCode Go")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.atbTextPrimary)
                Text("Cloud IDE · 三窗口共用")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color.atbTextTertiary)
                    .tracking(0.3)
            }
            Spacer(minLength: DesignTokens.spacingS)
            refreshButton
        }
    }

    private var refreshButton: some View {
        Button {
            Task { await model.refreshOpenCode() }
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.atbTextTertiary)
                .frame(width: 22, height: 22)
                .background(Color.primary.opacity(0.06))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .help("刷新 OpenCode 用量")
        .accessibilityLabel("刷新 OpenCode 用量")
    }

    // MARK: 内容(三态:数据/不可用/错误)

    @ViewBuilder
    private var content: some View {
        if let q = model.openCodeQuota {
            multiRingSection(q: q)
        } else if let err = model.openCodeError {
            let isNetwork = err.contains("网络") || err.contains("响应") || err.contains("解析")
            if isNetwork {
                unavailableTriple
            } else {
                errorHint(err)
            }
        } else {
            HStack { Spacer(); LoadingRing().frame(width: 18, height: 18); Spacer() }
                .frame(height: 64)
                .atbCard(corner: DesignTokens.radiusL, paddingH: DesignTokens.spacingL,
                         paddingV: DesignTokens.spacingL, alignment: .center)
        }
    }

    /// 三窗口一组(roll/week/month):横向三环卡片
    private func multiRingSection(q: OpenCodeQuota) -> some View {
        let brand = ProviderBrand.color(for: .opencode)
        return ATBMultiRingCard(slots: [
            ATBMultiRingCard.Slot(id: "rolling",
                                  title: "滚动4h",
                                  subtitle: q.rolling.rollingResetText ?? "—",
                                  percentage: Double(q.rolling.pct),
                                  bandColor: thresholdBrand(q.rolling.pct,
                                                            config: model.thresholdConfig,
                                                            brand: brand),
                                  threshold: model.thresholdConfig),
            ATBMultiRingCard.Slot(id: "weekly",
                                  title: "本周",
                                  subtitle: relativeReset(q.weekly) ?? "—",
                                  percentage: Double(q.weekly.pct),
                                  bandColor: thresholdBrand(q.weekly.pct,
                                                            config: model.thresholdConfig,
                                                            brand: brand),
                                  threshold: model.thresholdConfig),
            ATBMultiRingCard.Slot(id: "monthly",
                                  title: "本月",
                                  subtitle: relativeReset(q.monthly) ?? "—",
                                  percentage: Double(q.monthly.pct),
                                  bandColor: thresholdBrand(q.monthly.pct,
                                                            config: model.thresholdConfig,
                                                            brand: brand),
                                  threshold: model.thresholdConfig)
        ])
        .padding(.horizontal, DesignTokens.spacingM)
        .padding(.vertical, DesignTokens.spacingS)
        .frame(maxWidth: .infinity)
        .background(Color.atbCardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.radiusM)
                .strokeBorder(Color.atbSeparator.opacity(0.5), lineWidth: DesignTokens.strokeHairline)
        )
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radiusM))
        .overlay(alignment: .leading) {
            Rectangle().fill(brand)
                .frame(width: DesignTokens.stripeWidth)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radiusM))
                .padding(.vertical, 1)
        }
    }

    /// 网络/解析失败的三窗口不可用横杠
    private var unavailableTriple: some View {
        VStack(spacing: DesignTokens.spacingS) {
            unavailableCard("滚动4h限额")
            unavailableCard("每周限额")
            unavailableCard("每月限额")
        }
    }

    private func unavailableCard(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.atbTextSecondary)
            Spacer()
            Text("—")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.atbTextTertiary)
        }
        .atbCard(paddingV: DesignTokens.spacingS - 2)
    }

    /// 错误提示卡
    private func errorHint(_ err: String) -> some View {
        HStack(alignment: .top, spacing: DesignTokens.spacingS) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("配置异常")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.atbTextPrimary)
                Text(err)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.atbTextSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .atbCard(corner: DesignTokens.radiusL)
    }

    // MARK: helpers

    private func relativeReset(_ w: OpenCodeWindow) -> String? {
        w.resetInSec > 0 ? w.timeUntilReset : nil
    }
}

import SwiftUI
import AppKit
import AliyunTokenBarCore

// MARK: - 智谱 GLM Coding Plan 用量卡
//
// v2 视觉语言:与 OpenCodeCard / KimiCodeCard 对称(品牌行 + 三窗口环卡)。
// 数据源 quota/limit:5h + 周双 TOKENS_LIMIT + MCP 月度 TIME_LIMIT。
// 仅在已配置(手动 key 或自动发现 opencode 配置)后显示。

struct ZhipuCodeCard: View {
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
            ATBProviderMark(tab: .zhipu, size: 24)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text("智谱 GLM")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.atbTextPrimary)
                    if let level = model.zhipuQuota?.level {
                        Text(levelDisplay(level))
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Color.atbBrandZhipu)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Color.atbBrandZhipu.opacity(0.14))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }
                Text("Coding Plan · 5小时 + 周")
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
            Task { await model.refreshZhipu() }
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.atbTextTertiary)
                .frame(width: 22, height: 22)
                .background(Color.primary.opacity(0.06))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .help("刷新智谱 GLM 用量")
        .accessibilityLabel("刷新智谱 GLM 用量")
    }

    // MARK: 内容

    @ViewBuilder
    private var content: some View {
        if let q = model.zhipuQuota {
            VStack(spacing: DesignTokens.spacingM) {
                multiRingSection(q: q)
                if let mcp = q.mcp, !mcp.details.isEmpty {
                    mcpDetailRow(mcp)
                }
            }
        } else if let err = model.zhipuError {
            let isNetwork = err.contains("网络") || err.contains("响应") || err.contains("解析")
            if isNetwork {
                VStack(spacing: DesignTokens.spacingS) {
                    dashCard("5小时限额")
                    dashCard("每周限额")
                    dashCard("MCP 月度")
                }
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

    private func multiRingSection(q: ZhipuQuota) -> some View {
        let brand = ProviderBrand.color(for: .zhipu)
        return ATBMultiRingCard(slots: [
            ATBMultiRingCard.Slot(id: "5h",
                                  title: "5h",
                                  subtitle: q.fiveHour?.timeUntilReset ?? "—",
                                  percentage: q.fiveHour?.pct ?? 0,
                                  bandColor: thresholdBrand(q.fiveHour?.pctInt ?? 0,
                                                            config: model.thresholdConfig,
                                                            brand: brand),
                                  threshold: model.thresholdConfig),
            ATBMultiRingCard.Slot(id: "weekly",
                                  title: "本周",
                                  subtitle: q.weekly?.timeUntilReset ?? "—",
                                  percentage: q.weekly?.pct ?? 0,
                                  bandColor: thresholdBrand(q.weekly?.pctInt ?? 0,
                                                            config: model.thresholdConfig,
                                                            brand: brand),
                                  threshold: model.thresholdConfig),
            ATBMultiRingCard.Slot(id: "mcp",
                                  title: "MCP月",
                                  subtitle: q.mcp?.usageText ?? (q.mcp?.timeUntilReset ?? "—"),
                                  percentage: q.mcp?.percentage ?? 0,
                                  bandColor: brand,
                                  threshold: nil)  // 按次配额不做阈值变色(与系统指标同语义)
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

    /// MCP 明细行:各通道本月已用次数(search-prime 2 · zread 3 …)
    private func mcpDetailRow(_ mcp: ZhipuMCPQuota) -> some View {
        HStack(spacing: DesignTokens.spacingS) {
            Image(systemName: "wrench.and.screwdriver.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.atbTextTertiary)
            Text(mcp.details
                .filter { $0.usage > 0 }
                .sorted { $0.usage > $1.usage }
                .map { "\($0.modelCode) \($0.usage)" }
                .joined(separator: " · "))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.atbTextSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .atbCard(paddingV: DesignTokens.spacingS - 2)
    }

    private func dashCard(_ title: String) -> some View {
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

    /// level 原始值("lite"/"pro"/"max")→ 展示名;未知值宽容兜底。
    private func levelDisplay(_ level: String) -> String {
        switch level.lowercased() {
        case "lite": return "Lite"
        case "pro": return "Pro"
        case "max": return "Max"
        case "liteplan": return "Lite"
        case "proplan": return "Pro"
        case "maxplan": return "Max"
        default: return level.uppercased().prefix(8).description
        }
    }
}

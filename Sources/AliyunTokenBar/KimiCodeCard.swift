import SwiftUI
import AppKit
import AliyunTokenBarCore

// MARK: - Kimi Code 用量卡
//
// v3 视觉语言:与 OpenCodeCard 对称(品牌行 + 三窗口一组环卡 + 订阅池条 + 加油包条)。
// 仅在检测到本机 KimiCodeBar / Kimi CLI 凭证后显示。

struct KimiCodeCard: View {
    @StateObject private var model = TokenPlanModel.shared
    @State private var showKimiLogin = false

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
            ATBProviderMark(tab: .kimi, size: 24)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text("Kimi Code")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.atbTextPrimary)
                    if let level = model.kimiQuota?.membershipLevel {
                        Text(levelDisplay(level))
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Color.atbBrandKimi)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Color.atbBrandKimi.opacity(0.14))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }
                Text("Moonshot · 三窗口共用")
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
            Task { await model.refreshKimi() }
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.atbTextTertiary)
                .frame(width: 22, height: 22)
                .background(Color.primary.opacity(0.06))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .help("刷新 Kimi 用量")
        .accessibilityLabel("刷新 Kimi 用量")
    }

    // MARK: 内容

    @ViewBuilder
    private var content: some View {
        if let q = model.kimiQuota {
            VStack(spacing: DesignTokens.spacingM) {
                multiRingSection(q: q)
                if let balance = q.subscriptionBalance {
                    KimiSubscriptionCard(balance: balance)
                } else if model.kimiWebLoggedIn {
                    UsageCard(title: "总使用量", percentage: nil, resetText: nil,
                              brand: .atbBrandKimi, isLoading: false,
                              threshold: model.thresholdConfig, dataUnavailable: true)
                }
                if let booster = q.booster, booster.enabled {
                    KimiBoosterRow(booster: booster)
                }
                if !model.kimiWebLoggedIn {
                    kimiWebLoginHint
                }
            }
        } else if let err = model.kimiError {
            let isNetwork = err.contains("网络") || err.contains("响应") || err.contains("解析")
            if isNetwork {
                VStack(spacing: DesignTokens.spacingS) {
                    dashCard("5小时限额")
                    dashCard("每周限额")
                    dashCard("月度总额度")
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

    private func multiRingSection(q: KimiQuota) -> some View {
        let brand = ProviderBrand.color(for: .kimi)
        return ATBMultiRingCard(slots: [
            ATBMultiRingCard.Slot(id: "5h",
                                  title: "5h",
                                  subtitle: q.fiveHour.slidingResetText ?? "—",
                                  percentage: q.fiveHour.pct,
                                  bandColor: thresholdBrand(Int(q.fiveHour.pct.rounded()),
                                                            config: model.thresholdConfig,
                                                            brand: brand),
                                  threshold: model.thresholdConfig),
            ATBMultiRingCard.Slot(id: "weekly",
                                  title: "本周",
                                  subtitle: relativeReset(q.weekly) ?? "—",
                                  percentage: q.weekly.pct,
                                  bandColor: thresholdBrand(Int(q.weekly.pct.rounded()),
                                                            config: model.thresholdConfig,
                                                            brand: brand),
                                  threshold: model.thresholdConfig),
            ATBMultiRingCard.Slot(id: "monthly",
                                  title: "本月",
                                  subtitle: q.monthly.map { relativeReset($0) ?? "—" } ?? "—",
                                  percentage: q.monthly?.pct ?? 0,
                                  bandColor: thresholdBrand(
                                    Int((q.monthly?.pct ?? 0).rounded()),
                                    config: model.thresholdConfig, brand: brand),
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

    /// 登录网页控制台引导行
    private var kimiWebLoginHint: some View {
        HStack(spacing: DesignTokens.spacingS) {
            Image(systemName: "lock.open")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.atbTextTertiary)
            VStack(alignment: .leading, spacing: 1) {
                Text("登录 Kimi 网页控制台")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.atbTextPrimary)
                Text("查看订阅总额度明细")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.atbTextTertiary)
            }
            Spacer()
            Button("登录") { showKimiLogin = true }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.atbBrandKimi)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.atbBrandKimi.opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .buttonStyle(.plain)
        }
        .atbCard()
        .sheet(isPresented: $showKimiLogin) { KimiLoginView() }
    }

    private func relativeReset(_ w: KimiWindow) -> String? {
        w.resetTimeMs != nil ? w.timeUntilReset : nil
    }

    private func levelDisplay(_ level: String) -> String {
        switch level.uppercased() {
        case "LEVEL_FREE": return "Free"
        case "LEVEL_TRIAL", "TRIAL": return "Trial"
        case "LEVEL_BASIC": return "Adagio"
        case "LEVEL_STANDARD": return "Moderato"
        case "LEVEL_INTERMEDIATE": return "Allegretto"
        case "LEVEL_ADVANCED": return "Allegro"
        case "LEVEL_PREMIUM": return "Vivace"
        default:
            let trimmed = level.replacingOccurrences(of: "LEVEL_", with: "", options: .caseInsensitive)
            return trimmed.replacingOccurrences(of: "_", with: " ").lowercased().capitalized
        }
    }
}

// MARK: - Kimi 共享订阅池(Work/Code 分段 + 总量)
struct KimiSubscriptionCard: View {
    let balance: KimiSubscriptionBalance
    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingS - 2) {
            // 行 1:大数字 + 重置时间
            HStack(alignment: .firstTextBaseline) {
                Text("订阅池总量")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.atbTextPrimary)
                Spacer(minLength: DesignTokens.spacingS)
                Text(String(format: "%.2f%%", balance.totalUsedPercent))
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.atbBrandKimi)
            }
            // 行 2:Work/Code 分段条
            GeometryReader { proxy in
                let w = proxy.size.width
                HStack(spacing: 1) {
                    if let work = balance.workUsedPercent,
                       let code = balance.codeUsedPercent {
                        Rectangle().fill(Color.atbBrandKimi)
                            .frame(width: max(0, w * CGFloat(work / 100) - 0.5))
                        Rectangle().fill(Color.atbBrandKimi.opacity(0.55))
                            .frame(width: max(0, w * CGFloat(code / 100)))
                    } else {
                        Rectangle().fill(Color.atbBrandKimi.opacity(0.55))
                            .frame(width: max(0, w * CGFloat(balance.totalUsedPercent / 100)))
                    }
                    Rectangle().fill(Color.primary.opacity(0.08))
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .frame(height: 7)
            // 行 3:图例 + 重置时间
            HStack(spacing: 12) {
                if let work = balance.workUsedPercent,
                   let code = balance.codeUsedPercent {
                    KimiSubscriptionLegend(color: .atbBrandKimi, title: "Kimi/Work", percent: work)
                    KimiSubscriptionLegend(color: Color.atbBrandKimi.opacity(0.55), title: "Code", percent: code)
                } else {
                    Text("Work/Code 分项暂不可用")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.atbTextTertiary)
                }
                Spacer(minLength: 0)
                if let ms = balance.expireTimeMs {
                    Text("重置 \(Self.dateText(ms))")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Color.atbTextTertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, DesignTokens.spacingM)
        .padding(.vertical, DesignTokens.spacingS)
        .background(Color.atbCardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.radiusM)
                .strokeBorder(Color.atbSeparator.opacity(0.5), lineWidth: DesignTokens.strokeHairline)
        )
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radiusM))
        .overlay(alignment: .leading) {
            Rectangle().fill(Color.atbBrandKimi)
                .frame(width: DesignTokens.stripeWidth)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radiusM))
                .padding(.vertical, 1)
        }
    }

    private static func dateText(_ ms: Int64) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(ms) / 1000))
    }
}

struct KimiSubscriptionLegend: View {
    let color: Color
    let title: String
    let percent: Double

    var body: some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            Text("\(title)")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.atbTextSecondary)
            Text(String(format: "%.2f%%", percent))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.atbTextPrimary)
                .monospacedDigit()
        }
    }
}

// MARK: - 加油包余额行
struct KimiBoosterRow: View {
    let booster: KimiBooster
    var body: some View {
        HStack(spacing: DesignTokens.spacingS) {
            Image(systemName: "wallet.pass.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.orange)
            Text("加油包")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.atbTextPrimary)
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(String(format: "¥%.2f", booster.balanceYuan))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.atbTextPrimary)
                Text(String(format: "本月消费 ¥%.2f", booster.monthlyUsedYuan))
                    .font(.system(size: 9))
                    .foregroundStyle(Color.atbTextTertiary)
            }
        }
        .atbCard(paddingV: DesignTokens.spacingS)
    }
}

import SwiftUI
import AppKit
import AliyunTokenBarCore

// MARK: - Kimi Code 用量卡

/// Kimi Code 套餐用量(5h/周/月度总额 + 加油包)。
/// 与阿里云/OpenCode 共用 UsageCard——同一套设计 token(2 位小数/带刻度进度条)。
/// 仅在检测到本机 KimiCodeBar / Kimi CLI 凭证后显示。
struct KimiCodeCard: View {
    @StateObject private var model = TokenPlanModel.shared
    @State private var showKimiLogin = false
    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingM) {
            // 品牌头部行:青色闪电 + 刷新(Kimi 专属)
            HStack(spacing: DesignTokens.spacingS) {
                Image(systemName: "sparkles").font(.system(size: 13, weight: .bold)).foregroundStyle(.teal)
                Text("Kimi Code").font(.system(size: 13, weight: .medium)).foregroundStyle(.atbTextPrimary)
                if let level = model.kimiQuota?.membershipLevel {
                    Text(levelDisplay(level)).font(.system(size: 9, weight: .medium)).foregroundStyle(.teal)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.teal.opacity(0.12)).clipShape(RoundedRectangle(cornerRadius: DesignTokens.radiusS - 2))
                }
                Spacer()
                Button { Task { await model.refreshKimi() } } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 12)).foregroundStyle(.atbTextTertiary)
                }
                .buttonStyle(.plain)
                .help("刷新 Kimi 用量")
                .accessibilityLabel("刷新 Kimi 用量")
            }
            if let q = model.kimiQuota {
                // 三窗口各一张卡片,视觉 token 与阿里云 5h/7d 完全一致
                UsageCard(title: "5小时限额",
                          percentage: q.fiveHour.pct, resetText: q.fiveHour.slidingResetText,
                          color: .teal, isLoading: model.isLoading, thresholdConfig: model.thresholdConfig,
                          showSparkline: model.sparklineEnabled,
                          sparklineProvider: "kimi", sparklineWindow: "5h")
                UsageCard(title: "每周限额",
                          percentage: q.weekly.pct, resetText: q.weekly.resetTimeDisplay,
                          color: .indigo, isLoading: model.isLoading, thresholdConfig: model.thresholdConfig,
                          showSparkline: model.sparklineEnabled,
                          sparklineProvider: "kimi", sparklineWindow: "weekly")
                if let balance = q.subscriptionBalance {
                    KimiSubscriptionCard(balance: balance)
                } else if model.kimiWebLoggedIn {
                    UsageCard(title: "总使用量", percentage: nil, resetText: nil,
                              color: .orange, isLoading: false, thresholdConfig: model.thresholdConfig,
                              dataUnavailable: true)
                }
                if let booster = q.booster, booster.enabled {
                    KimiBoosterRow(booster: booster)
                }
                if !model.kimiWebLoggedIn {
                    kimiWebLoginHint
                }
            } else if let err = model.kimiError {
                // 网络/服务故障:卡片显示横杠(—),表示数值不可用
                let isNetworkError = err.contains("网络") || err.contains("响应") || err.contains("解析")
                if isNetworkError {
                    UsageCard(title: "5小时限额", percentage: nil, resetText: nil,
                              color: .teal, isLoading: false, thresholdConfig: model.thresholdConfig,
                              dataUnavailable: true)
                    UsageCard(title: "每周限额", percentage: nil, resetText: nil,
                              color: .indigo, isLoading: false, thresholdConfig: model.thresholdConfig,
                              dataUnavailable: true)
                    UsageCard(title: "月度总额度", percentage: nil, resetText: nil,
                              color: .orange, isLoading: false, thresholdConfig: model.thresholdConfig,
                              dataUnavailable: true)
                } else {
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

    /// 登录网页控制台引导行(未登录时显示,用于获取订阅总额度)。
    private var kimiWebLoginHint: some View {
        HStack(spacing: DesignTokens.spacingS) {
            Image(systemName: "lock.open").font(.system(size: 11)).foregroundStyle(.atbTextTertiary)
            Text("登录 Kimi 网页控制台查看订阅总额度").font(.system(size: 10)).foregroundStyle(.atbTextTertiary)
            Spacer()
            Button("登录") { showKimiLogin = true }
                .buttonStyle(ATBTextButtonStyle(color: .teal)).font(.system(size: 11, weight: .medium))
        }
        .padding(.horizontal, DesignTokens.spacingM).padding(.vertical, DesignTokens.spacingS)
        .background(Color.atbCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radiusM))
        .shadow(color: Color.black.opacity(0.04), radius: 2, y: 1)
        .sheet(isPresented: $showKimiLogin) { KimiLoginView() }
    }

    /// 会员等级映射:LEVEL_* → 官方名称(未知等级去前缀美化)。
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

/// Kimi 共享订阅池:Work/Kimi 与 Code 分段显示,总量只使用共享池分母。
struct KimiSubscriptionCard: View {
    let balance: KimiSubscriptionBalance

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingS + 1) {
            HStack {
                Text("总使用量")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.atbTextPrimary)
                Spacer()
                Text(String(format: "%.2f%%", balance.totalUsedPercent))
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.atbTextPrimary)
            }

            GeometryReader { proxy in
                HStack(spacing: 0) {
                    if let work = balance.workUsedPercent,
                       let code = balance.codeUsedPercent {
                        Rectangle()
                            .fill(Color.primary)
                            .frame(width: proxy.size.width * CGFloat(work / 100))
                        Rectangle()
                            .fill(Color.atbBlue)
                            .frame(width: proxy.size.width * CGFloat(code / 100))
                    } else {
                        Rectangle()
                            .fill(Color.atbBlue)
                            .frame(width: proxy.size.width * CGFloat(balance.totalUsedPercent / 100))
                    }
                    Rectangle()
                        .fill(Color.primary.opacity(0.10))
                }
                .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .frame(height: 8)

            HStack(spacing: 12) {
                if let work = balance.workUsedPercent,
                   let code = balance.codeUsedPercent {
                    KimiSubscriptionLegend(color: .primary, title: "Kimi/Work", percent: work)
                    KimiSubscriptionLegend(color: .atbBlue, title: "Code", percent: code)
                } else {
                    Text("Work/Code 分项暂不可用")
                        .font(.system(size: 10))
                        .foregroundStyle(.atbTextTertiary)
                }
                Spacer(minLength: 0)
            }

            if let ms = balance.expireTimeMs {
                Text("重置时间 \(Self.dateText(ms))")
                    .font(.system(size: 9))
                    .foregroundStyle(.atbTextTertiary)
            }
        }
        .padding(.horizontal, DesignTokens.spacingM)
        .padding(.vertical, DesignTokens.spacingS + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.atbCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radiusM))
        .shadow(color: Color.black.opacity(0.04), radius: 2, y: 1)
    }

    private static func dateText(_ ms: Int64) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(ms) / 1000))
    }
}

struct KimiSubscriptionLegend: View {
    let color: Color
    let title: String
    let percent: Double

    var body: some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 8, height: 8)
            Text("\(title) \(String(format: "%.2f%%", percent))")
                .font(.system(size: 10))
                .foregroundStyle(.atbTextSecondary)
                .monospacedDigit()
        }
    }
}

/// 加油包余额行:余额 + 本月消费/上限。
struct KimiBoosterRow: View {
    let booster: KimiBooster
    var body: some View {
        HStack(spacing: DesignTokens.spacingS) {
            Image(systemName: "wallet.pass.fill").font(.system(size: 12)).foregroundStyle(.orange)
            Text("加油包余额").font(.system(size: 11, weight: .medium)).foregroundStyle(.atbTextPrimary)
            Text(String(format: "¥%.2f", booster.balanceYuan))
                .font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(.atbTextPrimary)
            Spacer()
            Text(String(format: "本月消费 ¥%.2f", booster.monthlyUsedYuan))
                .font(.system(size: 10)).foregroundStyle(.atbTextTertiary)
        }
        .padding(.horizontal, DesignTokens.spacingM).padding(.vertical, DesignTokens.spacingS)
        .background(Color.atbCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radiusM))
        .shadow(color: Color.black.opacity(0.04), radius: 2, y: 1)
    }
}


import SwiftUI
import AppKit
import AliyunTokenBarCore

// MARK: - MiniMax Coding Plan 用量卡
//
// 视觉语言与 ZhipuCodeCard / KimiCodeCard 对称(品牌行 + 多窗口环卡)。
// 数据源 token_plan/remains:当前计费窗口(通常 5h 滚动)+ 周窗口(周额度为 0 时隐藏)。
// 附加信息行:套餐名 tag + 主模型 + 已用次数 + 积分余额。

struct MiniMaxCodeCard: View {
    @StateObject private var model = TokenPlanModel.shared
    @State private var draftKey = ""
    @State private var saveError: String?

    private var brand: Color { ProviderBrand.color(for: .minimax) }

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
            ATBProviderMark(tab: .minimax, size: 24)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text("MiniMax")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.atbTextPrimary)
                    if let plan = model.minimaxQuota?.planName {
                        Text(plan)
                            .font(.system(size: 9, weight: .semibold))
                            .lineLimit(1)
                            .foregroundStyle(brand)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(brand.opacity(0.14))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }
                Text("Coding Plan · 当前窗口 + 周")
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
            Task { await model.refreshMiniMax() }
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.atbTextTertiary)
                .frame(width: 22, height: 22)
                .background(Color.primary.opacity(0.06))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .help("刷新 MiniMax 用量")
        .accessibilityLabel("刷新 MiniMax 用量")
    }

    // MARK: 内容

    @ViewBuilder
    private var content: some View {
        if let q = model.minimaxQuota {
            VStack(spacing: DesignTokens.spacingM) {
                multiRingSection(q: q)
                detailRow(q: q)
            }
        } else if let err = model.minimaxError {
            let isNetwork = err.contains("网络") || err.contains("响应") || err.contains("解析")
            if isNetwork {
                VStack(spacing: DesignTokens.spacingS) {
                    dashCard("当前窗口")
                    dashCard("每周限额")
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

    private func multiRingSection(q: MiniMaxQuota) -> some View {
        var slots: [ATBMultiRingCard.Slot] = []
        if let interval = q.interval {
            slots.append(ATBMultiRingCard.Slot(
                id: "interval",
                title: "本窗",
                subtitle: interval.timeUntilReset ?? "—",
                percentage: interval.pct,
                bandColor: thresholdBrand(interval.pctInt, config: model.thresholdConfig, brand: brand),
                threshold: model.thresholdConfig))
        }
        if let weekly = q.weekly {
            slots.append(ATBMultiRingCard.Slot(
                id: "weekly",
                title: "本周",
                subtitle: weekly.timeUntilReset ?? "—",
                percentage: weekly.pct,
                bandColor: thresholdBrand(weekly.pctInt, config: model.thresholdConfig, brand: brand),
                threshold: model.thresholdConfig))
        }
        return ATBMultiRingCard(slots: slots)
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

    /// 明细行:专项模型次数(video 等)+ 主窗口次数 + 积分余额
    private func detailRow(q: MiniMaxQuota) -> some View {
        HStack(spacing: DesignTokens.spacingS) {
            Image(systemName: "number.square.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.atbTextTertiary)
            Text(detailText(q))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.atbTextSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .atbCard(paddingV: DesignTokens.spacingS - 2)
    }

    private func detailText(_ q: MiniMaxQuota) -> String {
        var parts: [String] = []
        // 主条目为 general(纯百分比)时名字不展示,避免噪音
        if let name = q.modelName, !name.isEmpty, name.lowercased() != "general" {
            parts.append(name)
        }
        if let usage = q.interval?.usageText { parts.append("本窗已用 \(usage)") }
        if let usage = q.weekly?.usageText { parts.append("周已用 \(usage)") }
        // 专项模型(video 等):日/周次数
        for m in q.models {
            var bits: [String] = []
            if let usage = m.interval?.usageText { bits.append(usage) }
            if let usage = m.weekly?.usageText { bits.append("周\(usage)") }
            if !bits.isEmpty { parts.append("\(m.name) \(bits.joined(separator: "/"))") }
        }
        if let points = q.pointsBalance {
            parts.append("积分 \(points == points.rounded() ? String(Int(points)) : String(format: "%.1f", points))")
        }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
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
        VStack(alignment: .leading, spacing: DesignTokens.spacingS) {
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
            // Key 失效可直接在面板重粘(设置页同款输入)
            HStack(spacing: DesignTokens.spacingS) {
                SecureField("API Key(eyJ…)", text: $draftKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                Button("保存并查询") { saveKey() }
                    .buttonStyle(ATBPrimaryButtonStyle())
                    .font(.system(size: 11, weight: .medium))
            }
            if let saveError {
                Text(saveError)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.atbCritical)
            }
        }
        .atbCard()
    }

    private func saveKey() {
        let trimmed = draftKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            saveError = "请输入 API Key"
            return
        }
        saveError = nil
        model.minimaxAPIKey = trimmed
        draftKey = ""
        Task { await model.refreshMiniMax() }
    }
}

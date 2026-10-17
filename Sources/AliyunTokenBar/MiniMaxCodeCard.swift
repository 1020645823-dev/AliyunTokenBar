import SwiftUI
import AppKit
import AliyunTokenBarCore

// MARK: - MiniMax Coding Plan 用量卡(多模型窗口 · 触顶预测)
//
// v1.0.66 视觉语言(StepFun v1.0.65 设计范式泛化 + MiniMax 特色):
// - 品牌行带套餐名徽章 + 数据更新时间;
// - 双环卡保留(当前计费窗口 / 本周);
// - 新增**触顶预测行**;
// - **多模型细条行**:MiniMax 的 model_remains[] 按模型给额度(general 之外还有
//   video 等专项,各自带 5h/日窗口与周窗口),旧版把所有模型挤成一行文字,
//   新版每个模型一条 3pt 细条(标签/百分比/次数一目了然);
// - 积分余额(按量付费赠送)单独信息行;Key 失效时错误卡内可直接重粘。

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
                        ATBBrandTag(text: plan, brand: brand)
                    }
                }
                ATBSubtitleText(text: subtitleText)
            }
            Spacer(minLength: DesignTokens.spacingS)
            ATBRefreshButton(action: { Task { await model.refreshMiniMax() } }, help: "刷新 MiniMax 用量")
        }
    }

    private var subtitleText: String {
        var base = "Coding Plan · 当前窗口 + 周"
        let t = ATBTimeFormat.updated(ATBTimeFormat.latestData(model))
        if !t.isEmpty { base += " · \(t) 更新" }
        return base
    }

    // MARK: 内容

    @ViewBuilder
    private var content: some View {
        if let q = model.minimaxQuota {
            VStack(spacing: DesignTokens.spacingM) {
                multiRingSection(q: q)
                forecastSection(q)
                modelRows(q)
                if let points = q.pointsBalance {
                    ATBInfoRow(icon: "star.circle.fill",
                               text: "积分余额 \(points == points.rounded() ? String(Int(points)) : String(format: "%.1f", points))",
                               tint: brand,
                               help: "按量付费赠送积分(points_balance)")
                }
            }
        } else if let err = model.minimaxError {
            if err.contains("网络") || err.contains("响应") || err.contains("解析") {
                VStack(spacing: DesignTokens.spacingS) {
                    ATBUnavailableRow(title: "当前窗口")
                    ATBUnavailableRow(title: "每周限额")
                }
            } else {
                errorHint(err)
            }
        } else {
            ATBLoadingCard()
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
            .atbStripeCard(brand: brand, paddingH: DesignTokens.spacingM, paddingV: DesignTokens.spacingS)
    }

    // MARK: 触顶预测(本窗 + 周)

    private struct ForecastItem: Identifiable {
        let id: String
        let icon: String
        let text: String
        let tint: Color
    }

    private func forecastItems(_ q: MiniMaxQuota) -> [ForecastItem] {
        var items: [ForecastItem] = []
        let windows: [(id: String, label: String, window: MiniMaxWindow?)] = [
            ("interval", "本窗", q.interval),
            ("weekly", "本周", q.weekly)
        ]
        for w in windows {
            guard let win = w.window, let ms = win.resetTimeMs else { continue }
            let samples = ATBHistory.pctSamples(model, provider: "minimax", window: w.id)
            guard let rate = UsageForecast.pctPerHour(samples: samples), rate > 0,
                  let last = samples.last else { continue }
            let hoursToReset = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
                .timeIntervalSinceNow / 3600
            guard hoursToReset > 0 else { continue }
            let projected = min(100, last.pct + rate * hoursToReset)
            if projected >= 99.5 {
                let minsLeft = UsageForecast.minutesToLimit(samples: samples) ?? 0
                items.append(ForecastItem(
                    id: w.id,
                    icon: "exclamationmark.triangle.fill",
                    text: "\(w.label) · 按当前速度约 \(UsageForecast.durationText(minutes: minsLeft)) 后触顶",
                    tint: Color(red: 0.95, green: 0.55, blue: 0.10)))
            } else {
                items.append(ForecastItem(
                    id: w.id,
                    icon: "chart.line.uptrend.xyaxis",
                    text: "\(w.label) · 预计重置时用到 \(Int(projected.rounded()))%",
                    tint: Color.atbTextTertiary))
            }
        }
        return items
    }

    @ViewBuilder
    private func forecastSection(_ q: MiniMaxQuota) -> some View {
        let items = forecastItems(q)
        if items.isEmpty {
            ATBForecastRow(text: "趋势积累中(约 6 小时数据后给出触顶预测)",
                           help: "按历史用量速率线性外推;至少需要 6 小时跨度的两个有效采样点。")
        } else {
            VStack(spacing: 4) {
                ForEach(items) { item in
                    ATBForecastRow(icon: item.icon, text: item.text, tint: item.tint)
                }
            }
        }
    }

    /// 多模型细条行(video 等专项额度):每模型一条 3pt 条 + 本窗百分比 + 次数。
    /// 主条目(general 纯百分比)不进列表——名字是噪音,主环卡已覆盖。
    @ViewBuilder
    private func modelRows(_ q: MiniMaxQuota) -> some View {
        let models = q.models.filter {
            !($0.name.lowercased() == "general" || $0.name.isEmpty)
        }
        if !models.isEmpty {
            VStack(spacing: 4) {
                ForEach(models, id: \.name) { m in
                    modelRow(m)
                }
            }
        }
    }

    private func modelRow(_ m: MiniMaxModelQuota) -> some View {
        let win = m.interval ?? m.weekly
        let pct = win?.pctInt ?? 0
        let band = thresholdBrand(pct, config: model.thresholdConfig, brand: brand)
        return ATBThinMeterRow(
            label: m.name,
            pct: pct,
            color: band,
            valueText: win?.usageText,
            trailing: (m.interval ?? m.weekly).flatMap { ATBResetText.compact(fromMs: $0.resetTimeMs) },
            help: "\(m.name) 专项额度(interval=当前计费窗口,weekly=周窗口)")
    }

    // MARK: Key 失效重粘(错误态专用)

    private func errorHint(_ err: String) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingS) {
            ATBErrorHintCard(message: err)
            HStack(spacing: DesignTokens.spacingS) {
                SecureField("API Key(eyJ…)", text: $draftKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                Button("保存并查询") { saveKey() }
                    .buttonStyle(ATBPrimaryButtonStyle())
                    .font(.system(size: 11, weight: .medium))
            }
            if let saveError {
                Text(saveError).font(.system(size: 10)).foregroundStyle(.atbCritical)
            }
        }
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

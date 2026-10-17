import SwiftUI
import AppKit
import AliyunTokenBarCore

// MARK: - Ollama Cloud 用量卡(近 30 天消费 · 月额度占比 · 触顶预测)
//
// v1.0.66 视觉语言(StepFun v1.0.65 设计范式泛化 + Ollama 特色):
// - 品牌行带套餐徽章(Free/Pro/Max/Team,来自远程 /api/me,daemon 未装也能拿)+ 更新时间;
// - **环组按档位可得性出 slot**:有月度额度(档位已知)→ 占比环;
//   档位探测失败 → 绝对金额 hero(参考 MiMo 余额卡),不编造百分比;
// - 新增**触顶预测行**:接口不返回重置时间(按订阅周年日清零),故预测用
//   "速率外推到 100%"而不是"重置时用到"——回答"照这个速度会不会用完";
// - 近 7 天消费 + 近 30 天请求数收敛为两条信息行(2026-10-09 新接口只给
//   按天美元报表,不再有每模型请求数)。

struct OllamaCard: View {
    @StateObject private var model = TokenPlanModel.shared
    @State private var draftKey = ""
    @State private var saveError: String?

    private let apiKeysURL = URL(string: "https://ollama.com/settings/keys")!
    private var brand: Color { ProviderBrand.color(for: .ollama) }

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
            ATBProviderMark(tab: .ollama, size: 24)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text("Ollama Cloud")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.atbTextPrimary)
                    if let plan = model.ollamaQuota?.planDisplay {
                        ATBBrandTag(text: plan, brand: brand)
                    }
                }
                ATBSubtitleText(text: subtitleText)
            }
            Spacer(minLength: DesignTokens.spacingS)
            if model.ollamaConfigured {
                ATBRefreshButton(action: { Task { await model.refreshOllama() } },
                                 help: "刷新 Ollama Cloud 用量")
            }
        }
    }

    /// 副标题随档位可得性变化(占月额度比例 / 仅绝对消费 / 尚未拉到数据)。
    private var subtitleText: String {
        var base: String
        if let q = model.ollamaQuota {
            base = q.capUSD != nil ? "使用额度 · 近 30 天 vs 月额度"
                                    : "使用额度 · 近 30 天消费"
        } else {
            base = "使用额度 · 近 30 天消费"
        }
        let t = ATBTimeFormat.updated(ATBTimeFormat.latestData(model))
        if !t.isEmpty { base += " · \(t) 更新" }
        return base
    }

    // MARK: 内容

    @ViewBuilder
    private var content: some View {
        if !model.ollamaConfigured {
            setupCard
        } else if let q = model.ollamaQuota {
            VStack(spacing: DesignTokens.spacingM) {
                usageSection(q: q)
                forecastSection(q)
                spendRows(q)
            }
        } else if let err = model.ollamaError {
            let isNetwork = err.contains("网络") || err.contains("响应") || err.contains("解析") || err.contains("限流")
            if isNetwork {
                ATBUnavailableRow(title: "近 30 天额度")
            } else {
                ATBErrorHintCard(message: err)
            }
        } else {
            ATBLoadingCard()
        }
    }

    // MARK: 主展示:占比环(档位已知)/ 金额 hero(档位未知)

    @ViewBuilder
    private func usageSection(q: OllamaQuota) -> some View {
        if let w = q.monthly {
            ringSection(q: q, window: w)
        } else {
            spendHeroCard(q)
        }
    }

    /// 占比环:近 30 天消费 ÷ 套餐月度额度(滚动窗口口径,非计费周期)。
    private func ringSection(q: OllamaQuota, window: OllamaWindow) -> some View {
        let slot = ATBMultiRingCard.Slot(
            id: "monthly", title: "近30天",
            subtitle: "占月额度 \(OllamaMoney.full(q.capUSD ?? 0))",
            percentage: window.pct,
            bandColor: thresholdBrand(window.pctInt, config: model.thresholdConfig, brand: brand),
            threshold: model.thresholdConfig)
        return ATBMultiRingCard(slots: [slot])
            .atbStripeCard(brand: brand, paddingH: DesignTokens.spacingM, paddingV: DesignTokens.spacingS)
    }

    /// 金额 hero:档位探测失败(无额度可除)时展示绝对消费,不编百分比。
    private func spendHeroCard(_ q: OllamaQuota) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingS - 2) {
            HStack(alignment: .firstTextBaseline) {
                Text("近 30 天消费")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.atbTextSecondary)
                    .textCase(.uppercase)
                    .tracking(0.4)
                Spacer()
                Text(OllamaMoney.full(q.spentUSD30d))
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.atbTextPrimary)
                    .atbHeroGlow(brand)
            }
            Text("套餐档位探测失败,暂无法计算占月度额度比例")
                .font(.system(size: 10))
                .foregroundStyle(Color.atbTextTertiary)
        }
        .atbStripeCard(brand: brand, paddingH: DesignTokens.spacingM + 2, paddingV: DesignTokens.spacingS + 2, hero: true)
    }

    // MARK: 触顶预测(无重置时间,按速率外推到 100%)

    private struct ForecastItem: Identifiable {
        let id: String
        let icon: String
        let text: String
        let tint: Color
    }

    private func forecastItems(_ q: OllamaQuota) -> [ForecastItem] {
        var items: [ForecastItem] = []
        guard q.monthly != nil else { return items }
        let samples = ATBHistory.pctSamples(model, provider: "ollama", window: "monthly")
        guard let rate = UsageForecast.pctPerDay(samples: samples), rate > 0 else { return items }
        guard let mins = UsageForecast.minutesToLimit(samples: samples) else { return items }
        // 30 天内才会用完才值得警告;远期(如 60 天后)用平静样式,避免狼来了
        let urgent = mins <= 30 * 24 * 60
        let text = "月额度 · 日均 +\(String(format: "%.1f", rate))%,"
            + "按当前速度约 \(UsageForecast.durationText(minutes: mins)) 后用完"
        items.append(ForecastItem(
            id: "monthly",
            icon: urgent ? "exclamationmark.triangle.fill" : "chart.line.uptrend.xyaxis",
            text: text,
            tint: urgent ? Color(red: 0.95, green: 0.55, blue: 0.10) : Color.atbTextTertiary))
        return items
    }

    @ViewBuilder
    private func forecastSection(_ q: OllamaQuota) -> some View {
        let items = forecastItems(q)
        if items.isEmpty {
            ATBForecastRow(text: "趋势积累中(约 6 小时数据后给出用完预测)",
                           help: "接口不返回重置时间;预测按历史速率线性外推到 100%。")
        } else {
            VStack(spacing: 4) {
                ForEach(items) { item in
                    ATBForecastRow(icon: item.icon, text: item.text, tint: item.tint)
                }
            }
        }
    }

    // MARK: 消费明细行(新接口只给按天美元报表)

    @ViewBuilder
    private func spendRows(_ q: OllamaQuota) -> some View {
        ATBInfoRow(icon: "creditcard.fill",
                   text: "近 7 天消费 \(OllamaMoney.full(q.spentUSD7d)) · 日均 \(OllamaMoney.full(q.dailyAvgUSD))",
                   tint: Color.atbTextTertiary,
                   help: "日桶尾部 7 天汇总(含今日部分);日均按近 30 天 ÷ 30")
        ATBInfoRow(icon: "arrow.up.arrow.down",
                   text: "近 30 天 \(q.requests30d) 次请求",
                   tint: brand,
                   help: "totals.request_count:近 30 天请求总数")
    }

    // MARK: 未配置引导卡(与 DeepSeekCard.setupCard 同范式:创建 Key 入口 + 内联粘贴)

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingS) {
            HStack(spacing: DesignTokens.spacingS) {
                Image(systemName: "key.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(brand)
                Text("未配置 API Key")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.atbTextPrimary)
                Spacer()
                ATBBrandActionButton(title: "创建 Key", symbol: "arrow.up.right.square", brand: brand,
                                     action: { NSWorkspace.shared.open(apiKeysURL) },
                                     help: "打开 ollama.com 的 API Keys 页面")
            }
            Text("填入 Ollama API Key 后,将显示近 30 天消费(美元)、占套餐月度额度比例,以及近 7 天消费与请求数。")
                .font(.system(size: 10))
                .foregroundStyle(Color.atbTextSecondary)
            HStack(spacing: DesignTokens.spacingS) {
                SecureField("API Key", text: $draftKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                Button("保存并查询") { saveKey() }
                    .buttonStyle(ATBPrimaryButtonStyle())
                    .font(.system(size: 11, weight: .medium))
            }
            if let saveError {
                Text(saveError).font(.system(size: 10)).foregroundStyle(.atbCritical)
            }
            Text("Key 仅保存在系统钥匙串,本机其他应用不可读;随时可在设置 → 服务中移除。")
                .font(.system(size: 9))
                .foregroundStyle(Color.atbTextTertiary)
        }
        .atbCard()
    }

    private func saveKey() {
        let k = draftKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else {
            saveError = "请输入 API Key"
            return
        }
        saveError = nil
        model.ollamaAPIKey = k
        draftKey = ""
        Task { await model.refreshOllama() }
    }
}

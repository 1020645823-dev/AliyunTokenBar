import SwiftUI
import AppKit
import AliyunTokenBarCore

// MARK: - 智谱 GLM Coding Plan 用量卡(多账户 · 触顶预测)
//
// v1.0.66 视觉语言 + v1.0.67 多账户(2026-10-04):
// - 每个智谱账户 = 一把独立 API Key(按 id 分槽存 Keychain;首账户 "main"
//   复用旧槽 + opencode 配置自动发现,零迁移);
// - 聚合口径(聚合纯函数 ZhipuQuota.aggregate):5h/周窗口**取 max**(最险的
//   账户决定会不会被限流),MCP 月度按次**求和**(各账户独立计数);
// - 面板多账户呈现(v1.0.122 起分账户,2026-10-25 用户需求:取 max 的"全局 5h%"
//   其实只是最险一个账户的数,有误解):**每账户一块独立仪表**(头行 + 各自
//   5h/周/MCP 三环 + 各自 MCP 明细行);聚合值仅菜单栏/历史/摘要继续使用;
// - 添加账户:卡内内联表单(粘 Key 即查,无需去设置页)。

struct ZhipuCodeCard: View {
    @StateObject private var model = TokenPlanModel.shared
    @State private var addingAccount = false
    @State private var renamingID: String?
    @State private var draftKey = ""
    @State private var draftLabel = ""
    @State private var saveError: String?

    private var brand: Color { ProviderBrand.color(for: .zhipu) }

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
                    // 多账户时聚合 level 只是首个非空值(会张冠李戴),
                    // 真实档位在每账户块头行的徽章里;单账户才在品牌行露出
                    if model.zhipuAccounts.count <= 1, let level = model.zhipuQuota?.level {
                        ATBBrandTag(text: levelDisplay(level), brand: brand)
                    }
                    if model.zhipuAccounts.count > 1 {
                        ATBBrandTag(text: "\(model.zhipuAccounts.count) 账户", brand: brand)
                    }
                }
                ATBSubtitleText(text: subtitleText)
            }
            Spacer(minLength: DesignTokens.spacingS)
            if model.zhipuConfigured {
                ATBBrandActionButton(title: "添加账户", symbol: "plus", brand: brand,
                                     action: { addingAccount = true },
                                     help: "添加另一个智谱账户(独立 API Key)")
                ATBRefreshButton(action: { Task { await model.refreshZhipu(force: true) } },
                                 help: "刷新智谱 GLM 用量")
            }
        }
    }

    private var subtitleText: String {
        var base = "Coding Plan · 5小时 + 周 + MCP"
        let t = ATBTimeFormat.updated(model.zhipuLastUpdated ?? ATBTimeFormat.latestData(model))
        if !t.isEmpty { base += " · \(t) 更新" }
        if model.zhipuAccounts.count > 1 {
            base += " · 分账户统计"
        } else if let hint = model.zhipuAccountHint("main") {
            base += " · Key \(hint)"
        }
        return base
    }

    // MARK: 内容

    @ViewBuilder
    private var content: some View {
        if model.zhipuAccounts.isEmpty {
            // 有 Key(手动/自动发现)但无账户:用户移除过全部 → 直接给添加表单
            addAccountForm
        } else if model.zhipuAccounts.count > 1 {
            // 多账户:每账户一块独立仪表,聚合不上面板(取 max 有误解)
            VStack(spacing: DesignTokens.spacingM) {
                ForEach(model.zhipuAccounts) { account in
                    accountDashboard(account)
                }
                if model.zhipuError != nil {
                    accountErrorSummary
                }
            }
        } else if let q = model.zhipuQuota {
            VStack(spacing: DesignTokens.spacingM) {
                ringCard(q)
                forecastSection(q)
                if let mcp = q.mcp, !mcp.details.isEmpty {
                    mcpDetailRow(mcp, accountLabel: nil)
                }
                if model.zhipuError != nil {
                    accountErrorSummary
                }
            }
        } else if let err = model.zhipuError {
            if err.contains("网络") || err.contains("响应") || err.contains("解析") {
                VStack(spacing: DesignTokens.spacingS) {
                    ATBUnavailableRow(title: "5小时限额")
                    ATBUnavailableRow(title: "每周限额")
                    ATBUnavailableRow(title: "MCP 月度")
                }
            } else {
                ATBErrorHintCard(message: err)
            }
        } else {
            ATBLoadingCard()
        }
        if addingAccount {
            addAccountForm
        }
    }

    /// 三环卡(单账户/每账户块共用):5h / 本周 / MCP 月度。
    private func ringCard(_ q: ZhipuQuota) -> some View {
        ATBMultiRingCard(slots: [
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
        .atbStripeCard(brand: brand, paddingH: DesignTokens.spacingM, paddingV: DesignTokens.spacingS)
    }

    // MARK: 触顶预测(5h/周;MCP 按次配额无历史采样,不出预测)

    private struct ForecastItem: Identifiable {
        let id: String
        let icon: String
        let text: String
        let tint: Color
    }

    private func forecastItems(_ q: ZhipuQuota) -> [ForecastItem] {
        var items: [ForecastItem] = []
        let windows: [(id: String, label: String, window: ZhipuWindow?)] = [
            ("5h", "5h 窗口", q.fiveHour),
            ("weekly", "本周额度", q.weekly)
        ]
        for w in windows {
            guard let win = w.window, let ms = win.resetTimeMs else { continue }
            let samples = ATBHistory.pctSamples(model, provider: "zhipu", window: w.id)
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
    private func forecastSection(_ q: ZhipuQuota) -> some View {
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

    /// MCP 明细行:各通道本月已用次数(search-prime 2 · zread 3 …)。
    /// accountLabel 非 nil = 多账户分账户块内(按次是各账户独立计数,不再合计)。
    private func mcpDetailRow(_ mcp: ZhipuMCPQuota, accountLabel: String?) -> some View {
        let detail = mcp.details
            .filter { $0.usage > 0 }
            .sorted { $0.usage > $1.usage }
            .map { "\($0.modelCode) \($0.usage)" }
            .joined(separator: " · ")
        let text = detail.isEmpty ? "本月暂无 MCP 调用" : detail
        let who = accountLabel.map { "\($0) 的" } ?? ""
        return ATBInfoRow(icon: "wrench.and.screwdriver.fill", text: text, tint: brand,
                          help: "\(who)MCP 通道(search-prime / web-reader / zread)本月已用次数")
    }

    // MARK: 每账户仪表块(多账户拆分:三环/MCP 都是该账户自己的;
    // 头行右键重命名/移除;错误账户保留内联移除)

    /// 单账户仪表块。快照缺失时按错误行/等待行兜底,块不消失。
    @ViewBuilder
    private func accountDashboard(_ account: ZhipuAccount) -> some View {
        let snap = model.zhipuAccountQuotas.first(where: { $0.id == account.id })
        VStack(spacing: DesignTokens.spacingS) {
            if renamingID == account.id {
                ATBRenameField(initial: account.label,
                               onSave: { newLabel in
                                   model.renameZhipuAccount(id: account.id, label: newLabel)
                                   renamingID = nil
                               },
                               onCancel: { renamingID = nil })
                    .atbCard(paddingV: DesignTokens.spacingS - 2)
            } else {
                ATBAccountDashHeader(label: account.label, brand: brand,
                                     tag: snap?.quota.level.map(levelDisplay),
                                     hint: model.zhipuAccountHint(account.id))
                    .contextMenu {
                        ATBAccountMenu.items(rename: { renamingID = account.id },
                                             remove: { model.removeZhipuAccount(id: account.id) })
                    }
            }
            if let snap {
                ringCard(snap.quota)
                if let mcp = snap.quota.mcp, !mcp.details.isEmpty {
                    mcpDetailRow(mcp, accountLabel: account.label)
                }
            } else if let err = model.zhipuAccountErrors[account.id] {
                HStack(spacing: DesignTokens.spacingS) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.orange)
                    Text(err)
                        .font(.system(size: 9))
                        .foregroundStyle(Color.atbTextSecondary)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    Button("移除") { model.removeZhipuAccount(id: account.id) }
                        .buttonStyle(ATBTextButtonStyle(color: .atbCritical))
                        .font(.system(size: 9))
                }
                .atbCard(paddingV: DesignTokens.spacingS - 2)
            } else {
                ATBUnavailableRow(title: "三窗口用量")
            }
        }
    }

    /// 全局错误摘要(逐账户错误已在内联行展示时,给一条汇总)。
    private var accountErrorSummary: some View {
        HStack(spacing: DesignTokens.spacingS) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.orange)
            Text(model.zhipuError ?? "")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.orange)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
    }

    // MARK: 内联添加账户表单

    private var addAccountForm: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingS - 2) {
            HStack(spacing: DesignTokens.spacingS) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(brand)
                Text("添加智谱账户")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.atbTextPrimary)
                Spacer()
                Button("取消") { addingAccount = false; saveError = nil }
                    .buttonStyle(ATBTextButtonStyle(color: .atbTextSecondary))
                    .font(.system(size: 9))
            }
            TextField("账户名(如 账户\(model.zhipuAccounts.count + 1))", text: $draftLabel)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
            HStack(spacing: DesignTokens.spacingS) {
                SecureField("API Key", text: $draftKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                Button("保存并查询") { saveAccount() }
                    .buttonStyle(ATBPrimaryButtonStyle())
                    .font(.system(size: 11, weight: .medium))
            }
            if let saveError {
                Text(saveError).font(.system(size: 10)).foregroundStyle(.atbCritical)
            }
            Text("各账户独立统计,面板分账户显示;菜单栏取最险账户。")
                .font(.system(size: 9))
                .foregroundStyle(Color.atbTextTertiary)
        }
        .atbCard(corner: DesignTokens.radiusL)
    }

    private func saveAccount() {
        let key = draftKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            saveError = "请输入 API Key"
            return
        }
        saveError = nil
        let label = draftLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        model.addZhipuAccount(label: label.isEmpty ? model.zhipuNextAccountLabel : label, apiKey: key)
        draftKey = ""
        draftLabel = ""
        addingAccount = false
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

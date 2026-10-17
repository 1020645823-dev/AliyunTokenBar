import SwiftUI
import AppKit
import AliyunTokenBarCore

// MARK: - Kimi Code 用量卡(多账户 · 共享池订阅 · 触顶预测)
//
// v1.0.66 视觉语言 + v1.0.67 多账户(2026-10-04):
// - 每个 Kimi 账户 = 一次 www.kimi.com 网页控制台登录(web JWT 按 id 分槽;
//   首账户 "main" 复用旧槽 + 本机 KimiCodeBar/Kimi CLI 凭证,零迁移);
// - 合计口径(KimiQuota.aggregate):5h/周/月计数窗口**求和**(每个订阅是独立池),
//   订阅共享池比率**取 max**(最紧的账户),加油包金额求和;
// - 面板:合计三环 + token 绝对量行 + 每账户细条行(失败账户内联重登/移除);
// - 添加账户:卡内「添加账户」→ 窗内登录新账户(登录即登记,自动并入合计)。

struct KimiCodeCard: View {
    @StateObject private var model = TokenPlanModel.shared
    @State private var showKimiLogin = false
    @State private var renamingID: String?
    @State private var loginAccountID: String = "main"
    @State private var loginAccountLabel: String?

    private var brand: Color { ProviderBrand.color(for: .kimi) }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingM) {
            providerHeader
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $showKimiLogin) {
            KimiLoginView(accountID: loginAccountID, newAccountLabel: loginAccountLabel)
        }
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
                        ATBBrandTag(text: levelDisplay(level), brand: brand)
                    }
                    if model.kimiAccounts.count > 1 {
                        ATBBrandTag(text: "\(model.kimiAccounts.count) 账户", brand: brand)
                    }
                }
                ATBSubtitleText(text: subtitleText)
            }
            Spacer(minLength: DesignTokens.spacingS)
            if model.kimiConfigured {
                ATBBrandActionButton(title: "添加账户", symbol: "plus", brand: brand,
                                     action: presentAddAccount,
                                     help: "登录另一个 Kimi 账户(独立网页登录态)")
                ATBRefreshButton(action: { Task { await model.refreshKimi(force: true) } },
                                 help: "刷新 Kimi 用量")
            }
        }
    }

    private var subtitleText: String {
        let t = ATBTimeFormat.updated(model.kimiLastUpdated ?? ATBTimeFormat.latestData(model))
        let time = t.isEmpty ? "" : " · \(t) 更新"
        // 单账户时把身份尾缀放进副标题(太长会被截断,故省去"三窗口共用")
        if model.kimiAccounts.count > 1 {
            return "Moonshot · 三窗口共用\(time) · 合计"
        }
        if let hint = model.kimiAccountHint("main") {
            return "Moonshot\(time) · \(hint)"
        }
        return "Moonshot · 三窗口共用\(time)"
    }

    private func presentAddAccount() {
        loginAccountID = UUID().uuidString
        loginAccountLabel = model.kimiNextAccountLabel
        showKimiLogin = true
    }

    private func presentRelogin(accountID: String) {
        loginAccountID = accountID
        loginAccountLabel = nil
        showKimiLogin = true
    }

    // MARK: 内容

    @ViewBuilder
    private var content: some View {
        if model.kimiAccounts.isEmpty {
            // 有本机凭证但无账户:用户移除过全部 → 给登录引导(登录即登记)
            HStack(spacing: DesignTokens.spacingS) {
                Image(systemName: "lock.open")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.atbTextTertiary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("登录 Kimi 账户开始统计")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.atbTextPrimary)
                    Text("每个账户一次网页登录;多账户自动合计")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.atbTextTertiary)
                }
                Spacer()
                Button("登录") { presentRelogin(accountID: "main") }
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(brand)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(brand.opacity(0.14))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .buttonStyle(.plain)
            }
            .atbCard()
        } else if let q = model.kimiQuota {
            VStack(spacing: DesignTokens.spacingM) {
                multiRingSection(q: q)
                tokenCountRow(q)
                forecastSection(q)
                if model.kimiAccounts.count > 1 {
                    accountList
                }
                if let balance = q.subscriptionBalance {
                    KimiSubscriptionCard(balance: balance)
                } else if model.kimiWebLoggedIn {
                    ATBUnavailableRow(title: "订阅总额度")
                }
                if let booster = q.booster, booster.enabled {
                    KimiBoosterRow(booster: booster)
                }
                if !model.kimiWebLoggedIn {
                    kimiWebLoginHint
                }
            }
        } else if let err = model.kimiError {
            if err.contains("网络") || err.contains("响应") || err.contains("解析") {
                VStack(spacing: DesignTokens.spacingS) {
                    ATBUnavailableRow(title: "5小时限额")
                    ATBUnavailableRow(title: "每周限额")
                    ATBUnavailableRow(title: "月度总额度")
                }
            } else {
                ATBErrorHintCard(message: err)
            }
        } else {
            ATBLoadingCard()
        }
    }

    private func multiRingSection(q: KimiQuota) -> some View {
        ATBMultiRingCard(slots: [
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
        .atbStripeCard(brand: brand, paddingH: DesignTokens.spacingM, paddingV: DesignTokens.spacingS)
    }

    /// token 绝对量行(Kimi 独有:接口给 used/limit 计数,百分比看不出池子大小)。
    private func tokenCountRow(_ q: KimiQuota) -> some View {
        var parts: [String] = []
        parts.append("5h \(Self.tokenText(q.fiveHour.used))/\(Self.tokenText(q.fiveHour.limit))")
        parts.append("周 \(Self.tokenText(q.weekly.used))/\(Self.tokenText(q.weekly.limit))")
        if let m = q.monthly {
            parts.append("月 \(Self.tokenText(m.used))/\(Self.tokenText(m.limit))")
        }
        return ATBInfoRow(icon: "number.circle.fill", text: parts.joined(separator: " · ") + " tokens",
                          tint: brand,
                          help: "官方接口返回的已用/限额 token 计数(5h 为滚动窗口)")
    }

    // MARK: 触顶预测(每窗口一行)

    private struct ForecastItem: Identifiable {
        let id: String
        let icon: String
        let text: String
        let tint: Color
    }

    private func forecastItems(_ q: KimiQuota) -> [ForecastItem] {
        var items: [ForecastItem] = []
        let windows: [(id: String, label: String, window: KimiWindow)] = [
            ("5h", "5h 窗口", q.fiveHour),
            ("weekly", "本周额度", q.weekly),
            ("monthly", "本月额度", q.monthly ?? KimiWindow(used: 0, limit: 0, resetTimeMs: nil))
        ]
        for w in windows where w.window.limit > 0 {
            let samples = ATBHistory.pctSamples(model, provider: "kimi", window: w.id)
            guard let rate = UsageForecast.pctPerHour(samples: samples), rate > 0,
                  let last = samples.last else { continue }
            let hoursToReset: Double
            if let ms = w.window.resetTimeMs {
                hoursToReset = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
                    .timeIntervalSinceNow / 3600
            } else {
                hoursToReset = 0
            }
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
    private func forecastSection(_ q: KimiQuota) -> some View {
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

    // MARK: 多账户行(5h 为主指标 + 周副标 + 3pt 条;右键重命名/重新登录/移除)

    private var accountList: some View {
        VStack(spacing: 4) {
            ForEach(model.kimiAccounts) { account in
                accountRow(account)
            }
        }
    }

    @ViewBuilder
    private func accountRow(_ account: KimiAccount) -> some View {
        if renamingID == account.id {
            ATBRenameField(initial: account.label,
                           onSave: { newLabel in
                               model.renameKimiAccount(id: account.id, label: newLabel)
                               renamingID = nil
                           },
                           onCancel: { renamingID = nil })
                .atbCard(paddingV: DesignTokens.spacingS - 2)
        } else {
            accountRowContent(account)
                .contextMenu {
                    ATBAccountMenu.items(rename: { renamingID = account.id },
                                         remove: { model.removeKimiAccount(id: account.id) },
                                         relogin: { presentRelogin(accountID: account.id) })
                }
        }
    }

    @ViewBuilder
    private func accountRowContent(_ account: KimiAccount) -> some View {
        let hint = model.kimiAccountHint(account.id)
        if let snap = model.kimiAccountQuotas.first(where: { $0.id == account.id }) {
            let pct = snap.quota.fiveHour.pctInt
            let band = thresholdBrand(pct, config: model.thresholdConfig, brand: brand)
            ATBThinMeterRow(
                label: account.label,
                pct: pct,
                color: band,
                hint: hint,
                valueText: "周 \(snap.quota.weekly.pctInt)%",
                trailing: ATBResetText.compact(fromMs: snap.quota.fiveHour.resetTimeMs),
                help: "\(account.label)\(hint.map { " \($0)" } ?? ""):5h \(pct)% · 周 \(snap.quota.weekly.pctInt)%"
                    + (snap.quota.monthly.map { " · 月 \($0.pctInt)%" } ?? " · 月 无"))
        } else if let err = model.kimiAccountErrors[account.id] {
            HStack(spacing: DesignTokens.spacingS) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.orange)
                Text("\(account.label):\(err)")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.atbTextSecondary)
                Spacer(minLength: 0)
                Button("重新登录") { presentRelogin(accountID: account.id) }
                    .buttonStyle(ATBTextButtonStyle(color: brand))
                    .font(.system(size: 9))
                Button("移除") { model.removeKimiAccount(id: account.id) }
                    .buttonStyle(ATBTextButtonStyle(color: .atbCritical))
                    .font(.system(size: 9))
            }
            .atbCard(paddingV: DesignTokens.spacingS - 2)
        } else {
            ATBThinMeterRow(label: account.label, pct: 0, color: Color.atbTextTertiary,
                            hint: hint, valueText: nil, trailing: "等待刷新…",
                            help: "\(account.label):等待刷新")
        }
    }

    /// 登录网页控制台引导行(main 账户未登录网页时显示;附加账户本身就是网页登录)
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
            Button("登录") { presentRelogin(accountID: "main") }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(brand)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(brand.opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .buttonStyle(.plain)
        }
        .atbCard()
    }

    private func relativeReset(_ w: KimiWindow) -> String? {
        w.resetTimeMs != nil ? w.timeUntilReset : nil
    }

    /// token 计数紧凑格式:"12.5M" / "980K" / "1200"。
    static func tokenText(_ v: Int) -> String {
        if v >= 1_000_000 { return String(format: "%.1fM", Double(v) / 1_000_000) }
        if v >= 1_000 { return String(format: "%.0fK", Double(v) / 1_000) }
        return "\(v)"
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
    private var brand: Color { ProviderBrand.color(for: .kimi) }

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
        .atbStripeCard(brand: brand, paddingH: DesignTokens.spacingM, paddingV: DesignTokens.spacingS)
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
    private var brand: Color { ProviderBrand.color(for: .kimi) }

    var body: some View {
        HStack(spacing: DesignTokens.spacingS) {
            Image(systemName: "wallet.pass.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(brand)
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

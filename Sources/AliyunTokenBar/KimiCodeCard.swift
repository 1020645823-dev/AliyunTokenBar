import SwiftUI
import AppKit
import AliyunTokenBarCore

// MARK: - Kimi Code 用量卡(多账户 · 共享池订阅 · 触顶预测)
//
// v1.0.66 视觉语言 + v1.0.67 多账户(2026-10-04):
// - 每个 Kimi 账户 = 一次 www.kimi.com 网页控制台登录(web JWT 按 id 分槽;
//   首账户 "main" 复用旧槽 + 本机 KimiCodeBar/Kimi CLI 凭证,零迁移);
// - 聚合口径(KimiQuota.aggregate):5h/周/月计数窗口**求和**(每个订阅是独立池),
//   订阅共享池比率**取 max**(最紧的账户),加油包金额求和;
// - 面板多账户呈现(v1.0.122 起分账户,2026-10-25 用户需求:汇总分母不存在于
//   任何真实账户,有误解):**每账户一块独立仪表**(头行 + 各自三环 + 计数行
//   + 订阅池/加油包紧凑行),不再显示聚合三环/聚合计数/聚合订阅池大卡;
//   聚合值仅菜单栏/历史/摘要继续使用;
// - 触顶预测基于聚合历史序列,多账户下会稀释(单账户烧满也看不出来),不出行;
// - 添加账户:卡内「添加账户」→ 窗内登录新账户(登录即登记)。

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
        if model.kimiAccounts.count > 1 {
            return "Moonshot · 分账户统计\(time)"
        }
        // 单账户时把身份尾缀放进副标题(太长会被截断,故省去"三窗口共用")
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
        } else if model.kimiAccounts.count > 1 {
            // 多账户:每账户一块独立仪表,聚合不上面板(汇总有误解)
            VStack(spacing: DesignTokens.spacingM) {
                ForEach(model.kimiAccounts) { account in
                    accountDashboard(account)
                }
                if !model.kimiWebLoggedIn {
                    kimiWebLoginHint
                }
            }
        } else if let q = model.kimiQuota {
            VStack(spacing: DesignTokens.spacingM) {
                ringCard(q)
                tokenCountRow(q)
                forecastSection(q)
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

    /// 三环卡(单账户/每账户块共用):5h / 本周 / 本月;该窗口无数据(如月度)则整环隐藏。
    private func ringCard(_ q: KimiQuota) -> some View {
        var slots: [ATBMultiRingCard.Slot] = [
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
                                  threshold: model.thresholdConfig)
        ]
        if let m = q.monthly {
            slots.append(ATBMultiRingCard.Slot(id: "monthly",
                                               title: "本月",
                                               subtitle: relativeReset(m) ?? "—",
                                               percentage: m.pct,
                                               bandColor: thresholdBrand(Int(m.pct.rounded()),
                                                                         config: model.thresholdConfig,
                                                                         brand: brand),
                                               threshold: model.thresholdConfig))
        }
        return ATBMultiRingCard(slots: slots)
            .atbStripeCard(brand: brand, paddingH: DesignTokens.spacingM, paddingV: DesignTokens.spacingS)
    }

    /// token 绝对量行(Kimi 独有:接口给 used/limit 计数,百分比看不出池子大小)。
    /// ⚠️ 口径随通道:web 控制台(现行路径)返回**次数**(每窗口 ~100 次),
    /// 本机 coding 凭证路径才是 token 量(几十万级)。按 limit 量级自适应单位,
    /// 修复"次数挂 tokens 后缀"的错乱观感(2026-10-24 用户实案)。
    private func tokenCountRow(_ q: KimiQuota) -> some View {
        var parts: [String] = []
        parts.append("5h \(Self.tokenText(q.fiveHour.used))/\(Self.tokenText(q.fiveHour.limit))")
        parts.append("周 \(Self.tokenText(q.weekly.used))/\(Self.tokenText(q.weekly.limit))")
        if let m = q.monthly {
            parts.append("月 \(Self.tokenText(m.used))/\(Self.tokenText(m.limit))")
        }
        let isCount = q.fiveHour.limit > 0 && q.fiveHour.limit <= 2000
        return ATBInfoRow(icon: "number.circle.fill",
                          text: parts.joined(separator: " · ") + (isCount ? " 次" : " tokens"),
                          tint: brand,
                          help: isCount
                            ? "官方接口返回的已用/限额**次数**(web 控制台口径;5h 为滚动窗口,多账户求和)"
                            : "官方接口返回的已用/限额 token 计数(5h 为滚动窗口)")
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

    // MARK: 每账户仪表块(多账户拆分:三环/计数/订阅池/加油包都是该账户自己的;
    // 头行右键重命名/重新登录/移除;失败账户保留内联重登/移除)

    /// 单账户仪表块。快照缺失时按错误行/等待行兜底,块不消失。
    @ViewBuilder
    private func accountDashboard(_ account: KimiAccount) -> some View {
        let snap = model.kimiAccountQuotas.first(where: { $0.id == account.id })
        VStack(spacing: DesignTokens.spacingS) {
            if renamingID == account.id {
                ATBRenameField(initial: account.label,
                               onSave: { newLabel in
                                   model.renameKimiAccount(id: account.id, label: newLabel)
                                   renamingID = nil
                               },
                               onCancel: { renamingID = nil })
                    .atbCard(paddingV: DesignTokens.spacingS - 2)
            } else {
                ATBAccountDashHeader(label: account.label, brand: brand,
                                     tag: snap?.quota.planDisplayName,
                                     hint: model.kimiAccountHint(account.id))
                    .contextMenu {
                        ATBAccountMenu.items(rename: { renamingID = account.id },
                                             remove: { model.removeKimiAccount(id: account.id) },
                                             relogin: { presentRelogin(accountID: account.id) })
                    }
            }
            if let snap {
                ringCard(snap.quota)
                tokenCountRow(snap.quota)
                if let balance = snap.quota.subscriptionBalance {
                    accountPoolRow(balance)
                }
                if let booster = snap.quota.booster, booster.enabled {
                    accountBoosterRow(booster)
                }
            } else if let err = model.kimiAccountErrors[account.id] {
                accountErrorRow(err, account: account)
            } else {
                ATBUnavailableRow(title: "三窗口用量")
            }
        }
    }

    /// 该账户订阅池紧凑行(Work/Code 分段;多账户下取代聚合「订阅池总量」大卡)。
    private func accountPoolRow(_ balance: KimiSubscriptionBalance) -> some View {
        var text = "订阅池 \(String(format: "%.2f%%", balance.totalUsedPercent))"
        if let work = balance.workUsedPercent, let code = balance.codeUsedPercent {
            text += " · Work \(String(format: "%.2f%%", work)) / Code \(String(format: "%.2f%%", code))"
        }
        var help = "该账户 Work/Kimi + Code 共用订阅池的使用比例"
        if let ms = balance.expireTimeMs {
            help += ";重置 \(KimiSubscriptionCard.dateText(ms))"
        }
        return ATBInfoRow(icon: "chart.pie.fill", text: text, tint: brand, help: help)
    }

    /// 该账户加油包紧凑行。
    private func accountBoosterRow(_ booster: KimiBooster) -> some View {
        ATBInfoRow(icon: "wallet.pass.fill",
                   text: "加油包 ¥\(String(format: "%.2f", booster.balanceYuan))"
                       + " · 本月 ¥\(String(format: "%.2f", booster.monthlyUsedYuan))",
                   tint: brand,
                   help: "该账户加油包余额与本月消费")
    }

    /// 该账户拉取失败行(内联重登/移除;块头行已示账户名,行内不再重复)。
    private func accountErrorRow(_ err: String, account: KimiAccount) -> some View {
        HStack(spacing: DesignTokens.spacingS) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.orange)
            Text(err)
                .font(.system(size: 9))
                .foregroundStyle(Color.atbTextSecondary)
                .lineLimit(2)
            Spacer(minLength: 0)
            Button("重新登录") { presentRelogin(accountID: account.id) }
                .buttonStyle(ATBTextButtonStyle(color: brand))
                .font(.system(size: 9))
            Button("移除") { model.removeKimiAccount(id: account.id) }
                .buttonStyle(ATBTextButtonStyle(color: .atbCritical))
                .font(.system(size: 9))
        }
        .atbCard(paddingV: DesignTokens.spacingS - 2)
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

    static func dateText(_ ms: Int64) -> String {
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

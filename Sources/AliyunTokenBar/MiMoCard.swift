import SwiftUI
import AppKit
import AliyunTokenBarCore

// MARK: - 小米 MiMo API 余额卡(余额 + Token 套餐 · 双预测)
//
// v1.0.66 视觉语言(StepFun v1.0.65 设计范式泛化 + MiMo 特色):
// - 品牌行带数据更新时间;
// - 总余额 Hero(现金/赠送拆分)保留,新增**余额 runway 行**:
//   按近 7 日余额下降速度预估"还能撑几天"(余额回升/数据不足时隐藏,不猜);
// - Token 套餐卡重设计:mini-ring + 次数主口径(本月已用 X/Y Credits)
//   + 周期到期 + **周期末预测**(按近 3 日速度,回答"这个周期会不会用完");
// - 自动续期状态行 + 本机 CLI 账本行保留(零凭据的活动量参考)。

struct MiMoCard: View {
    @StateObject private var model = TokenPlanModel.shared
    @State private var draftCookie = ""
    @State private var saveError: String?
    @State private var showLogin = false
    private let consoleURL = URL(string: "https://platform.xiaomimimo.com/#/console/balance")!

    private var brand: Color { .atbBrandMiMo }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingM) {
            header
            if model.mimoConfigured {
                if let usage = model.mimoUsage {
                    balanceCard(usage.balance)
                    if let plan = usage.plan { planCard(plan) }
                    statusRow
                } else if let err = model.mimoError, isAuthError(err) {
                    cookieErrorCard(err)
                    fallbackCards
                } else if model.mimoLoading {
                    loadingCard
                } else {
                    unavailableCards
                    fallbackCards
                    statusRow
                }
            } else {
                setupCard
            }
            autoRenewRow
            localLedgerRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $showLogin) { MiMoLoginView() }
    }

    // MARK: 品牌行

    private var header: some View {
        HStack(spacing: DesignTokens.spacingS) {
            ATBProviderMark(tab: .mimo, size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text("小米 MiMo")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.atbTextPrimary)
                ATBSubtitleText(text: subtitleText)
            }
            Spacer(minLength: DesignTokens.spacingS)
            if model.mimoConfigured {
                ATBRefreshButton(action: { Task { await model.refreshMiMo(force: true) } },
                                 help: "刷新余额与套餐用量")
            }
        }
    }

    private var subtitleText: String {
        var base = "开放平台 · 余额与套餐用量"
        let t = ATBTimeFormat.updated(model.mimoLastUpdated ?? ATBTimeFormat.latestData(model))
        if !t.isEmpty { base += " · \(t) 更新" }
        return base
    }

    // MARK: 总余额卡(Hero:¥ 主口径 + 现金/赠送拆分)

    private func balanceCard(_ b: MiMoUsageService.MiMoBalance) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingS - 2) {
            HStack(alignment: .firstTextBaseline) {
                Text("总余额")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.atbTextSecondary)
                    .textCase(.uppercase)
                    .tracking(0.4)
                Spacer()
                Text(MiMoMoneyFormat.full(b.balance, currency: b.currency))
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.atbTextPrimary)
                    .atbHeroGlow(brand)
            }
            HStack(spacing: DesignTokens.spacingM) {
                if let cash = b.cashBalance {
                    Label {
                        Text("现金 \(MiMoMoneyFormat.full(cash, currency: b.currency))")
                    } icon: {
                        Image(systemName: "creditcard").font(.system(size: 9, weight: .semibold))
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.atbTextSecondary)
                }
                if let gift = b.giftBalance {
                    Label {
                        Text("赠送 \(MiMoMoneyFormat.full(gift, currency: b.currency))")
                    } icon: {
                        Image(systemName: "gift").font(.system(size: 9, weight: .semibold))
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.atbTextSecondary)
                }
                Spacer(minLength: 0)
            }
            // 余额 runway:按近 7 日下降速度预估可用天数(回升/不足数据时隐藏)
            if let runway = balanceRunway(b) {
                ATBForecastRow(icon: "calendar.badge.clock", text: runway,
                               tint: runway.starts(with: "⚠") ? Color(red: 0.95, green: 0.55, blue: 0.10) : Color.atbTextTertiary,
                               help: "按近 7 日余额下降速度线性外推;仅反映余额消耗,不含新充值。")
            }
        }
        .atbStripeCard(brand: brand, paddingH: DesignTokens.spacingM + 2, paddingV: DesignTokens.spacingS + 2, hero: true)
    }

    /// "按近 7 日速度(日均 ¥X),余额约可支撑 N 天";N<14 加 ⚠。
    private func balanceRunway(_ b: MiMoUsageService.MiMoBalance) -> String? {
        let samples = ATBHistory.valueSamples(model, provider: "mimo")
        guard let burn = UsageForecast.burnPerDay(samples: samples), burn > 0 else { return nil }
        guard let days = UsageForecast.runwayDays(remaining: b.balance, burnPerDay: burn) else { return nil }
        let perDay = MiMoMoneyFormat.full(burn, currency: b.currency)
        if days < 14 {
            return "⚠ 按近 7 日速度(日均 \(perDay)),余额约可支撑 \(Int(days.rounded())) 天"
        }
        return "按近 7 日速度(日均 \(perDay)),余额约可支撑 \(Int(days.rounded())) 天"
    }

    // MARK: Token 套餐卡(mini-ring + 次数主口径 + 周期预测)

    private func planCard(_ p: MiMoUsageService.MiMoTokenPlan) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingS - 2) {
            HStack(spacing: 6) {
                Text("Token 套餐")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.atbTextPrimary)
                if let code = p.planCode, !code.isEmpty {
                    ATBBrandTag(text: code, brand: brand)
                }
                if p.expired == true {
                    ATBBrandTag(text: "已过期", brand: Color.atbCritical)
                }
                Spacer()
            }
            if p.limit > 0 {
                HStack(spacing: DesignTokens.spacingM) {
                    ATBMiniRing(pct: Int(p.usedPct.rounded()),
                                color: thresholdBrand(Int(p.usedPct.rounded()),
                                                      config: model.thresholdConfig, brand: brand),
                                diameter: 46)
                        .help("套餐本月已用 \(Int(p.usedPct.rounded()))%")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("本月已用 \(Self.countText(p.used)) / \(Self.countText(p.limit)) \(MiMoUsageService.planQuotaUnit)")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Color.atbTextPrimary)
                        Text(planForecast(p))
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Color.atbTextSecondary)
                    }
                    Spacer(minLength: 0)
                }
                // 已用进度条(刻度风格与 UsageCard 一致:品牌底 + 阈值色填充)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(brand.opacity(0.12))
                        Capsule()
                            .fill(thresholdBrand(Int(p.usedPct.rounded()),
                                                 config: model.thresholdConfig, brand: brand))
                            .frame(width: max(3, geo.size.width * min(1, max(0, p.usedPct) / 100)))
                    }
                }
                .frame(height: 5)
                HStack(spacing: DesignTokens.spacingM) {
                    if let end = p.periodEnd {
                        Text("周期至 \(Self.dateText(end))")
                            .font(.system(size: 9))
                            .foregroundStyle(Color.atbTextTertiary)
                    }
                    Spacer(minLength: 0)
                }
            } else {
                Text(p.periodEnd.map { "套餐周期至 \(Self.dateText($0))" } ?? "暂无用量数据")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.atbTextTertiary)
            }
        }
        .atbStripeCard(brand: brand, paddingH: DesignTokens.spacingM + 2, paddingV: DesignTokens.spacingS + 2)
    }

    /// 周期末预测:按近 3 日套餐用量速度外推到周期结束;
    /// 数据不足/无周期结束时间 → 诚实说明,不猜数字。
    private func planForecast(_ p: MiMoUsageService.MiMoTokenPlan) -> String {
        guard let end = p.periodEnd else { return "按周期发放,不结转" }
        let resetMs = Int64(end.timeIntervalSince1970 * 1000)
        let samples = ATBHistory.pctSamples(model, provider: "mimo", window: "plan")
        let forecast = UsageForecast.monthEndPct(samples: samples, now: Date(), resetMs: resetMs)
        if let forecast {
            let perDay = UsageForecast.pctPerDay(samples: samples)
            let extra = perDay.map { " · 日均 +\(String(format: "%.1f", abs($0)))%" } ?? ""
            return "按近 3 日速度,预计周期末用到 \(Int(forecast.rounded()))%\(extra)"
        }
        return "趋势积累中(约 6 小时数据后给出周期预测)"
    }

    // MARK: 状态行

    private var statusRow: some View {
        HStack(alignment: .top, spacing: 6) {
            if model.isOffline {
                Image(systemName: "wifi.slash")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.orange)
                Text("离线:网络恢复后自动刷新")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.orange)
            } else if let err = model.mimoError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.orange)
                Text("刷新失败:\(err)(显示 \(Self.timeText(model.mimoLastUpdated)) 的旧数据)")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            } else {
                Text("最后查询 \(Self.timeText(model.mimoLastUpdated))")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color.atbTextTertiary)
                    .tracking(0.2)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Loading / unavailable

    private var loadingCard: some View {
        ATBLoadingCard(height: 56)
    }

    private var unavailableCards: some View {
        VStack(spacing: DesignTokens.spacingS) {
            ATBUnavailableRow(title: "总余额")
            ATBUnavailableRow(title: "Token 套餐")
        }
    }

    // MARK: Cookie 过期重登

    private func cookieErrorCard(_ err: String) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingS) {
            HStack(spacing: DesignTokens.spacingS) {
                Image(systemName: "key.slash")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.atbCritical)
                Text(err)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.atbCritical)
            }
            Text("平台登录态已失效。点下方「登录平台」在窗内重新登录即可(自动续期失败时才需要);"
                 + "也可以手工粘贴新的 Cookie 请求头。")
                .font(.system(size: 10))
                .foregroundStyle(Color.atbTextSecondary)
            HStack(spacing: DesignTokens.spacingS) {
                Button("登录平台") { showLogin = true }
                    .buttonStyle(ATBPrimaryButtonStyle())
                    .font(.system(size: 11, weight: .medium))
                Button("打开平台网页") { NSWorkspace.shared.open(consoleURL) }
                    .buttonStyle(ATBTextButtonStyle(color: brand))
                    .font(.system(size: 11, weight: .medium))
            }
            cookieInputRow
        }
        .atbCard()
    }

    // MARK: 未配置引导

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingS) {
            HStack(spacing: DesignTokens.spacingS) {
                Image(systemName: "key.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(brand)
                Text("未配置平台凭据")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.atbTextPrimary)
                Spacer()
                ATBBrandActionButton(title: "登录平台", symbol: "person.badge.key", brand: brand,
                                     action: { showLogin = true },
                                     help: "在窗内登录 platform.xiaomimimo.com,自动保存两域 Cookie")
                ATBBrandActionButton(title: "打开平台", symbol: "arrow.up.right.square", brand: brand,
                                     action: { NSWorkspace.shared.open(consoleURL) },
                                     help: "打开小米 MiMo 开放平台余额页")
            }
            Text("MiMo 未开放 API Key 余额接口。**推荐点「登录平台」**:在窗内登录一次即可,"
                 + "App 会自动保存平台与小米账号两域 Cookie,并在登录态过期时静默续期。")
                .font(.system(size: 10))
                .foregroundStyle(Color.atbTextSecondary)
            Text("也可以手工粘贴:浏览器开发者工具 → 网络 → 任一 api/v1 请求,复制整段 Cookie 请求头。"
                 + "手工粘贴只含平台段,过期后需重新粘贴(不启用自动续期)。")
                .font(.system(size: 10))
                .foregroundStyle(Color.atbTextTertiary)
            cookieInputRow
            Text("Cookie 仅保存在系统钥匙串,本机其他应用不可读。")
                .font(.system(size: 9))
                .foregroundStyle(Color.atbTextTertiary)
        }
        .atbCard()
    }

    // MARK: 本地兜底(上次成功快照 + 本机 CLI 口径)

    /// 控制台不可用时的兜底卡片:上次成功快照(含时间)。
    @ViewBuilder
    private var fallbackCards: some View {
        if let snap = model.mimoLastSnapshot {
            VStack(alignment: .leading, spacing: DesignTokens.spacingS - 2) {
                HStack {
                    Text("上次成功查询")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.atbTextSecondary)
                    Spacer()
                    Text(Self.timeText(snap.capturedAt))
                        .font(.system(size: 9))
                        .foregroundStyle(Color.atbTextTertiary)
                }
                HStack(spacing: DesignTokens.spacingM) {
                    Text("余额 \(MiMoMoneyFormat.full(snap.usage.balance.balance, currency: snap.usage.balance.currency))")
                        .font(.system(size: 10, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(Color.atbTextSecondary)
                    if let p = snap.usage.plan, p.limit > 0 {
                        Text("套餐 \(Int(p.usedPct.rounded()))%")
                            .font(.system(size: 10, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(Color.atbTextSecondary)
                    }
                    Spacer(minLength: 0)
                }
            }
            .atbCard(paddingV: DesignTokens.spacingS - 2)
        }
    }

    /// 本机 CLI 用量账本(零凭据)。
    ///
    /// ⚠️ **不要把它当成控制台数字的上/下界**:控制台计费单位是 **Credits**(1 token = 2 Credits),
    /// 而这里统计的是本机 mimocode/opencode 的**原始 token**;两者单位不同、覆盖范围也完全不同
    /// (实测控制台月用量 ≈ 10 亿 tokens 量级,本机 4 天仅 52 万 tokens)。
    /// 它的价值是"本机活动量 + 趋势",与套餐余量无关。
    @ViewBuilder
    private var localLedgerRow: some View {
        if let local = model.mimoLocalUsage, !local.days.isEmpty {
            HStack(spacing: 5) {
                Image(systemName: "internaldrive")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.atbTextTertiary)
                Text("本机 CLI 消耗(与控制台 Credits 不同口径)\(local.days.count) 天累计 "
                     + "\(Self.countText(MiMoLocalLedger.totalTokens(in: local))) tokens,"
                     + "今日 \(Self.countText(MiMoLocalLedger.todayTokens(in: local, now: Date())))")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color.atbTextTertiary)
                Spacer(minLength: 0)
            }
            .help("读取本机 mimocode / opencode 数据库统计的原始 token 消耗。"
                  + "控制台套餐用量计费单位是 Credits(1 token = 2 Credits)且覆盖所有客户端,"
                  + "两者口径不同、不可比较,此处仅反映本机 CLI 的活动量。")
        }
    }

    // MARK: 自动续期状态行
    private var autoRenewRow: some View {
        HStack(spacing: 5) {
            Image(systemName: model.mimoAutoRenewEnabled ? "arrow.triangle.2.circlepath" : "exclamationmark.circle")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(model.mimoAutoRenewEnabled ? Color.atbTextTertiary : .orange)
            Text(model.mimoAutoRenewEnabled
                 ? "自动续期已启用(已保存小米账号 passToken)"
                 : "自动续期未启用 —— 登录态过期后需重新登录")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(model.mimoAutoRenewEnabled ? Color.atbTextTertiary : .orange)
            Spacer(minLength: 0)
            if !model.mimoAutoRenewEnabled {
                Button("登录以启用") { showLogin = true }
                    .buttonStyle(ATBTextButtonStyle(color: brand))
                    .font(.system(size: 9, weight: .semibold))
            }
        }
    }

    private var cookieInputRow: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingS - 2) {
            HStack(spacing: DesignTokens.spacingS) {
                SecureField("Cookie: api-platform_serviceToken=…; userId=…",
                            text: $draftCookie)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                Button("保存并查询") { saveCookie() }
                    .buttonStyle(ATBPrimaryButtonStyle())
                    .font(.system(size: 11, weight: .medium))
            }
            if let saveError {
                Text(saveError)
                    .font(.system(size: 10))
                    .foregroundStyle(.atbCritical)
            }
        }
    }

    private func saveCookie() {
        let trimmed = draftCookie.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            saveError = "请粘贴 Cookie 请求头"
            return
        }
        guard MiMoUsageService.normalizedCookie(from: trimmed) != nil else {
            saveError = "缺少必需 cookie(api-platform_serviceToken / userId),请从平台网页请求中完整复制"
            return
        }
        saveError = nil
        model.mimoCookie = trimmed
        draftCookie = ""
        Task { await model.refreshMiMo(force: true) }
    }

    // MARK: helpers

    private func isAuthError(_ err: String) -> Bool {
        err.contains("过期") || err.contains("401") || err.contains("403")
            || err.contains("Cookie 缺少")
    }

    private static func countText(_ v: Int) -> String {
        if v >= 100_000_000 { return String(format: "%.1f亿", Double(v) / 100_000_000) }
        if v >= 10_000 { return String(format: "%.1f万", Double(v) / 10_000) }
        return "\(v)"
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static func dateText(_ d: Date) -> String {
        dateFormatter.string(from: d)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    private static func timeText(_ date: Date?) -> String {
        guard let date else { return "--" }
        return timeFormatter.string(from: date)
    }
}

import SwiftUI
import AppKit
import AliyunTokenBarCore

// MARK: - 阶跃 StepFun Step Plan 用量卡(多账户)
//
// 视觉语言沿用项目 DesignTokens/ATB 组件(Preserve 模式),信息层级为 Credit
// 月池计费重新设计:
//   旧:装饰性大环(月池 1% 时近乎空环) + 账单小字 + 复读状态行
//   新:hero = 小环 + ¥金额主口径(官方 1M Credit=¥1,心理账户是钱不是 Credit)
//       + 清零倒计时 + **月末预测行**(v1.0.65 新增,线性外推到清零时刻,
//       回答「按当前速度能不能撑到清零」这个月池计费真正的问题)
//   多账户:合计 hero + 每账户细条行(标签/环/已用%/剩余/清零/重登)
struct StepFunCard: View {
    @StateObject private var model = TokenPlanModel.shared
    @State private var loginAccountID: String?
    @State private var loginAccountLabel: String?
    @State private var showLogin = false

    private var brand: Color { ProviderBrand.color(for: .stepfun) }
    private let consoleURL = URL(string: "https://platform.stepfun.com/step-plan")!

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingM) {
            providerHeader
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $showLogin) {
            StepFunLoginView(accountID: loginAccountID, newAccountLabel: loginAccountLabel)
        }
    }

    // MARK: 品牌行

    private var providerHeader: some View {
        HStack(spacing: DesignTokens.spacingS) {
            ATBProviderMark(tab: .stepfun, size: 24)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text("阶跃 Step Plan")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.atbTextPrimary)
                    if model.stepfunAccounts.count > 1 {
                        ATBBrandTag(text: "\(model.stepfunAccounts.count) 账户", brand: brand)
                    }
                    if !model.stepfunDuplicateAccountIDs.isEmpty {
                        // 标题级重复告警:同一账户登录了多次(合计已去重)
                        ATBBrandTag(text: "有重复", brand: .orange)
                    }
                }
                ATBSubtitleText(text: subtitleText)
            }
            Spacer(minLength: DesignTokens.spacingS)
            if model.stepfunConfigured {
                ATBBrandActionButton(title: "添加账户", symbol: "plus", brand: brand,
                                     action: {
                                         loginAccountID = UUID().uuidString
                                         loginAccountLabel = "账户\(model.stepfunAccounts.count + 1)"
                                         showLogin = true
                                     },
                                     help: "登录另一个阶跃账户(独立会话,互不影响)")
                ATBRefreshButton(action: { Task { await model.refreshStepFun(force: true) } },
                                 help: "刷新阶跃 Step Plan 用量")
            }
        }
    }

    private var subtitleText: String {
        let time = ATBTimeFormat.updated(model.stepfunLastUpdated)
        let stale = model.stepfunAccountQuotas.filter(\.isStale).count
        var parts: [String] = []
        if !time.isEmpty { parts.append("\(time) 更新") }
        if model.stepfunAccounts.count > 1 { parts.append("\(model.stepfunAccounts.count) 账户合计") }
        if stale > 0 { parts.append("\(stale) 个为旧数据") }
        return parts.isEmpty ? "Step Plan 订阅额度" : parts.joined(separator: " · ")
    }

    // MARK: 内容分发

    @ViewBuilder
    private var content: some View {
        if !model.stepfunConfigured {
            setupCard
        } else {
            VStack(spacing: DesignTokens.spacingM) {
                duplicateBanner
                contentBody
            }
        }
    }

    @ViewBuilder
    private var contentBody: some View {
        if let q = model.stepfunQuota {
            VStack(spacing: DesignTokens.spacingM) {
                heroCard(q, accounts: model.stepfunAccountQuotas)
                if model.stepfunAccounts.count > 1 {
                    accountList
                }
                forecastRow(q)
                statusRow
            }
        } else if model.stepfunAccounts.count > 1 || !isAuthError {
            // 无聚合数据:逐账户行兜底(错误/冷却/重载中/加载中都有一席之地,
            // 不再整卡只剩一句全局错误——单账户鉴权失败仍走醒目重登卡)
            VStack(spacing: DesignTokens.spacingM) {
                accountList
                statusRow
            }
        } else if let first = model.stepfunAccounts.first {
            reloginCard(accountID: first.id, label: nil)
        } else {
            errorHint(model.stepfunError ?? "")
        }
    }

    /// 重复账户横幅:同一 oasis_id 的多个会话 = 同一个阶跃账户(重复登录)。
    /// 合计已只计一次(聚合层去重),这里给显式提示 + 一键移除多余会话。
    @ViewBuilder
    private var duplicateBanner: some View {
        let dupes = model.stepfunDuplicateAccountIDs
        if !dupes.isEmpty {
            HStack(spacing: DesignTokens.spacingS) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(dupes.count) 个账户是重复登录")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.atbTextPrimary)
                    Text("与已有账户是同一个阶跃账户(oasis_id 相同),合计已只计一次。")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.atbTextSecondary)
                }
                Spacer(minLength: 0)
                Button("移除重复") {
                    for id in model.removeStepFunDuplicateAccounts() {
                        StepFunSessionController.shared.logout(accountID: id)
                    }
                }
                .buttonStyle(ATBPrimaryButtonStyle())
                .font(.system(size: 9, weight: .medium))
            }
            .atbCard(paddingV: DesignTokens.spacingS)
        }
    }

    /// 鉴权类错误(过期/凭证类型不对)→ 内联重登;其余错误走 errorHint。
    private var isAuthError: Bool {
        let e = model.stepfunError ?? ""
        return e.contains("登录态已过期") || e.contains("凭证类型不对") || e.contains("无法识别")
    }

    // MARK: Hero(小环 + ¥ 口径 + 倒计时)

    /// main display panel: left mini-ring (at-a-glance usage), right text stack.
    /// `sub` = aggregate or single-account pool; totals line only when count exists.
    private func heroCard(_ q: StepFunQuota, accounts: [StepFunAccountSnapshot]) -> some View {
        let sub = q.subscription
        let pctInt = sub?.usedPctInt ?? 0
        let band = thresholdBrand(pctInt, config: model.thresholdConfig, brand: brand)
        return HStack(spacing: DesignTokens.spacingM) {
            ATBMiniRing(pct: pctInt, color: band, diameter: 46)
                .help("月池已用 \(pctInt)%")
            VStack(alignment: .leading, spacing: 2) {
                if let sub, sub.total > 0 {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(StepFunCreditFormat.cny(sub.residual))
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Color.atbTextPrimary)
                        Text("/ \(StepFunCreditFormat.cny(sub.total))")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Color.atbTextTertiary)
                    }
                    Text("\(StepFunCreditFormat.compact(sub.residual)) / \(StepFunCreditFormat.compact(sub.total)) Credits · 剩 \(Int((sub.residual / max(1, sub.total) * 100).rounded()))%")
                        .font(.system(size: 9))
                        .monospacedDigit()
                        .foregroundStyle(Color.atbTextTertiary)
                } else {
                    Text("月池 \(pctInt)%")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(band)
                }
                if let reset = StepFunRateWindow.resetText(fromMs: sub?.resetTimeMs) {
                    Text(reset)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Color.atbTextSecondary)
                } else if sub != nil {
                    Text("月末清零,不结转")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Color.atbTextSecondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(DesignTokens.spacingM)
        .frame(maxWidth: .infinity, alignment: .leading)
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

    // MARK: 多账户行(细条 + 值)

    private var accountList: some View {
        VStack(spacing: 4) {
            // 按**已登记账户**渲染(不是按成功快照):本轮失败的账户保留 last-good
            // 旧值 + 错误明细,行不消失、合计不静默缩水(2026-10-09 修)
            ForEach(model.stepfunAccounts) { account in
                accountRow(account: account,
                           snap: model.stepfunAccountQuotas.first(where: { $0.id == account.id }),
                           err: model.stepfunAccountErrors[account.id])
            }
        }
    }

    @ViewBuilder
    private func accountRow(account: StepFunAccount, snap: StepFunAccountSnapshot?, err: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let m = snap?.quota.subscription {
                let pct = m.usedPctInt
                let band = thresholdBrand(pct, config: model.thresholdConfig, brand: brand)
                HStack(spacing: DesignTokens.spacingS) {
                    Text(account.label)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.atbTextSecondary)
                        .frame(width: 40, alignment: .leading)
                    // 身份展示:优先手机号尾号(****5678),拿不到回落 oasis_id 尾4位
                    // (#8016)——多账户一眼区分是谁,重复登录也藏不住
                    if let identity = account.identityDisplay {
                        Text(identity)
                            .font(.system(size: 8, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.atbTextTertiary)
                    }
                    Text("\(pct)%")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(band)
                        .frame(width: 32, alignment: .trailing)
                    // 3pt thin bar: glance-level usage
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.08))
                            Capsule().fill(band)
                                .frame(width: geo.size.width * CGFloat(pct) / 100)
                        }
                    }
                    .frame(height: 3)
                    if m.total > 0 {
                        Text("剩 \(StepFunCreditFormat.compact(m.residual))")
                            .font(.system(size: 9, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Color.atbTextTertiary)
                            .frame(width: 56, alignment: .trailing)
                    }
                    if let reset = StepFunRateWindow.resetText(fromMs: m.resetTimeMs) {
                        Text(reset)
                            .font(.system(size: 9))
                            .foregroundStyle(Color.atbTextTertiary)
                    }
                    Spacer(minLength: 0)
                }
            } else if snap != nil {
                HStack(spacing: DesignTokens.spacingS) {
                    Text(account.label)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.atbTextSecondary)
                    // 兜底态也带身份:拉取失败时用户仍认得出是哪一个个账户
                    if let identity = account.identityDisplay {
                        Text(identity)
                            .font(.system(size: 8, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.atbTextTertiary)
                    }
                    Text("无月池数据")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.atbTextTertiary)
                    Spacer(minLength: 0)
                }
            } else {
                HStack(spacing: DesignTokens.spacingS) {
                    Text(account.label)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.atbTextSecondary)
                    if let identity = account.identityDisplay {
                        Text(identity)
                            .font(.system(size: 8, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.atbTextTertiary)
                    }
                    Text(err == nil ? "加载中…" : "暂无数据")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.atbTextTertiary)
                    Spacer(minLength: 0)
                }
            }
            if let err {
                HStack(spacing: DesignTokens.spacingS) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.orange)
                    // 旧数据行附拉取时刻:用户能分辨「数字旧」和「数字新」
                    Text(err + (snap?.isStale == true && snap?.fetchedAt != nil
                                ? " · 数据截至 \(ATBTimeFormat.updated(snap?.fetchedAt))" : ""))
                        .font(.system(size: 9)).foregroundStyle(Color.atbTextSecondary)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    Button("重登") { presentLogin(accountID: account.id, label: nil) }
                        .buttonStyle(ATBTextButtonStyle(color: brand)).font(.system(size: 9))
                    Button("移除") { removeAccount(account.id) }
                        .buttonStyle(ATBTextButtonStyle(color: .atbCritical)).font(.system(size: 9))
                }
            } else if model.stepfunDuplicateAccountIDs.contains(account.id) {
                // 重复账户:同一 oasis_id,数据不计入合计
                HStack(spacing: DesignTokens.spacingS) {
                    Image(systemName: "rectangle.on.rectangle.slash")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.orange)
                    Text("与「\(model.stepfunFirstAccountLabel(oasisID: account.oasisID) ?? "另一账户")」是同一账户,未计入合计")
                        .font(.system(size: 9)).foregroundStyle(Color.atbTextSecondary)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    Button("移除") { removeAccount(account.id) }
                        .buttonStyle(ATBTextButtonStyle(color: .atbCritical)).font(.system(size: 9))
                }
            } else if snap?.isStale == true, let at = snap?.fetchedAt {
                HStack(spacing: DesignTokens.spacingS) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.atbTextTertiary)
                    Text("旧数据,截至 \(ATBTimeFormat.updated(at))")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.atbTextTertiary)
                    Spacer(minLength: 0)
                }
            }
        }
        .atbCard(paddingV: DesignTokens.spacingS - 2)
    }

    // MARK: 月末预测(v1.0.65:月池计费的真正问题——按当前速度能否撑到清零)

    private func forecastRow(_ q: StepFunQuota) -> some View {
        let samples = model.historyStore.within(lastHours: 96).map { snap in
            (t: snap.timestamp, pct: Double(snap.stepfunMonthly ?? 0))
        }
        let now = Date()
        let forecast = UsageForecast.monthEndPct(samples: samples, now: now, resetMs: q.subscription?.resetTimeMs)
        let perDay = UsageForecast.pctPerDay(samples: samples)
        let icon = forecast.map { $0 > 100 - 0.5 ? "exclamationmark.triangle.fill" : "chart.line.uptrend.xyaxis" } ?? "chart.line.uptrend.xyaxis"
        let tint: Color = forecast.map { $0 > 80 ? thresholdBrand(Int($0.rounded()), config: model.thresholdConfig, brand: brand) : Color.atbTextTertiary } ?? Color.atbTextTertiary
        let text: String
        if let forecast {
            text = "按近 3 日速度,预计清零时用到 \(Int(forecast.rounded()))%"
            + (perDay.map { " · 日均 +\(String(format: "%.1f", abs($0)))%" } ?? "")
        } else {
            text = "趋势积累中(≥6 小时数据后给出月末预测)"
        }
        return ATBForecastRow(icon: icon, text: text, tint: tint)
    }

    /// 状态行(全局错误优先;否则数据源说明)。
    private var statusRow: some View {
        HStack(spacing: DesignTokens.spacingS) {
            Circle().fill(brand).frame(width: 5, height: 5)
            Text(model.stepfunError ?? "阶跃开放平台 · Step Plan · 官方 1M Credit = ¥1")
                .font(.system(size: 10))
                .foregroundStyle(model.stepfunError == nil ? Color.atbTextTertiary : .atbCritical)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .atbCard(paddingV: DesignTokens.spacingS - 2)
    }

    // MARK: 未配置引导卡 / 重登卡

    private func presentLogin(accountID: String, label: String?) {
        loginAccountID = accountID
        loginAccountLabel = label
        showLogin = true
    }

    private func removeAccount(_ id: String) {
        model.removeStepFunAccount(id: id)
        StepFunSessionController.shared.logout(accountID: id)
    }

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingS) {
            HStack(spacing: DesignTokens.spacingS) {
                Image(systemName: "stairs")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(brand)
                Text("未配置控制台登录态")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.atbTextPrimary)
                Spacer()
                Button {
                    presentLogin(accountID: "main", label: nil)
                } label: {
                    HStack(spacing: 3) {
                        Text("登录平台")
                            .font(.system(size: 10, weight: .semibold))
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(brand)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(brand.opacity(0.14))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .help("在窗内登录 platform.stepfun.com 并自动保存会话")
            }
            Text("额度查询走控制台登录态(平台登录凭据持续轮换,App 登录一次后在后台保持会话自动续期,无需粘贴 Cookie;API Key 只能调模型)。登录后显示订阅月池与加油包的 Credit 已用比例、月末清零倒计时与消耗预测;支持登录多个账户,同一账户重复登录会自动识别、不会重复计算。")
                .font(.system(size: 10))
                .foregroundStyle(Color.atbTextSecondary)
            HStack(spacing: DesignTokens.spacingS) {
                Button("打开控制台") { NSWorkspace.shared.open(consoleURL) }
                    .buttonStyle(ATBTextButtonStyle(color: .atbTextSecondary))
                    .font(.system(size: 10))
            }
        }
        .atbCard()
    }

    /// 登录态过期:内联重登卡(面板恒可展开,鉴权按 provider 隔离)。
    private func reloginCard(accountID: String, label: String?) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingS) {
            HStack(alignment: .top, spacing: DesignTokens.spacingS) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("登录态已过期")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.atbTextPrimary)
                    Text(model.stepfunError ?? "")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.atbTextSecondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                Button("重新登录") { presentLogin(accountID: accountID, label: label) }
                    .buttonStyle(ATBPrimaryButtonStyle())
                    .font(.system(size: 10, weight: .medium))
            }
        }
        .atbCard(corner: DesignTokens.radiusL)
    }

    private func errorHint(_ err: String) -> some View {
        ATBErrorHintCard(message: err)
    }

    private static func timeText(_ date: Date?) -> String {
        ATBTimeFormat.updated(date)
    }
}

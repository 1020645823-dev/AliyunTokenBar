import SwiftUI
import AppKit
import AliyunTokenBarCore

// MARK: - 小米 MiMo API 余额卡
//
// 视觉语言与 DeepSeekCard 对称(余额型 provider):
// - 品牌行 + 总余额 Hero 卡(现金/赠送拆分)
// - Token 套餐月度用量卡(有套餐数据时)
// - 状态行(时间/错误)
// - 未配置引导:粘贴平台控制台 Cookie(平台未开放 API Key 查余额)
//
// 认证:浏览器登录 platform.xiaomimimo.com 后整段复制 Cookie 请求头
// (必需 api-platform_serviceToken 与 userId 两个 cookie)。

struct MiMoCard: View {
    @StateObject private var model = TokenPlanModel.shared
    @State private var draftCookie = ""
    @State private var saveError: String?
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
                } else if model.mimoLoading {
                    loadingCard
                } else {
                    unavailableCards
                    statusRow
                }
            } else {
                setupCard
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 品牌行

    private var header: some View {
        HStack(spacing: DesignTokens.spacingS) {
            ATBProviderMark(tab: .mimo, size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text("小米 MiMo")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.atbTextPrimary)
                Text("开放平台 · 余额与套餐用量")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color.atbTextTertiary)
                    .tracking(0.3)
            }
            Spacer(minLength: DesignTokens.spacingS)
            if model.mimoConfigured {
                Button {
                    Task { await model.refreshMiMo() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.atbTextTertiary)
                        .frame(width: 22, height: 22)
                        .background(Color.primary.opacity(0.06))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help("刷新余额与套餐用量")
                .accessibilityLabel("刷新 MiMo 余额")
            }
        }
    }

    // MARK: 总余额卡(Hero)

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
        }
        .padding(.horizontal, DesignTokens.spacingM + 2)
        .padding(.vertical, DesignTokens.spacingS + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.atbCardBackground)
        .background(brand.opacity(0.05))
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.radiusM + 2)
                .strokeBorder(brand.opacity(0.18), lineWidth: DesignTokens.strokeHairline)
        )
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radiusM + 2))
        .overlay(alignment: .leading) {
            Rectangle().fill(brand)
                .frame(width: DesignTokens.stripeWidth)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radiusM + 2))
                .padding(.vertical, 1)
        }
    }

    // MARK: Token 套餐卡

    private func planCard(_ p: MiMoUsageService.MiMoTokenPlan) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingS - 2) {
            HStack(spacing: 6) {
                Text("Token 套餐")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.atbTextPrimary)
                if let code = p.planCode, !code.isEmpty {
                    Text(code)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(brand)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(brand.opacity(0.14))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                if p.expired {
                    Text("已过期")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.atbCritical)
                }
                Spacer()
                if p.limit > 0 {
                    ATBHeroNumber(percentage: p.usedPct, brand: brand,
                                  threshold: model.thresholdConfig, size: 18)
                }
            }
            if p.limit > 0 {
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
                    Text("本月已用 \(Self.countText(p.used)) / \(Self.countText(p.limit)) tokens")
                        .font(.system(size: 10, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(Color.atbTextSecondary)
                    Spacer(minLength: 0)
                    if let end = p.periodEnd {
                        Text("周期至 \(Self.dateText(end))")
                            .font(.system(size: 9))
                            .foregroundStyle(Color.atbTextTertiary)
                    }
                }
            } else {
                Text(p.periodEnd.map { "套餐周期至 \(Self.dateText($0))" } ?? "暂无用量数据")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.atbTextTertiary)
            }
        }
        .padding(.horizontal, DesignTokens.spacingM + 2)
        .padding(.vertical, DesignTokens.spacingS + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.atbCardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.radiusM + 2)
                .strokeBorder(Color.atbSeparator.opacity(0.5), lineWidth: DesignTokens.strokeHairline)
        )
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radiusM + 2))
        .overlay(alignment: .leading) {
            Rectangle().fill(brand)
                .frame(width: DesignTokens.stripeWidth)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radiusM + 2))
                .padding(.vertical, 1)
        }
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
        HStack { Spacer(); LoadingRing().frame(width: 18, height: 18); Spacer() }
            .frame(height: 56)
            .atbCard(corner: DesignTokens.radiusL, paddingH: DesignTokens.spacingL,
                     paddingV: DesignTokens.spacingL, alignment: .center)
    }

    private var unavailableCards: some View {
        VStack(spacing: DesignTokens.spacingS) {
            dashCard(title: "总余额")
            dashCard(title: "Token 套餐")
        }
    }

    private func dashCard(title: String) -> some View {
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
            Text("平台登录态已失效。请重新登录 platform.xiaomimimo.com,复制新的 Cookie 请求头粘贴到下方。")
                .font(.system(size: 10))
                .foregroundStyle(Color.atbTextSecondary)
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
                Text("未配置平台 Cookie")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.atbTextPrimary)
                Spacer()
                Button {
                    NSWorkspace.shared.open(consoleURL)
                } label: {
                    HStack(spacing: 3) {
                        Text("打开平台")
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
                .help("打开小米 MiMo 开放平台余额页")
            }
            Text("MiMo 未开放 API Key 余额接口。在平台网页登录后,打开浏览器开发者工具 → 网络 → 任一 api/v1 请求,复制整段 Cookie 请求头粘贴到下方,即可显示总余额(现金/赠送)与 Token 套餐月度用量。")
                .font(.system(size: 10))
                .foregroundStyle(Color.atbTextSecondary)
            cookieInputRow
            Text("Cookie 仅保存在系统钥匙串,本机其他应用不可读;过期后在面板重新粘贴即可。")
                .font(.system(size: 9))
                .foregroundStyle(Color.atbTextTertiary)
        }
        .atbCard()
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
                    .foregroundStyle(Color.atbCritical)
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
        Task { await model.refreshMiMo() }
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

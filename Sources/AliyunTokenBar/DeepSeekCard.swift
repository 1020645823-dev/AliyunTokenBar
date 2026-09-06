import SwiftUI
import AppKit
import AliyunTokenBarCore

// MARK: - DeepSeek API 余额卡
//
// v2 视觉语言:
// - 顶部品牌行(钴蓝双圆点 + DeepSeek API 名称 + 刷新按钮)
// - 总余额卡:**Hero 卡**(品牌色铺底 + 双层填充 + 描边),22pt rounded 大数字
// - 当日费用卡:普通卡,品牌色 hero number + 估算标签
// - 近 7 日趋势:小条形图(品牌色 + 当天高亮)+ 合计数字
// - 状态行:沿用 v1 的时间/错误格式(已打磨),但放到卡片底部

struct DeepSeekCard: View {
    @StateObject private var model = TokenPlanModel.shared
    @State private var draftKey = ""
    @State private var saveError: String?
    private let platformURL = URL(string: "https://platform.deepseek.com/api_keys")!

    private var brand: Color { .atbBrandDeepSeek }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingM) {
            header
            if model.deepSeekConfigured {
                if let b = model.deepSeekBalance {
                    balanceCard(b)
                    if let c = model.deepSeekTodayCost { todayCostCard(c) }
                    weekTrendCard
                    statusRow
                } else if let err = model.deepSeekError, isAuthError(err) {
                    keyErrorCard(err)
                } else if model.deepSeekLoading {
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
            ATBProviderMark(tab: .deepSeek, size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text("DeepSeek API")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.atbTextPrimary)
                Text("OpenAI 兼容 · 余额与日花费")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color.atbTextTertiary)
                    .tracking(0.3)
            }
            Spacer(minLength: DesignTokens.spacingS)
            if model.deepSeekConfigured {
                Button {
                    Task { await model.refreshDeepSeek() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.atbTextTertiary)
                        .frame(width: 22, height: 22)
                        .background(Color.primary.opacity(0.06))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help("刷新余额与当日费用")
                .accessibilityLabel("刷新 DeepSeek 余额")
            }
        }
    }

    // MARK: 总余额卡(Hero)

    private func balanceCard(_ b: DeepSeekUsageService.DeepSeekBalance) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingS - 2) {
            HStack(alignment: .firstTextBaseline) {
                Text("总余额")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.atbTextSecondary)
                    .textCase(.uppercase)
                    .tracking(0.4)
                Spacer()
                HStack(alignment: .firstTextBaseline, spacing: DesignTokens.spacingS) {
                    Text(DeepSeekMoneyFormat.full(b.totalBalance))
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Color.atbTextPrimary)
                        .atbHeroGlow(brand)
                    HStack(spacing: 3) {
                        Circle()
                            .fill(b.isAvailable ? Color.atbSuccess : Color.atbCritical)
                            .frame(width: 6, height: 6)
                        Text(b.isAvailable ? "可用" : "官方标记不可用")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Color.atbTextTertiary)
                    }
                }
            }
            HStack(spacing: DesignTokens.spacingM) {
                Label {
                    Text("充值 \(DeepSeekMoneyFormat.full(b.toppedUpBalance))")
                } icon: {
                    Image(systemName: "creditcard").font(.system(size: 9, weight: .semibold))
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.atbTextSecondary)
                Label {
                    Text("赠金 \(DeepSeekMoneyFormat.full(b.grantedBalance))")
                } icon: {
                    Image(systemName: "gift").font(.system(size: 9, weight: .semibold))
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.atbTextSecondary)
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

    // MARK: 当日费用卡

    private func todayCostCard(_ c: DeepSeekDailyCost) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingS - 2) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("当日使用费用")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.atbTextSecondary)
                        .textCase(.uppercase)
                        .tracking(0.4)
                    Text("0 点 → 现在")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.atbTextTertiary)
                }
                Spacer()
                HStack(alignment: .firstTextBaseline, spacing: DesignTokens.spacingS) {
                    if c.estimated {
                        Text("估算")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Color.orange.opacity(0.14))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .help("应用今天首次刷新晚于 0 点,费用按最近一次余额估算;此后 0 点刷新即恢复精确累计。")
                    }
                    Text(DeepSeekMoneyFormat.full(c.cost))
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(c.cost > 0 ? brand : Color.atbTextPrimary)
                        .atbHeroGlow(brand)
                }
            }
            if let baseline = c.baselineAt {
                Text("基线 \(Self.timeText(baseline)) · 点击刷新或按刷新间隔更新")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color.atbTextTertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, DesignTokens.spacingM + 2)
        .padding(.vertical, DesignTokens.spacingS + 2)
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

    // MARK: 近 7 日花费趋势

    private struct DailyCostPoint: Identifiable {
        let id: String
        let date: String
        let cost: Double
        let isToday: Bool
    }

    private var weekCostPoints: [DailyCostPoint] {
        let entries = model.deepSeekDailyStore.load()
        guard !entries.isEmpty else { return [] }
        let todayKey = DeepSeekDailyLedger.dateKey(Date())
        return Array(entries.suffix(7)).map { e in
            let isToday = e.date == todayKey
            var cost = max(0, e.firstBalance - e.lastBalance)
            if isToday, let live = model.deepSeekTodayCost { cost = live.cost }
            return DailyCostPoint(id: e.date, date: e.date, cost: cost, isToday: isToday)
        }
    }

    @ViewBuilder
    private var weekTrendCard: some View {
        let points = weekCostPoints
        if points.count >= 2, points.contains(where: { $0.cost > 0 }) {
            let maxCost = points.map(\.cost).max() ?? 0
            let total = points.reduce(0) { $0 + $1.cost }
            VStack(alignment: .leading, spacing: DesignTokens.spacingS - 2) {
                HStack(alignment: .firstTextBaseline, spacing: DesignTokens.spacingXS) {
                    Text("近 7 日花费")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.atbTextPrimary)
                    Text("· 余额差估算")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Color.atbTextTertiary)
                    Spacer(minLength: DesignTokens.spacingXS)
                    Text(DeepSeekMoneyFormat.full(total))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(brand)
                }
                HStack(alignment: .bottom, spacing: 4) {
                    ForEach(points) { p in
                        VStack(spacing: 3) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(p.isToday ? brand : brand.opacity(0.22))
                                .frame(height: maxCost > 0 ? max(2, 22 * CGFloat(p.cost / maxCost)) : 2)
                            Text(Self.dayText(p.date))
                                .font(.system(size: 8, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(p.isToday ? brand : Color.atbTextTertiary)
                        }
                        .frame(maxWidth: .infinity)
                        .help("\(p.date) 花费 \(DeepSeekMoneyFormat.full(p.cost))\(p.isToday ? "(今日实时)" : "")")
                    }
                }
                .frame(height: 38)
            }
            .padding(.horizontal, DesignTokens.spacingM + 2)
            .padding(.vertical, DesignTokens.spacingS + 2)
            .frame(maxWidth: .infinity)
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
    }

    private static func dayText(_ dateKey: String) -> String {
        let parts = dateKey.split(separator: "-")
        return parts.count == 3 ? String(parts[2]) : dateKey
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
            } else if let err = model.deepSeekError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.orange)
                Text("刷新失败:\(err)(显示 \(Self.timeText(model.deepSeekLastUpdated)) 的旧数据)")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            } else {
                Text("最后查询 \(Self.timeText(model.deepSeekLastUpdated))")
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
            dashCard(title: "当日使用费用")
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

    // MARK: Key auth error

    private func keyErrorCard(_ err: String) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingS) {
            HStack(spacing: DesignTokens.spacingS) {
                Image(systemName: "key.slash")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.atbCritical)
                Text(err)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.atbCritical)
            }
            Text("Key 可能已被删除或吊销,请在下方重新粘贴有效 Key(仅存系统钥匙串)。")
                .font(.system(size: 10))
                .foregroundStyle(Color.atbTextSecondary)
            keyInputRow
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
                Text("未配置 API Key")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.atbTextPrimary)
                Spacer()
                Button {
                    NSWorkspace.shared.open(platformURL)
                } label: {
                    HStack(spacing: 3) {
                        Text("创建 Key")
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
                .help("打开 DeepSeek 开放平台 API Keys 页面")
            }
            Text("填入 DeepSeek 开放平台 API Key 后,将显示总余额、当日使用费用(0 点起累计)与近 7 日花费趋势。")
                .font(.system(size: 10))
                .foregroundStyle(Color.atbTextSecondary)
            keyInputRow
            Text("Key 仅保存在系统钥匙串,本机其他应用不可读;随时可在设置 → 服务中移除。")
                .font(.system(size: 9))
                .foregroundStyle(Color.atbTextTertiary)
        }
        .atbCard()
    }

    private var keyInputRow: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingS - 2) {
            HStack(spacing: DesignTokens.spacingS) {
                SecureField("sk-...", text: $draftKey)
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
    }

    private func saveKey() {
        let trimmed = draftKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            saveError = "请填写 API Key"
            return
        }
        // 直接通过 model 写,触发 didSet → Keychain
        model.deepSeekAPIKey = trimmed
        saveError = nil
        draftKey = ""
        Task { await model.refreshDeepSeek() }
    }

    // MARK: helpers

    private func isAuthError(_ err: String) -> Bool {
        err.contains("401") || err.contains("Authentication") || err.contains("API Key") || err.contains("权限")
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

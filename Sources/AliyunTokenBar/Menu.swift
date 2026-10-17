import SwiftUI
import AppKit
import AliyunTokenBarCore

// MARK: - Provider 标签页(紧凑 5 个标签)

enum ProviderTab: String, CaseIterable, Identifiable {
    case aliyun
    case opencode
    case kimi
    case deepSeek
    case zhipu
    case mimo
    case minimax
    case ollama
    case stepfun
    case system
    var id: String { rawValue }

    /// 对应的统一 registry 身份(Core 层 ProviderKind)。
    var kind: ProviderKind {
        switch self {
        case .aliyun: return .aliyun
        case .opencode: return .openCode
        case .kimi: return .kimi
        case .deepSeek: return .deepSeek
        case .zhipu: return .zhipu
        case .mimo: return .mimo
        case .minimax: return .minimax
        case .ollama: return .ollama
        case .stepfun: return .stepfun
        case .system: return .system
        }
    }
    /// registry → tab 反向映射(rawValue 仅 openCode/opencode 大小写不同,故走显式 switch)。
    init?(kind: ProviderKind) {
        switch kind {
        case .aliyun: self = .aliyun
        case .openCode: self = .opencode
        case .kimi: self = .kimi
        case .deepSeek: self = .deepSeek
        case .zhipu: self = .zhipu
        case .mimo: self = .mimo
        case .minimax: self = .minimax
        case .ollama: self = .ollama
        case .stepfun: self = .stepfun
        case .system: self = .system
        }
    }
    var title: String {
        switch self {
        case .aliyun: return "百炼"
        case .opencode: return "OpenCode"
        case .kimi: return "Kimi"
        case .deepSeek: return "DeepSeek"
        case .zhipu: return "GLM"
        case .mimo: return "MiMo"
        case .minimax: return "MiniMax"
        case .ollama: return "Ollama"
        case .stepfun: return "阶跃"
        case .system: return "本机"
        }
    }
    var icon: String {
        switch self {
        case .aliyun: return "cloud.fill"
        case .opencode: return "bolt.fill"
        case .kimi: return "sparkles"
        case .deepSeek: return "brain.head.profile"
        case .zhipu: return "atom"
        case .mimo: return "waveform"
        case .minimax: return "infinity"
        case .ollama: return "hare.fill"
        case .stepfun: return "stairs"
        case .system: return "cpu"
        }
    }
    var shortLabel: String {
        switch self {
        case .aliyun: return "云"
        case .opencode: return "码"
        case .kimi: return "K"
        case .deepSeek: return "D"
        case .zhipu: return "G"
        case .mimo: return "M"
        case .minimax: return "X"
        case .ollama: return "O"
        case .stepfun: return "阶"
        case .system: return "机"
        }
    }
}

// MARK: - 主面板外壳(NSPopover 装入此)

struct TokenPlanMenu: View {
    var body: some View {
        // v3: 移除 ScrollView,让面板自适应内容高度
        TokenPlanMenuContent()
            .frame(width: 360)
            .background(.regularMaterial)
            .task {
                NotificationManager.shared.requestAuthorization()
            }
    }
}

// MARK: - 主面板内容

struct TokenPlanMenuContent: View {
    @StateObject private var model = TokenPlanModel.shared
    @State private var selectedTab: ProviderTab = .aliyun
    @State private var updatingBl = false
    private let consoleURL = URL(string: "https://bailian.console.aliyun.com/cn-beijing?tab=plan#/efm/subscription/token-plan/personal")!

    /// 当前可用的标签(统一 registry 驱动:停用的数据源不出 tab;
    /// 恒在项 = 阿里云/DeepSeek/本机(卡内自带引导),其余需已配置)。
    private var availableTabs: [ProviderTab] {
        ProviderKind.allCases.compactMap { kind -> ProviderTab? in
            guard model.isEnabled(kind) else { return nil }
            guard kind.panelTabAlwaysListed || model.isConfigured(kind) else { return nil }
            return ProviderTab(kind: kind)
        }
    }

    /// 实际生效的标签(选中项被隐藏/停用时回退到第一个可用项;全部停用为 nil)
    private var effectiveTab: ProviderTab? {
        availableTabs.contains(selectedTab) ? selectedTab : availableTabs.first
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if !availableTabs.isEmpty {
                tabBar
            }
            Divider().opacity(0.4).padding(.horizontal, DesignTokens.spacingM)
            VStack(spacing: DesignTokens.spacingM) {
                if let tab = effectiveTab {
                    selectedContent(for: tab)
                } else {
                    allSourcesDisabledPlaceholder
                }
                footerBar
            }
            .padding(.horizontal, DesignTokens.spacingM)
            .padding(.top, DesignTokens.spacingM)
            .padding(.bottom, DesignTokens.spacingM)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: 顶部品牌头

    private var header: some View {
        HStack(alignment: .center, spacing: DesignTokens.spacingM) {
            ATBProviderMark(tab: .aliyun, size: 30)
                .atbHeroGlow(.atbBrandAliyun, radius: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text("CodingTokenBar")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.atbTextPrimary)
                Text("套餐用量 · 本机指标")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.atbTextTertiary)
                    .tracking(0.3)
            }
            Spacer(minLength: DesignTokens.spacingS)
            if let update = model.appUpdate {
                Button {
                    model.openUpdatePage()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 10, weight: .bold))
                        Text("v\(update.version)")
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(0.3)
                    }
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.orange.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("发现新版本 \(update.version),点击前往下载")
            }
            Button {
                NSWorkspace.shared.open(consoleURL)
            } label: {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.atbTextSecondary)
            }
            .buttonStyle(.plain)
            .help("打开百炼控制台")
            .accessibilityLabel("打开百炼控制台")
        }
        .padding(.horizontal, DesignTokens.spacingM + 2)
        .padding(.top, DesignTokens.spacingM)
        .padding(.bottom, DesignTokens.spacingS)
    }

    // MARK: 标签栏(分段式 · 选中项用 Provider 品牌色)

    private var tabBar: some View {
        let tabs = availableTabs
        return HStack(spacing: 3) {
            ForEach(tabs) { tab in
                tabPill(tab)
            }
        }
        .padding(3)
        .background(Color.primary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.atbSeparator.opacity(0.4), lineWidth: DesignTokens.strokeHairline)
        )
        .padding(.horizontal, DesignTokens.spacingM)
        .padding(.bottom, DesignTokens.spacingS)
    }

    private func tabPill(_ tab: ProviderTab) -> some View {
        let isSelected = (effectiveTab == tab)
        let brand = ProviderBrand.color(for: tab)
        return Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                selectedTab = tab
            }
        } label: {
            HStack(spacing: 4) {
                ZStack {
                    Circle().fill(isSelected ? Color.white.opacity(0.25) : brand.opacity(0.18))
                        .frame(width: 14, height: 14)
                    Image(systemName: tab.icon)
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(isSelected ? .white : brand)
                }
                Text(tab.title)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .foregroundStyle(isSelected ? .white : Color.atbTextSecondary)
            .frame(maxWidth: .infinity, minHeight: 26)
            .padding(.horizontal, 4)
            .background(
                Group {
                    if isSelected {
                        ZStack {
                            brand
                            LinearGradient(colors: [.white.opacity(0.18), .clear],
                                           startPoint: .top, endPoint: .bottom)
                        }
                    } else {
                        Color.clear
                    }
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(isSelected ? brand.opacity(0.6) : Color.clear, lineWidth: 0.5)
            )
        }
        .buttonStyle(PlainPillButtonStyle())
        .accessibilityLabel("\(tab.title)标签页")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // MARK: 内容切换

    @ViewBuilder
    private func selectedContent(for tab: ProviderTab) -> some View {
        VStack(spacing: DesignTokens.spacingM) {
            switch tab {
            case .aliyun: aliyunContent
            case .opencode: OpenCodeCard()
            case .kimi: KimiCodeCard()
            case .deepSeek: DeepSeekCard()
            case .zhipu: ZhipuCodeCard()
            case .mimo: MiMoCard()
            case .minimax: MiniMaxCodeCard()
            case .ollama: OllamaCard()
            case .stepfun: StepFunCard()
            case .system: SystemProcessesCard()
            }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.99)))
    }

    /// 全部数据源停用时的占位卡(引导去设置重新启用)。
    private var allSourcesDisabledPlaceholder: some View {
        VStack(spacing: DesignTokens.spacingS) {
            Image(systemName: "eye.slash")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(Color.atbTextTertiary)
            Text("所有数据源已关闭")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.atbTextSecondary)
            Button("在 设置 → 外观 → 数据源 中启用") {
                SettingsWindowManager.shared.show()
            }
            .buttonStyle(ATBTextButtonStyle())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DesignTokens.spacingXL)
        .atbCard(alignment: .center)
    }

    // MARK: 阿里云内容

    private var aliyunContent: some View {
        VStack(spacing: DesignTokens.spacingM) {
            if model.authState == .blNotInstalled || model.authState == .notLoggedIn || model.authState == .expired {
                AliyunAuthCard()
            } else {
                aliyunHeader
                aliyunStatusRow
                usageSection
                aliyunForecastSection
                planCard
            }
        }
    }

    /// 阿里云品牌行(v1.0.66:与其他订阅卡统一的 header 形态——此前阿里云 tab 无 header)。
    private var aliyunHeader: some View {
        HStack(spacing: DesignTokens.spacingS) {
            ATBProviderMark(tab: .aliyun, size: 24)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text("阿里云百炼")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.atbTextPrimary)
                    if let sub = model.quota?.subscription {
                        ATBBrandTag(text: sub.specDisplay, brand: .atbBrandAliyun)
                    }
                }
                ATBSubtitleText(text: aliyunSubtitleText)
            }
            Spacer(minLength: DesignTokens.spacingS)
            ATBRefreshButton(action: { Task { await model.refreshFull() } }, help: "刷新阿里云用量")
        }
    }

    private var aliyunSubtitleText: String {
        var base = "Token Plan · 窗口用量"
        let t = ATBTimeFormat.updated(model.lastUpdated ?? ATBTimeFormat.latestData(model))
        if !t.isEmpty { base += " · \(t) 更新" }
        return base
    }

    // MARK: 阿里云窗口预测(v1.0.66:5h 触顶 + 7d/月重置时预判)

    private struct AliyunForecastItem: Identifiable {
        let id: String
        let icon: String
        let text: String
        let tint: Color
    }

    /// 5h 是滚动窗口 → 速率触顶预测;7d/月是固定边界 → 重置时刻百分比外推。
    /// 速率非正(刚重置归零)/数据不足/重置时间在过去 → 不出行(不猜)。
    private var aliyunForecastItems: [AliyunForecastItem] {
        guard let q = model.quota else { return [] }
        let urgent = Color(red: 0.95, green: 0.55, blue: 0.10)
        var items: [AliyunForecastItem] = []

        if let five = q.usage.fiveHour {
            let samples = ATBHistory.pctSamples(model, provider: "aliyun", window: "5h")
            if let rate = UsageForecast.pctPerHour(samples: samples), rate > 0, let last = samples.last {
                let hoursToReset = Date(timeIntervalSince1970: TimeInterval(five.resetTimeMs) / 1000)
                    .timeIntervalSinceNow / 3600
                if hoursToReset > 0 {
                    let projected = min(100, last.pct + rate * hoursToReset)
                    if projected >= 99.5 {
                        let mins = UsageForecast.minutesToLimit(samples: samples) ?? 0
                        items.append(AliyunForecastItem(
                            id: "5h",
                            icon: "exclamationmark.triangle.fill",
                            text: "5小时窗口 · 按当前速度约 \(UsageForecast.durationText(minutes: mins)) 后触顶",
                            tint: urgent))
                    } else {
                        items.append(AliyunForecastItem(
                            id: "5h",
                            icon: "chart.line.uptrend.xyaxis",
                            text: "5小时窗口 · 预计重置时用到 \(Int(projected.rounded()))%",
                            tint: Color.atbTextTertiary))
                    }
                }
            }
        }

        for (id, label, detail) in [("7d", "7天窗口", q.usage.oneWeek), ("monthly", "月度窗口", q.usage.oneMonth)] {
            guard let d = detail else { continue }
            let samples = ATBHistory.pctSamples(model, provider: "aliyun", window: id)
            guard let projected = UsageForecast.monthEndPct(samples: samples, now: Date(), resetMs: d.resetTimeMs),
                  let perDay = UsageForecast.pctPerDay(samples: samples), abs(perDay) > 0.05 else { continue }
            let willHit = projected >= 99.5
            items.append(AliyunForecastItem(
                id: id,
                icon: willHit ? "exclamationmark.triangle.fill" : "chart.line.uptrend.xyaxis",
                text: "\(label) · 预计重置时用到 \(Int(projected.rounded()))% · 日均 +\(String(format: "%.1f", abs(perDay)))%",
                tint: willHit ? urgent : Color.atbTextTertiary))
        }
        return items
    }

    @ViewBuilder
    private var aliyunForecastSection: some View {
        let items = aliyunForecastItems
        if !items.isEmpty {
            VStack(spacing: 4) {
                ForEach(items) { item in
                    ATBForecastRow(icon: item.icon, text: item.text, tint: item.tint)
                }
            }
        } else if model.quota != nil {
            ATBForecastRow(text: "趋势积累中(约 6 小时数据后给出触顶预测)",
                           help: "按历史用量速率线性外推;至少需要 6 小时跨度的两个有效采样点。")
        }
    }

    private var usageSection: some View {
        VStack(spacing: DesignTokens.spacingM) {
            if let q = model.quota {
                // 窗口按存在性动态出卡(官方窗口形态多次调整:2026-08-15 取消 5h 限额、
                // 2026-09 取消周限额改月限额):缺失的窗口不显示,存在的窗口里第一个为 hero。
                let heroExists = q.usage.fiveHour != nil || q.usage.oneWeek != nil
                if let fiveHour = q.usage.fiveHour {
                    UsageCard(title: "5小时限额",
                              percentage: fiveHour.percentage,
                              resetText: relativeReset(fiveHour),
                              brand: .atbBrandAliyun, isLoading: model.isLoading,
                              threshold: model.thresholdConfig,
                              showSparkline: model.sparklineEnabled,
                              sparklineProvider: "aliyun", sparklineWindow: "5h",
                              resetTooltip: absoluteReset(fiveHour),
                              hero: true)
                }
                if let oneWeek = q.usage.oneWeek {
                    UsageCard(title: "7天限额",
                              percentage: oneWeek.percentage,
                              resetText: relativeReset(oneWeek),
                              brand: .atbBrandAliyun, isLoading: model.isLoading,
                              threshold: model.thresholdConfig,
                              showSparkline: model.sparklineEnabled,
                              sparklineProvider: "aliyun", sparklineWindow: "7d",
                              resetTooltip: absoluteReset(oneWeek),
                              hero: !heroExists)
                }
                if let oneMonth = q.usage.oneMonth {
                    UsageCard(title: "月度限额",
                              percentage: oneMonth.percentage,
                              resetText: relativeReset(oneMonth),
                              brand: .atbBrandAliyun, isLoading: model.isLoading,
                              threshold: model.thresholdConfig,
                              showSparkline: model.sparklineEnabled,
                              sparklineProvider: "aliyun", sparklineWindow: "monthly",
                              resetTooltip: absoluteReset(oneMonth),
                              hero: !heroExists)
                }
            } else if model.isLoading {
                HStack { Spacer(); LoadingRing().frame(width: 18, height: 18); Spacer() }
                    .frame(height: 48)
                    .atbCard(corner: DesignTokens.radiusL, paddingH: DesignTokens.spacingL,
                             paddingV: DesignTokens.spacingL, alignment: .center)
            } else if model.lastError != nil {
                UsageCard(title: "月度限额", percentage: nil, resetText: nil,
                          brand: .atbBrandAliyun, isLoading: false,
                          threshold: model.thresholdConfig, dataUnavailable: true, hero: true)
            } else {
                Text("加载中…")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.atbTextSecondary)
                    .atbCard(corner: DesignTokens.radiusL, paddingH: DesignTokens.spacingL,
                             paddingV: DesignTokens.spacingL)
            }
        }
    }

    private func relativeReset(_ d: UsageDetail) -> String? {
        d.resetTimeMs > 0 ? d.timeUntilReset : nil
    }

    private func absoluteReset(_ d: UsageDetail) -> String? {
        guard d.resetTimeMs > 0, let display = d.resetTimeDisplay else { return nil }
        return "重置时间 \(display)"
    }

    private var aliyunStatusRow: some View {
        HStack(alignment: .top, spacing: 6) {
            if model.isOffline {
                Image(systemName: "wifi.slash")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.orange)
                Text("离线:网络恢复后自动刷新")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.orange)
            } else if let err = model.lastError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.orange)
                Text("刷新失败:\(err)(显示 \(Self.statusTimeText(model.lastUpdated)) 的旧数据)")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            } else {
                Text("最后统计 \(Self.statusTimeText(model.lastUpdated))")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color.atbTextTertiary)
                    .tracking(0.2)
            }
            Spacer(minLength: 0)
        }
    }

    private static let statusTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    private static func statusTimeText(_ date: Date?) -> String {
        guard let date else { return "--" }
        return statusTimeFormatter.string(from: date)
    }

    // MARK: 套餐信息

    @ViewBuilder
    private var planCard: some View {
        if let sub = model.quota?.subscription {
            VStack(alignment: .leading, spacing: DesignTokens.spacingS - 2) {
                subscriptionRows(sub)
                if let addon = model.quota?.addon {
                    Divider().opacity(0.4)
                    addonRow(addon)
                }
            }
            .atbCard()
        } else if let addon = model.quota?.addon {
            addonRow(addon).atbCard()
        }
    }

    private func subscriptionRows(_ sub: SubscriptionDetail) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingXS) {
            HStack(spacing: DesignTokens.spacingS) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.green)
                Text("\(sub.specDisplay) 套餐")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.atbTextPrimary)
                ATBTag(text: sub.statusDisplay, brand: .green, symbol: "checkmark")
                if sub.autoRenewFlag {
                    ATBTag(text: "自动续费", brand: .atbBrandDeepSeek, symbol: "arrow.triangle.2.circlepath")
                }
                Spacer(minLength: DesignTokens.spacingXS)
                let days = sub.remainingDays
                Text(days <= 0 ? "已到期" : "剩余 \(days) 天")
                    .font(.system(size: 11, weight: days <= 7 ? .bold : .semibold))
                    .foregroundStyle(days <= 0 ? Color.atbCritical : (days <= 7 ? .orange : Color.atbTextSecondary))
            }
            if let end = sub.endTimeMs.map({ Self.detailDateText(TimeInterval($0) / 1000) }) {
                HStack(spacing: DesignTokens.spacingXS) {
                    Image(systemName: "calendar").font(.system(size: 9)).foregroundStyle(Color.atbTextTertiary)
                    Text("有效期至 \(end)")
                        .font(.system(size: 10)).foregroundStyle(Color.atbTextTertiary)
                }
                .padding(.leading, 1)
            }
        }
    }

    private func addonRow(_ addon: AddonSummary) -> some View {
        HStack(spacing: DesignTokens.spacingS) {
            Image(systemName: "wallet.pass.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.atbBrandAliyun)
            Text("加购资源包")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.atbTextPrimary)
            ATBTag(text: "\(addon.activeCount) 生效", brand: .orange)
            Spacer(minLength: DesignTokens.spacingXS)
            if addon.totalCredits > 0 {
                Text("剩余 \(Self.creditsText(addon.remainingCredits)) / \(Self.creditsText(addon.totalCredits))")
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Color.atbTextSecondary)
            } else {
                Text("—")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.atbTextTertiary)
            }
        }
    }

    private static func creditsText(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }

    private static func detailDateText(_ seconds: TimeInterval) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date(timeIntervalSince1970: seconds))
    }

    // MARK: 页脚操作栏

    private var footerBar: some View {
        HStack(spacing: 6) {
            footerButton("刷新", icon: "arrow.clockwise", isLoading: model.isLoading) {
                // registry 驱动:只刷已启用的数据源;阿里云手动刷新走全量(无视 24h 缓存)
                Task {
                    for kind in ProviderKind.allCases where model.isEnabled(kind) {
                        if kind == .aliyun {
                            await model.refreshFull()
                        } else {
                            await model.refresh(provider: kind)
                        }
                    }
                }
            }
            footerButton("控制台", icon: "globe") {
                NSWorkspace.shared.open(consoleURL)
            }
            footerButton("设置", icon: "gearshape") {
                SettingsWindowManager.shared.show()
            }
            footerButton("退出", icon: "power") {
                NSApplication.shared.terminate(nil)
            }
            Spacer(minLength: DesignTokens.spacingXS)
            blVersionChip
        }
    }

    private func footerButton(_ title: String, icon: String, isLoading: Bool = false,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if isLoading {
                    LoadingRing().frame(width: 10, height: 10)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.2)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Color.atbCardBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.atbSeparator.opacity(0.6), lineWidth: DesignTokens.strokeHairline)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(PlainPillButtonStyle())
        .accessibilityLabel(title)
    }

    @ViewBuilder
    private var blVersionChip: some View {
        if let v = model.blInstalledVersion {
            HStack(spacing: 4) {
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color.atbTextTertiary)
                Text("bl \(v)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.atbTextTertiary)
                if model.blUpdateAvailable, let latest = model.blLatestVersion {
                    if updatingBl {
                        LoadingRing().frame(width: 9, height: 9)
                    } else {
                        Button("更新 \(latest)") { updateBl() }
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.orange)
                            .buttonStyle(.plain)
                            .help("在 Terminal 安装最新版 bl(完成后自动刷新)")
                    }
                }
            }
        }
    }

    private func updateBl() {
        updatingBl = true
        BlAuthManager.updateBl()
        let before = model.blInstalledVersion
        Task {
            for _ in 0..<30 {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                await model.checkBlVersion()
                if model.blInstalledVersion != before { break }
            }
            updatingBl = false
        }
    }
}

// MARK: - Pill 按钮样式

private struct PlainPillButtonStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : (hovering ? 0.85 : 1.0))
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .onHover { hovering = $0 }
    }
}

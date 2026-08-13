import SwiftUI
import AppKit
import AliyunTokenBarCore

// MARK: - 阿里云风格云朵 logo

/// 风格化阿里云云朵 logo(橙色,Canvas 绘制)。
/// 视觉:底部平直、顶部三个圆弧隆起的抽象云朵,呼应阿里云标志性视觉。
struct AliyunCloudLogo: View {
    var size: CGFloat = 28
    var body: some View {
        Canvas { ctx, sz in
            // 云朵路径:用多个圆弧拼出底部平、顶部三隆起的云形
            let w = sz.width, h = sz.height
            var path = Path()
            // 从左下起,顺时针:左弧 → 左上凸起 → 中间大凸起 → 右上凸起 → 右弧 → 底部直线回起点
            path.move(to: CGPoint(x: w*0.10, y: h*0.70))
            // 左侧弧(上行)
            path.addQuadCurve(to: CGPoint(x: w*0.22, y: h*0.42),
                              control: CGPoint(x: w*0.04, y: h*0.45))
            // 左上小凸起
            path.addQuadCurve(to: CGPoint(x: w*0.38, y: h*0.28),
                              control: CGPoint(x: w*0.24, y: h*0.22))
            // 中间大凸起(最高点)
            path.addQuadCurve(to: CGPoint(x: w*0.55, y: h*0.18),
                              control: CGPoint(x: w*0.44, y: h*0.12))
            path.addQuadCurve(to: CGPoint(x: w*0.70, y: h*0.28),
                              control: CGPoint(x: w*0.66, y: h*0.14))
            // 右上凸起
            path.addQuadCurve(to: CGPoint(x: w*0.85, y: h*0.40),
                              control: CGPoint(x: w*0.86, y: h*0.22))
            // 右侧弧(下行)
            path.addQuadCurve(to: CGPoint(x: w*0.90, y: h*0.70),
                              control: CGPoint(x: w*1.00, y: h*0.50))
            // 底部直线回起点
            path.addLine(to: CGPoint(x: w*0.10, y: h*0.70))
            path.closeSubpath()
            // 填充阿里云橙
            ctx.fill(path, with: .color(Color(red: 1.0, green: 0.42, blue: 0.0)))
        }
        .frame(width: size, height: size * 0.78)
    }
}

// MARK: - 主面板

/// 面板 Provider 标签页(节省空间:三个 Provider 上下堆叠会超出屏幕)。
enum ProviderTab: String, CaseIterable, Identifiable {
    case aliyun
    case opencode
    case kimi
    case system
    var id: String { rawValue }
    var title: String {
        switch self {
        case .aliyun: return "阿里云"
        case .opencode: return "OpenCode"
        case .kimi: return "Kimi"
        case .system: return "本机"
        }
    }
    var icon: String {
        switch self {
        case .aliyun: return "cloud.fill"
        case .opencode: return "bolt.fill"
        case .kimi: return "sparkles"
        case .system: return "cpu"
        }
    }
}

struct TokenPlanMenu: View {
    @StateObject private var model = TokenPlanModel.shared
    @State private var selectedTab: ProviderTab = .aliyun
    private let consoleURL = URL(string: "https://bailian.console.aliyun.com/cn-beijing?tab=plan#/efm/subscription/token-plan/personal")!

    /// 当前可用的标签页(阿里云恒有;OpenCode/Kimi 配置了才显示)。
    private var availableTabs: [ProviderTab] {
        var tabs: [ProviderTab] = [.aliyun]
        if model.openCodeConfigured { tabs.append(.opencode) }
        if model.kimiConfigured { tabs.append(.kimi) }
        tabs.append(.system)
        return tabs
    }

    /// 实际生效的标签(选中项不可用时回退阿里云)。
    private var effectiveTab: ProviderTab {
        availableTabs.contains(selectedTab) ? selectedTab : .aliyun
    }

    var body: some View {
        // 面板恒可展开:阿里云鉴权问题只影响阿里云 tab 内联提示,不挡其他 Provider
        // (2026-08-03 用户反馈:token 失效不应整面板不可用,OpenCode/Kimi 仍要能看)。
        // ScrollView 包裹:高 tab(Kimi 订阅+加油包 / System 10 进程)不再被裁切。
        ScrollView {
            VStack(spacing: DesignTokens.spacingM) {
                header
                providerTabs
                selectedContent
                actionButtons
                if model.blInstalledVersion != nil { BlVersionRow() }
            }
            .padding(DesignTokens.spacingL)
            .frame(maxWidth: .infinity)
        }
        .frame(width: 340)
        .background(.regularMaterial)
        .task {
            // 数据刷新由 AppDelegate 在启动时触发(不等面板打开)。
            // 这里仅确保通知授权(面板可能是应用启动后很久才打开的场景)。
            NotificationManager.shared.requestAuthorization()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            AliyunCloudLogo(size: 28)
            Text("CodingTokenBar").font(.system(size: 18, weight: .bold)).foregroundStyle(.atbTextPrimary)
            Spacer()
            Button { NSWorkspace.shared.open(consoleURL) } label: {
                Image(systemName: "arrow.up.right.square").foregroundStyle(.atbTextTertiary)
            }.buttonStyle(.plain)
        }
    }

    // MARK: 标签页切换

    /// 分段式标签栏:三个 Provider 平铺,选中项高亮。
    private var providerTabs: some View {
        HStack(spacing: DesignTokens.spacingXS) {
            ForEach(availableTabs) { tab in
                tabButton(tab)
            }
        }
        .padding(DesignTokens.spacingXS - 1)
        .background(Color.atbCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radiusM))
    }

    private func tabButton(_ tab: ProviderTab) -> some View {
        let isSelected = effectiveTab == tab
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                selectedTab = tab
            }
        } label: {
            HStack(spacing: DesignTokens.spacingXS) {
                Image(systemName: tab.icon).font(.system(size: 10))
                Text(tab.title).font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(isSelected ? .white : .atbTextSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(isSelected ? Color.atbBlue : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radiusS))
        }
        .buttonStyle(.plain)
    }

    /// 当前标签页内容。
    @ViewBuilder
    private var selectedContent: some View {
        switch effectiveTab {
        case .aliyun: aliyunContent
        case .opencode: OpenCodeCard()
        case .kimi: KimiCodeCard()
        case .system: SystemProcessesCard()
        }
    }

    /// 阿里云内容:鉴权异常时内联提示卡(重新登录入口);正常时 5h/7d 用量卡 + 趋势估算 + 套餐信息。
    private var aliyunContent: some View {
        VStack(spacing: 12) {
            if model.authState == .blNotInstalled || model.authState == .notLoggedIn || model.authState == .expired {
                AliyunAuthCard()
            } else {
                usageSection
                if let sub = model.quota?.subscription { subscriptionRow(sub) }
                if let addon = model.quota?.addon { addonRow(addon) }
            }
        }
    }

    private var usageSection: some View {
        // 上下结构(与 OpenCode 三窗口同向),小空间内信息密度更高
        VStack(spacing: DesignTokens.spacingM) {
            aliyunStatusRow
            if let q = model.quota {
                UsageCard(title: "5小时限额",
                          percentage: q.usage.fiveHour.percentage, resetText: q.usage.fiveHour.resetTimeDisplay,
                          color: .atbBlue, isLoading: model.isLoading, thresholdConfig: model.thresholdConfig,
                          showSparkline: model.sparklineEnabled, sparklineWindow: "5h")
                UsageCard(title: "7天限额",
                          percentage: q.usage.oneWeek.percentage, resetText: q.usage.oneWeek.resetTimeDisplay,
                          color: .orange, isLoading: model.isLoading, thresholdConfig: model.thresholdConfig,
                          showSparkline: model.sparklineEnabled, sparklineWindow: "7d")
            } else if model.isLoading {
                HStack { Spacer(); LoadingRing().frame(width: 18, height: 18); Spacer() }
                    .padding(DesignTokens.spacingL)
                    .background(Color.atbCardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radiusL))
                    .shadow(color: Color.black.opacity(0.04), radius: 2, y: 1)
            } else if model.lastError != nil {
                // 网络/服务故障:卡片显示横杠(—),表示数值不可用
                UsageCard(title: "5小时限额", percentage: nil, resetText: nil,
                          color: .atbBlue, isLoading: false, thresholdConfig: model.thresholdConfig,
                          dataUnavailable: true)
                UsageCard(title: "7天限额", percentage: nil, resetText: nil,
                          color: .orange, isLoading: false, thresholdConfig: model.thresholdConfig,
                          dataUnavailable: true)
            } else {
                Text("加载中…").foregroundStyle(.atbTextSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DesignTokens.spacingL)
                    .background(Color.atbCardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radiusL))
                    .shadow(color: Color.black.opacity(0.04), radius: 2, y: 1)
            }
        }
    }

    /// 数据时间戳行:对齐官方"最后统计时间"。刷新失败但保留旧数据时显示橙色告警,
    /// 避免面板静默展示过期值(2026-08-03 事故:旧值连显 7 小时无任何提示)。
    private var aliyunStatusRow: some View {
        HStack(alignment: .top, spacing: 6) {
            if let err = model.lastError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9)).foregroundStyle(.orange)
                Text("刷新失败:\(err)(显示 \(Self.statusTimeText(model.lastUpdated)) 的旧数据)")
                    .font(.system(size: 9)).foregroundStyle(.orange)
                    .lineLimit(2)
            } else {
                Text("最后统计时间 \(Self.statusTimeText(model.lastUpdated))")
                    .font(.system(size: 9)).foregroundStyle(.atbTextTertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 2)
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

    private var actionButtons: some View {
        HStack(spacing: DesignTokens.spacingS) {
            ActionButton(title: "刷新", icon: "arrow.clockwise") {
                Task {
                    await model.refreshFull()
                    await model.refreshOpenCode()
                    await model.refreshKimi()
                }
            }
            ActionButton(title: "控制台", icon: "globe") { NSWorkspace.shared.open(consoleURL) }
            ActionButton(title: "设置", icon: "gearshape") { SettingsWindowManager.shared.show() }
            ActionButton(title: "退出", icon: "power") { NSApplication.shared.terminate(nil) }
        }
    }

    private func subscriptionRow(_ sub: SubscriptionDetail) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingS - 2) {
            HStack(spacing: DesignTokens.spacingS) {
                Text("\(sub.specDisplay) 套餐").font(.system(size: 13, weight: .medium)).foregroundStyle(.atbTextPrimary)
                tagPill(sub.statusDisplay, color: .green)
                if sub.autoRenewFlag {
                    tagPill("自动续费", color: .atbBlue)
                }
                Spacer()
                let days = sub.remainingDays
                Text(days <= 0 ? "已到期" : "剩余 \(days) 天")
                    .font(.system(size: 12, weight: days <= 7 ? .semibold : .regular))
                    .foregroundStyle(days <= 0 ? .atbCritical : (days <= 7 ? .orange : .atbTextSecondary))
            }
            if let end = sub.endTimeMs.map({ Self.detailDateText(TimeInterval($0) / 1000) }) {
                HStack(spacing: DesignTokens.spacingXS) {
                    Image(systemName: "calendar").font(.system(size: 9)).foregroundStyle(.atbTextTertiary)
                    Text("有效期至 \(end)")
                        .font(.system(size: 10)).foregroundStyle(.atbTextTertiary)
                }
            }
        }
        .padding(.horizontal, DesignTokens.spacingM).padding(.vertical, DesignTokens.spacingS + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.atbCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radiusM))
        .shadow(color: Color.black.opacity(0.04), radius: 2, y: 1)
    }

    /// 加购资源包行:此前数据拉取了但从未展示(P1-B1)。
    private func addonRow(_ addon: AddonSummary) -> some View {
        HStack(spacing: DesignTokens.spacingS) {
            Image(systemName: "wallet.pass").font(.system(size: 12)).foregroundStyle(.orange)
            Text("加购资源包").font(.system(size: 13, weight: .medium)).foregroundStyle(.atbTextPrimary)
            Text("\(addon.activeCount) 个生效")
                .font(.system(size: 9, weight: .medium)).foregroundStyle(.atbTextSecondary)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Color.atbSeparator)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radiusS - 2))
            Spacer()
            if addon.totalCredits > 0 {
                Text("剩余 \(Self.creditsText(addon.remainingCredits)) / \(Self.creditsText(addon.totalCredits))")
                    .font(.system(size: 12)).monospacedDigit().foregroundStyle(.atbTextSecondary)
            } else {
                Text("—").font(.system(size: 12)).foregroundStyle(.atbTextTertiary)
            }
        }
        .padding(.horizontal, DesignTokens.spacingM).padding(.vertical, DesignTokens.spacingS + 2)
        .background(Color.atbCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radiusM))
        .shadow(color: Color.black.opacity(0.04), radius: 2, y: 1)
    }

    /// credits 数值展示:整数不带小数,其余保留 1 位。
    private static func creditsText(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }

    private static func detailDateText(_ seconds: TimeInterval) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date(timeIntervalSince1970: seconds))
    }

    private func tagPill(_ text: String, color: Color) -> some View {
        Text(text).font(.system(size: 9, weight: .medium)).foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.12)).clipShape(RoundedRectangle(cornerRadius: DesignTokens.radiusS - 2))
    }
}

// MARK: - 用量卡片(统一视觉 token:阿里云 5h/7d + OpenCode 三窗口共用)

/// 用量卡片。**所有用量窗口共用此组件**,保证设计 token 完全一致。
/// 数据源与视觉解耦:`percentage`/`resetText` 由调用方从
/// UsageDetail(阿里云)或 OpenCodeWindow(OpenCode)提取。
/// 对齐官方控制台:2 位小数精度 + 带刻度进度条(0/50/90/100) + 完整重置时间。
/// 当 `dataUnavailable` 为 true 时,数值显示为横杠(—),表示服务/网络不可用。
struct UsageCard: View {
    let title: String
    /// 百分比值(0–100 浮点,2 位小数精度)。nil = 加载中。
    let percentage: Double?
    let resetText: String?
    let color: Color
    let isLoading: Bool
    /// 阈值配置:进度条按风险变色(safe→color / warning→橙 / critical→红)。
    var thresholdConfig: ThresholdConfig = ThresholdConfig()
    /// 是否显示 sparkline(由面板按全局开关传入)。
    var showSparkline: Bool = false
    /// sparkline 数据序列标识(aliyun 5h/7d、opencode rolling/weekly/monthly)。
    var sparklineProvider: String = "aliyun"
    var sparklineWindow: String = "7d"
    /// 紧凑模式:true 单行高密度(推荐,默认);false 全尺寸展开(大字号)。
    var compact: Bool = true
    /// 数据不可用(服务/网络故障):显示横杠而非数值。
    var dataUnavailable: Bool = false

    var body: some View {
        if compact { compactBody } else { fullBody }
    }

    /// 百分比显示文本:2 位小数,对齐官方。
    private var pctDisplayText: String {
        guard let pct = percentage else { return "—" }
        return String(format: "%.2f%%", pct)
    }

    /// 阈值色(用整数部分判定 band,避免 0.26% 误触 warning)。
    private var thresholdPctInt: Int { Int((percentage ?? 0).rounded()) }

    /// 紧凑卡:对齐官方控制台布局——标题+重置时间 / 百分比已用 / 带刻度进度条。
    private var compactBody: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingS) {
            // 上层:标题 + 重置时间
            HStack {
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.atbTextPrimary)
                Spacer()
                if dataUnavailable {
                    Text("—").font(.system(size: 10)).foregroundStyle(.atbTextTertiary)
                } else if let reset = resetText {
                    Text("将于 \(reset) 重置刷新")
                        .font(.system(size: 9)).foregroundStyle(.atbTextTertiary)
                        .lineLimit(1)
                }
            }
            // 中层:百分比数值 + "已用" 标签
            HStack(spacing: DesignTokens.spacingXS) {
                if isLoading {
                    LoadingRing().frame(width: 14, height: 14)
                } else if dataUnavailable {
                    Text("—").font(.system(size: 15, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.atbTextTertiary)
                } else {
                    Text(pctDisplayText)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(thresholdColor(thresholdPctInt, config: thresholdConfig, base: .atbTextPrimary))
                    Text("已用").font(.system(size: 10)).foregroundStyle(.atbTextTertiary)
                }
            }
            // 下层:带刻度进度条(0% / 50% / 90% / 100%)
            scaledProgressBar
            if showSparkline && !dataUnavailable {
                UsageSparkline(provider: sparklineProvider, window: sparklineWindow, color: color, height: 16)
                LimitEstimateLabel(provider: sparklineProvider, window: sparklineWindow)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, DesignTokens.spacingM).padding(.vertical, DesignTokens.spacingS + 2)
        .frame(maxWidth: .infinity)
        .background(Color.atbCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radiusM))
        .shadow(color: Color.black.opacity(0.04), radius: 2, y: 1)
    }

    /// 全尺寸卡:大数字 + 带刻度进度条 + 重置时间 + sparkline。
    private var fullBody: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingS + 2) {
            Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(.atbTextPrimary)
            // 百分比数值
            ZStack(alignment: .leading) {
                if isLoading {
                    LoadingRing().frame(width: 24, height: 24)
                } else if dataUnavailable {
                    Text("—").font(.system(size: 32, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.atbTextTertiary)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: DesignTokens.spacingXS) {
                        Text(pctDisplayText)
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(thresholdColor(thresholdPctInt, config: thresholdConfig, base: .atbTextPrimary))
                        Text("已用").font(.system(size: 12)).foregroundStyle(.atbTextTertiary)
                    }
                }
            }.frame(height: 38)
            // 带刻度进度条
            scaledProgressBar
            // 重置时间
            if dataUnavailable {
                Text("—").font(.system(size: 11)).foregroundStyle(.atbTextTertiary)
            } else if let reset = resetText {
                Text("将于 \(reset) 重置刷新").font(.system(size: 10)).foregroundStyle(.atbTextTertiary)
            }
            if showSparkline && !dataUnavailable {
                UsageSparkline(provider: sparklineProvider, window: sparklineWindow, color: color)
            }
        }
        .padding(DesignTokens.spacingL).frame(maxWidth: .infinity)
        .background(Color.atbCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radiusL))
        .shadow(color: Color.black.opacity(0.04), radius: 2, y: 1)
    }

    /// 带刻度标记的进度条:对齐官方 0% / 50% / 90% / 100% 四档刻度线。
    private var scaledProgressBar: some View {
        VStack(spacing: 2) {
            GeometryReader { proxy in
                let w = proxy.size.width
                ZStack(alignment: .leading) {
                    // 底轨
                    Capsule().frame(height: 6).foregroundStyle(Color.primary.opacity(0.10))
                    // 填充
                    if !dataUnavailable, let pct = percentage {
                        Capsule()
                            .frame(width: w * CGFloat(min(pct, 100)) / 100, height: 6)
                            .foregroundStyle(thresholdColor(thresholdPctInt, config: thresholdConfig, base: color))
                    }
                    // 刻度线:50% / 90%(0% 和 100% 在两端不需要额外标记)
                    ForEach([50, 90], id: \.self) { tick in
                        Rectangle()
                            .frame(width: 1, height: 10)
                            .foregroundStyle(Color.primary.opacity(0.25))
                            .offset(x: w * CGFloat(tick) / 100 - 0.5)
                    }
                }
            }.frame(height: 10)
            // 刻度标签
            HStack(spacing: 0) {
                Text("0%").font(.system(size: 8)).foregroundStyle(.atbTextSecondary)
                Spacer()
                Text("50%").font(.system(size: 8)).foregroundStyle(.atbTextSecondary)
                Spacer()
                Text("90%").font(.system(size: 8)).foregroundStyle(.atbTextSecondary)
                Spacer()
                Text("100%").font(.system(size: 8)).foregroundStyle(.atbTextSecondary)
            }
        }
    }
}

// MARK: - 阿里云鉴权内联提示卡

/// 阿里云 tab 内的鉴权异常提示卡(未装 bl / 未登录 / token 失效)。
/// 内联而非全屏遮罩:其他 Provider 标签与面板按钮始终可用
/// (2026-08-03 用户反馈修复:全屏遮罩导致 token 失效时整面板不可用)。
struct AliyunAuthCard: View {
    @StateObject private var model = TokenPlanModel.shared
    @State private var copied = false
    var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: DesignTokens.spacingS) {
                Image(systemName: iconName).font(.system(size: 28)).foregroundStyle(.orange)
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(.atbTextPrimary)
                if model.authState == .blNotInstalled {
                    blInstallGuide
                } else {
                    Text(hint).font(.system(size: 11)).foregroundStyle(.atbTextSecondary).multilineTextAlignment(.center)
                    if model.aliyunAKSKConfiguring {
                        HStack(spacing: DesignTokens.spacingS - 2) {
                            ProgressView().controlSize(.small)
                            Text("正在自动恢复登录状态…")
                                .font(.system(size: 10))
                                .foregroundStyle(.atbTextSecondary)
                        }
                    } else {
                        reloginButton
                    }
                    if let failedAt = model.aliyunAutoRecoveryFailedAt,
                       AliyunAuthRecovery.inCooldown(
                           failedAt: failedAt, now: Date(),
                           cooldownMinutes: max(model.refreshIntervalMinutes * 2, 10)) {
                        Text("自动恢复已暂停，稍后将重试。如需立即恢复请点击「使用 AK/SK 配置」。")
                            .font(.system(size: 10))
                            .foregroundStyle(.atbTextTertiary)
                            .multilineTextAlignment(.center)
                    }
                    if !model.aliyunAKSKConfigured && !model.aliyunAKSKConfiguring {
                        Button {
                            AliyunAKSKWindowManager.shared.show()
                        } label: {
                            Label("使用 AK/SK 配置（推荐，自动刷新）", systemImage: "key.fill")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(ATBTextButtonStyle())
                        .padding(.top, DesignTokens.spacingXS)
                        .help("配置一次后自动续期阿里云登录状态")
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(DesignTokens.spacingL)
            .background(Color.atbCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radiusL))
            .shadow(color: Color.black.opacity(0.04), radius: 2, y: 1)
        }
    }

    /// 重新登录按钮:点击后拉起浏览器并轮询,登录完成自动恢复数据(无需手动操作)。
    private var reloginButton: some View {
        VStack(spacing: DesignTokens.spacingS - 2) {
            Button {
                model.relogin()
            } label: {
                HStack(spacing: DesignTokens.spacingS - 2) {
                    if model.isReloginWatching { LoadingRing().frame(width: 12, height: 12) }
                    Text("重新登录")
                }
            }
            .buttonStyle(ATBPrimaryButtonStyle())
            if model.isReloginWatching {
                Text("已打开浏览器,登录完成后自动刷新…")
                    .font(.system(size: 10)).foregroundStyle(.atbTextTertiary)
            }
        }
    }

    /// 未装 bl 时的安装引导:安装命令(可复制)+ Node.js 要求链接
    private var blInstallGuide: some View {
        VStack(spacing: DesignTokens.spacingS + 2) {
            Text("CodingTokenBar 依赖百炼 CLI (bl) 获取套餐用量,但未检测到 bl。")
                .font(.system(size: 12)).foregroundStyle(.atbTextSecondary)
                .multilineTextAlignment(.center)
            // 安装命令框
            HStack(spacing: DesignTokens.spacingS) {
                Text("npm install -g bailian-cli")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.atbTextPrimary)
                    .padding(.horizontal, DesignTokens.spacingM).padding(.vertical, DesignTokens.spacingS - 2)
                    .background(Color.atbSeparator)
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radiusS))
                    .textSelection(.enabled)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("npm install -g bailian-cli", forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 12)).foregroundStyle(.atbTextSecondary)
                }.buttonStyle(.plain)
            }
            // Node.js 要求 + 官方文档链接
            VStack(spacing: DesignTokens.spacingXS) {
                Text("需要 Node.js 18+").font(.system(size: 10)).foregroundStyle(.atbTextTertiary)
                HStack(spacing: DesignTokens.spacingL - DesignTokens.spacingXS) {
                    Link("Node.js 下载", destination: URL(string: "https://nodejs.org/")!)
                        .font(.system(size: 11)).foregroundStyle(.atbBlue)
                    Link("百炼 CLI 文档", destination: URL(string: "https://bailian.console.aliyun.com/cli/install.md")!)
                        .font(.system(size: 11)).foregroundStyle(.atbBlue)
                }
            }
            Text("安装后重启 CodingTokenBar").font(.system(size: 10)).foregroundStyle(.atbTextTertiary)
        }
    }

    private var iconName: String { model.authState == .blNotInstalled ? "exclamationmark.triangle" : "lock.rotation" }
    private var title: String {
        switch model.authState {
        case .blNotInstalled: return "无法使用:未安装 bl CLI"
        case .notLoggedIn: return "请先登录百炼控制台"
        case .expired: return "控制台登录已过期"
        default: return ""
        }
    }
    private var hint: String {
        switch model.authState {
        case .notLoggedIn: return "点击下方登录(将打开浏览器授权)"
        case .expired: return "token 已失效,点击下方重新登录"
        default: return ""
        }
    }
}

/// bl 版本检查行:已装版本 + 有新版本时一键更新(可忽略)。
/// 仅当 bl 已装时显示。
struct BlVersionRow: View {
    @StateObject private var model = TokenPlanModel.shared
    @State private var updating = false
    var body: some View {
        HStack(spacing: DesignTokens.spacingS - 2) {
            Image(systemName: "terminal").font(.system(size: 11)).foregroundStyle(.atbTextTertiary)
            if let v = model.blInstalledVersion {
                Text("bl \(v)").font(.system(size: 11)).foregroundStyle(.atbTextTertiary)
            } else {
                Text("bl 版本未知").font(.system(size: 11)).foregroundStyle(.atbTextTertiary)
            }
            Spacer()
            if model.blUpdateAvailable, let latest = model.blLatestVersion {
                Text("可更新至 \(latest)").font(.system(size: 10)).foregroundStyle(.orange)
                if updating {
                    LoadingRing().frame(width: 10, height: 10)
                } else {
                    Button("更新") {
                        updating = true
                        BlAuthManager.updateBl()
                        // P1-C5:在 Terminal 里安装后轮询版本变化(最长 2.5 分钟),完成后自动刷新版本行
                        let before = model.blInstalledVersion
                        Task {
                            for _ in 0..<30 {
                                try? await Task.sleep(nanoseconds: 5_000_000_000)
                                await model.checkBlVersion()
                                if model.blInstalledVersion != before { break }
                            }
                            updating = false
                        }
                    }
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(.atbBlue).buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, DesignTokens.spacingL - DesignTokens.spacingXS).padding(.vertical, DesignTokens.spacingS)
        .background(Color.atbCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radiusM))
        .shadow(color: Color.black.opacity(0.04), radius: 2, y: 1)
    }
}

// MARK: - OpenCode Go 用量卡

/// OpenCode Go 套餐用量(rolling/weekly/monthly 三窗口)。
/// 与阿里云区域共用 UsageCard——同一套设计 token(紧凑卡/进度条/sparkline)。
/// 仅在用户配置了 cookie+workspace 后显示。
struct OpenCodeCard: View {
    @StateObject private var model = TokenPlanModel.shared
    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingM) {
            // 品牌头部行:紫色闪电 + 刷新(OpenCode 专属)
            HStack(spacing: DesignTokens.spacingS) {
                Image(systemName: "bolt.fill").font(.system(size: 13, weight: .bold)).foregroundStyle(.purple)
                Text("OpenCode Go").font(.system(size: 13, weight: .medium)).foregroundStyle(.atbTextPrimary)
                Spacer()
                Button { Task { await model.refreshOpenCode() } } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 12)).foregroundStyle(.atbTextTertiary)
                }.buttonStyle(.plain)
            }
            if let q = model.openCodeQuota {
                // 三窗口各一张卡片,视觉 token 与阿里云 5h/7d 完全一致
                UsageCard(title: "滚动限额",
                          percentage: Double(q.rolling.pct), resetText: q.rolling.rollingResetText,
                          color: .purple, isLoading: model.isLoading, thresholdConfig: model.thresholdConfig,
                          showSparkline: model.sparklineEnabled,
                          sparklineProvider: "opencode", sparklineWindow: "rolling")
                UsageCard(title: "每周限额",
                          percentage: Double(q.weekly.pct), resetText: q.weekly.timeUntilReset,
                          color: .atbBlue, isLoading: model.isLoading, thresholdConfig: model.thresholdConfig,
                          showSparkline: model.sparklineEnabled,
                          sparklineProvider: "opencode", sparklineWindow: "weekly")
                UsageCard(title: "每月限额",
                          percentage: Double(q.monthly.pct), resetText: q.monthly.timeUntilReset,
                          color: .orange, isLoading: model.isLoading, thresholdConfig: model.thresholdConfig,
                          showSparkline: model.sparklineEnabled,
                          sparklineProvider: "opencode", sparklineWindow: "monthly")
            } else if let err = model.openCodeError {
                // 网络/服务故障:卡片显示横杠(—),表示数值不可用
                let isNetworkError = err.contains("网络") || err.contains("响应") || err.contains("解析")
                if isNetworkError {
                    UsageCard(title: "滚动限额", percentage: nil, resetText: nil,
                              color: .purple, isLoading: false, thresholdConfig: model.thresholdConfig,
                              dataUnavailable: true)
                    UsageCard(title: "每周限额", percentage: nil, resetText: nil,
                              color: .atbBlue, isLoading: false, thresholdConfig: model.thresholdConfig,
                              dataUnavailable: true)
                    UsageCard(title: "每月限额", percentage: nil, resetText: nil,
                              color: .orange, isLoading: false, thresholdConfig: model.thresholdConfig,
                              dataUnavailable: true)
                } else {
                    // 非网络错误(cookie 过期等):保留文本提示
                    Text(err).font(.system(size: 11)).foregroundStyle(.atbTextTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(DesignTokens.spacingL)
                        .background(Color.atbCardBackground)
                        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radiusL))
                        .shadow(color: Color.black.opacity(0.04), radius: 2, y: 1)
                }
            } else {
                // 加载态:与阿里云一致的加载环
                HStack { Spacer(); LoadingRing().frame(width: 18, height: 18); Spacer() }
                    .padding(DesignTokens.spacingL)
                    .frame(maxWidth: .infinity)
                    .background(Color.atbCardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radiusL))
                    .shadow(color: Color.black.opacity(0.04), radius: 2, y: 1)
            }
        }
        .padding(DesignTokens.spacingL)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Kimi Code 用量卡

/// Kimi Code 套餐用量(5h/周/月度总额 + 加油包)。
/// 与阿里云/OpenCode 共用 UsageCard——同一套设计 token(2 位小数/带刻度进度条)。
/// 仅在检测到本机 KimiCodeBar / Kimi CLI 凭证后显示。
struct KimiCodeCard: View {
    @StateObject private var model = TokenPlanModel.shared
    @State private var showKimiLogin = false
    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingM) {
            // 品牌头部行:青色闪电 + 刷新(Kimi 专属)
            HStack(spacing: DesignTokens.spacingS) {
                Image(systemName: "sparkles").font(.system(size: 13, weight: .bold)).foregroundStyle(.teal)
                Text("Kimi Code").font(.system(size: 13, weight: .medium)).foregroundStyle(.atbTextPrimary)
                if let level = model.kimiQuota?.membershipLevel {
                    Text(levelDisplay(level)).font(.system(size: 9, weight: .medium)).foregroundStyle(.teal)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.teal.opacity(0.12)).clipShape(RoundedRectangle(cornerRadius: DesignTokens.radiusS - 2))
                }
                Spacer()
                Button { Task { await model.refreshKimi() } } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 12)).foregroundStyle(.atbTextTertiary)
                }.buttonStyle(.plain)
            }
            if let q = model.kimiQuota {
                // 三窗口各一张卡片,视觉 token 与阿里云 5h/7d 完全一致
                UsageCard(title: "5小时限额",
                          percentage: q.fiveHour.pct, resetText: q.fiveHour.slidingResetText,
                          color: .teal, isLoading: model.isLoading, thresholdConfig: model.thresholdConfig,
                          showSparkline: model.sparklineEnabled,
                          sparklineProvider: "kimi", sparklineWindow: "5h")
                UsageCard(title: "每周限额",
                          percentage: q.weekly.pct, resetText: q.weekly.resetTimeDisplay,
                          color: .indigo, isLoading: model.isLoading, thresholdConfig: model.thresholdConfig,
                          showSparkline: model.sparklineEnabled,
                          sparklineProvider: "kimi", sparklineWindow: "weekly")
                if let balance = q.subscriptionBalance {
                    KimiSubscriptionCard(balance: balance)
                } else if model.kimiWebLoggedIn {
                    UsageCard(title: "总使用量", percentage: nil, resetText: nil,
                              color: .orange, isLoading: false, thresholdConfig: model.thresholdConfig,
                              dataUnavailable: true)
                }
                if let booster = q.booster, booster.enabled {
                    KimiBoosterRow(booster: booster)
                }
                if !model.kimiWebLoggedIn {
                    kimiWebLoginHint
                }
            } else if let err = model.kimiError {
                // 网络/服务故障:卡片显示横杠(—),表示数值不可用
                let isNetworkError = err.contains("网络") || err.contains("响应") || err.contains("解析")
                if isNetworkError {
                    UsageCard(title: "5小时限额", percentage: nil, resetText: nil,
                              color: .teal, isLoading: false, thresholdConfig: model.thresholdConfig,
                              dataUnavailable: true)
                    UsageCard(title: "每周限额", percentage: nil, resetText: nil,
                              color: .indigo, isLoading: false, thresholdConfig: model.thresholdConfig,
                              dataUnavailable: true)
                    UsageCard(title: "月度总额度", percentage: nil, resetText: nil,
                              color: .orange, isLoading: false, thresholdConfig: model.thresholdConfig,
                              dataUnavailable: true)
                } else {
                    Text(err).font(.system(size: 11)).foregroundStyle(.atbTextTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(DesignTokens.spacingL)
                        .background(Color.atbCardBackground)
                        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radiusL))
                        .shadow(color: Color.black.opacity(0.04), radius: 2, y: 1)
                }
            } else {
                // 加载态:与阿里云一致的加载环
                HStack { Spacer(); LoadingRing().frame(width: 18, height: 18); Spacer() }
                    .padding(DesignTokens.spacingL)
                    .frame(maxWidth: .infinity)
                    .background(Color.atbCardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radiusL))
                    .shadow(color: Color.black.opacity(0.04), radius: 2, y: 1)
            }
        }
        .padding(DesignTokens.spacingL)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 登录网页控制台引导行(未登录时显示,用于获取订阅总额度)。
    private var kimiWebLoginHint: some View {
        HStack(spacing: DesignTokens.spacingS) {
            Image(systemName: "lock.open").font(.system(size: 11)).foregroundStyle(.atbTextTertiary)
            Text("登录 Kimi 网页控制台查看订阅总额度").font(.system(size: 10)).foregroundStyle(.atbTextTertiary)
            Spacer()
            Button("登录") { showKimiLogin = true }
                .buttonStyle(ATBTextButtonStyle(color: .teal)).font(.system(size: 11, weight: .medium))
        }
        .padding(.horizontal, DesignTokens.spacingM).padding(.vertical, DesignTokens.spacingS)
        .background(Color.atbCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radiusM))
        .shadow(color: Color.black.opacity(0.04), radius: 2, y: 1)
        .sheet(isPresented: $showKimiLogin) { KimiLoginView() }
    }

    /// 会员等级映射:LEVEL_* → 官方名称(未知等级去前缀美化)。
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

/// Kimi 共享订阅池:Work/Kimi 与 Code 分段显示,总量只使用共享池分母。
struct KimiSubscriptionCard: View {
    let balance: KimiSubscriptionBalance

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingS + 1) {
            HStack {
                Text("总使用量")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.atbTextPrimary)
                Spacer()
                Text(String(format: "%.2f%%", balance.totalUsedPercent))
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.atbTextPrimary)
            }

            GeometryReader { proxy in
                HStack(spacing: 0) {
                    if let work = balance.workUsedPercent,
                       let code = balance.codeUsedPercent {
                        Rectangle()
                            .fill(Color.primary)
                            .frame(width: proxy.size.width * CGFloat(work / 100))
                        Rectangle()
                            .fill(Color.atbBlue)
                            .frame(width: proxy.size.width * CGFloat(code / 100))
                    } else {
                        Rectangle()
                            .fill(Color.atbBlue)
                            .frame(width: proxy.size.width * CGFloat(balance.totalUsedPercent / 100))
                    }
                    Rectangle()
                        .fill(Color.primary.opacity(0.10))
                }
                .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .frame(height: 8)

            HStack(spacing: 12) {
                if let work = balance.workUsedPercent,
                   let code = balance.codeUsedPercent {
                    KimiSubscriptionLegend(color: .primary, title: "Kimi/Work", percent: work)
                    KimiSubscriptionLegend(color: .atbBlue, title: "Code", percent: code)
                } else {
                    Text("Work/Code 分项暂不可用")
                        .font(.system(size: 10))
                        .foregroundStyle(.atbTextTertiary)
                }
                Spacer(minLength: 0)
            }

            if let ms = balance.expireTimeMs {
                Text("重置时间 \(Self.dateText(ms))")
                    .font(.system(size: 9))
                    .foregroundStyle(.atbTextTertiary)
            }
        }
        .padding(.horizontal, DesignTokens.spacingM)
        .padding(.vertical, DesignTokens.spacingS + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.atbCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radiusM))
        .shadow(color: Color.black.opacity(0.04), radius: 2, y: 1)
    }

    private static func dateText(_ ms: Int64) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(ms) / 1000))
    }
}

struct KimiSubscriptionLegend: View {
    let color: Color
    let title: String
    let percent: Double

    var body: some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 8, height: 8)
            Text("\(title) \(String(format: "%.2f%%", percent))")
                .font(.system(size: 10))
                .foregroundStyle(.atbTextSecondary)
                .monospacedDigit()
        }
    }
}

/// 加油包余额行:余额 + 本月消费/上限。
struct KimiBoosterRow: View {
    let booster: KimiBooster
    var body: some View {
        HStack(spacing: DesignTokens.spacingS) {
            Image(systemName: "wallet.pass.fill").font(.system(size: 12)).foregroundStyle(.orange)
            Text("加油包余额").font(.system(size: 11, weight: .medium)).foregroundStyle(.atbTextPrimary)
            Text(String(format: "¥%.2f", booster.balanceYuan))
                .font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(.atbTextPrimary)
            Spacer()
            Text(String(format: "本月消费 ¥%.2f", booster.monthlyUsedYuan))
                .font(.system(size: 10)).foregroundStyle(.atbTextTertiary)
        }
        .padding(.horizontal, DesignTokens.spacingM).padding(.vertical, DesignTokens.spacingS)
        .background(Color.atbCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radiusM))
        .shadow(color: Color.black.opacity(0.04), radius: 2, y: 1)
    }
}

// MARK: - 复用小组件

struct ActionButton: View {
    let title: String; let icon: String; let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: DesignTokens.spacingXS) {
                Image(systemName: icon).font(.system(size: 16))
                Text(title).font(.system(size: 11))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, DesignTokens.spacingS)
        }
        .buttonStyle(ATBSecondaryButtonStyle())
    }
}

struct LoadingRing: View {
    @State private var rotate = false
    var body: some View {
        Image(systemName: "circle.dashed")
            .rotationEffect(.degrees(rotate ? 360 : 0))
            .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: rotate)
            .onAppear { rotate = true }
    }
}

// MARK: - 本机进程(CPU/内存 Top 10 + kill)

/// 面板「本机」tab:分段显示 CPU/内存占用前 10 进程,可两步确认 kill(SIGKILL)。
/// 数据源:ProcessListMonitor(libproc,3s 采样,面板关闭即停)。
struct SystemProcessesCard: View {
    enum SubTab: String, CaseIterable, Identifiable {
        case cpu, memory
        var id: String { rawValue }
        var title: String { self == .cpu ? "CPU" : "内存" }
    }

    @State private var subTab: SubTab = .cpu
    /// 两步确认 kill:确认中的 pid + 到期时间(3 秒未二次点击自动还原)。
    @State private var confirmingPid: Int32?
    @State private var confirmDeadline: Date = .distantPast

    @ObservedObject private var monitor = ProcessListMonitor.shared

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingM) {
            header
            subTabPicker
            processList
        }
        .padding(DesignTokens.spacingL)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { monitor.start() }
        .onDisappear {
            monitor.stop()
            confirmingPid = nil
        }
    }

    private var header: some View {
        HStack(spacing: DesignTokens.spacingS) {
            Image(systemName: "cpu").font(.system(size: 13, weight: .bold)).foregroundStyle(.green)
            Text("本机进程").font(.system(size: 13, weight: .medium)).foregroundStyle(.atbTextPrimary)
            Spacer()
            Button { monitor.refreshNow() } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 12)).foregroundStyle(.atbTextTertiary)
            }.buttonStyle(.plain)
        }
    }

    private var subTabPicker: some View {
        HStack(spacing: DesignTokens.spacingXS) {
            ForEach(SubTab.allCases) { t in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { subTab = t }
                } label: {
                    Text(t.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(subTab == t ? .white : .atbTextSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(subTab == t ? Color.atbBlue : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radiusS))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(DesignTokens.spacingXS - 1)
        .background(Color.atbCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radiusM))
    }

    /// 当前子页签的 Top 10 列表。
    private var topList: [ProcessSnapshot] {
        switch subTab {
        case .cpu: return ProcessListMonitor.topByCPU(monitor.snapshots)
        case .memory: return ProcessListMonitor.topByMemory(monitor.snapshots)
        }
    }

    private var processList: some View {
        let list = topList
        let maxValue: Double = {
            switch subTab {
            case .cpu: return list.compactMap(\.cpuPercent).max() ?? 1
            case .memory: return Double(list.map(\.memoryBytes).max() ?? 1)
            }
        }()
        return VStack(spacing: DesignTokens.spacingS - 2) {
            if list.isEmpty {
                HStack { Spacer(); LoadingRing().frame(width: 18, height: 18); Spacer() }
                    .padding(DesignTokens.spacingL)
                    .background(Color.atbCardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radiusM))
                    .shadow(color: Color.black.opacity(0.04), radius: 2, y: 1)
            } else {
                ForEach(list) { p in
                    ProcessRow(snapshot: p, subTab: subTab, maxValue: maxValue,
                               isConfirming: confirmingPid == p.pid && Date() < confirmDeadline,
                               onKill: { killTapped(p) })
                }
            }
        }
    }

    /// kill 两步确认:第一次点 → 进入确认态;3 秒内第二次点 → SIGKILL;root 进程不可点。
    /// 超时还原:asyncAfter 到期后若仍处于确认态则清除(二次点击已杀成功时 confirmingPid 已置 nil,不会误清)。
    private func killTapped(_ p: ProcessSnapshot) {
        guard !p.isRoot else { return }
        if confirmingPid == p.pid, Date() < confirmDeadline {
            _ = ProcessListMonitor.kill(p.pid)   // 失败静默:下轮刷新该行自然消失
            confirmingPid = nil
        } else {
            confirmingPid = p.pid
            confirmDeadline = Date().addingTimeInterval(3)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                if confirmingPid == p.pid, confirmDeadline <= Date() { confirmingPid = nil }
            }
        }
    }
}

/// 进程行:app 图标 + 名称(副行进程名)+ 数值 + 迷你进度条 + kill 按钮。
private struct ProcessRow: View {
    let snapshot: ProcessSnapshot
    let subTab: SystemProcessesCard.SubTab
    let maxValue: Double
    let isConfirming: Bool
    let onKill: () -> Void

    var body: some View {
        HStack(spacing: DesignTokens.spacingS) {
            procIcon
            VStack(alignment: .leading, spacing: 1) {
                Text(snapshot.appName)
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.atbTextPrimary)
                    .lineLimit(1)
                if snapshot.name != snapshot.appName {
                    Text(snapshot.name)
                        .font(.system(size: 9)).foregroundStyle(.atbTextTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: DesignTokens.spacingXS)
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: DesignTokens.spacingXS) {
                    Text(valueText)
                        .font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(.atbTextPrimary)
                    if snapshot.isRoot {
                        Text("系统")
                            .font(.system(size: 8, weight: .medium)).foregroundStyle(.atbTextTertiary)
                            .padding(.horizontal, 3).padding(.vertical, 1)
                            .background(Color.atbSeparator)
                            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radiusS - 3))
                    }
                }
                miniBar
            }
            killButton
        }
        .padding(.horizontal, DesignTokens.spacingM).padding(.vertical, 7)
        .background(Color.atbCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radiusM))
        .shadow(color: Color.black.opacity(0.04), radius: 2, y: 1)
    }

    /// app 图标(.app 进程)或齿轮占位。
    @ViewBuilder
    private var procIcon: some View {
        if let appPath = snapshot.appPath {
            Image(nsImage: NSWorkspace.shared.icon(forFile: appPath))
                .resizable().frame(width: 20, height: 20)
        } else {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 14)).foregroundStyle(.atbTextTertiary)
                .frame(width: 20, height: 20)
        }
    }

    /// 数值:CPU 不钳制可 >100%,首采 nil → 横杠;内存人类可读。
    private var valueText: String {
        switch subTab {
        case .cpu:
            guard let pct = snapshot.cpuPercent else { return "—" }
            return String(format: "%.1f%%", pct)
        case .memory:
            return ProcessListMonitor.bytesToHuman(snapshot.memoryBytes)
        }
    }

    /// 迷你进度条:相对本列表最大值(视觉参考,非 100% 上限)。
    private var miniBar: some View {
        let value: Double = {
            switch subTab {
            case .cpu: return snapshot.cpuPercent ?? 0
            case .memory: return Double(snapshot.memoryBytes)
            }
        }()
        let ratio = maxValue > 0 ? min(value / maxValue, 1) : 0
        return GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().frame(height: 3).foregroundStyle(Color.primary.opacity(0.10))
                Capsule().frame(width: proxy.size.width * CGFloat(ratio), height: 3)
                    .foregroundStyle(Color.atbBlue.opacity(0.7))
            }
        }
        .frame(width: 64, height: 3)
    }

    /// kill 按钮:root 置灰;确认态红色文字"确认?";常态 xmark.circle。
    private var killButton: some View {
        Button(action: onKill) {
            if isConfirming {
                Text("确认?")
                    .font(.system(size: 10, weight: .bold)).foregroundStyle(.atbCritical)
                    .padding(.horizontal, DesignTokens.spacingS - 2).padding(.vertical, 3)
                    .background(Color.atbCritical.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radiusS - 1))
            } else {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(snapshot.isRoot ? Color.atbTextTertiary.opacity(0.35) : .atbTextSecondary)
            }
        }
        .buttonStyle(.plain)
        .disabled(snapshot.isRoot)
    }
}

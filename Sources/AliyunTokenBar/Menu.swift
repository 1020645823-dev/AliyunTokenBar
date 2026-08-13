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

/// 面板 Provider 标签页(节省空间:多个 Provider 上下堆叠会超出屏幕)。
enum ProviderTab: String, CaseIterable, Identifiable {
    case aliyun
    case opencode
    case kimi
    case deepSeek
    case system
    var id: String { rawValue }
    var title: String {
        switch self {
        case .aliyun: return "阿里云"
        case .opencode: return "OpenCode"
        case .kimi: return "Kimi"
        case .deepSeek: return "DeepSeek"
        case .system: return "本机"
        }
    }
    var icon: String {
        switch self {
        case .aliyun: return "cloud.fill"
        case .opencode: return "bolt.fill"
        case .kimi: return "sparkles"
        case .deepSeek: return "brain.head.profile"
        case .system: return "cpu"
        }
    }
}

struct TokenPlanMenu: View {
    @StateObject private var model = TokenPlanModel.shared
    @State private var selectedTab: ProviderTab = .aliyun
    private let consoleURL = URL(string: "https://bailian.console.aliyun.com/cn-beijing?tab=plan#/efm/subscription/token-plan/personal")!

    /// 当前可用的标签页(阿里云/DeepSeek 恒有——未配置时卡片内有引导;
    /// OpenCode/Kimi 配置了才显示)。
    private var availableTabs: [ProviderTab] {
        var tabs: [ProviderTab] = [.aliyun]
        if model.openCodeConfigured { tabs.append(.opencode) }
        if model.kimiConfigured { tabs.append(.kimi) }
        tabs.append(.deepSeek)
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
            VStack(alignment: .leading, spacing: 0) {
                Text("CodingTokenBar").font(.system(size: 18, weight: .bold)).foregroundStyle(.atbTextPrimary)
                if let update = model.appUpdate {
                    Button { model.openUpdatePage() } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.down.circle.fill").font(.system(size: 8))
                            Text("新版本 \(update.version) 可用")
                                .font(.system(size: 9, weight: .medium))
                        }
                        .foregroundStyle(.orange)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("发现新版本 \(update.version),点击前往下载")
                }
            }
            Spacer()
            Button { NSWorkspace.shared.open(consoleURL) } label: {
                Image(systemName: "arrow.up.right.square").foregroundStyle(.atbTextTertiary)
            }
            .buttonStyle(.plain)
            .help("打开百炼控制台")
            .accessibilityLabel("打开百炼控制台")
        }
    }

    // MARK: 标签页切换

    /// 分段式标签栏:Provider 平铺,选中项高亮。
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
            .background(TabBackground(isSelected: isSelected))
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radiusS))
        }
        .buttonStyle(PlainTabButtonStyle(isSelected: isSelected))
        .accessibilityLabel("\(tab.title)标签页")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// 当前标签页内容。
    @ViewBuilder
    private var selectedContent: some View {
        switch effectiveTab {
        case .aliyun: aliyunContent
        case .opencode: OpenCodeCard()
        case .kimi: KimiCodeCard()
        case .deepSeek: DeepSeekCard()
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
            if model.isOffline {
                Image(systemName: "wifi.slash")
                    .font(.system(size: 9)).foregroundStyle(.orange)
                Text("离线:网络恢复后自动刷新")
                    .font(.system(size: 9)).foregroundStyle(.orange)
            } else if let err = model.lastError {
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

    /// 标签按钮背景:选中品牌蓝;未选中 hover 时轻微高亮(UI/UX 打磨)。
    private struct TabBackground: View {
        let isSelected: Bool
        @State private var hovering = false
        var body: some View {
            Group {
                if isSelected {
                    Color.atbBlue
                } else {
                    (hovering ? Color.atbTextPrimary.opacity(0.07) : Color.clear)
                }
            }
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }

    /// 标签按钮样式:未选中 hover 文字加深。
    private struct PlainTabButtonStyle: ButtonStyle {
        let isSelected: Bool
        @State private var hovering = false
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .opacity(configuration.isPressed ? 0.8 : (hovering && !isSelected ? 0.85 : 1.0))
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }

    private var actionButtons: some View {
        HStack(spacing: DesignTokens.spacingS) {
            ActionButton(title: "刷新", icon: "arrow.clockwise") {
                Task {
                    await model.refreshFull()
                    await model.refreshOpenCode()
                    await model.refreshKimi()
                    await model.refreshDeepSeek()
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


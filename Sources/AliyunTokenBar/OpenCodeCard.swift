import SwiftUI
import AppKit
import AliyunTokenBarCore

// MARK: - OpenCode Go 用量卡(多 workspace · 触顶预测)
//
// v1.0.66 视觉语言(StepFun v1.0.65 设计范式泛化):
// - 品牌行副标题带**数据更新时间**(旧版只有静态描述);
// - 三窗口环卡保留(打磨过的大数字 + 环 + 倒计时);
// - 新增**触顶预测行**:按历史速率外推到重置时刻——会触顶的窗口直接回答
//   "还有多久被限流",不会触顶的回答"重置时大约用到几成";数据不足时诚实
//   显示"积累中",不拍脑袋。
//
// v1.0.81 多 workspace(2026-10-17,用户需求:一个 opencode.ai 账户下有多个
// workspace,每个是独立订阅/独立配额):
// - 登录 cookie 全账户共享一份(Keychain 单槽);受监控 workspace 列表落 UserDefaults;
// - 登录/「发现工作区」经 `GET /console/api/user/workspaces` 拉取账户下全部
//   workspace 自动并入(端点失效可手动填 wrk_xxx);
// - 合计口径(聚合纯函数 OpenCodeQuota.aggregate):三窗口都是独立订阅池的
//   百分比,**取 max**(最险的 workspace 决定会不会被限流);
// - 面板:合计三环 + 每 workspace 细条行(滚动%主指标 + 周%副标,可重命名/移除)。

struct OpenCodeCard: View {
    @StateObject private var model = TokenPlanModel.shared
    @State private var showLogin = false
    @State private var renamingID: String?
    @State private var addingWorkspace = false
    @State private var draftWorkspaceID = ""
    @State private var draftLabel = ""
    @State private var addError: String?

    private var brand: Color { ProviderBrand.color(for: .opencode) }
    /// 是否已登录(opencode.ai 账户 cookie)
    private var loggedIn: Bool { !model.openCodeCookie.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingM) {
            providerHeader
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $showLogin) { OpenCodeLoginView() }
    }

    // MARK: 品牌行

    private var providerHeader: some View {
        HStack(spacing: DesignTokens.spacingS) {
            ATBProviderMark(tab: .opencode, size: 24)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text("OpenCode Go")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.atbTextPrimary)
                    if model.openCodeWorkspaces.count > 1 {
                        ATBBrandTag(text: "\(model.openCodeWorkspaces.count) 个工作区", brand: brand)
                    }
                }
                ATBSubtitleText(text: subtitleText)
            }
            Spacer(minLength: DesignTokens.spacingS)
            if loggedIn {
                ATBBrandActionButton(title: "发现工作区", symbol: "magnifyingglass", brand: brand,
                                     action: { Task { await model.discoverOpenCodeWorkspaces() } },
                                     help: "重新拉取账户下的 workspace 列表并并入")
                ATBRefreshButton(action: { Task { await model.refreshOpenCode(force: true) } },
                                 help: "刷新 OpenCode 用量")
            }
        }
    }

    private var subtitleText: String {
        var base = "Cloud IDE · 三窗口共用"
        let t = ATBTimeFormat.updated(model.openCodeLastUpdated ?? ATBTimeFormat.latestData(model))
        if !t.isEmpty { base += " · \(t) 更新" }
        if model.openCodeWorkspaces.count > 1 { base += " · 合计" }
        return base
    }

    // MARK: 内容(四态:未登录引导/无 workspace 引导/数据/错误)

    @ViewBuilder
    private var content: some View {
        if !loggedIn {
            loginGuide
        } else if model.openCodeWorkspaces.isEmpty {
            emptyWorkspaceGuide
        } else if let q = model.openCodeQuota {
            VStack(spacing: DesignTokens.spacingM) {
                multiRingSection(q: q)
                forecastSection
                if model.openCodeWorkspaces.count > 1 {
                    workspaceList
                }
                if model.openCodeError != nil {
                    accountErrorSummary
                }
            }
        } else if let err = model.openCodeError {
            if err.contains("网络") || err.contains("响应") || err.contains("解析") {
                VStack(spacing: DesignTokens.spacingS) {
                    ATBUnavailableRow(title: "滚动4h限额")
                    ATBUnavailableRow(title: "每周限额")
                    ATBUnavailableRow(title: "每月限额")
                }
            } else {
                ATBErrorHintCard(message: err)
            }
        } else {
            ATBLoadingCard()
        }
    }

    /// 未登录引导(登录 = opencode.ai 账户一次网页登录,覆盖全部 workspace)。
    private var loginGuide: some View {
        HStack(spacing: DesignTokens.spacingS) {
            Image(systemName: "lock.open")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.atbTextTertiary)
            VStack(alignment: .leading, spacing: 1) {
                Text("登录 OpenCode Go 开始统计")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.atbTextPrimary)
                Text("一次登录覆盖账户下全部 workspace(各自独立订阅)")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.atbTextTertiary)
            }
            Spacer()
            Button("登录") { showLogin = true }
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

    /// 已登录但没有 workspace(发现失败/被全部移除):重新发现 + 手动添加。
    private var emptyWorkspaceGuide: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingS) {
            HStack(spacing: DesignTokens.spacingS) {
                Image(systemName: "rectangle.on.rectangle.slash")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.atbTextTertiary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("尚未发现 workspace")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.atbTextPrimary)
                    Text("每个 workspace 是独立订阅;可从浏览器地址栏复制 wrk_xxx 手动添加")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.atbTextTertiary)
                }
                Spacer()
                Button("重新发现") { Task { await model.discoverOpenCodeWorkspaces() } }
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(brand)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(brand.opacity(0.14))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .buttonStyle(.plain)
            }
            if addingWorkspace { addWorkspaceForm }
        }
        .atbCard()
    }

    /// 三窗口一组(roll/week/month):横向三环卡片(保留 v3 打磨版式)。
    private func multiRingSection(q: OpenCodeQuota) -> some View {
        ATBMultiRingCard(slots: [
            ATBMultiRingCard.Slot(id: "rolling",
                                  title: "滚动4h",
                                  subtitle: q.rolling.rollingResetText ?? "—",
                                  percentage: Double(q.rolling.pct),
                                  bandColor: thresholdBrand(q.rolling.pct,
                                                            config: model.thresholdConfig,
                                                            brand: brand),
                                  threshold: model.thresholdConfig),
            ATBMultiRingCard.Slot(id: "weekly",
                                  title: "本周",
                                  subtitle: relativeReset(q.weekly) ?? "—",
                                  percentage: Double(q.weekly.pct),
                                  bandColor: thresholdBrand(q.weekly.pct,
                                                            config: model.thresholdConfig,
                                                            brand: brand),
                                  threshold: model.thresholdConfig),
            ATBMultiRingCard.Slot(id: "monthly",
                                  title: "本月",
                                  subtitle: relativeReset(q.monthly) ?? "—",
                                  percentage: Double(q.monthly.pct),
                                  bandColor: thresholdBrand(q.monthly.pct,
                                                            config: model.thresholdConfig,
                                                            brand: brand),
                                  threshold: model.thresholdConfig)
        ])
        .atbStripeCard(brand: brand, paddingH: DesignTokens.spacingM, paddingV: DesignTokens.spacingS)
    }

    // MARK: 触顶预测(每窗口一行)

    private struct ForecastItem: Identifiable {
        let id: String
        let icon: String
        let text: String
        let tint: Color
    }

    /// 每窗口按历史速率外推到重置时刻:
    /// - 会触顶(重置时 ≥100%)→ "约 X 后触顶"(直接回答会不会被限流);
    /// - 不会 → "预计重置时用到 X%";
    /// - 速率非正/数据不足 → 不出行(不猜)。
    private var forecastItems: [ForecastItem] {
        guard let q = model.openCodeQuota else { return [] }
        let windows: [(id: String, label: String, pct: Int, resetInSec: Int64)] = [
            ("rolling", "5h 窗口", q.rolling.pct, q.rolling.resetInSec),
            ("weekly", "本周额度", q.weekly.pct, q.weekly.resetInSec),
            ("monthly", "本月额度", q.monthly.pct, q.monthly.resetInSec)
        ]
        var items: [ForecastItem] = []
        for w in windows {
            guard w.resetInSec > 0 else { continue }
            let samples = ATBHistory.pctSamples(model, provider: "opencode", window: w.id)
            guard let rate = UsageForecast.pctPerHour(samples: samples), rate > 0,
                  let last = samples.last else { continue }
            let hoursToReset = Double(w.resetInSec) / 3600
            let projected = min(100, last.pct + rate * hoursToReset)
            let rounded = Int(projected.rounded())
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
                    text: "\(w.label) · 预计重置时用到 \(rounded)%",
                    tint: Color.atbTextTertiary))
            }
        }
        return items
    }

    @ViewBuilder
    private var forecastSection: some View {
        let items = forecastItems
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

    // MARK: workspace 行(滚动%主指标 + 周%副标 + 3pt 条;右键重命名/移除)

    private var workspaceList: some View {
        VStack(spacing: 4) {
            ForEach(model.openCodeWorkspaces) { ws in
                workspaceRow(ws)
            }
        }
    }

    @ViewBuilder
    private func workspaceRow(_ ws: OpenCodeWorkspace) -> some View {
        if renamingID == ws.id {
            ATBRenameField(initial: ws.label,
                           onSave: { newLabel in
                               model.renameOpenCodeWorkspace(id: ws.id, label: newLabel)
                               renamingID = nil
                           },
                           onCancel: { renamingID = nil })
                .atbCard(paddingV: DesignTokens.spacingS - 2)
        } else {
            workspaceRowContent(ws)
                .contextMenu {
                    ATBAccountMenu.items(rename: { renamingID = ws.id },
                                         remove: { model.removeOpenCodeWorkspace(id: ws.id) })
                }
        }
    }

    @ViewBuilder
    private func workspaceRowContent(_ ws: OpenCodeWorkspace) -> some View {
        if let snap = model.openCodeWorkspaceQuotas.first(where: { $0.id == ws.id }) {
            let pct = snap.quota.rolling.pct
            let band = thresholdBrand(pct, config: model.thresholdConfig, brand: brand)
            ATBThinMeterRow(
                label: ws.label,
                pct: pct,
                color: band,
                valueText: "周 \(snap.quota.weekly.pct)%",
                trailing: snap.quota.rolling.rollingResetCompactText,
                help: "\(ws.label)(\(ws.id)):滚动 \(pct)% · 周 \(snap.quota.weekly.pct)% · 月 \(snap.quota.monthly.pct)%"
            )
        } else if let err = model.openCodeWorkspaceErrors[ws.id] {
            HStack(spacing: DesignTokens.spacingS) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.orange)
                Text("\(ws.label):\(err)")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.atbTextSecondary)
                Spacer(minLength: 0)
                Button("移除") { model.removeOpenCodeWorkspace(id: ws.id) }
                    .buttonStyle(ATBTextButtonStyle(color: .atbCritical))
                    .font(.system(size: 9))
            }
            .atbCard(paddingV: DesignTokens.spacingS - 2)
        } else {
            ATBThinMeterRow(label: ws.label, pct: 0, color: Color.atbTextTertiary,
                            valueText: nil, trailing: "等待刷新…",
                            help: "\(ws.label):等待刷新")
        }
    }

    /// 全局错误摘要(逐 workspace 错误已在内联行展示时,给一条汇总)。
    private var accountErrorSummary: some View {
        HStack(spacing: DesignTokens.spacingS) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.orange)
            Text(model.openCodeError ?? "")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.orange)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
    }

    // MARK: 手动添加 workspace(列表端点失效时)

    private var addWorkspaceForm: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingS - 2) {
            HStack(spacing: DesignTokens.spacingS) {
                TextField("workspace ID (wrk_xxx)", text: $draftWorkspaceID)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                TextField("名称(可选)", text: $draftLabel)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .frame(width: 110)
                Button("添加") { saveWorkspace() }
                    .buttonStyle(ATBPrimaryButtonStyle())
                    .font(.system(size: 11, weight: .medium))
            }
            if let addError {
                Text(addError).font(.system(size: 10)).foregroundStyle(.atbCritical)
            }
        }
    }

    private func saveWorkspace() {
        let wsID = draftWorkspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard wsID.hasPrefix("wrk_") || wsID.hasPrefix("org_") else {
            addError = "ID 应以 wrk_ / org_ 开头"
            return
        }
        guard !model.openCodeWorkspaces.contains(where: { $0.id == wsID }) else {
            addError = "该 workspace 已在列表中"
            return
        }
        addError = nil
        model.addOpenCodeWorkspace(id: wsID, label: draftLabel)
        draftWorkspaceID = ""
        draftLabel = ""
        addingWorkspace = false
    }

    // MARK: helpers

    private func relativeReset(_ w: OpenCodeWindow) -> String? {
        w.resetInSec > 0 ? w.timeUntilReset : nil
    }
}

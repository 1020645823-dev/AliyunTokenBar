import SwiftUI
import AppKit
import Combine
import AliyunTokenBarCore

// MARK: - 灵动岛(菜单栏 Dynamic Island 形态)
//
// 形态语义(对照 iPhone 灵动岛):
//   收起态 = 菜单栏胶囊(浅/深皮肤跟随全 App 主题):全源健康度计数 + 每源健康刻度。
//   展开态 = 从胶囊下沿生长的玻璃驾驶舱:全源品牌星图为主,悬停源在
//           下方细节坞展示双窗口/多账户分段/绝对量;点击源进入主面板。
//
// 实现要点:
//   - 展开态使用透明 NSPanel;仅指针位于卡片内时吃事件,胶囊与其余区域
//     保持透传,不抢焦点,也不破坏「点胶囊→主面板」。
//   - 展开触发 = 状态项按钮的 NSTrackingArea(mouseEntered);收起 = 0.1s 轮询
//     全局鼠标位置(比全局事件监视器可靠:自己进程内的事件不到 global monitor)。
//   - 面板帧按两行星图 + 固定细节坞一次预留,悬停切源/数据刷新不重建帧。
//   - macOS 26 会把状态项停到屏幕外(-1,1113)→ 展开前校验胶囊 rect 在屏内,
//     停死态不显示(恢复监控重建状态项后由新的 mouseEntered 再触发)。

// MARK: - 度量常量(面板帧与内容高度共用同一组公式,避免错位)

enum IslandMetrics {
    static let expandedWidth: CGFloat = 360
    static let paddingH: CGFloat = 14
    static let paddingV: CGFloat = 12
    static let headerHeight: CGFloat = 34
    static let tileHeight: CGFloat = 64
    static let gridGap: CGFloat = 6
    static let detailHeight: CGFloat = 118
    static let footerHeight: CGFloat = 16
    static let gapHeaderGrid: CGFloat = 6
    static let gapGridDetail: CGFloat = 8
    static let gapDetailFooter: CGFloat = 4
    static let collapsedCorner: CGFloat = 11
    static let expandedCorner: CGFloat = 20
    static let overviewColumns = 5
    static let maxRows = MenuBarColumnKind.allCases.count

    static func overviewRowCount(sourceCount: Int) -> Int {
        max(1, min(2, Int(ceil(Double(sourceCount) / Double(overviewColumns)))))
    }

    static func gridHeight(sourceCount: Int) -> CGFloat {
        let rows = overviewRowCount(sourceCount: sourceCount)
        return CGFloat(rows) * tileHeight + CGFloat(rows - 1) * gridGap
    }

    static func height(sourceCount: Int) -> CGFloat {
        paddingV * 2 + headerHeight + gapHeaderGrid + gridHeight(sourceCount: sourceCount)
            + gapGridDetail + detailHeight + gapDetailFooter + footerHeight
    }

    /// 固定窗口尺寸只允许搬原点;内容 fitting size 不得改写窗口帧。
    static let panelWidth: CGFloat = expandedWidth + 20
    static let panelHeight: CGFloat = height(sourceCount: maxRows) + 20
}

// MARK: - 岛状态(SwiftUI 侧唯一数据源)

@MainActor
final class IslandState: ObservableObject {
    @Published var expanded = false
    /// 由全 App 主题与系统菜单栏明暗共同解析,驱动浅/深两套调色板。
    @Published var isDark = true
    /// 全源星图按 registry 固定顺序展示,避免刷新时格子漂移。
    @Published var columns: [MenuBarTableColumn] = []
    /// 细节坞跟随悬停源;每次展开默认落在风险最高源。
    @Published var focusedKind: MenuBarColumnKind?
    /// 每源的分段进度条(Kimi/智谱/阶跃=每账户一段,OpenCode=每 workspace 一段,其余=主/次窗口段)。
    @Published var segmentsByKind: [MenuBarColumnKind: [IslandMeterSegment]] = [:]
    @Published var health = IslandHealth(needAction: 0, critical: 0, warning: 0)
    /// 收起态胶囊 rect(面板坐标系,左上原点 y 向下)。
    @Published var collapsedRect: CGRect = .zero
    /// 展开态卡片 rect(面板坐标系)。
    @Published var expandedRect: CGRect = .zero
    var config = ThresholdConfig()
    var moneyFloor: Double = 0
    var updated: Date?
}

// MARK: - 分段进度(多套餐进度条)

/// 一个进度段:短标签 + 已用% + 阈值状态色(+悬停详情:绝对用量/重置时间)。
struct IslandMeterSegment: Identifiable, Equatable {
    let id: String
    let label: String
    let usedPct: Int
    let state: ColumnState
    /// 悬停段的补充信息(如「5h 已用 0/100 · 17分钟后重置」),没有则不显示 tooltip。
    var detail: String? = nil

    /// 链式补 detail(组装处一行搞定)。
    func withDetail(_ d: String?) -> IslandMeterSegment {
        var copy = self
        copy.detail = d
        return copy
    }
}

@MainActor
enum IslandMeters {
    /// 组装某源的进度段。多账户源(Kimi/智谱/阶跃)=每账户一段(标签=套餐名/手机尾号/
    /// 账户名);OpenCode 多 workspace=每 workspace(独立订阅)一段;单账户源=主/次窗口段;
    /// 纯金额源(DeepSeek)→ 空,细节坞改画金额 pill。
    static func segments(for col: MenuBarTableColumn,
                         model: TokenPlanModel,
                         config: ThresholdConfig) -> [IslandMeterSegment] {
        func stateOf(_ pct: Int) -> ColumnState {
            pct >= config.critical ? .critical : (pct >= config.warning ? .warning : .ok)
        }
        func seg(_ id: String, _ label: String, _ pct: Int?) -> IslandMeterSegment? {
            guard let pct else { return nil }
            let clamped = max(0, min(100, pct))
            return IslandMeterSegment(id: id, label: label, usedPct: clamped, state: stateOf(clamped))
        }
        switch col.kind {
        case .kimi:
            // 每账户一段:套餐商品名优先(Pro/Alle),无套餐回落账户名尾段。
            // ⚠️ 值取**最紧窗口**而非固定 5h——不同套餐活跃窗口不同
            // (实测 Allegro 用量在周/月、5h 恒 0,固定 5h 会显示成误导性的 0%)。
            return model.kimiAccountQuotas.compactMap { s in
                let label = s.quota.planDisplayName.map { String($0.prefix(4)) }
                    ?? String(s.label.suffix(3))
                let worst = s.quota.worstWindow
                var detail = "5h 已用 \(s.quota.fiveHour.used)/\(s.quota.fiveHour.limit)"
                    + " · 周 \(s.quota.weekly.used)/\(s.quota.weekly.limit)"
                if let m = s.quota.monthly {
                    detail += " · 月 \(m.used)/\(m.limit)"
                }
                detail += "(最紧:\(worst.label))"
                if let plan = s.quota.planDisplayName { detail = "\(plan) · " + detail }
                return seg("kimi-\(s.id)", label, worst.pct)?.withDetail(detail)
            }
        case .zhipu:
            // 多账户=每账户一段(账户名尾段区分);单账户=窗口段(5h/周更有信息量,
            // 「账户1」标签无意义)。该账户最紧窗口:5h 优先,无则周。
            if model.zhipuAccountQuotas.count > 1 {
                return model.zhipuAccountQuotas.compactMap { s in
                    let fiveH = s.quota.fiveHour
                    let week = s.quota.weekly
                    let pct = [fiveH?.pctInt, week?.pctInt].compactMap { $0 }.max()
                    var detail = "5h \(fiveH?.pctInt ?? 0)% · 周 \(week?.pctInt ?? 0)%"
                    if let lvl = s.quota.level { detail = "\(lvl) · " + detail }
                    return seg("zhipu-\(s.id)", String(s.label.suffix(3)), pct)?.withDetail(detail)
                }
            }
            var out: [IslandMeterSegment] = []
            if let snap = model.zhipuAccountQuotas.first {
                if let s = seg("zhipu-5h", "5h", snap.quota.fiveHour?.pctInt) {
                    out.append(s.withDetail("5h 已用 \(snap.quota.fiveHour?.pctInt ?? 0)%\(snap.quota.fiveHour?.timeUntilReset.map { " · \($0)" } ?? "")"))
                }
                if let s = seg("zhipu-week", "周", snap.quota.weekly?.pctInt) {
                    out.append(s.withDetail("周 已用 \(snap.quota.weekly?.pctInt ?? 0)%"))
                }
            }
            return out
        case .stepfun:
            // 每账户一段:标签=手机尾号(****5678,与面板一致)回落账户名;值=主窗口
            return model.stepfunAccountQuotas.compactMap { s in
                let identity = model.stepfunAccounts.first(where: { $0.id == s.id })?.identityDisplay
                let label = identity.map { String($0.suffix(6)) } ?? String(s.label.suffix(3))
                var detail: String?
                if let sub = s.quota.subscription, sub.total > 0 {
                    detail = "月池 剩 \(Int(sub.residual))/\(Int(sub.total)) credits"
                }
                return seg("stepfun-\(s.id)", label, s.quota.primaryPct)?.withDetail(detail)
            }
        case .openCode:
            // 多 workspace(每个是独立订阅)=每 workspace 一段:标签取尾段区分
            // (同智谱/阶跃规格),详情前缀全名;值取该订阅三窗口最险的。
            // 单 workspace=窗口段(滚动/周),与 default 同构(workspace 名标签无信息量)。
            if model.openCodeWorkspaceQuotas.count > 1 {
                return model.openCodeWorkspaceQuotas.compactMap { s in
                    let pct = max(s.quota.rolling.pct, s.quota.weekly.pct, s.quota.monthly.pct)
                    let detail = "\(s.label) · 滚动 \(s.quota.rolling.pct)% · 周 \(s.quota.weekly.pct)% · 月 \(s.quota.monthly.pct)%"
                    return seg("openCode-\(s.id)", String(s.label.suffix(3)), pct)?.withDetail(detail)
                }
            }
            var out: [IslandMeterSegment] = []
            if let s = seg("openCode-p", short(col.primaryLabel), col.primary.pct) {
                out.append(s.withDetail("\(short(col.primaryLabel)) 已用 \(col.primary.text)"))
            }
            if let s = seg("openCode-s", short(col.secondaryLabel ?? ""),
                          col.secondary.pct) {
                out.append(s.withDetail("\(short(col.secondaryLabel ?? "")) 已用 \(col.secondary.text)"))
            }
            return out
        case .deepSeek:
            return []
        default:
            // 单账户源:主/次窗口各一段(标签取列标签短版)
            var out: [IslandMeterSegment] = []
            if let s = seg("\(col.kind.rawValue)-p", short(col.primaryLabel), col.primary.pct) {
                out.append(s.withDetail("\(short(col.primaryLabel)) 已用 \(col.primary.text)"))
            }
            if let s = seg("\(col.kind.rawValue)-s", short(col.secondaryLabel ?? ""),
                          col.secondary.pct) {
                out.append(s.withDetail("\(short(col.secondaryLabel ?? "")) 已用 \(col.secondary.text)"))
            }
            return out
        }
    }

    /// 窗口标签短版(段宽有限):「5小时」→「5h」,「30天」保留(3 字不挤),其余取前 2 字。
    private static func short(_ s: String) -> String {
        if s == "5小时" { return "5h" }
        if s == "30天" { return s }
        return String(s.prefix(2))
    }
}

// MARK: - 岛根视图(胶囊 ↔ 实时星图的 spring 变形)

struct IslandRootView: View {
    @ObservedObject var state: IslandState
    /// 点行 → 打开主面板并落在该源 tab(由 App 层注入的 sink 真正打开面板)。
    let onTapRow: (MenuBarColumnKind) -> Void

    var body: some View {
        let rect = state.expanded ? state.expandedRect : state.collapsedRect
        let palette = IslandPalette(isDark: state.isDark)
        ZStack(alignment: .topLeading) {
            IslandAmbientBackground(
                cornerRadius: state.expanded ? IslandMetrics.expandedCorner : IslandMetrics.collapsedCorner,
                elevated: state.expanded
            )
            .frame(width: rect.width, height: rect.height)
            .offset(x: rect.minX, y: rect.minY)
            IslandExpandedContent(
                columns: state.columns,
                segmentsByKind: state.segmentsByKind,
                health: state.health,
                config: state.config, moneyFloor: state.moneyFloor, updated: state.updated,
                focusedKind: state.focusedKind,
                onFocus: { state.focusedKind = $0 },
                onTapRow: onTapRow
            )
            .frame(width: state.expandedRect.width, height: state.expandedRect.height,
                   alignment: .topLeading)
            .offset(x: state.expandedRect.minX, y: state.expandedRect.minY)
            .opacity(state.expanded ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .environment(\.islandPalette, palette)
        .environment(\.colorScheme, state.isDark ? .dark : .light)
        // 一个 spring 驱动全部衍生量:rect / 圆角 / 内容透明度同步变形,
        // dampingFraction 0.72 的轻微回弹即灵动岛的「呼吸感」。
        .animation(.spring(response: 0.42, dampingFraction: 0.72), value: state.expanded)
    }
}

/// 岛宿主视图:**只让展开卡矩形吃鼠标事件**。覆盖面板叠在状态项之上,
/// 整窗收事件会让点胶囊再也打不开主面板——所以 hitTest 白名单之外一律透传。
@MainActor
final class IslandHostingView: NSHostingView<IslandRootView> {
    /// 事件白名单(视图坐标,左上原点 y 向下);nil = 全窗透传。
    var hitRect: CGRect?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hitRect else { return nil }
        let p = isFlipped ? point : NSPoint(x: point.x, y: bounds.height - point.y)
        return hitRect.contains(p) ? super.hitTest(point) : nil
    }
}

/// 岛状态色:深底用亮色,浅底用更深的同语义色;胶囊与展开卡共用。
enum IslandStateColor {
    static func color(_ s: ColumnState, isDark: Bool = true) -> Color {
        if !isDark {
            switch s {
            case .needsAction: return Color(red: 0.21, green: 0.35, blue: 0.78)
            case .critical: return Color(red: 0.79, green: 0.16, blue: 0.14)
            case .warning: return Color(red: 0.70, green: 0.32, blue: 0.02)
            case .ok: return Color(red: 0.05, green: 0.42, blue: 0.20)
            }
        }
        switch s {
        case .needsAction: return Color(red: 0.55, green: 0.68, blue: 1.0)   // 蓝紫:需要你动手
        case .critical: return Color(red: 1.0, green: 0.40, blue: 0.36)      // 红
        case .warning: return Color(red: 1.0, green: 0.65, blue: 0.24)       // 橙
        case .ok: return Color(red: 0.30, green: 0.85, blue: 0.45)           // 绿
        }
    }
}

// MARK: - 覆盖面板控制器

@MainActor
final class IslandOverlayController {
    static let shared = IslandOverlayController()

    private var panel: NSPanel?
    private let state = IslandState()
    private var pollTimer: Timer?
    private var hideWorkItem: DispatchWorkItem?
    private var keepRect: CGRect = .zero
    /// 展开卡 rect(屏幕坐标 y 向上,外扩 6pt):**只有指针落在卡内时才吃鼠标事件**。
    /// 系统按窗口帧挑事件接收者,`hitTest` 返回 nil 不会把点击转交下层状态项 ——
    /// 若整窗收事件,点胶囊就再也打不开主面板(实测)。
    private var cardScreenRect: CGRect = .zero
    private var modelCancellable: AnyCancellable?
    /// 主面板(popover)打开期间不展开,避免岛与弹层重叠。
    private var suppressed = false

    private init() {}

    /// 全 App 主题变化或系统明暗变化时,同时更新展开卡与材质外观。
    func refreshAppearance() {
        let dark = ThemeManager.shared.theme.isDark(systemIsDark: MenuBarAppearance.shared.isDark)
        state.isDark = dark
        panel?.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    }

    // MARK: 展开 / 收起

    /// 鼠标进入状态项胶囊(AppDelegate tracking area 转发)。
    /// 幂等:已展开→只刷数据;收合动画中→取消隐藏并回弹。
    func expandIfNeeded(_ button: NSStatusBarButton?) {
        refreshAppearance()
        guard !suppressed, let button, let buttonWindow = button.window else { return }
        let pill = buttonWindow.frame
        guard pill.width > 2, pill.height > 2 else { return }
        // macOS 26 停车/隐藏态:胶囊 rect 不在任何屏内 → 不显示
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(pill) }) else { return }

        let model = TokenPlanModel.shared
        let columns = model.menuBarColumns()
        guard !columns.isEmpty else { return }
        let config = model.thresholdConfig

        let segmentsByKind = segmentsMap(columns: columns, model: model, config: config)
        let contentHeight = IslandMetrics.height(sourceCount: columns.count)

        // 几何(屏幕坐标 y 向上 → 面板内左上原点 y 向下):
        // 展开态**从胶囊下沿向下生长**(卡顶 = 胶囊底 pill.minY):卡若与胶囊顶对齐会
        // 把胶囊整个盖住——而悬停即展开,于是「点胶囊开面板」这条既有动线会被吃掉。
        // 水平居中对齐胶囊并夹在屏内。
        let expandedRect = CGRect(
            x: min(max(pill.midX - IslandMetrics.expandedWidth / 2,
                       screen.frame.minX + 6),
                   screen.frame.maxX - IslandMetrics.expandedWidth - 6),
            y: pill.minY - contentHeight,
            width: IslandMetrics.expandedWidth,
            height: contentHeight
        )
        // 面板帧按满列数预留(±10 给 spring 回弹留空间)
        let frameExpanded = CGRect(
            x: min(max(pill.midX - IslandMetrics.expandedWidth / 2, screen.frame.minX + 6),
                   screen.frame.maxX - IslandMetrics.expandedWidth - 6),
            y: pill.minY - IslandMetrics.height(sourceCount: IslandMetrics.maxRows),
            width: IslandMetrics.expandedWidth,
            height: IslandMetrics.height(sourceCount: IslandMetrics.maxRows)
        )
        let panelRect = pill.union(frameExpanded).insetBy(dx: -10, dy: -10)

        state.columns = columns
        if state.focusedKind == nil || !columns.contains(where: { $0.kind == state.focusedKind }) {
            state.focusedKind = MenuBarTable.islandRows(columns: columns, config: config,
                                                        moneyFloor: model.moneyFloor).first?.kind
        }
        state.segmentsByKind = segmentsByKind
        state.health = MenuBarTable.islandHealth(columns: columns, config: config, moneyFloor: model.moneyFloor)
        state.config = config
        state.moneyFloor = model.moneyFloor
        state.updated = model.lastUpdated

        hideWorkItem?.cancel()
        hideWorkItem = nil

        if panel == nil { panel = createPanel() }
        guard let panel else { return }
        // 状态先于 setFrame:内容几何就位后再搬窗口(固定尺寸,只改原点)
        state.collapsedRect = relRect(pill, in: panelRect)
        state.expandedRect = relRect(expandedRect, in: panelRect)
        panel.setFrame(panelRect, display: true)
        // 展开卡外扩 6pt(兼容 spring 回弹):指针在卡内才吃事件,否则透传给状态项
        cardScreenRect = expandedRect.insetBy(dx: -6, dy: -6)
        panel.acceptsMouseMovedEvents = true
        (panel.contentView as? IslandHostingView)?.hitRect = state.expandedRect.insetBy(dx: -6, dy: -6)
        panel.ignoresMouseEvents = !cardScreenRect.contains(NSEvent.mouseLocation)
        panel.orderFrontRegardless()
        keepRect = panelRect

        if !state.expanded {
            // 先落一帧收起态(与菜单栏胶囊像素级重合),下一帧翻 expanded →
            // spring 从胶囊原地生长。面板是透明无影的,重合帧看不出拼接。
            state.expanded = false
            DispatchQueue.main.async { [weak self] in
                self?.state.expanded = true
            }
        }
        startPolling()
        observeModelUpdates()
    }

    /// 收起(带收合动画;动画结束后面板隐藏)。
    func collapse(animated: Bool) {
        stopPolling()
        modelCancellable = nil
        guard let panel, panel.isVisible else { return }
        state.expanded = false
        state.focusedKind = nil
        panel.ignoresMouseEvents = true
        (panel.contentView as? IslandHostingView)?.hitRect = nil
        let work = DispatchWorkItem { [weak self] in
            self?.panel?.orderOut(nil)
        }
        hideWorkItem?.cancel()
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (animated ? 0.5 : 0.05), execute: work)
    }

    /// 立即收起(切 scheme、开主面板、重建状态项等场景:不留过渡)。
    func collapseNow() {
        stopPolling()
        hideWorkItem?.cancel()
        hideWorkItem = nil
        modelCancellable = nil
        panel?.ignoresMouseEvents = true
        (panel?.contentView as? IslandHostingView)?.hitRect = nil
        panel?.orderOut(nil)
        state.expanded = false
        state.focusedKind = nil
    }

    // MARK: 行点击(岛 → 面板)

    /// 点行 → 收起岛并请求打开主面板(实际打开由 App 层注入的 sink 完成)。
    func openPanel(for kind: MenuBarColumnKind) {
        AppLog.info("岛行点击 \(kind.rawValue) sink=\(openPanelSink != nil)", category: .general)
        collapseNow()
        setSuppressed(true)
        openPanelSink?(kind)
    }

    /// App 层注入:打开面板并落在该源 tab。
    var openPanelSink: ((MenuBarColumnKind) -> Void)?

    /// 主面板显示期间抑制展开(popover 与岛同区,不能同时存在)。
    func setSuppressed(_ v: Bool) {
        suppressed = v
        if v { collapseNow() }
    }

    /// 启动期预热:提前建面板并强制一次 SwiftUI 布局(屏外 + 透明一帧即撤)。
    /// 否则首次悬停要同时承担「建 NSHostingView + 首布局 + 品牌 SVG path 解析
    /// + spring」,实测可超过 1.5s 才可见——灵动岛的卖点就是即时响应。
    func prewarm() {
        refreshAppearance()
        if panel == nil { panel = createPanel() }
        guard let panel else { return }
        // 固定尺寸,屏外一帧即撤(alpha 0 双保险)
        panel.setFrame(CGRect(x: -IslandMetrics.panelWidth - 100, y: 0,
                              width: IslandMetrics.panelWidth, height: IslandMetrics.panelHeight),
                       display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.layoutIfNeeded()
        DispatchQueue.main.async { [weak self] in
            self?.panel?.orderOut(nil)
            self?.panel?.alphaValue = 1
        }
    }

    // MARK: 私有

    private func createPanel() -> NSPanel {
        let size = NSSize(width: IslandMetrics.panelWidth, height: IslandMetrics.panelHeight)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.appearance = NSAppearance(named: state.isDark ? .darkAqua : .aqua)
        panel.hasShadow = false
        panel.ignoresMouseEvents = true   // 初始透传;展开后由指针位置翻转
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        // 尺寸锁死:内容(SwiftUI fitting size)不得再改动窗口帧,只允许搬原点
        panel.contentMinSize = size
        panel.contentMaxSize = size
        let host = IslandHostingView(rootView: IslandRootView(state: state) { [weak self] kind in
            self?.openPanel(for: kind)
        })
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        return panel
    }

    /// 屏幕坐标(y 向上)→ 面板内左上原点(y 向下)。
    private func relRect(_ rect: CGRect, in panelRect: CGRect) -> CGRect {
        CGRect(x: rect.minX - panelRect.minX,
               y: panelRect.maxY - rect.maxY,
               width: rect.width, height: rect.height)
    }

    /// 0.1s 轮询全局鼠标位置:离开 keepRect(面板 ∪ 胶囊,±10 容差)即收起。
    /// 用轮询而非全局事件监视器:自己进程内的事件不会进 global monitor,
    /// 而指针掠过胶囊间隙/面板时的判定轮询足够及时,且无权限依赖。
    private func startPolling() {
        guard pollTimer == nil else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkMouse() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func checkMouse() {
        guard let panel, panel.isVisible else { stopPolling(); return }
        let mouse = NSEvent.mouseLocation
        // 事件开关随指针位置翻转:卡内吃事件(行 hover/点击),卡外透传(胶囊仍可点)
        panel.ignoresMouseEvents = !cardScreenRect.contains(mouse)
        if !keepRect.contains(mouse) {
            collapse(animated: true)
        }
    }

    /// 展开期间数据刷新(模型 renderedIcon 变化)→ 行内容实时更新(live activity)。
    private func observeModelUpdates() {
        guard modelCancellable == nil else { return }
        modelCancellable = TokenPlanModel.shared.$renderedIcon
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, let panel = self.panel, panel.isVisible else { return }
                let model = TokenPlanModel.shared
                let columns = model.menuBarColumns()
                self.state.columns = columns
                if self.state.focusedKind == nil || !columns.contains(where: { $0.kind == self.state.focusedKind }) {
                    self.state.focusedKind = MenuBarTable.islandRows(
                        columns: columns, config: model.thresholdConfig, moneyFloor: model.moneyFloor
                    ).first?.kind
                }
                self.state.config = model.thresholdConfig
                self.state.segmentsByKind = self.segmentsMap(columns: columns, model: model,
                                                             config: model.thresholdConfig)
                self.state.health = MenuBarTable.islandHealth(columns: columns, config: model.thresholdConfig,
                                                              moneyFloor: model.moneyFloor)
                self.state.moneyFloor = model.moneyFloor
                self.state.updated = model.lastUpdated
            }
    }

    /// 组装全部源的分段进度(高度随段数变化只发生在下次展开;展开中行数不变帧不重建)。
    private func segmentsMap(columns: [MenuBarTableColumn], model: TokenPlanModel,
                             config: ThresholdConfig) -> [MenuBarColumnKind: [IslandMeterSegment]] {
        var out: [MenuBarColumnKind: [IslandMeterSegment]] = [:]
        for col in columns {
            let segs = IslandMeters.segments(for: col, model: model, config: config)
            if !segs.isEmpty { out[col.kind] = segs }
        }
        return out
    }
}

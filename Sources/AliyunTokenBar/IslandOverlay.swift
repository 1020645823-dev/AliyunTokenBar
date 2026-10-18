import SwiftUI
import AppKit
import Combine
import AliyunTokenBarCore

// MARK: - 灵动岛(菜单栏 Dynamic Island 形态)
//
// 形态语义(对照 iPhone 灵动岛):
//   收起态 = 菜单栏里的黑色胶囊(状态项图片 islandPillImage),内容 = 聚焦列
//           (风险最高/占比最高的一项):真实品牌 logo 剪影 + 主值。
//   展开态 = 悬停时胶囊原地弹簧「生长」为一张实时用量卡:品牌彩色 logo +
//           各数据源双窗口行 + 概览 chip;移开鼠标自动收回。
//
// 实现要点:
//   - 展开态不用 NSPopover/NSPanel 交互面板:一个**透明、ignoresMouseEvents**
//     的 NSPanel 叠在状态项上,SwiftUI 黑胶囊在其内部做 spring 变形。面板不吃
//     点击、不抢焦点,鼠标交互完全照旧(点胶囊→主面板)。
//   - 展开触发 = 状态项按钮的 NSTrackingArea(mouseEntered);收起 = 0.1s 轮询
//     全局鼠标位置(比全局事件监视器可靠:自己进程内的事件不到 global monitor)。
//   - 面板帧按满列数(10)一次预留,悬停期间数据到达补列不重建帧;内容行数
//     随时更新(「live activity」语义)。
//   - macOS 26 会把状态项停到屏幕外(-1,1113)→ 展开前校验胶囊 rect 在屏内,
//     停死态不显示(恢复监控重建状态项后由新的 mouseEntered 再触发)。

// MARK: - 度量常量(面板帧与内容高度共用同一组公式,避免错位)

enum IslandMetrics {
    /// 展开态宽度:logo 15 + 名称 52 + 剩余口径窗口段(「5小时 剩 100% · 周 剩 22%」)
    /// + 需处理行的「重登」徽标 + 水平内边距 28,260 会挤 → 280。
    static let expandedWidth: CGFloat = 280
    static let paddingH: CGFloat = 14
    static let paddingV: CGFloat = 11
    static let headerHeight: CGFloat = 20      // 字标 + 概览 chip 行
    static let rowHeight: CGFloat = 21         // 单数据源行
    static let gapHeaderRows: CGFloat = 8      // 分隔线到首行
    static let collapsedCorner: CGFloat = 11   // 收起态胶囊圆角(与 islandPillImage 的 22pt 高胶囊一致)
    static let expandedCorner: CGFloat = 18    // 展开态圆角
    /// 面板帧按满列数预留(悬停期间补列不重建帧)。
    static let maxRows = MenuBarColumnKind.allCases.count
    static func height(rows: Int) -> CGFloat {
        paddingV * 2 + headerHeight + 0.5 + gapHeaderRows + CGFloat(rows) * rowHeight
    }
    /// 面板**固定**尺寸(内容永不变):曾让面板跟随 SwiftUI 内容 fitting size
    /// 自动适配,setFrame 会被内容尺寸变化覆盖、位置漂移(实测偏 281pt);
    /// 固定尺寸 + contentMin/Max 同值后窗口不再被内容牵走,只搬原点。
    static let panelWidth: CGFloat = expandedWidth + 20
    static let panelHeight: CGFloat = height(rows: maxRows) + 20
}

// MARK: - 岛状态(SwiftUI 侧唯一数据源)

@MainActor
final class IslandState: ObservableObject {
    @Published var expanded = false
    /// 已按紧迫度排序的源行(需处理 → 告急 → 预警 → 正常,同级剩余升序)。
    @Published var rows: [MenuBarTableColumn] = []
    @Published var health = IslandHealth(needAction: 0, critical: 0, warning: 0)
    /// 收起态胶囊 rect(面板坐标系,左上原点 y 向下)。
    @Published var collapsedRect: CGRect = .zero
    /// 展开态卡片 rect(面板坐标系)。
    @Published var expandedRect: CGRect = .zero
    var config = ThresholdConfig()
    var moneyFloor: Double = 0
    var updated: Date?
}

// MARK: - 岛根视图(黑胶囊 ↔ 实时卡片的 spring 变形)

struct IslandRootView: View {
    @ObservedObject var state: IslandState
    /// 点行 → 打开主面板并落在该源 tab(由 App 层注入的 sink 真正打开面板)。
    let onTapRow: (MenuBarColumnKind) -> Void

    var body: some View {
        let rect = state.expanded ? state.expandedRect : state.collapsedRect
        ZStack(alignment: .topLeading) {
            RoundedRectangle(
                cornerRadius: state.expanded ? IslandMetrics.expandedCorner : IslandMetrics.collapsedCorner,
                style: .continuous
            )
            .fill(.black)
            .frame(width: rect.width, height: rect.height)
            .offset(x: rect.minX, y: rect.minY)
            IslandExpandedContent(
                rows: state.rows, health: state.health,
                config: state.config, moneyFloor: state.moneyFloor, updated: state.updated,
                onTapRow: onTapRow
            )
            .frame(width: state.expandedRect.width, height: state.expandedRect.height,
                   alignment: .topLeading)
            .offset(x: state.expandedRect.minX, y: state.expandedRect.minY)
            .opacity(state.expanded ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

// MARK: - 展开态内容

private struct IslandExpandedContent: View {
    let rows: [MenuBarTableColumn]
    let health: IslandHealth
    let config: ThresholdConfig
    let moneyFloor: Double
    let updated: Date?
    let onTapRow: (MenuBarColumnKind) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("CodingTokenBar")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.55))
                Spacer(minLength: 4)
                Text("口径:剩余")
                    .font(.system(size: 8.5)).foregroundStyle(.white.opacity(0.35))
                statusChip
            }
            .frame(height: IslandMetrics.headerHeight)
            Rectangle().fill(Color.white.opacity(0.14)).frame(height: 0.5)
                .padding(.bottom, IslandMetrics.gapHeaderRows)
            ForEach(rows, id: \.kind) { col in
                IslandRow(col: col, config: config, moneyFloor: moneyFloor) { onTapRow(col.kind) }
            }
        }
        .padding(.horizontal, IslandMetrics.paddingH)
        .padding(.vertical, IslandMetrics.paddingV)
    }

    /// 与胶囊**同一套**计数文案(需处理/告急/预警),颜色取最严重类别。
    private var statusChip: some View {
        let tint = IslandStateColor.color(health.worst)
        return HStack(spacing: 4) {
            Circle().fill(tint).frame(width: 5, height: 5)
            Text(MenuBarTable.islandHealthText(health))
                .font(.system(size: 9.5, weight: .semibold)).foregroundStyle(tint)
        }
    }
}

private struct IslandRow: View {
    let col: MenuBarTableColumn
    let config: ThresholdConfig
    let moneyFloor: Double
    let onTap: () -> Void

    @State private var hovering = false

    private var state: ColumnState { MenuBarTable.state(col, config: config, moneyFloor: moneyFloor) }

    /// 最紧窗口的剩余比例(0…1);纯金额列无 pct → nil(不画底条)。
    private var remainingFraction: Double? {
        guard let worst = [col.primary.pct, col.secondary.pct].compactMap({ $0 }).max() else { return nil }
        return Double(max(0, min(100, 100 - worst))) / 100
    }

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if let mark = col.kind.brandMark {
                    // 展开态用彩色版(黑底上品牌色最鲜活)
                    mark.mark(in: CGRect(x: 0, y: 0, width: 13, height: 13))
                } else {
                    Image(systemName: col.kind.symbolName)
                        .font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                }
            }
            .frame(width: 15, alignment: .leading)
            Text(col.kind.displayName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1).minimumScaleFactor(0.8)
                .frame(width: 52, alignment: .leading)
            Spacer(minLength: 2)
            Text(MenuBarTable.islandRowText(col))
                .font(.system(size: 10.5)).monospacedDigit()
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1).minimumScaleFactor(0.85)
            if state == .needsAction {
                Text("重登")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(IslandStateColor.color(.needsAction))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(IslandStateColor.color(.needsAction).opacity(0.18)))
            }
        }
        .padding(.horizontal, 6)
        .frame(height: IslandMetrics.rowHeight)
        .background(rowBackground)
        .overlay(alignment: .bottom) { meterBar }
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            // 手型光标(项目 floor 是 macOS 14,没有 .pointerStyle):push/pop 必须成对
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .onTapGesture { onTap() }
    }

    /// 行底色:需处理淡蓝紫 / 告急淡红 / 预警淡橙;正常行仅 hover 时微亮。
    private var rowBackground: some View {
        let fill: Color
        switch state {
        case .needsAction: fill = IslandStateColor.color(.needsAction).opacity(0.14)
        case .critical: fill = IslandStateColor.color(.critical).opacity(0.16)
        case .warning: fill = IslandStateColor.color(.warning).opacity(0.10)
        case .ok: fill = hovering ? .white.opacity(0.07) : .clear
        }
        return RoundedRectangle(cornerRadius: 6, style: .continuous).fill(fill)
    }

    /// 行底部 2pt 剩余条(不占横向空间):长度 = 最紧窗口的剩余,颜色随状态。
    @ViewBuilder
    private var meterBar: some View {
        if let fraction = remainingFraction {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.10))
                    Capsule().fill(IslandStateColor.color(state))
                        .frame(width: max(1, geo.size.width * fraction))
                }
            }
            .frame(height: 2)
            .padding(.horizontal, 6)
            .padding(.bottom, 2)
        }
    }
}

/// 岛状态色(黑底上更亮一档)。胶囊圆点/文字、展开卡行底条与行底色共用同一套,
/// 避免两处色值各写一遍后漂移。
enum IslandStateColor {
    static func color(_ s: ColumnState) -> Color {
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
    private var modelCancellable: AnyCancellable?
    /// 主面板(popover)打开期间不展开,避免岛与弹层重叠。
    private var suppressed = false

    private init() {}

    // MARK: 展开 / 收起

    /// 鼠标进入状态项胶囊(AppDelegate tracking area 转发)。
    /// 幂等:已展开→只刷数据;收合动画中→取消隐藏并回弹。
    func expandIfNeeded(_ button: NSStatusBarButton?) {
        guard !suppressed, let button, let buttonWindow = button.window else { return }
        let pill = buttonWindow.frame
        guard pill.width > 2, pill.height > 2 else { return }
        // macOS 26 停车/隐藏态:胶囊 rect 不在任何屏内 → 不显示
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(pill) }) else { return }

        let model = TokenPlanModel.shared
        let columns = model.menuBarColumns()
        guard !columns.isEmpty else { return }
        let config = model.thresholdConfig

        // 几何(屏幕坐标 y 向上 → 面板内左上原点 y 向下):
        // 展开态顶边对齐胶囊顶边(从菜单栏向下生长),水平居中对齐胶囊并夹在屏内。
        let expandedRect = CGRect(
            x: min(max(pill.midX - IslandMetrics.expandedWidth / 2,
                       screen.frame.minX + 6),
                   screen.frame.maxX - IslandMetrics.expandedWidth - 6),
            y: pill.maxY - IslandMetrics.height(rows: columns.count),
            width: IslandMetrics.expandedWidth,
            height: IslandMetrics.height(rows: columns.count)
        )
        // 面板帧按满列数预留(±10 给 spring 回弹留空间)
        let frameExpanded = CGRect(
            x: min(max(pill.midX - IslandMetrics.expandedWidth / 2, screen.frame.minX + 6),
                   screen.frame.maxX - IslandMetrics.expandedWidth - 6),
            y: pill.maxY - IslandMetrics.height(rows: IslandMetrics.maxRows),
            width: IslandMetrics.expandedWidth,
            height: IslandMetrics.height(rows: IslandMetrics.maxRows)
        )
        let panelRect = pill.union(frameExpanded).insetBy(dx: -10, dy: -10)

        state.rows = MenuBarTable.islandRows(columns: columns, config: config, moneyFloor: model.moneyFloor)
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
        // 展开态才吃鼠标事件(外扩 6pt 兼容 spring 回弹);hitTest 白名单之外仍透传
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        (panel.contentView as? IslandHostingView)?.hitRect = state.expandedRect.insetBy(dx: -6, dy: -6)
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
    }

    // MARK: 行点击(岛 → 面板)

    /// 点行 → 收起岛并请求打开主面板(实际打开由 App 层注入的 sink 完成)。
    func openPanel(for kind: MenuBarColumnKind) {
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
        panel.hasShadow = false
        panel.ignoresMouseEvents = true   // 永远不吃点击/悬停,交互完全透传
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
        if !keepRect.contains(NSEvent.mouseLocation) {
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
                self.state.rows = MenuBarTable.islandRows(columns: columns, config: model.thresholdConfig,
                                                          moneyFloor: model.moneyFloor)
                self.state.health = MenuBarTable.islandHealth(columns: columns, config: model.thresholdConfig,
                                                              moneyFloor: model.moneyFloor)
                self.state.moneyFloor = model.moneyFloor
                self.state.updated = model.lastUpdated
            }
    }
}

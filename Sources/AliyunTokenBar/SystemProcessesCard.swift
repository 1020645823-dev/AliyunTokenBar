import SwiftUI
import AppKit
import AliyunTokenBarCore

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
            }
            .buttonStyle(.plain)
            .help("立即重新采样")
            .accessibilityLabel("立即重新采样")
        }
    }

    private var subTabPicker: some View {
        HStack(spacing: DesignTokens.spacingXS) {
            ForEach(SubTab.allCases) { t in
                SubTabButton(title: t.title, isSelected: subTab == t) {
                    withAnimation(.easeInOut(duration: 0.15)) { subTab = t }
                }
            }
        }
        .padding(DesignTokens.spacingXS - 1)
        .background(Color.atbCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radiusM))
    }

    /// 子标签按钮:选中蓝底白字,未选中 hover 轻微高亮(与主面板标签一致的交互)。
    private struct SubTabButton: View {
        let title: String
        let isSelected: Bool
        let action: () -> Void
        @State private var hovering = false
        var body: some View {
            Button(action: action) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isSelected ? .white : (hovering ? .atbTextPrimary : .atbTextSecondary))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .background(isSelected ? Color.atbBlue : (hovering ? Color.atbTextPrimary.opacity(0.07) : Color.clear))
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radiusS))
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
        }
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

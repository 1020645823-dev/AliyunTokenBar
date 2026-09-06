import SwiftUI
import AppKit
import AliyunTokenBarCore

// MARK: - 本机进程 · CPU/内存 双指标 Hero 卡 + Top 10 进程列表
//
// v2 视觉语言:
// - 顶部品牌行(银灰 CPU + 名称 + 立即采样)
// - **Hero 系统指标卡**:左 CPU / 右 内存,各占半宽,各自一个填充环 + 大数字百分比
// - 子页签(CPU/内存)做成统一的分段式,激活态用品牌色填充
// - 进程列表行:app icon + 名称 + 数值 + 迷你进度条 + kill 按钮;行 padding 紧凑但不死

struct SystemProcessesCard: View {
    enum SubTab: String, CaseIterable, Identifiable {
        case cpu, memory
        var id: String { rawValue }
        var title: String { self == .cpu ? "CPU Top" : "内存 Top" }
    }

    @State private var subTab: SubTab = .cpu
    @State private var confirmingPid: Int32?
    @State private var confirmDeadline: Date = .distantPast

    @ObservedObject private var monitor = ProcessListMonitor.shared
    @ObservedObject private var sysMonitor = SystemMetricsMonitor.shared

    private var brand: Color { .atbBrandSystem }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingM) {
            header
            heroMetricsCard
            subTabPicker
            processList
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            monitor.start()
            // Hero 指标卡需要系统采样;菜单栏「显示本机 CPU/内存」关闭时 AppDelegate 不会启动它,
            // 这里兜底(start 幂等);关闭面板时仅当该开关仍关闭才停采,避免干扰开关驱动的采样
            sysMonitor.start()
        }
        .onDisappear {
            monitor.stop()
            if !TokenPlanModel.shared.systemStatsEnabled {
                sysMonitor.stop()
            }
            confirmingPid = nil
        }
    }

    // MARK: 品牌行

    private var header: some View {
        HStack(spacing: DesignTokens.spacingS) {
            ATBProviderMark(tab: .system, size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text("本机监控")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.atbTextPrimary)
                Text("CPU / 内存 · 进程 Top 10")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color.atbTextTertiary)
                    .tracking(0.3)
            }
            Spacer(minLength: DesignTokens.spacingS)
            Button {
                monitor.refreshNow()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.atbTextTertiary)
                    .frame(width: 22, height: 22)
                    .background(Color.primary.opacity(0.06))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .help("立即重新采样")
            .accessibilityLabel("立即重新采样")
        }
    }

    // MARK: Hero 系统指标卡(CPU + 内存并列)

    private var heroMetricsCard: some View {
        let cpu = sysMonitor.cpuPercent
        let mem = sysMonitor.memoryPercent
        return HStack(spacing: DesignTokens.spacingM) {
            metricBlock(
                label: "CPU",
                pct: cpu,
                subtitle: cpu.map { cpuSubtitle($0) } ?? "采样中…"
            )
            metricBlock(
                label: "内存",
                pct: mem,
                subtitle: mem.map { memSubtitle($0) } ?? "采样中…"
            )
        }
    }

    private func metricBlock(label: String, pct: Int?, subtitle: String) -> some View {
        VStack(spacing: 6) {
            // 环 + 标签
            ZStack {
                ATBFillRing(
                    percentage: Double(pct ?? 0),
                    brand: brand,
                    diameter: 50, lineWidth: 5,
                    threshold: nil  // 系统指标不按阈值变色(永远品牌色)
                )
                VStack(spacing: 0) {
                    Text(pct.map { "\($0)%" } ?? "—")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Color.atbTextPrimary)
                    Text(label)
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Color.atbTextTertiary)
                        .textCase(.uppercase)
                        .tracking(0.5)
                }
            }
            Text(subtitle)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Color.atbTextTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DesignTokens.spacingS)
        .padding(.horizontal, DesignTokens.spacingS)
        .background(Color.atbCardBackground)
        .background(brand.opacity(0.05))
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.radiusM + 2)
                .strokeBorder(brand.opacity(0.18), lineWidth: DesignTokens.strokeHairline)
        )
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radiusM + 2))
    }

    private func cpuSubtitle(_ pct: Int) -> String {
        switch pct {
        case 0..<25: return "空闲"
        case 25..<60: return "轻负载"
        case 60..<85: return "中等负载"
        default: return "高负载"
        }
    }

    private func memSubtitle(_ pct: Int) -> String {
        let usedGB = sysMonitor.memoryUsedGB ?? 0
        let totalGB = sysMonitor.memoryTotalGB ?? 0
        if totalGB > 0 {
            return String(format: "%.1f / %.0f GB", usedGB, totalGB)
        }
        return pct < 60 ? "宽松" : (pct < 85 ? "中等" : "吃紧")
    }

    // MARK: 子页签

    private var subTabPicker: some View {
        HStack(spacing: 0) {
            ForEach(SubTab.allCases) { t in
                SubTabButton(title: t.title, isSelected: subTab == t, brand: brand) {
                    withAnimation(.easeInOut(duration: 0.18)) { subTab = t }
                }
            }
        }
        .padding(2.5)
        .background(Color.primary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private struct SubTabButton: View {
        let title: String
        let isSelected: Bool
        let brand: Color
        let action: () -> Void
        @State private var hovering = false
        var body: some View {
            Button(action: action) {
                Text(title)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? .white : (hovering ? Color.atbTextPrimary : Color.atbTextSecondary))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .background(
                        Group {
                            if isSelected {
                                ZStack {
                                    brand
                                    LinearGradient(colors: [.white.opacity(0.15), .clear],
                                                   startPoint: .top, endPoint: .bottom)
                                }
                            } else {
                                Color.clear
                            }
                        }
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }

    // MARK: 进程列表

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
        return VStack(spacing: DesignTokens.spacingXS) {
            if list.isEmpty {
                HStack { Spacer(); LoadingRing().frame(width: 18, height: 18); Spacer() }
                    .frame(height: 60)
                    .atbCard(alignment: .center)
            } else {
                ForEach(list) { p in
                    ProcessRow(snapshot: p, subTab: subTab, maxValue: maxValue,
                               isConfirming: confirmingPid == p.pid && Date() < confirmDeadline,
                               onKill: { killTapped(p) })
                }
            }
        }
    }

    /// kill 两步确认
    private func killTapped(_ p: ProcessSnapshot) {
        guard !p.isRoot else { return }
        if confirmingPid == p.pid, Date() < confirmDeadline {
            _ = ProcessListMonitor.kill(p.pid)
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

// MARK: - 进程行
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
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.atbTextPrimary)
                    .lineLimit(1)
                if snapshot.name != snapshot.appName {
                    Text(snapshot.name)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Color.atbTextTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: DesignTokens.spacingXS)
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: DesignTokens.spacingXS) {
                    Text(valueText)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Color.atbTextPrimary)
                    if snapshot.isRoot {
                        Text("系统")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(Color.atbTextTertiary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.primary.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                }
                miniBar
            }
            killButton
        }
        .padding(.horizontal, DesignTokens.spacingM - 2)
        .padding(.vertical, DesignTokens.spacingS - 2)
        .background(Color.atbCardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.radiusM - 2)
                .strokeBorder(Color.atbSeparator.opacity(0.4), lineWidth: DesignTokens.strokeHairline)
        )
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radiusM - 2))
    }

    @ViewBuilder
    private var procIcon: some View {
        if let appPath = snapshot.appPath {
            Image(nsImage: NSWorkspace.shared.icon(forFile: appPath))
                .resizable().frame(width: 18, height: 18)
        } else {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.atbTextTertiary)
                .frame(width: 18, height: 18)
        }
    }

    private var valueText: String {
        switch subTab {
        case .cpu:
            guard let pct = snapshot.cpuPercent else { return "—" }
            return String(format: "%.1f%%", pct)
        case .memory:
            return ProcessListMonitor.bytesToHuman(snapshot.memoryBytes)
        }
    }

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
                    .foregroundStyle(Color.atbBrandSystem.opacity(0.7))
            }
        }
        .frame(width: 76, height: 3)
    }

    private var killButton: some View {
        Button(action: onKill) {
            if isConfirming {
                Text("确认?")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.atbCritical)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.atbCritical.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(snapshot.isRoot ? Color.atbTextTertiary.opacity(0.35) : Color.atbTextSecondary)
            }
        }
        .buttonStyle(.plain)
        .disabled(snapshot.isRoot)
    }
}

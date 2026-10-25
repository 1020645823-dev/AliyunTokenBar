import SwiftUI
import AppKit
import AliyunTokenBarCore

// MARK: - 星云全源驾驶舱
//
// 星图与细节坞共用固定几何:窗口帧不得随悬停源/数据刷新改变。
// 星图统一展示剩余口径;细条仍展示已用,footer 明示两种口径。

struct IslandAmbientBackground: View {
    @Environment(\.islandPalette) private var palette
    let cornerRadius: CGFloat
    var elevated = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return ZStack {
            shape.fill(.ultraThinMaterial)
            shape.fill(palette.surfaceBase)
            shape.fill(
                LinearGradient(colors: [palette.surfaceSheen, .clear, palette.surfaceBlue],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            )
            RadialGradient(colors: [Color(red: 0.18, green: 0.42, blue: 1.0).opacity(palette.auroraBlue), .clear],
                           center: .center, startRadius: 0, endRadius: 110)
                .frame(width: 240, height: 160)
                .offset(x: -105, y: -92)
                .blur(radius: 16)
            RadialGradient(colors: [Color(red: 0.55, green: 0.20, blue: 0.95).opacity(palette.auroraPurple), .clear],
                           center: .center, startRadius: 0, endRadius: 120)
                .frame(width: 250, height: 180)
                .offset(x: 115, y: 105)
                .blur(radius: 22)
        }
        .clipShape(shape)
        .overlay(
            shape.strokeBorder(
                LinearGradient(colors: [palette.borderStrong, palette.borderAccent, palette.borderWeak],
                               startPoint: .topLeading, endPoint: .bottomTrailing),
                lineWidth: 0.65
            )
        )
        .shadow(color: elevated ? .black.opacity(palette.shadowOpacity) : .clear, radius: 12, x: 0, y: 6)
    }
}

struct IslandSourceHealthTicks: View {
    @Environment(\.islandPalette) private var palette
    let columns: [MenuBarTableColumn]
    let config: ThresholdConfig
    let moneyFloor: Double
    var subduedOK = false

    var body: some View {
        HStack(spacing: 1.5) {
            ForEach(columns, id: \.kind) { col in
                let state = MenuBarTable.state(col, config: config, moneyFloor: moneyFloor)
                Capsule()
                    .fill(state == .ok && subduedOK ? palette.textFaint : palette.stateColor(state))
                    .frame(width: 2, height: 7)
            }
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }
}

struct IslandExpandedContent: View {
    @Environment(\.islandPalette) private var palette
    let columns: [MenuBarTableColumn]
    let segmentsByKind: [MenuBarColumnKind: [IslandMeterSegment]]
    let health: IslandHealth
    let config: ThresholdConfig
    let moneyFloor: Double
    let updated: Date?
    let focusedKind: MenuBarColumnKind?
    let onFocus: (MenuBarColumnKind) -> Void
    let onTapRow: (MenuBarColumnKind) -> Void

    private var focusedColumn: MenuBarTableColumn? {
        columns.first(where: { $0.kind == focusedKind }) ?? columns.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            IslandDashboardHeader(columns: columns, health: health, config: config,
                                  moneyFloor: moneyFloor, updated: updated)
                .frame(height: IslandMetrics.headerHeight)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: IslandMetrics.gridGap),
                                     count: IslandMetrics.overviewColumns),
                      spacing: IslandMetrics.gridGap) {
                ForEach(columns, id: \.kind) { col in
                    IslandSourceTile(col: col, config: config, moneyFloor: moneyFloor,
                                     isFocused: focusedColumn?.kind == col.kind,
                                     onFocus: { onFocus(col.kind) },
                                     onTap: { onTapRow(col.kind) })
                }
            }
            .frame(height: IslandMetrics.gridHeight(sourceCount: columns.count), alignment: .top)
            .padding(.top, IslandMetrics.gapHeaderGrid)

            ZStack {
                if let col = focusedColumn {
                    IslandDetailDock(col: col, segments: segmentsByKind[col.kind] ?? [],
                                     config: config, moneyFloor: moneyFloor,
                                     onTap: { onTapRow(col.kind) })
                        .id(col.kind)
                        .transition(.opacity.combined(with: .scale(scale: 0.985)))
                } else {
                    Text("等待用量数据…")
                        .font(.system(size: 10))
                        .foregroundStyle(palette.textSecondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(height: IslandMetrics.detailHeight)
            .padding(.top, IslandMetrics.gapGridDetail)
            .animation(.easeInOut(duration: 0.16), value: focusedKind)

            HStack(spacing: 6) {
                Image(systemName: "cursorarrow.rays")
                    .font(.system(size: 8, weight: .semibold))
                Text("悬停切换 · 点击查看完整卡片")
                Spacer(minLength: 4)
                Text("值为剩余 · 细条为已用")
            }
            .font(.system(size: 8.5))
            .foregroundStyle(palette.textTertiary)
            .frame(height: IslandMetrics.footerHeight)
            .padding(.top, IslandMetrics.gapDetailFooter)
        }
        .padding(.horizontal, IslandMetrics.paddingH)
        .padding(.vertical, IslandMetrics.paddingV)
    }
}

private struct IslandDashboardHeader: View {
    @Environment(\.islandPalette) private var palette
    let columns: [MenuBarTableColumn]
    let health: IslandHealth
    let config: ThresholdConfig
    let moneyFloor: Double
    let updated: Date?

    private var normalCount: Int { max(0, columns.count - health.total) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.cyan.opacity(0.8))
                Text("CODING PULSE")
                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                    .tracking(1.15)
                    .foregroundStyle(palette.textSecondary)
                Spacer(minLength: 4)
                Circle()
                    .fill(Color.green)
                    .frame(width: 4.5, height: 4.5)
                    .shadow(color: .green.opacity(0.65), radius: 3)
                Text("LIVE")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .tracking(0.7)
                    .foregroundStyle(palette.textTertiary)
            }
            HStack(spacing: 5) {
                Text("\(columns.count) 个服务")
                    .foregroundStyle(palette.textSecondary)
                Text("·")
                    .foregroundStyle(palette.textFaint.opacity(0.45))
                Text(health.total == 0 ? "全部正常" : "\(normalCount) 正常 · \(MenuBarTable.islandHealthText(health))")
                    .foregroundStyle(health.total == 0 ? palette.textSecondary : palette.stateColor(health.worst))
                if columns.count > 1 {
                    IslandSourceHealthTicks(columns: columns, config: config,
                                            moneyFloor: moneyFloor, subduedOK: true)
                        .padding(.leading, 2)
                }
                Spacer(minLength: 4)
                if let updated {
                    Text(Self.updatedText(updated))
                        .monospacedDigit()
                } else {
                    Text("等待刷新")
                }
            }
            .font(.system(size: 8.5, weight: .medium))
            .foregroundStyle(palette.textTertiary)
        }
    }

    private static func updatedText(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        return fmt.string(from: date)
    }
}

private struct IslandSourceTile: View {
    @Environment(\.islandPalette) private var palette
    let col: MenuBarTableColumn
    let config: ThresholdConfig
    let moneyFloor: Double
    let isFocused: Bool
    let onFocus: () -> Void
    let onTap: () -> Void

    @State private var hovering = false

    private var state: ColumnState { MenuBarTable.state(col, config: config, moneyFloor: moneyFloor) }
    private var tint: Color { palette.stateColor(state) }
    private var brand: Color { col.kind.brandMark?.mainColor ?? .atbBrandSystem }
    private var metric: IslandOverviewMetric { MenuBarTable.islandOverviewMetric(col) }
    private var remainingPct: Int? {
        metric.value.pct.map { max(0, min(100, 100 - $0)) }
    }

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                Circle()
                    .fill(brand.opacity(isFocused ? 0.15 : 0.07))
                Circle()
                    .stroke(palette.track, lineWidth: 2.2)
                if let remainingPct {
                    Circle()
                        .trim(from: 0, to: CGFloat(remainingPct) / 100)
                        .stroke(tint, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .shadow(color: tint.opacity(isFocused ? 0.48 : 0.20), radius: isFocused ? 4 : 2)
                } else {
                    Circle()
                        .stroke(tint.opacity(state == .ok ? 0.24 : 0.72), lineWidth: 1.4)
                }
                if let mark = col.kind.brandMark {
                    mark.mark(in: CGRect(x: 0, y: 0, width: 14, height: 14))
                } else {
                    Image(systemName: col.kind.symbolName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(palette.textPrimary)
                }
            }
            .frame(width: 30, height: 30)

            Text(col.kind.displayName)
                .font(.system(size: 8.5, weight: .medium))
                .foregroundStyle(isFocused ? palette.textPrimary : palette.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            HStack(spacing: 2) {
                Text(metric.label)
                    .font(.system(size: 7.5, weight: .medium))
                    .foregroundStyle(palette.textTertiary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(remainingPct.map { "\($0)%" } ?? metric.value.text)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(remainingPct == nil && state == .ok ? palette.textPrimary : tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity)
        .frame(height: IslandMetrics.tileHeight)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(brand.opacity(isFocused ? 0.12 : 0.035))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(palette.tileOverlay.opacity(hovering ? 0.045 : 0.012)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isFocused ? tint.opacity(0.48) : palette.tileStroke, lineWidth: isFocused ? 0.8 : 0.5)
        )
        .overlay(alignment: .topTrailing) {
            Circle()
                .fill(tint)
                .frame(width: 3.5, height: 3.5)
                .opacity(state == .ok ? 0.32 : 0.95)
                .padding(5)
        }
        .scaleEffect(hovering ? 1.025 : 1)
        .animation(.easeOut(duration: 0.14), value: hovering)
        .animation(.easeInOut(duration: 0.16), value: isFocused)
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { inside in
            hovering = inside
            if inside {
                onFocus()
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .onTapGesture(perform: onTap)
        .help("\(col.kind.displayName) · \(MenuBarTable.islandRowText(col))")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(col.kind.displayName)，\(MenuBarTable.islandRowText(col))")
        .accessibilityAddTraits(.isButton)
    }
}

private struct IslandDetailDock: View {
    @Environment(\.islandPalette) private var palette
    let col: MenuBarTableColumn
    let segments: [IslandMeterSegment]
    let config: ThresholdConfig
    let moneyFloor: Double
    let onTap: () -> Void

    private var state: ColumnState { MenuBarTable.state(col, config: config, moneyFloor: moneyFloor) }
    private var tint: Color { palette.stateColor(state) }
    private var brand: Color { col.kind.brandMark?.mainColor ?? .atbBrandSystem }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if let mark = col.kind.brandMark {
                    mark.mark(in: CGRect(x: 0, y: 0, width: 15, height: 15))
                } else {
                    Image(systemName: col.kind.symbolName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                }
                Text(col.kind.displayName)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                Text("DETAIL")
                    .font(.system(size: 6.5, weight: .bold, design: .monospaced))
                    .tracking(0.7)
                    .foregroundStyle(brand.opacity(0.85))
                Spacer(minLength: 4)
                IslandDetailStateBadge(state: state)
                Image(systemName: "chevron.right")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(palette.textFaint)
            }
            .frame(height: 18)

            Text(MenuBarTable.islandRowText(col))
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(palette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .frame(height: 18, alignment: .leading)

            Group {
                if segments.isEmpty {
                    IslandDetailContextNote(col: col, moneyFloor: moneyFloor)
                } else {
                    IslandDetailSegments(segments: segments)
                }
            }
            .frame(height: 27, alignment: .leading)

            IslandDetailCaption(col: col, segments: segments)
                .frame(height: 22, alignment: .topLeading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    LinearGradient(colors: [brand.opacity(0.105), palette.detailBase],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(tint.opacity(state == .ok ? 0.12 : 0.32), lineWidth: 0.65)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture(perform: onTap)
        .onHover { inside in
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

private struct IslandDetailStateBadge: View {
    @Environment(\.islandPalette) private var palette
    let state: ColumnState

    private var text: String {
        switch state {
        case .needsAction: return "需重登"
        case .critical: return "告急"
        case .warning: return "预警"
        case .ok: return "正常"
        }
    }

    var body: some View {
        Text(text)
            .font(.system(size: 7.5, weight: .bold))
            .foregroundStyle(palette.stateColor(state))
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(palette.stateColor(state).opacity(0.12)))
    }
}

private struct IslandDetailSegments: View {
    @Environment(\.islandPalette) private var palette
    let segments: [IslandMeterSegment]

    var body: some View {
        HStack(spacing: 9) {
            ForEach(segments) { seg in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 3) {
                        Text(seg.label)
                            .font(.system(size: 7.5, weight: .semibold))
                            .foregroundStyle(palette.textSecondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                        Spacer(minLength: 0)
                        Text("\(seg.usedPct)%")
                            .font(.system(size: 8.5, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(palette.stateColor(seg.state))
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(palette.track)
                            Capsule()
                                .fill(palette.stateColor(seg.state))
                                .frame(width: max(1, geo.size.width * CGFloat(seg.usedPct) / 100))
                        }
                    }
                    .frame(height: 3)
                }
                .frame(maxWidth: .infinity)
                .help(seg.detail ?? "\(seg.label) 已用 \(seg.usedPct)%")
            }
        }
        .padding(.horizontal, 1)
    }
}

private struct IslandDetailContextNote: View {
    @Environment(\.islandPalette) private var palette
    let col: MenuBarTableColumn
    let moneyFloor: Double

    private var balance: Double? {
        [col.primary, col.secondary].compactMap(\.amount).first
    }

    private var hasMetric: Bool {
        col.primary.text != "—" || col.secondary.text != "—"
    }

    private var text: String {
        if col.needsAttention {
            return "登录状态需要处理 · 点击打开对应面板"
        }
        if moneyFloor > 0, let balance {
            let floor = moneyFloor.rounded() == moneyFloor
                ? String(format: "%.0f", moneyFloor)
                : String(format: "%.2f", moneyFloor)
            return balance < moneyFloor
                ? "余额低于 ¥\(floor) 告急下限 · 点击查看消费趋势"
                : "余额告急下限 ¥\(floor) · 当前未触发"
        }
        if col.kind == .deepSeek, hasMetric {
            return "今日花费为本地快照估算 · 点击查看历史趋势"
        }
        if balance != nil {
            return "余额按最近成功快照更新 · 点击查看完整卡片"
        }
        if hasMetric {
            return "指标按最近成功快照更新 · 点击查看完整卡片"
        }
        return "暂无实时指标 · 点击查看完整卡片"
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: balance != nil ? "banknote" : "chart.line.uptrend.xyaxis")
                .font(.system(size: 8, weight: .semibold))
            Text(text)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
        .font(.system(size: 8, weight: .medium))
        .foregroundStyle(palette.textSecondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(Capsule().fill(palette.tileOverlay.opacity(0.04)))
    }
}

private struct IslandDetailCaption: View {
    @Environment(\.islandPalette) private var palette
    let col: MenuBarTableColumn
    let segments: [IslandMeterSegment]

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if segments.isEmpty {
                Text(emptyCaption)
                    .foregroundStyle(palette.textSecondary)
            } else {
                ForEach(Array(segments.prefix(2))) { seg in
                    Text((seg.detail ?? "\(seg.label) 已用 \(seg.usedPct)%") + suffix(for: seg))
                        .foregroundStyle(palette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .font(.system(size: 8, weight: .medium))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyCaption: String {
        if col.needsAttention {
            return "重新登录后恢复实时配额与账户明细"
        }
        let hasMetric = col.primary.text != "—" || col.secondary.text != "—"
        guard hasMetric else { return "数据就绪后展示用量与账户明细" }
        let hasBalance = [col.primary, col.secondary].contains(where: { $0.amount != nil })
        return hasBalance || col.kind == .deepSeek
            ? "趋势与可用天数按历史快照估算"
            : "点击查看完整指标与账户明细"
    }

    private func suffix(for seg: IslandMeterSegment) -> String {
        guard segments.count > 2, seg.id == segments[1].id else { return "" }
        return " · 另 \(segments.count - 2) 段"
    }
}

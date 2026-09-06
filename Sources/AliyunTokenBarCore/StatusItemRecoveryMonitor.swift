import Foundation
import CoreGraphics

/// 状态项可见性恢复状态机(运行期菜单栏图标被系统隐藏/停放的自愈)。
///
/// 背景:macOS 26 会在菜单栏空间竞争(刘海屏+全屏应用+多第三方状态项)或系统级
/// 开关变化时,把 NSStatusItem 隐藏(isVisible=false)或「停放」到屏幕外
/// (isVisible=true 但按钮窗口帧不在任何屏幕内)。Accessory 应用没有 Dock 图标,
/// 状态项是唯一入口——启动时可见、运行中消失的话,旧逻辑(仅启动采样)无自愈路径,
/// 进程存活但用户永久失联(表现为「应用打不开」)。
///
/// 采样判定用「有效可见」:isVisible 且按钮窗口帧有足够面积落在屏幕内(停放态
/// 的帧只有边缘几像素蹭在屏幕内)。帧信息缺失时只信 isVisible——状态项刚创建、
/// 窗口未落位时 window 为 nil,此时误判会触发不必要的重建。
/// 连续 requiredHiddenSamples 次异常后按阶梯升级恢复动作
/// (resurrect → recreate → dockFallback);恢复可见后阶梯回零,下次从最轻动作
/// 重试;Dock 回退一旦发出则保持(与既有 handleVisibilityFallback 行为一致,
/// 不反复横跳)。
public struct StatusItemRecoveryMonitor {
    /// 恢复阶梯动作(由轻到重)。
    public enum Action: Equatable {
        /// 无需动作
        case none
        /// 重设 isVisible=true(对抗系统单次隐藏)
        case resurrect
        /// 重建状态项(对抗「停放」:停放坐标挂在旧 item 上,重建即重排)
        case recreate
        /// 回退 Dock 图标+通知(保底入口)
        case dockFallback
    }

    private let requiredHiddenSamples: Int
    private var hiddenSamples = 0
    private var nextActionIndex = 0 // 0=resurrect, 1=recreate, 2=dockFallback
    private var dockFallbackIssued = false

    public init(requiredHiddenSamples: Int) {
        self.requiredHiddenSamples = max(1, requiredHiddenSamples)
    }

    /// Dock 回退是否已发出(发出后保持,不撤销)。
    public var hasIssuedDockFallback: Bool { dockFallbackIssued }

    /// 采样一次「有效可见性」,返回应执行的恢复动作。
    /// 触发动作后采样计数清零——给恢复动作留出生效窗口,不连续升级。
    public mutating func sample(isEffectivelyVisible: Bool) -> Action {
        if isEffectivelyVisible {
            hiddenSamples = 0
            nextActionIndex = dockFallbackIssued ? 2 : 0
            return .none
        }
        hiddenSamples += 1
        guard hiddenSamples >= requiredHiddenSamples else { return .none }
        hiddenSamples = 0
        switch nextActionIndex {
        case 0:
            nextActionIndex = 1
            return .resurrect
        case 1:
            nextActionIndex = 2
            return .recreate
        default:
            if dockFallbackIssued { return .none }
            dockFallbackIssued = true
            return .dockFallback
        }
    }

    /// 有效可见性判定:isVisible 且按钮帧与屏幕的可见面积占比达标。
    /// 停放态的帧只有边缘几像素蹭在屏幕内(如 AX 停放位 (-1,1113) 换算到
    /// AppKit 左下原点坐标后仍与屏幕有微小交集),按「有交集」判定会漏检,
    /// 因此要求 ≥ requiredVisibleAreaRatio 的帧面积落在屏幕内。
    /// 帧信息缺失时只信 isVisible——状态项刚创建、窗口未落位时 window 为 nil,
    /// 误判会触发不必要的重建。
    public static func isEffectivelyVisible(
        isVisible: Bool,
        buttonFrame: CGRect?,
        screenFrames: [CGRect],
        requiredVisibleAreaRatio: CGFloat = 0.5
    ) -> Bool {
        guard isVisible else { return false }
        guard let frame = buttonFrame, !screenFrames.isEmpty else { return true }
        let frameArea = frame.width * frame.height
        guard frameArea > 0 else { return true }
        let visibleArea = screenFrames.reduce(CGFloat(0)) { sum, screen in
            let overlap = frame.intersection(screen)
            return sum + overlap.width * overlap.height
        }
        return visibleArea >= frameArea * requiredVisibleAreaRatio
    }
}

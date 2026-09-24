import UIKit

/// 应用级界面方向控制（录制中锁界面方向）
/// -------------------------------------------------------------
/// 背景：SwiftUI 内嵌子控制器的 supportedInterfaceOrientations 通常
/// **不会被 UIKit 查询**（SwiftUI 托管控制器不聚合子控制器的方向），
/// 上一版 OrientationLockController 方案大概率不生效。
///
/// 可靠做法：通过 @UIApplicationDelegateAdaptor 挂载本 Delegate，
/// 在 application(_:supportedInterfaceOrientationsFor:) 动态返回支持方向：
///   - 录制中：仅返回录制开始时的方向（锁屏）
///   - 停止录制：返回 .all（恢复横竖屏自由旋转）
/// 状态变化时调用 setNeedsUpdateOfSupportedInterfaceOrientations()
/// 主动触发系统重新查询。
final class AppDelegate: NSObject, UIApplicationDelegate {

    /// 当前锁定的界面方向；nil = 不锁定（允许全部方向）
    private(set) var lockedOrientation: UIInterfaceOrientation?

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        guard let lockedOrientation else { return .all }
        switch lockedOrientation {
        case .landscapeLeft:       return .landscapeLeft
        case .landscapeRight:      return .landscapeRight
        case .portraitUpsideDown:  return .portraitUpsideDown
        default:                   return .portrait
        }
    }

    /// 锁定 / 解除界面方向；变更后主动触发系统重新查询
    /// 若新 mask 不含当前方向，UIKit 会自动把界面转回支持的方向。
    func applyOrientationLock(_ orientation: UIInterfaceOrientation?) {
        // 值未变化时直接返回：避免 SwiftUI 每次 body 更新（录制期间 Timer 每 0.1s
        // 更新 recordingElapsed）都触发 setNeedsUpdateOfSupportedInterfaceOrientations，
        // 造成方向系统高频回调、干扰渲染。
        guard lockedOrientation != orientation else { return }
        lockedOrientation = orientation
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.windows.first?.rootViewController?
            .setNeedsUpdateOfSupportedInterfaceOrientations()
    }
}

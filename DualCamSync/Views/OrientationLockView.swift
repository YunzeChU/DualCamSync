import SwiftUI
import UIKit

/// 录制中锁定界面方向（SwiftUI 侧）
/// -------------------------------------------------------------
/// 背景：CameraManager 只锁了"相机画面方向"（updateInterfaceOrientation
/// 在录制中不再更新），但屏幕本身仍会跟随设备旋转，导致录制中三键布局
/// 仍会横竖切换——不符合"录制中锁方向"的完整含义。
///
/// 本控制器通过动态返回 supportedInterfaceOrientations 实现真正的界面锁：
///   - 录制中：锁住录制开始时的方向（竖屏锁竖屏、横屏锁横屏）
///   - 停止录制：恢复全部方向（.all）
/// 挂载方式：作为 CameraView 的 .background(OrientationLockView(...))，
/// 它是 SwiftUI 托管控制器下的子控制器，动态锁方向是社区验证有效的方案。
struct OrientationLockView: UIViewControllerRepresentable {

    /// 需要锁定时锁住的方向；nil = 不锁定（允许全部方向）
    let lockedOrientation: UIInterfaceOrientation?

    func makeUIViewController(context: Context) -> OrientationLockController {
        OrientationLockController()
    }

    func updateUIViewController(_ uiViewController: OrientationLockController,
                                context: Context) {
        uiViewController.lockedOrientation = lockedOrientation
    }
}

final class OrientationLockController: UIViewController {
    var lockedOrientation: UIInterfaceOrientation? {
        didSet {
            // 通知系统重新查询支持方向（iOS 16+；项目最低 iOS 26 必然可用）
            setNeedsUpdateOfSupportedInterfaceOrientations()
        }
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        guard let lockedOrientation else { return .all }
        switch lockedOrientation {
        case .landscapeLeft:       return .landscapeLeft
        case .landscapeRight:      return .landscapeRight
        case .portraitUpsideDown:  return .portraitUpsideDown
        default:                   return .portrait
        }
    }
}

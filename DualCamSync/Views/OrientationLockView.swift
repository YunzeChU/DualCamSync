import SwiftUI
import UIKit

/// 录制中锁定界面方向（SwiftUI 侧入口）
/// -------------------------------------------------------------
/// 背景：CameraManager 只锁了"相机画面方向"（updateInterfaceOrientation
/// 在录制中不再更新），但屏幕本身仍会跟随设备旋转，导致录制中三键布局
/// 横竖切换——不符合"录制中锁方向"的完整含义。
///
/// 本视图只是"状态感知入口"：录制开始/停止时，通过 AppDelegate 的
/// application(_:supportedInterfaceOrientationsFor:) 动态返回支持方向，
/// 系统据此锁定屏幕方向（方案详见 AppDelegate.swift）。
/// 注意：不要在子控制器里 override supportedInterfaceOrientations——
/// SwiftUI 托管控制器不会查询子控制器方向，该做法不生效。
struct OrientationLockView: UIViewControllerRepresentable {

    /// 需要锁定时锁住的方向；nil = 不锁定（允许全部方向）
    let lockedOrientation: UIInterfaceOrientation?

    func makeUIViewController(context: Context) -> UIViewController {
        // 占位控制器：仅作为 representable 的状态更新载体
        UIViewController()
    }

    func updateUIViewController(_ uiViewController: UIViewController,
                                context: Context) {
        (UIApplication.shared.delegate as? AppDelegate)?
            .applyOrientationLock(lockedOrientation)
    }
}

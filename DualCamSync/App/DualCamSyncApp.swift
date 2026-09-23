import SwiftUI

/// DualCamSync 应用入口
/// - 主界面：CameraView（双摄预览 + 液态玻璃控制层）
/// - 全应用深色外观（相机 App 惯例）
@main
struct DualCamSyncApp: App {
    // 应用级方向锁（录制中锁界面方向，见 AppDelegate 注释）
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            CameraView()
                .preferredColorScheme(.dark)
                .statusBarHidden(true)
        }
    }
}

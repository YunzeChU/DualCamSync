import SwiftUI

/// DualCamSync 应用入口
/// - 主界面：CameraView（双摄预览 + 液态玻璃控制层）
/// - 全应用深色外观（相机 App 惯例）
@main
struct DualCamSyncApp: App {
    var body: some Scene {
        WindowGroup {
            CameraView()
                .preferredColorScheme(.dark)
                .statusBarHidden(true)
        }
    }
}

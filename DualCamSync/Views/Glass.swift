import SwiftUI

/// Liquid Glass 液态玻璃统一修饰器
/// -------------------------------------------------------------
/// 硬性约束：所有控件/面板一律使用原生 .glassEffect()，
/// 禁止用模拟磨砂（如 .ultraThinMaterial）替代。
///
/// iOS 26 的玻璃材质会实时采样底层内容（这里是双摄预览画面），
/// 自动呈现动态模糊与折射效果；配合大圆角即可获得原生相机观感。
extension View {

    /// 面板容器（功能面板 / 设置面板）
    /// 用户要求（真机验证）：液态玻璃背景在真机上渲染为**胶囊形**，
    /// clipShape(RoundedRectangle) 无法裁成圆角矩形 → **直接不要背景**，
    /// 且**不用任何替代材质**。面板内容（分区/行/文字）完整保留，
    /// 仅去掉玻璃底，让面板直接浮在预览画面上。
    func glassPanel(cornerRadius: CGFloat = 28) -> some View {
        self
    }

    /// 玻璃胶囊（镜头角标 / 状态条）
    func glassCapsule() -> some View {
        self
            .glassEffect(.regular)
            .clipShape(Capsule())
    }

    /// 玻璃圆形按钮
    func glassCircle(size: CGFloat) -> some View {
        self
            .frame(width: size, height: size)
            .glassEffect(.regular)
            .clipShape(Circle())
    }
}

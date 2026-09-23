import SwiftUI

/// Liquid Glass 液态玻璃统一修饰器
/// -------------------------------------------------------------
/// 硬性约束：所有控件/面板一律使用原生 .glassEffect()，
/// 禁止用模拟磨砂（如 .ultraThinMaterial）替代。
///
/// iOS 26 的玻璃材质会实时采样底层内容（这里是双摄预览画面），
/// 自动呈现动态模糊与折射效果；配合大圆角即可获得原生相机观感。
extension View {

    /// 圆角玻璃面板（设置面板 / 选摄面板）
    func glassPanel(cornerRadius: CGFloat = 28) -> some View {
        self
            .glassEffect(.regular)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
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

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
    /// 注意：iOS 26 液态玻璃的默认背景形状是"胶囊"（Capsule），
    /// 直接 .glassEffect 后内容越多越接近椭圆/药丸。要变成圆角矩形，
    /// 必须用 .containerShape 指定形状（环境值从外层传给内层 glassEffect，
    /// 因此 containerShape 需放在 glassEffect 之后；为兼容各版本渲染路径，
    /// 前后各放一份 + clipShape 兜底裁切，三者叠加必出圆角矩形）。
    func glassPanel(cornerRadius: CGFloat = 28) -> some View {
        self
            .containerShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .glassEffect(.regular)
            .containerShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
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

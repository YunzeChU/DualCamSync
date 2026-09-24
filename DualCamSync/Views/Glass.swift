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
    /// 使用原生 `.glassEffect(.regular)` 保证在 iOS 26.6 上一定能渲染，
    /// 再用 `.clipShape(RoundedRectangle)` 把玻璃背景裁成圆角矩形。
    /// 不在 glassEffect 的 in: 中直接塞形状——部分 26.x 系统上该写法会导致
    /// 面板整体不可见（用户反馈“点击后没有界面展开”）。
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

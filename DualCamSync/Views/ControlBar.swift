import SwiftUI

/// 玻璃按钮按压反馈：手指按下轻微缩小，松手回弹（原生手感）
struct GlassPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// 玻璃圆形图标按钮（功能键 / 设置键）
/// 命中修复：glassEffect 的 UIKit 命中层（UIGlassEffectView）在拖动小窗等
/// body 重算后可能不同步，导致按钮收不到触摸（真机症状：拖动小窗后功能/
/// 设置键点不了、点非玻璃的录制键触发刷新后恢复）。因此**玻璃装饰与命中
/// 载体分离**：外层 Button 承担命中（普通 SwiftUI 命中），玻璃圆只做外观
/// 且 .allowsHitTesting(false) 不参与命中。
struct GlassIconButton: View {
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                // 玻璃装饰：纯外观，不参与命中（UIGlassEffectView 命中缺陷的根源）
                Circle()
                    .fill(.white.opacity(0.12))
                    .glassEffect(.regular)
                    .clipShape(Circle())
                    .allowsHitTesting(false)
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.white)
            }
            .frame(width: 48, height: 48)
            .contentShape(Circle())
        }
        .buttonStyle(GlassPressStyle())
        .contentShape(Circle())   // 固定命中形状，点击更灵敏
    }
}

/// 录制快门按钮（仿原生相机：白圈 + 白色圆钮，录制中变为红色圆角方块）
struct ShutterButton: View {
    let isRecording: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .stroke(.white, lineWidth: 4)
                    .frame(width: 68, height: 68)
                RoundedRectangle(cornerRadius: isRecording ? 6 : 24, style: .continuous)
                    .fill(isRecording ? Color.red : Color.white)
                    .frame(width: isRecording ? 26 : 54,
                           height: isRecording ? 26 : 54)
                    .animation(.spring(duration: 0.3), value: isRecording)
            }
            .padding(8)                // 扩大命中区域，手指更容易点到
            .contentShape(Circle())
        }
        .buttonStyle(GlassPressStyle())
    }
}

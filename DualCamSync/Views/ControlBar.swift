import SwiftUI

/// 玻璃圆形图标按钮（布局切换 / 设置入口）
struct GlassIconButton: View {
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .glassEffect(.regular)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
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
            .padding(4)
        }
        .buttonStyle(.plain)
    }
}

/// 镜头角标（液态玻璃胶囊）：显示镜头名称 + AE/AF 锁定开关
/// 点按角标上的锁图标可锁定/解锁该路对焦与曝光
struct CameraLabelView: View {
    let name: String
    let locked: Bool
    let onToggleLock: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onToggleLock) {
                Image(systemName: locked ? "lock.fill" : "lock.open")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(locked ? Color.yellow : .white)
            }
            .buttonStyle(.plain)

            Text(name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .glassCapsule()
    }
}

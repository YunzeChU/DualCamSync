import SwiftUI

/// 选摄面板（液态玻璃弹层）
/// -------------------------------------------------------------
/// 列出全部可用镜头，供挑选某一插槽（A/B）的摄像头。
/// 与另一路不兼容的组合自动置灰（CameraPairProbe 运行时探测），
/// 符合需求 10 的"不支持所选镜头组合自动置灰并提示"。
struct CameraPickerPanel: View {
    let slot: CameraSlot
    let onSelect: (CameraOption) -> Void
    let onDismiss: () -> Void

    @EnvironmentObject private var camera: CameraManager

    var body: some View {
        let other = (slot == .a) ? camera.cameraB : camera.cameraA
        let current = (slot == .a) ? camera.cameraA : camera.cameraB

        VStack(spacing: 6) {
            Text("选择 \(slot.displayName) 路镜头")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.top, 12)
                .padding(.bottom, 4)

            ForEach(camera.availableCameras) { option in
                let usable = other.map { CameraPairProbe.shared.canUseTogether($0, option) } ?? true
                let isCurrent = option.id == current?.id

                Button {
                    onSelect(option)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: option.systemImage)
                            .font(.system(size: 14))
                            .frame(width: 22)
                        Text(option.fullName)
                            .font(.system(size: 14, weight: .medium))
                        Spacer()
                        if isCurrent {
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.yellow)
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                }
                .buttonStyle(.plain)
                .disabled(!usable || isCurrent)
                .opacity(usable ? 1 : 0.35)
            }
            .padding(.horizontal, 8)
        }
        .padding(.bottom, 12)
        .frame(width: 250)
        .glassPanel(cornerRadius: 26)
    }
}

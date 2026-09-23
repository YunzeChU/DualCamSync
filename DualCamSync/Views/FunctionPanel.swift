import SwiftUI

/// 功能面板（液态玻璃二级菜单）
/// -------------------------------------------------------------
/// 收纳原"镜头选择 + 布局切换"等高频拍摄设置：
///   镜头A / 镜头B / 布局 / 录制模式 / 分辨率
/// 每个分区为可展开行，展开时选项以原生弹簧动画淡入缩放
/// （iOS 26 液态玻璃菜单观感）；与另一路不兼容的镜头、
/// 当前规格不支持的档位自动置灰（需求 10）。
struct FunctionPanel: View {
    let onDismiss: () -> Void

    @EnvironmentObject private var camera: CameraManager
    @State private var expanded: String?

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 6) {
                header
                cameraSection("镜头 A", slot: .a)
                cameraSection("镜头 B", slot: .b)
                layoutSection
                modeSection
                presetSection
                if camera.isRecording {
                    Text("录制中：设置已锁定")
                        .font(.system(size: 11))
                        .foregroundStyle(.yellow.opacity(0.8))
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 6)
                }
            }
            .padding(16)
        }
        .frame(width: 300)
        .glassPanel(cornerRadius: 30)
    }

    // MARK: - 分区组件

    /// 镜头选择分区（A / B 各一个）
    private func cameraSection(_ title: String,
                               slot: CameraSlot) -> some View {
        let key = "cam-\(slot.id)"
        let current = slot == .a ? camera.cameraA : camera.cameraB
        let other = slot == .a ? camera.cameraB : camera.cameraA
        return VStack(spacing: 4) {
            sectionHeader(key: key, title: title, value: current?.fullName ?? "—") {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    expanded = expanded == key ? nil : key
                }
            }
            if expanded == key {
                VStack(spacing: 2) {
                    ForEach(camera.availableCameras) { option in
                        let usable = other.map { CameraPairProbe.shared.canUseTogether($0, option) } ?? true
                        let isCurrent = option.id == current?.id
                        optionRow(title: option.fullName,
                                  systemImage: option.systemImage,
                                  usable: usable,
                                  isCurrent: isCurrent) {
                            camera.selectCamera(option, for: slot)
                            onDismiss()
                        }
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            }
        }
    }

    /// 布局分区：分屏 / 画中画
    private var layoutSection: some View {
        let key = "layout"
        return VStack(spacing: 4) {
            sectionHeader(key: key, title: "布局", value: camera.layout.displayName) {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    expanded = expanded == key ? nil : key
                }
            }
            if expanded == key {
                VStack(spacing: 2) {
                    ForEach(PreviewLayout.allCases) { layout in
                        Button {
                            camera.setLayout(layout)
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                expanded = nil
                            }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: layout.systemImage)
                                    .font(.system(size: 14))
                                    .frame(width: 22)
                                Text(layout.displayName)
                                    .font(.system(size: 14, weight: .medium))
                                Spacer()
                                if camera.layout == layout {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(.yellow)
                                }
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(camera.layout == layout ? Color.white.opacity(0.14) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(camera.isRecording)
                        .opacity(camera.isRecording ? 0.35 : 1)
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            }
        }
    }

    /// 录制模式分区：合成单条 / 双独立文件
    private var modeSection: some View {
        let key = "mode"
        return VStack(spacing: 4) {
            sectionHeader(key: key, title: "录制模式", value: camera.mode.displayName) {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    expanded = expanded == key ? nil : key
                }
            }
            if expanded == key {
                VStack(spacing: 2) {
                    ForEach(RecordingMode.allCases) { mode in
                        Button {
                            camera.setMode(mode)
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                expanded = nil
                            }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: mode == .composite ? "square.split.2x1" : "rectangle.stack")
                                    .font(.system(size: 14))
                                    .frame(width: 22)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(mode.displayName)
                                        .font(.system(size: 14, weight: .medium))
                                    Text(mode.detail)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.white.opacity(0.55))
                                }
                                Spacer()
                                if camera.mode == mode {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(.yellow)
                                }
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(camera.mode == mode ? Color.white.opacity(0.14) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(camera.isRecording)
                        .opacity(camera.isRecording ? 0.35 : 1)
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            }
        }
    }

    /// 分辨率/帧率分区：不支持档位自动置灰
    private var presetSection: some View {
        let key = "preset"
        return VStack(spacing: 4) {
            sectionHeader(key: key, title: "分辨率 / 帧率", value: camera.preset.displayName) {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    expanded = expanded == key ? nil : key
                }
            }
            if expanded == key {
                VStack(spacing: 2) {
                    ForEach(ResolutionPreset.allCases) { preset in
                        let available = camera.presetAvailability[preset] ?? false
                        Button {
                            camera.setPreset(preset)
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                expanded = nil
                            }
                        } label: {
                            HStack(spacing: 10) {
                                Text(preset.displayName)
                                    .font(.system(size: 14, weight: .medium))
                                    .frame(width: 22, alignment: .leading)
                                Text("\(preset.fps) fps")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.white.opacity(0.55))
                                Spacer()
                                if camera.preset == preset {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(.yellow)
                                }
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(camera.preset == preset ? Color.white.opacity(0.14) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(!available || camera.isRecording)
                        .opacity(available ? 1 : 0.35)
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            }
        }
    }

    /// 可展开分区头：标题 + 当前值 + 旋转箭头
    private func sectionHeader(key: String,
                               title: String,
                               value: String,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Text(value)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                    .rotationEffect(.degrees(expanded == key ? 180 : 0))
                    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: expanded == key)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(Color.white.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// 通用选项行（置灰 + 当前项高亮 + 对勾）
    private func optionRow(title: String,
                           systemImage: String,
                           usable: Bool,
                           isCurrent: Bool,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 14))
                    .frame(width: 22)
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                Spacer()
                if isCurrent {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.yellow)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(isCurrent ? Color.white.opacity(0.14) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!usable || isCurrent)
        .opacity(usable ? 1 : 0.35)
    }

    private var header: some View {
        HStack {
            Text("功能")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(.white.opacity(0.15), in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.bottom, 8)
    }
}

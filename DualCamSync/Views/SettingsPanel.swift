import SwiftUI

/// 设置面板（液态玻璃弹层）
/// -------------------------------------------------------------
/// 包含：对焦/曝光锁定（每路独立）、杜比视界 HDR、空间音频、
/// 每路防抖开关、每路曝光补偿滑块。
/// 所有"当前设备/组合不支持"的选项自动置灰（需求 5、6、10）。
struct SettingsPanel: View {
    let onDismiss: () -> Void

    @EnvironmentObject private var camera: CameraManager

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {

                header

                // 对焦 / 曝光锁定（每路独立：对焦锁与曝光锁互不影响，可单独锁其一）
                sectionTitle("对焦 / 曝光锁定")
                ForEach(CameraSlot.allCases) { slot in
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("\(slot.displayName) 路 对焦锁定", isOn: Binding(
                            get: { camera.focusLockState[slot.index] },
                            set: { camera.setFocusLock($0, slot: slot) }
                        ))
                        .tint(.yellow)
                        .disabled(camera.isRecording)
                        Toggle("\(slot.displayName) 路 曝光锁定", isOn: Binding(
                            get: { camera.exposureLockState[slot.index] },
                            set: { camera.setExposureLock($0, slot: slot) }
                        ))
                        .tint(.yellow)
                        .disabled(camera.isRecording)
                    }
                }

                // 杜比视界 HDR
                Toggle("杜比视界 HDR (Dolby Vision)", isOn: Binding(
                    get: { camera.dolbyVisionEnabled },
                    set: { camera.setDolbyVision($0) }
                ))
                .tint(.yellow)
                .disabled(!camera.isDolbyVisionAvailable
                          || camera.mode == .composite
                          || camera.isRecording)
                .opacity((camera.isDolbyVisionAvailable && camera.mode == .dualFiles) ? 1 : 0.35)
                if camera.mode == .composite {
                    hint("仅双文件模式支持杜比视界 HDR；合成模式为保证兼容使用普通 HEVC")
                } else if !camera.isDolbyVisionAvailable {
                    hint("当前设备/镜头组合不支持杜比视界 HDR，已自动置灰")
                } else if camera.dolbyVisionEnabled {
                    hint("正在以 Dolby Vision 录制：采集、预览、成片全链路 HDR")
                }

                // 空间音频
                Toggle("空间音频 (Spatial Audio)", isOn: Binding(
                    get: { camera.spatialAudioEnabled },
                    set: { camera.setSpatialAudio($0) }
                ))
                .tint(.yellow)
                .disabled(!camera.isSpatialAudioAvailable
                          || camera.mode == .composite
                          || camera.isRecording)
                .opacity((camera.isSpatialAudioAvailable && camera.mode == .dualFiles) ? 1 : 0.35)
                if camera.mode == .composite {
                    hint("仅双文件模式支持空间音频；合成模式为保证兼容，使用立体声")
                } else if !camera.isSpatialAudioAvailable {
                    hint("当前设备不支持空间音频（需 iOS 18+ 及多麦克风机型）")
                }

                // 防抖
                sectionTitle("视频防抖")
                ForEach(CameraSlot.allCases) { slot in
                    Toggle("\(slot.displayName) 路防抖", isOn: Binding(
                        get: { camera.stabilizationEnabled[slot.index] },
                        set: { camera.setStabilization($0, slot: slot) }
                    ))
                    .tint(.yellow)
                    .disabled(camera.isRecording)
                }

                // 拍摄地点（保存时写入视频元数据，需要定位权限）
                Toggle("拍摄地点 (写入视频)", isOn: Binding(
                    get: { camera.includeLocation },
                    set: { camera.includeLocation = $0 }
                ))
                .tint(.yellow)
                .disabled(camera.isRecording)
                hint("保存视频时把拍摄地点写入视频元数据；未授权定位则不写入")

                // 曝光补偿
                sectionTitle("曝光补偿")
                ForEach(CameraSlot.allCases) { slot in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(slot.displayName) 路  \(String(format: "%+.1f", camera.exposureBias[slot.index])) EV")
                            .font(.system(size: 13, weight: .medium))
                        Slider(value: Binding(
                            get: { camera.exposureBias[slot.index] },
                            set: { camera.setExposureBias($0, slot: slot) }
                        ), in: camera.exposureBiasRange(for: slot))
                        .tint(.yellow)
                        .disabled(camera.isRecording)
                    }
                }

                // 录制中不可修改提示
                if camera.isRecording {
                    Text("录制中：设置已锁定")
                        .font(.system(size: 11))
                        .foregroundStyle(.yellow.opacity(0.8))
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .padding(18)
        }
        .frame(width: 360)   // 固定宽度（内容与玻璃边缘留足呼吸空间）
        .frame(maxHeight: 560)   // 限高：竖屏贴合 560，横屏受限父级自动 ≤ 屏高
        .glassPanel(cornerRadius: 28)
    }

    // MARK: - 组件

    private var header: some View {
        HStack {
            Text("设置")
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
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white.opacity(0.55))
            .textCase(.uppercase)
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.45))
    }
}

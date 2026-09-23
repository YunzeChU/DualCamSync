import AVFoundation
import SwiftUI
import UIKit

/// 主界面：双摄预览 + 液态玻璃控制层
/// -------------------------------------------------------------
/// 结构仿 iPhone 原生相机：
///  - 底层：双相机实时预览（分屏 / 画中画，可一键切换）
///  - 上层：液态玻璃控件（顶部功能按钮、录制中红色计时、底部快门 + 镜头选择）
///  - 横屏时控件栏移到右侧（原生相机横屏布局，竖屏/横屏观感不同）
///  - 点按预览任意位置 = 该路点按对焦+点测光；点按角标锁图标 = 锁定 AE/AF
struct CameraView: View {
    @StateObject private var camera = CameraManager()
    @Environment(\.scenePhase) private var scenePhase

    @State private var pickerSlot: CameraSlot?
    @State private var showingSettings = false

    var body: some View {
        GeometryReader { geo in
            let isLandscape = geo.size.width > geo.size.height
            ZStack {
                Color.black.ignoresSafeArea()

                // 底层：双摄预览
                previewArea(geo: geo, isLandscape: isLandscape)

                // 上层：液态玻璃控制层
                controlOverlay(isLandscape: isLandscape)

                // 选摄面板（液态玻璃）
                if let slot = pickerSlot {
                    overlayDim()
                        .onTapGesture { withAnimation(.snappy) { pickerSlot = nil } }
                    CameraPickerPanel(slot: slot) { option in
                        camera.selectCamera(option, for: slot)
                        withAnimation(.snappy) { pickerSlot = nil }
                    } onDismiss: {
                        withAnimation(.snappy) { pickerSlot = nil }
                    }
                    .transition(.scale(scale: 0.92).combined(with: .opacity))
                }

                // 设置面板（液态玻璃）
                if showingSettings {
                    overlayDim()
                        .onTapGesture { withAnimation(.snappy) { showingSettings = false } }
                    SettingsPanel {
                        withAnimation(.snappy) { showingSettings = false }
                    }
                    .transition(.scale(scale: 0.92).combined(with: .opacity))
                }

                // 降级/提示横幅
                if let banner = camera.degradationBanner {
                    degradationBannerView(banner)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.snappy, value: camera.degradationBanner)
            .animation(.snappy, value: pickerSlot)
            .animation(.snappy, value: showingSettings)
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .onAppear {
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            camera.start()
            syncOrientation()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            syncOrientation()
        }
        .onChange(of: scenePhase) { _, newPhase in
            // 退后台立即停止录制并保存（需求 7）
            if newPhase != .active {
                camera.stopRecording()
            }
        }
        .alert("提示", isPresented: $camera.hasError, presenting: camera.error) { _ in
            Button("好") {}
        } message: { err in
            Text([err.errorDescription, err.recoverySuggestion]
                .compactMap { $0 }
                .joined(separator: "\n"))
        }
        .environmentObject(camera)
    }

    // MARK: - 方向同步

    private func syncOrientation() {
        let device = UIDevice.current.orientation
        let interface: UIInterfaceOrientation
        switch device {
        case .landscapeLeft:       interface = .landscapeLeft
        case .landscapeRight:      interface = .landscapeRight
        case .portraitUpsideDown:  interface = .portraitUpsideDown
        default:                   interface = .portrait
        }
        camera.updateInterfaceOrientation(interface)
    }

    // MARK: - 预览区域

    @ViewBuilder
    private func previewArea(geo: GeometryProxy, isLandscape: Bool) -> some View {
        switch camera.layout {
        case .split:
            // 等分双屏：竖屏上下、横屏左右
            if isLandscape {
                HStack(spacing: 2) {
                    previewSlot(.a)
                    previewSlot(.b)
                }
            } else {
                VStack(spacing: 2) {
                    previewSlot(.a)
                    previewSlot(.b)
                }
            }
        case .pictureInPicture:
            // 画中画：A 全屏主画面，B 悬浮右下角
            ZStack {
                previewSlot(.a)
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        previewSlot(.b)
                            .frame(width: geo.size.width * 0.34,
                                   height: geo.size.height * 0.34)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .padding(20)
                    }
                }
            }
        }
    }

    /// 单路预览：画面 + 镜头角标 + 点按对焦
    private func previewSlot(_ slot: CameraSlot) -> some View {
        let layer = slot == .a ? camera.previewLayerA : camera.previewLayerB
        let option = slot == .a ? camera.cameraA : camera.cameraB
        return ZStack(alignment: .topLeading) {
            PreviewLayerView(layer: layer)
                .contentShape(Rectangle())
                // 点按预览 = 该路点按对焦 + 点测光
                .gesture(SpatialTapGesture().onEnded { value in
                    let devicePoint = camera.devicePoint(for: value.location, in: layer)
                    camera.focus(at: devicePoint, slot: slot)
                })

            CameraLabelView(name: option?.fullName ?? "—",
                            locked: camera.lockState[slot.index]) {
                camera.toggleLock(slot: slot)
            }
            .padding(12)
        }
    }

    // MARK: - 控制层

    @ViewBuilder
    private func controlOverlay(isLandscape: Bool) -> some View {
        if isLandscape {
            // 横屏：控件栏在右侧（竖屏/横屏布局不同）
            HStack {
                Spacer()
                VStack(spacing: 16) {
                    topControls
                    Spacer()
                    recordingTimerView
                    bottomControls
                }
                .padding(.vertical, 18)
                .padding(.horizontal, 14)
            }
        } else {
            // 竖屏：顶部功能 + 底部快门
            VStack {
                HStack {
                    topControls
                    Spacer()
                    recordingTimerView
                }
                .padding(.horizontal, 18)
                .padding(.top, 14)
                Spacer()
                bottomControls
            }
        }
    }

    /// 顶部功能按钮：布局切换 + 设置
    private var topControls: some View {
        HStack(spacing: 14) {
            GlassIconButton(systemImage: camera.layout.systemImage) {
                camera.setLayout(camera.layout == .split ? .pictureInPicture : .split)
            }
            GlassIconButton(systemImage: "gearshape.fill") {
                withAnimation(.snappy) { showingSettings = true }
            }
        }
        .disabled(camera.isRecording)
        .opacity(camera.isRecording ? 0.4 : 1)
    }

    /// 录制中的红色计时（液态玻璃胶囊，仿原生相机）
    @ViewBuilder
    private var recordingTimerView: some View {
        if camera.isRecording {
            HStack(spacing: 6) {
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
                Text(timeString(camera.recordingElapsed))
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.red)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .glassCapsule()
        }
    }

    /// 底部：镜头A选择 + 快门 + 镜头B选择
    private var bottomControls: some View {
        HStack(alignment: .center, spacing: 0) {
            slotButton(.a)
            Spacer()
            VStack(spacing: 8) {
                Text(camera.mode.displayName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                ShutterButton(isRecording: camera.isRecording) {
                    if camera.isRecording {
                        camera.stopRecording()
                    } else {
                        camera.startRecording()
                    }
                }
            }
            Spacer()
            slotButton(.b)
        }
        .padding(.horizontal, 26)
        .padding(.bottom, 26)
    }

    /// 镜头选择按钮（液态玻璃胶囊）
    private func slotButton(_ slot: CameraSlot) -> some View {
        let option = slot == .a ? camera.cameraA : camera.cameraB
        return Button {
            withAnimation(.snappy) { pickerSlot = slot }
        } label: {
            HStack(spacing: 5) {
                Text(option?.fullName ?? "—")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .glassCapsule()
        }
        .buttonStyle(.plain)
        .disabled(camera.isRecording)
        .opacity(camera.isRecording ? 0.4 : 1)
    }

    /// 降级横幅
    private func degradationBannerView(_ text: String) -> some View {
        VStack {
            Spacer().frame(height: 64)
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .glassCapsule()
            Spacer()
        }
        .padding(.horizontal, 30)
    }

    /// 面板背景遮罩
    private func overlayDim() -> some View {
        Color.black.opacity(0.35)
            .ignoresSafeArea()
            .transition(.opacity)
    }

    /// 秒表格式化 mm:ss
    private func timeString(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

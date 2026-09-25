import AVFoundation
import SwiftUI
import UIKit

/// 主界面：双摄预览 + 液态玻璃控制层
/// -------------------------------------------------------------
/// 结构仿 iPhone 原生相机（竖屏底部三键 / 横屏右侧三键）：
///  - 底层：双相机实时预览（分屏 / 画中画，默认画中画）
///  - 上层：液态玻璃控件：功能键 / 录制键 / 设置键 + 录制中红色计时
///  - 功能键 → 功能面板：镜头A/B、布局、录制模式、分辨率（二级菜单）
///  - 设置键 → 设置面板：AE/AF锁定、杜比视界HDR、空间音频、防抖、曝光补偿
///
/// 本轮修复要点：
///  1. 界面极简为 3 个按钮（用户要求"越少越好"）；
///  2. 预览层纯显示、不拦截触摸（修复按键点不动/不灵敏）；
///  3. 预览布局用稳定结构，旋转/切布局不重建容器（修复黑屏）；
///  4. 移除预览画面上的镜头角标（用户认为多余、占空间）。
struct CameraView: View {
    @State private var camera = CameraManager()
    @Environment(\.scenePhase) private var scenePhase

    @State private var showingFunction = false
    @State private var showingSettings = false
    /// 画中画小窗拖动偏移（@State：旋转/切布局后保留，越界时 clamp）
    @State private var pipOffset = CGSize.zero
    @State private var pipDragOffset = CGSize.zero

    var body: some View {
        @Bindable var camera = camera
        GeometryReader { geo in
            let isLandscape = geo.size.width > geo.size.height
            ZStack {
                Color.black.ignoresSafeArea()

                // 底层：双摄预览（稳定结构，旋转不重建容器）
                previewArea(geo: geo, isLandscape: isLandscape)

                // 上层：三键控制层（竖屏底部横排 / 横屏右侧竖排）
                controlOverlay(isLandscape: isLandscape)

                // 录制中红色计时（顶部居中）
                recordingTimerView()

                // 功能面板（液态玻璃二级菜单，从功能键所在侧弹出）
                if showingFunction {
                    overlayDim()
                        .onTapGesture { dismissAllPanels() }
                        .zIndex(9)
                    FunctionPanel { dismissAllPanels() }
                        .padding(isLandscape ? .trailing : .bottom,
                                 isLandscape ? 30 : 120)
                        .frame(maxWidth: .infinity, maxHeight: .infinity,
                               alignment: isLandscape ? .trailing : .bottom)
                        // 不用 .transition：真机上首次弹出时转场动画可能不触发，
                        // 面板停在"屏幕外/透明"的初始态 = "按键打不开"；
                        // 去掉转场后 if 条件为真即直接可见（点一次录制键触发
                        // 刷新后"能打开"，正是转场初始态被刷新的表现）。
                        // zIndex 保证压在预览层之上。
                        .zIndex(10)
                }

                // 设置面板（液态玻璃弹层，从设置键所在侧弹出）
                if showingSettings {
                    overlayDim()
                        .onTapGesture { dismissAllPanels() }
                        .zIndex(9)
                    SettingsPanel { dismissAllPanels() }
                        .padding(isLandscape ? .trailing : .bottom,
                                 isLandscape ? 30 : 120)
                        .frame(maxWidth: .infinity, maxHeight: .infinity,
                               alignment: isLandscape ? .trailing : .bottom)
                        .zIndex(10)
                }

    /// 降级/提示横幅
                if let banner = camera.degradationBanner {
                    degradationBannerView(banner)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                // 临时诊断横幅（真机定位用，验证后删除）
                diagnosticBannerView()
            }
            .animation(.spring(response: 0.38, dampingFraction: 0.85), value: showingFunction)
            .animation(.spring(response: 0.38, dampingFraction: 0.85), value: showingSettings)
            .animation(.snappy, value: camera.degradationBanner)
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        // 录制中锁界面方向（开始方向），停止后恢复全部方向
        .background(OrientationLockView(
            lockedOrientation: camera.isRecording ? camera.interfaceOrientation : nil))
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
        .alert("提示", isPresented: Binding(
            get: { camera.error != nil },
            set: { if !$0 { camera.error = nil } }
        ), presenting: camera.error) { _ in
            Button("好") {}
        } message: { err in
            Text([err.errorDescription, err.recoverySuggestion]
                .compactMap { $0 }
                .joined(separator: "\n"))
        }
        .environment(camera)
    }

    /// 收起所有弹出面板（统一弹簧动画，保持原生手感）
    private func dismissAllPanels() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            showingFunction = false
            showingSettings = false
        }
    }

    // MARK: - 方向同步

    /// 同步界面方向给相机层
    /// 用 **windowScene.interfaceOrientation**（界面方向）而非 UIDevice.orientation
    /// （物理方向）：物理方向含 faceUp/faceDown，且 Info.plist 不支持倒置时，
    /// 物理倒置会被识别成 .portraitUpsideDown，出现"界面还是竖屏、预览被转 270°"
    /// 的不一致。这里只映射工程实际支持的三个方向。
    private func syncOrientation() {
        // iOS 26 中 UIWindowScene.interfaceOrientation 已弃用，改用 effectiveGeometry
        let raw = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.effectiveGeometry.interfaceOrientation.rawValue
            ?? UIInterfaceOrientation.portrait.rawValue
        var interface = UIInterfaceOrientation(rawValue: raw) ?? .portrait
        if interface == .portraitUpsideDown { interface = .portrait } // 不支持倒置
        camera.updateInterfaceOrientation(interface)
    }

    // MARK: - 预览区域（稳定结构）

    /// 用固定顺序的两个插槽 + 计算帧布局：
    /// 旋转/切换布局时 ZStack 结构不变，SwiftUI 不会拆除重建预览容器，
    /// 避免共享预览层被摘除导致黑屏（原 HStack/VStack 分支切换会重建）。
    /// B 路定位用 **frame + alignment 布局引擎**（而非 .offset 手动位移）：
    /// 手动 offset 在旋转完成后的几何重算中会把 B 推出显示区域
    /// （真机实测：分屏横屏旋转后 B 跑到屏幕外）。
    /// 画中画小窗：尺寸参考苹果原生相机（宽约屏宽 26%、高按画面比例），
    /// 可拖动（@State pipOffset 记忆位置，越界 clamp 回屏内）。
    @ViewBuilder
    private func previewArea(geo: GeometryProxy, isLandscape: Bool) -> some View {
        ZStack {
            // A 路：画中画占满全屏；分屏占左/上半。
            // 分屏必须显式对齐（竖屏 top / 横屏 leading）：ZStack 默认居中，
            // 不对齐时 A 会浮在垂直/水平中间，与 B 重叠（用户实测"上面的画面
            // 被下面的遮挡一部分 + 屏幕最顶上黑色"正是 A 未对齐所致）。
            previewSlot(.a)
                .frame(width: slotAWidth(geo, isLandscape),
                       height: slotAHeight(geo, isLandscape))
                .frame(maxWidth: .infinity, maxHeight: .infinity,
                       alignment: camera.layout == .pictureInPicture
                           ? .center
                           : (isLandscape ? .leading : .top))
            if camera.layout == .pictureInPicture {
                // 画中画：B 悬浮右下角，可拖动
                let pipSize = pipWindowSize(geo, isLandscape)
                previewSlot(.b)
                    .frame(width: pipSize.width, height: pipSize.height)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .shadow(color: .black.opacity(0.25), radius: 9, x: 0, y: 3)
                    .offset(x: pipOffset.width + pipDragOffset.width,
                            y: pipOffset.height + pipDragOffset.height)
                    .padding(20)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                pipDragOffset = value.translation
                            }
                            .onEnded { value in
                                pipOffset = CGSize(
                                    width: pipOffset.width + value.translation.width,
                                    height: pipOffset.height + value.translation.height)
                                pipDragOffset = .zero
                                clampPipOffset(to: geo.size, window: pipSize)
                            }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: .bottomTrailing)
            } else {
                // 分屏：B 占右/下半
                previewSlot(.b)
                    .frame(width: isLandscape ? geo.size.width / 2 : geo.size.width,
                           height: isLandscape ? geo.size.height : geo.size.height / 2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: isLandscape ? .trailing : .bottom)
            }
        }
        // 尺寸变化（= 界面旋转）时：同步相机方向 + 把小窗偏移 clamp 回屏内。
        // 方向同步不能只靠 UIDevice.orientationDidChangeNotification：真机上
        // "从倾斜回正"（不经过 faceUp）时该通知不触发，画面角度停在旧值
        // （用户实测：向左倾 → 画面顺时针差 90°；向右倾 → 逆时针差 90°；
        //  放平才恢复正常）。geo.size 变化必然伴随界面旋转，此处兜底。
        .onChange(of: geo.size) { _, _ in
            syncOrientation()
            if camera.layout == .pictureInPicture {
                clampPipOffset(to: geo.size, window: pipWindowSize(geo, isLandscape))
            }
        }
    }

    /// 画中画小窗尺寸：宽约屏宽 26%（参考苹果原生相机小窗），
    /// 高按当前画面比例（竖屏 9:16、横屏 16:9）——比例与合成输出一致，
    /// 保证"模式A合成时小窗大小与预览框一致、上下裁切"。
    private func pipWindowSize(_ geo: GeometryProxy, _ landscape: Bool) -> CGSize {
        let w = geo.size.width * 0.26
        let h = w * (landscape ? 9.0 / 16.0 : 16.0 / 9.0)
        return CGSize(width: w, height: h)
    }

    /// 把小窗偏移限制在屏内（完整可见，四周留 8pt 边距）
    private func clampPipOffset(to size: CGSize, window: CGSize) {
        // 无偏移时小窗位于右下角（距边 20）；offset 相对该位置
        let baseX = size.width - window.width - 20
        let baseY = size.height - window.height - 20
        let minOX = 8 - baseX
        let maxOX = (size.width - window.width - 8) - baseX
        let minOY = 8 - baseY
        let maxOY = (size.height - window.height - 8) - baseY
        pipOffset.width = min(max(pipOffset.width, minOX), maxOX)
        pipOffset.height = min(max(pipOffset.height, minOY), maxOY)
    }

    /// 单路预览：纯显示容器（不拦截触摸、无镜头角标）
    /// 预览层由 CameraManager 在 init 中一次性创建并持有（永不重建，
    /// 见 CameraManager.applyConfiguration 注释），本视图只负责把它
    /// 放进视图层级、跟随布局尺寸；PreviewContainerView.didSet/
    /// layoutSubviews 负责挂载与跟随 frame。
    private func previewSlot(_ slot: CameraSlot) -> some View {
        PreviewLayerView(layer: slot == .a ? camera.previewLayerA : camera.previewLayerB)
    }

    // MARK: 预览几何（分屏：A 占一半、B 占另一半；画中画：A 全屏、B 右下角）

    private func slotAWidth(_ geo: GeometryProxy, _ landscape: Bool) -> CGFloat {
        camera.layout == .pictureInPicture ? geo.size.width
            : (landscape ? geo.size.width / 2 : geo.size.width)
    }

    private func slotAHeight(_ geo: GeometryProxy, _ landscape: Bool) -> CGFloat {
        camera.layout == .pictureInPicture ? geo.size.height
            : (landscape ? geo.size.height : geo.size.height / 2)
    }

    // MARK: - 三键控制层

    @ViewBuilder
    private func controlOverlay(isLandscape: Bool) -> some View {
        if isLandscape {
            // 横屏：右侧竖排三键（功能 / 快门 / 设置）
            HStack {
                Spacer()
                VStack(spacing: 30) {
                    GlassIconButton(systemImage: "rectangle.split.2x1") {
                        withAnimation(.spring(response: 0.38, dampingFraction: 0.85)) { showingFunction = true }
                    }
                    // 按钮层不禁用：面板内部行已有 isRecording/isFinalizing 防护
                    // （录制中改设置 setter 静默 return），保证首次启动面板必能打开
                    // （真机反复验证：按钮层禁用会因状态机首次快照导致"必须点一次
                    //  录制键才能打开面板"——见诊断横幅 BTN 行）
                    Spacer()
                    ShutterButton(isRecording: camera.isRecording) {
                        camera.isRecording ? camera.stopRecording() : camera.startRecording()
                    }
                    Spacer()
                    GlassIconButton(systemImage: "gearshape.fill") {
                        withAnimation(.spring(response: 0.38, dampingFraction: 0.85)) { showingSettings = true }
                    }
                    // 按钮层不禁用：面板内部行已有 isRecording/isFinalizing 防护
                    // （录制中改设置 setter 静默 return），保证首次启动面板必能打开
                    // （真机反复验证：按钮层禁用会因状态机首次快照导致"必须点一次
                    //  录制键才能打开面板"——见诊断横幅 BTN 行）
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 28)
            }
        } else {
            // 竖屏：底部横排三键（功能 / 快门 / 设置）
            VStack {
                Spacer()
                HStack(spacing: 40) {
                    GlassIconButton(systemImage: "rectangle.split.2x1") {
                        withAnimation(.spring(response: 0.38, dampingFraction: 0.85)) { showingFunction = true }
                    }
                    // 按钮层不禁用：面板内部行已有 isRecording/isFinalizing 防护
                    // （录制中改设置 setter 静默 return），保证首次启动面板必能打开
                    // （真机反复验证：按钮层禁用会因状态机首次快照导致"必须点一次
                    //  录制键才能打开面板"——见诊断横幅 BTN 行）
                    ShutterButton(isRecording: camera.isRecording) {
                        camera.isRecording ? camera.stopRecording() : camera.startRecording()
                    }
                    GlassIconButton(systemImage: "gearshape.fill") {
                        withAnimation(.spring(response: 0.38, dampingFraction: 0.85)) { showingSettings = true }
                    }
                    // 按钮层不禁用：面板内部行已有 isRecording/isFinalizing 防护
                    // （录制中改设置 setter 静默 return），保证首次启动面板必能打开
                    // （真机反复验证：按钮层禁用会因状态机首次快照导致"必须点一次
                    //  录制键才能打开面板"——见诊断横幅 BTN 行）
                }
                .padding(.bottom, 46)
            }
        }
    }

    /// 录制中的红色计时（原生相机风格：红底圆角矩形 + 白色数字）
    /// 修复两个问题：
    ///  1. 之前玻璃胶囊在黑背景上渲染成半透明看不清 → 改红底不透明；
    ///  2. 顶部 .padding(14) 会被灵动岛/刘海遮住 → 用真实窗口安全区偏移。
    ///     注意不能读 GeometryReader 的 safeAreaInsets：CameraView 外层
    ///     ignoresSafeArea 后该值恒为 0，必须从 UIWindow 取。
    private func recordingTimerView() -> some View {
        HStack(spacing: 5) {
            if camera.isRecording {
                Circle()
                    .fill(.white)
                    .frame(width: 7, height: 7)
                Text(timeString(camera.recordingElapsed))
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.red, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .opacity(camera.isRecording ? 1 : 0)
        .allowsHitTesting(false)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, max(Self.topSafeInset() + 8, 14))
    }

    /// 从窗口读取真实顶部安全区（灵动岛/刘海高度）
    private static func topSafeInset() -> CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .compactMap { $0.keyWindow }
            .first?.safeAreaInsets.top ?? 0
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

    /// 临时诊断横幅（真机定位：B 路预览失败原因 / 面板状态是否变化 / 录制状态是否变化）
    /// 用 TimelineView 每秒刷新，避免异步配置完成后横幅仍显示初始快照。
    /// 每行格式固定，用户拍照/抄录后删除本视图。
    @ViewBuilder
    private func diagnosticBannerView() -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let status = camera.previewConnStatus
            VStack(alignment: .leading, spacing: 2) {
                Text("A:\(status.a) | B:\(status.b)")
                Text("RUN:\(camera.isSessionRunning ? 1 : 0) REC:\(camera.isRecording ? 1 : 0) FIN:\(camera.isFinalizing ? 1 : 0)")
                Text("LAY:\(camera.layout == .pictureInPicture ? "PIP" : "SPL") MOD:\(camera.mode == .dualFiles ? "B" : "A")")
                Text("SET:\(showingSettings ? 1 : 0) FUN:\(showingFunction ? 1 : 0) GEN:\(camera.previewGeneration) BTN:\(camera.isRecording || camera.isFinalizing ? 1 : 0)")
            }
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundStyle(.yellow)
            .padding(5)
            .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.top, 6)
            .padding(.leading, 6)
            .allowsHitTesting(false)
        }
    }
}

import AVFoundation
import Photos
import SwiftUI
import UIKit

/// 相机管理器：整个双摄功能的唯一权威来源
/// -------------------------------------------------------------
/// 职责：
///  1. 管理 AVCaptureMultiCamSession（任意双镜头组合、逐设备格式配置）
///  2. 两路预览层 + 每路独立对焦/曝光锁定/曝光补偿
///  3. 分辨率档位 / 杜比视界 / 防抖 / 空间音频 / 录制模式 配置
///  4. 异常容错：组合探测、自动降级、运行期错误兜底、高温/内存监控
///
/// 线程模型：本类主要在主线程使用；AVFoundation 回调统一转回主队列后
/// 再修改 @Published 状态，避免 SwiftUI 断言崩溃。
final class CameraManager: NSObject, ObservableObject {
    // MARK: - 会话与预览层

    /// 多摄会话（支持任意双镜头组合的核心）
    let session = AVCaptureMultiCamSession()

    /// 两路独立预览层（视图层通过 PreviewLayerView 包装渲染）
    /// 使用 lazy + sessionWithNoConnection：多摄会话禁止自动建连，
    /// 连接由本类在配置阶段手动创建；lazy 避免初始化顺序问题。
    lazy var previewLayerA: AVCaptureVideoPreviewLayer = {
        let layer = AVCaptureVideoPreviewLayer(sessionWithNoConnection: session)
        layer.videoGravity = .resizeAspectFill
        return layer
    }()
    lazy var previewLayerB: AVCaptureVideoPreviewLayer = {
        let layer = AVCaptureVideoPreviewLayer(sessionWithNoConnection: session)
        layer.videoGravity = .resizeAspectFill
        return layer
    }()
    private var previewConnA: AVCaptureConnection?
    private var previewConnB: AVCaptureConnection?

    // MARK: - 对外状态（SwiftUI 驱动）

    @Published var availableCameras: [CameraOption] = []
    @Published var cameraA: CameraOption?
    @Published var cameraB: CameraOption?
    @Published var preset: ResolutionPreset = .uhd30
    @Published var layout: PreviewLayout = .split
    @Published var mode: RecordingMode = .dualFiles
    @Published var dolbyVisionEnabled = false
    @Published var spatialAudioEnabled = true
    @Published var stabilizationEnabled = [true, true]
    @Published var lockState = [false, false]          // 每路 AE/AF 锁定
    @Published var exposureBias: [Float] = [0, 0]      // 每路曝光补偿

    @Published var isRecording = false
    @Published var recordingElapsed: TimeInterval = 0
    @Published var interfaceOrientation: UIInterfaceOrientation = .portrait

    /// 各档位在"当前双摄组合"下的可用性（UI 置灰用）
    @Published var presetAvailability: [ResolutionPreset: Bool] = [:]
    @Published var isDolbyVisionAvailable = false
    @Published var isSpatialAudioAvailable = false
    @Published var isMultiCamSupported = true

    @Published var error: CameraError?
    @Published var degradationBanner: String?

    var hasError: Bool {
        get { error != nil }
        set { if !newValue { error = nil } }
    }

    // MARK: - 私有配置

    private var audioInput: AVCaptureDeviceInput?
    private var didStart = false
    private var elapsedTimer: Timer?

    // 模式B（双文件）输出
    private var movieOutputA: AVCaptureMovieFileOutput?
    private var movieOutputB: AVCaptureMovieFileOutput?
    private let modeBRecorder = ModeBRecorder()

    // 模式A（合成）输出
    private var videoDataOutputA: AVCaptureVideoDataOutput?
    private var videoDataOutputB: AVCaptureVideoDataOutput?
    private var audioDataOutput: AVCaptureAudioDataOutput?
    private var compositeVideoConnA: AVCaptureConnection?
    private var compositeVideoConnB: AVCaptureConnection?
    private let modeARecorder = ModeARecorder()

    /// 当前模式下的两路"录制用"视频连接（防抖/旋转统一入口）
    /// - 双文件模式：MovieFileOutput 上启用中的视频连接
    /// - 合成模式：VideoDataOutput 上启用中的视频连接
    private var activeVideoConnA: AVCaptureConnection? {
        mode == .dualFiles
            ? movieOutputA?.connections.first { $0.isEnabled && $0.mediaType == .video }
            : compositeVideoConnA
    }
    private var activeVideoConnB: AVCaptureConnection? {
        mode == .dualFiles
            ? movieOutputB?.connections.first { $0.isEnabled && $0.mediaType == .video }
            : compositeVideoConnB
    }

    private let systemMonitor = SystemMonitor()

    // MARK: - 初始化

    override init() {
        super.init()
        modeARecorder.manager = self
        observeAppEvents()
    }

    // MARK: - 启动流程

    /// 应用启动时调用：权限 -> 枚举镜头 -> 默认组合 -> 配置会话
    func start() {
        guard !didStart else { return }
        didStart = true

        isMultiCamSupported = AVCaptureMultiCamSession.isMultiCamSupported
        guard isMultiCamSupported else {
            error = .multiCamUnsupported
            return
        }

        discoverCameras()
        if cameraA == nil || cameraB == nil { pickDefaultCameras() }

        requestPermissions { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.error = .permissionDenied
                return
            }
            self.applyConfiguration()
            self.systemMonitor.start()
            self.systemMonitor.onThermalChange = { [weak self] level in
                self?.handleThermalChange(level)
            }
            self.systemMonitor.onMemoryChange = { [weak self] level in
                self?.handleMemoryChange(level)
            }
        }
    }

    /// 枚举全部可用镜头（后置超广角/广角/长焦 + 前置）
    private func discoverCameras() {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTelephotoCamera],
            mediaType: .video,
            position: .unspecified
        )
        var list = discovery.devices.map(CameraOption.resolve)
        // 按 uniqueID 去重
        var seen = Set<String>()
        list = list.filter { seen.insert($0.id).inserted }
        // 排序：后置优先，镜头顺序 超广角->广角->长焦->前置
        let lensOrder: [LensType: Int] = [.ultraWide: 0, .wide: 1, .telephoto: 2, .front: 3]
        list.sort {
            let pa = $0.position == .front ? 1 : 0
            let pb = $1.position == .front ? 1 : 0
            if pa != pb { return pa < pb }
            return (lensOrder[$0.lensType] ?? 9) < (lensOrder[$1.lensType] ?? 9)
        }
        availableCameras = list
    }

    /// 默认组合：后置广角 + 后置超广角；无超广角则 后置广角 + 前置
    private func pickDefaultCameras() {
        let backs = availableCameras.filter { $0.position != .front }
        if let wide = backs.first(where: { $0.lensType == .wide }),
           let ultra = backs.first(where: { $0.lensType == .ultraWide }) {
            cameraA = wide
            cameraB = ultra
        } else if let wide = backs.first, let front = availableCameras.first(where: { $0.position == .front }) {
            cameraA = wide
            cameraB = front
        } else if backs.count >= 2 {
            cameraA = backs[0]
            cameraB = backs[1]
        } else if let first = availableCameras.first {
            cameraA = first
        }
    }

    // MARK: - 权限

    private func requestPermissions(completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .video) { videoOK in
            AVCaptureDevice.requestAccess(for: .audio) { audioOK in
                // 相册只申请"写入"权限（addOnly），不读取相册内容
                PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                    let photoOK = (status == .authorized || status == .limited)
                    DispatchQueue.main.async {
                        completion(videoOK && audioOK && photoOK)
                    }
                }
            }
        }
    }

    // MARK: - 会话配置（任何设置变化都走这里全量重配）

    private func applyConfiguration() {
        guard isMultiCamSupported,
              let camA = cameraA,
              let camB = cameraB else { return }
        // 录制中不允许改动会话结构
        guard !isRecording else { return }

        session.beginConfiguration()
        teardownSession()
        do {
            let inputA = try AVCaptureDeviceInput(device: camA.device)
            let inputB = try AVCaptureDeviceInput(device: camB.device)
            guard session.canAddInput(inputA), session.canAddInput(inputB) else {
                throw CameraError.comboUnsupported("\(camA.fullName) + \(camB.fullName)")
            }
            session.addInput(inputA)
            session.addInput(inputB)

            // 多摄会话中每台设备可独立配置 activeFormat
            try applyFormat(device: camA.device, preset: preset)
            try applyFormat(device: camB.device, preset: preset)

            // 预览层连接（手动建连）
            previewConnA = makePreviewConnection(layer: previewLayerA, input: inputA)
            previewConnB = makePreviewConnection(layer: previewLayerB, input: inputB)

            // 音频输入（立体声 / 空间音频）
            try attachAudioInput()

            // 录制输出（按模式）
            switch mode {
            case .dualFiles:
                try attachDualFileOutputs(videoInputA: inputA, videoInputB: inputB)
            case .composite:
                attachCompositeOutputs(videoInputA: inputA, videoInputB: inputB)
            }

            // 防抖 / 方向 / 杜比
            applyStabilization()
            applyOrientation()
            refreshDolbyCapability()

            session.commitConfiguration()
            session.startRunning()
            refreshCapabilities()
        } catch {
            session.commitConfiguration()
            self.error = (error as? CameraError) ?? .configurationFailed(error.localizedDescription)
        }
    }

    /// 清空会话：移除全部输入/输出/手动连接（重配前置动作）
    private func teardownSession() {
        if let c = previewConnA { session.removeConnection(c) }
        if let c = previewConnB { session.removeConnection(c) }
        previewConnA = nil
        previewConnB = nil
        compositeVideoConnA = nil
        compositeVideoConnB = nil
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }
        modeBRecorder.detach()
        modeARecorder.detach()
        movieOutputA = nil
        movieOutputB = nil
        videoDataOutputA = nil
        videoDataOutputB = nil
        audioDataOutput = nil
        audioInput = nil
    }

    /// 手动创建预览层连接（多摄会话禁止自动建连）
    private func makePreviewConnection(layer: AVCaptureVideoPreviewLayer,
                                       input: AVCaptureDeviceInput) -> AVCaptureConnection? {
        guard let port = input.ports.first(where: { $0.mediaType == .video }) else { return nil }
        let conn = AVCaptureConnection(inputPort: port, layer: layer)
        guard session.canAddConnection(conn) else { return nil }
        // 前置不镜像（需求：前置摄像头不允许镜像）
        conn.automaticallyAdjustsVideoMirroring = false
        conn.isVideoMirrored = false
        session.addConnection(conn)
        return conn
    }

    /// 逐设备配置分辨率/帧率
    private func applyFormat(device: AVCaptureDevice, preset: ResolutionPreset) throws {
        let dims = preset.landscapeDimensions
        guard let format = device.formats.first(where: { f in
            let fd = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            return fd.width == dims.width && fd.height == dims.height
                && f.videoSupportedFrameRateRanges.contains {
                    $0.minFrameRate <= Double(preset.fps) && Double(preset.fps) <= $0.maxFrameRate
                }
        }) else {
            throw CameraError.presetUnsupported(preset)
        }
        try device.lockForConfiguration()
        device.activeFormat = format
        let duration = CMTime(value: 1, timescale: CMTimeScale(preset.fps))
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
        device.unlockForConfiguration()
    }

    /// 麦克风输入 + 空间音频/立体声模式
    private func attachAudioInput() throws {
        guard let mic = AVCaptureDevice.default(for: .audio) else {
            throw CameraError.captureDeviceUnavailable("麦克风")
        }
        let input = try AVCaptureDeviceInput(device: mic)
        guard session.canAddInput(input) else {
            throw CameraError.captureDeviceUnavailable("麦克风")
        }
        session.addInput(input)
        audioInput = input

        // 空间音频能力（一阶Ambisonics）探测
        isSpatialAudioAvailable = input.isMultichannelAudioModeSupported(.firstOrderAmbisonics)

        // 空间音频仅"双文件模式（MovieFileOutput）"原生支持；
        // 合成模式（AVAssetWriter）v1 只保证立体声，空间音频在 UI 置灰。
        let wantSpatial = spatialAudioEnabled && isSpatialAudioAvailable && mode == .dualFiles
        let targetMode: AVCaptureDeviceInput.MultichannelAudioMode = wantSpatial ? .firstOrderAmbisonics : .stereo
        if input.isMultichannelAudioModeSupported(targetMode) {
            input.multichannelAudioMode = targetMode
        }
    }

    // MARK: - 模式B：双独立文件（MovieFileOutput）

    private func attachDualFileOutputs(videoInputA: AVCaptureDeviceInput,
                                       videoInputB: AVCaptureDeviceInput) throws {
        let outA = AVCaptureMovieFileOutput()
        let outB = AVCaptureMovieFileOutput()
        guard session.canAddOutput(outA), session.canAddOutput(outB) else {
            throw CameraError.configurationFailed("无法添加录像输出")
        }
        session.addOutput(outA)
        session.addOutput(outB)
        movieOutputA = outA
        movieOutputB = outB

        // 每个 MovieFileOutput 会自动为所有视频/音频端口建连，
        // 必须关闭"不属于自己"的那路视频连接，保证每个文件只含一路画面。
        constrainMovieOutput(outA, keep: cameraA)
        constrainMovieOutput(outB, keep: cameraB)

        modeBRecorder.attach(outputA: outA, outputB: outB)
        modeBRecorder.onFinished = { [weak self] urls in
            self?.handleRecordingFinished(urls: urls)
        }
        modeBRecorder.onError = { [weak self] err in
            self?.handleRecordingFailed(err)
        }
    }

    /// 关闭 MovieFileOutput 上不属于指定镜头的视频连接（音频连接保持启用）
    private func constrainMovieOutput(_ output: AVCaptureMovieFileOutput, keep: CameraOption?) {
        for conn in output.connections {
            guard let port = conn.inputPorts.first else { continue }
            if conn.mediaType == .audio {
                conn.isEnabled = true
                continue
            }
            guard conn.mediaType == .video else { continue }
            let belongs = (keep != nil
                && port.sourceDevicePosition == keep!.position
                && port.sourceDeviceType == keep!.device.deviceType)
            conn.isEnabled = belongs
            // 录制输出同样不镜像（前置不允许镜像）
            conn.automaticallyAdjustsVideoMirroring = false
            conn.isVideoMirrored = false
            // 默认 HEVC；杜比视界由 refreshDolbyCapability 覆盖
            if belongs {
                try? output.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.hevc], for: conn)
            }
        }
    }

    // MARK: - 模式A：合成单条（视频数据输出 + AVAssetWriter）

    private func attachCompositeOutputs(videoInputA: AVCaptureDeviceInput,
                                        videoInputB: AVCaptureDeviceInput) {
        let outA = AVCaptureVideoDataOutput()
        let outB = AVCaptureVideoDataOutput()
        let outAudio = AVCaptureAudioDataOutput()

        for out in [outA, outB] {
            out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            out.alwaysDiscardsLateVideoFrames = true
        }
        outA.setSampleBufferDelegate(modeARecorder, queue: modeARecorder.videoQueueA)
        outB.setSampleBufferDelegate(modeARecorder, queue: modeARecorder.videoQueueB)
        outAudio.setSampleBufferDelegate(modeARecorder, queue: modeARecorder.audioQueue)

        session.addOutput(outA)
        session.addOutput(outB)
        session.addOutput(outAudio)
        videoDataOutputA = outA
        videoDataOutputB = outB
        audioDataOutput = outAudio

        // 每个数据输出同样会自动为两路视频建连：关闭不属于自己的那路
        compositeVideoConnA = constrainDataOutput(outA, keep: cameraA)
        compositeVideoConnB = constrainDataOutput(outB, keep: cameraB)

        modeARecorder.attach(videoOutputA: outA, videoOutputB: outB,
                             audioOutput: outAudio,
                             connA: compositeVideoConnA, connB: compositeVideoConnB)
        modeARecorder.onFinished = { [weak self] urls in
            self?.handleRecordingFinished(urls: urls)
        }
        modeARecorder.onError = { [weak self] err in
            self?.handleRecordingFailed(err)
        }
    }

    private func constrainDataOutput(_ output: AVCaptureVideoDataOutput,
                                     keep: CameraOption?) -> AVCaptureConnection? {
        var kept: AVCaptureConnection?
        for conn in output.connections {
            guard let port = conn.inputPorts.first, conn.mediaType == .video else { continue }
            let belongs = (keep != nil
                && port.sourceDevicePosition == keep!.position
                && port.sourceDeviceType == keep!.device.deviceType)
            conn.isEnabled = belongs
            conn.automaticallyAdjustsVideoMirroring = false
            conn.isVideoMirrored = false
            if belongs { kept = conn }
        }
        return kept
    }

    // MARK: - 防抖 / 方向 / 杜比

    /// 两路可分别开启/关闭防抖（系统自动选择最佳档位）
    private func applyStabilization() {
        guard let connA = activeVideoConnA, let connB = activeVideoConnB else { return }
        applyStabilization(conn: connA, enabled: stabilizationEnabled[0])
        applyStabilization(conn: connB, enabled: stabilizationEnabled[1])
    }

    private func applyStabilization(conn: AVCaptureConnection, enabled: Bool) {
        guard conn.isVideoStabilizationSupported else { return }
        conn.preferredVideoStabilizationMode = enabled ? .auto : .off
    }

    /// 预览跟随设备方向（录制中锁定，不中途旋转）
    func updateInterfaceOrientation(_ orientation: UIInterfaceOrientation) {
        guard !isRecording else { return }
        interfaceOrientation = orientation
        applyOrientation()
    }

    private func applyOrientation() {
        let angle = Self.rotationAngle(for: interfaceOrientation)
        previewConnA?.videoRotationAngle = angle
        previewConnB?.videoRotationAngle = angle
        // 录制连接（未在录制时更新；录制起点方向在 startRecording 里锁定）
        if !isRecording {
            activeVideoConnA?.videoRotationAngle = angle
            activeVideoConnB?.videoRotationAngle = angle
        }
    }

    /// 竖屏=90°，横屏按左右映射（与 Apple AVCam 官方样例一致）
    static func rotationAngle(for orientation: UIInterfaceOrientation) -> CGFloat {
        switch orientation {
        case .portrait:              return 90
        case .portraitUpsideDown:    return 270
        case .landscapeLeft:         return 0
        case .landscapeRight:        return 180
        default:                     return 90
        }
    }

    /// 杜比视界能力探测 + 应用（仅双文件模式；合成路径不支持）
    private func refreshDolbyCapability() {
        guard mode == .dualFiles, let outA = movieOutputA else {
            isDolbyVisionAvailable = false
            return
        }
        isDolbyVisionAvailable = outA.availableVideoCodecTypes.contains(.dolbyVisionHEVC)
        applyDolbySetting()
    }

    private func applyDolbySetting() {
        guard mode == .dualFiles, let outA = movieOutputA, let outB = movieOutputB else { return }
        let codec: AVVideoCodecType = (dolbyVisionEnabled && isDolbyVisionAvailable) ? .dolbyVisionHEVC : .hevc
        for out in [outA, outB] {
            for conn in out.connections where conn.isEnabled && conn.mediaType == .video {
                try? out.setOutputSettings([AVVideoCodecKey: codec], for: conn)
            }
        }
    }

    /// 刷新各档位可用性；当前档位不可用时自动降级到最高可用档位
    private func refreshCapabilities() {
        guard let camA = cameraA, let camB = cameraB else { return }
        var availability: [ResolutionPreset: Bool] = [:]
        for p in ResolutionPreset.allCases {
            availability[p] = CameraPairProbe.shared.supportsPreset(camA.device, p)
                && CameraPairProbe.shared.supportsPreset(camB.device, p)
        }
        presetAvailability = availability

        if availability[preset] == false {
            let old = preset
            if let fallback = ResolutionPreset.allCases.first(where: { availability[$0] == true }) {
                preset = fallback
                showDegradationBanner("当前镜头组合不支持 \(old.displayName)，已自动降级到 \(fallback.displayName)")
            }
        }
    }

    // MARK: - 对外设置方法（全部在非录制状态下生效）

    func setPreset(_ newValue: ResolutionPreset) {
        guard !isRecording, preset != newValue else { return }
        preset = newValue
        applyConfiguration()
    }

    func setLayout(_ newValue: PreviewLayout) {
        guard !isRecording, layout != newValue else { return }
        layout = newValue
    }

    func setMode(_ newValue: RecordingMode) {
        guard !isRecording, mode != newValue else { return }
        mode = newValue
        applyConfiguration()
    }

    func setDolbyVision(_ enabled: Bool) {
        guard !isRecording, dolbyVisionEnabled != enabled else { return }
        dolbyVisionEnabled = enabled
        applyConfiguration()
    }

    func setSpatialAudio(_ enabled: Bool) {
        guard !isRecording, spatialAudioEnabled != enabled else { return }
        spatialAudioEnabled = enabled
        applyConfiguration()
    }

    func setStabilization(_ enabled: Bool, slot: CameraSlot) {
        guard !isRecording, stabilizationEnabled[slot.index] != enabled else { return }
        stabilizationEnabled[slot.index] = enabled
        applyStabilization()
    }

    /// 更换某路镜头（先做组合校验，不支持的组合直接拒绝并提示）
    func selectCamera(_ option: CameraOption, for slot: CameraSlot) {
        guard !isRecording else { return }
        let other = (slot == .a) ? cameraB : cameraA
        if let other, !CameraPairProbe.shared.canUseTogether(option, other) {
            error = .comboUnsupported("\(option.fullName) + \(other.fullName)")
            return
        }
        if slot == .a { cameraA = option } else { cameraB = option }
        lockState = [false, false]
        exposureBias = [0, 0]
        applyConfiguration()
    }

    // MARK: - 对焦 / 曝光（每路独立）

    /// 点按对焦+点测光（devicePoint 为设备坐标系下的归一化坐标）
    func focus(at devicePoint: CGPoint, slot: CameraSlot) {
        guard let device = device(for: slot) else { return }
        try? device.lockForConfiguration()
        if device.isFocusPointOfInterestSupported {
            device.focusPointOfInterest = devicePoint
            device.focusMode = .autoFocus
        }
        if device.isExposurePointOfInterestSupported {
            device.exposurePointOfInterest = devicePoint
            device.exposureMode = .autoExpose
        }
        device.unlockForConfiguration()
    }

    /// 切换该路 AE/AF 锁定
    func toggleLock(slot: CameraSlot) {
        lockState[slot.index].toggle()
        applyLock(slot: slot)
    }

    private func applyLock(slot: CameraSlot) {
        guard let device = device(for: slot) else { return }
        let locked = lockState[slot.index]
        try? device.lockForConfiguration()
        if locked {
            if device.isFocusModeSupported(.locked) { device.focusMode = .locked }
            if device.isExposureModeSupported(.locked) { device.exposureMode = .locked }
        } else {
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
        }
        device.unlockForConfiguration()
    }

    /// 手动曝光补偿（每路独立）
    func setExposureBias(_ value: Float, slot: CameraSlot) {
        guard let device = device(for: slot) else { return }
        let clamped = min(max(value, device.minExposureTargetBias), device.maxExposureTargetBias)
        device.setExposureTargetBias(clamped, completionHandler: nil)
        exposureBias[slot.index] = clamped
    }

    /// 该路曝光补偿可调范围
    func exposureBiasRange(for slot: CameraSlot) -> ClosedRange<Float> {
        guard let device = device(for: slot) else { return -2...2 }
        return device.minExposureTargetBias...device.maxExposureTargetBias
    }

    func device(for slot: CameraSlot) -> AVCaptureDevice? {
        (slot == .a ? cameraA : cameraB)?.device
    }

    /// 将预览层的点转换为设备归一化坐标（点按对焦用）
    func devicePoint(for location: CGPoint, in layer: AVCaptureVideoPreviewLayer) -> CGPoint {
        layer.captureDevicePointConverted(fromLayerPoint: location)
    }

    // MARK: - 录制

    /// 开始录制：按当前布局/方向/规格启动对应录制器
    func startRecording() {
        guard !isRecording, session.isRunning, isMultiCamSupported,
              cameraA != nil, cameraB != nil else { return }
        do {
            // 两路连接的方向已在 applyOrientation() 中跟随界面锁定，
            // 录制起点即当前方向；录制期间不再跟随旋转（成片方向固定）。
            switch mode {
            case .dualFiles:
                try modeBRecorder.start()
            case .composite:
                let target = targetOutputDimensions()
                try modeARecorder.start(outputSize: target, layout: layout)
            }
            isRecording = true
            startElapsedTimer()
        } catch {
            self.error = (error as? CameraError) ?? .recordingFailed(error.localizedDescription)
        }
    }

    /// 停止录制（保存由录制器回调统一触发）
    func stopRecording() {
        guard isRecording else { return }
        switch mode {
        case .dualFiles: modeBRecorder.stop()
        case .composite: modeARecorder.stop()
        }
    }

    /// 成片方向：竖屏时宽高对调
    private func targetOutputDimensions() -> (width: Int32, height: Int32) {
        let base = preset.landscapeDimensions
        let isPortrait = (interfaceOrientation == .portrait || interfaceOrientation == .portraitUpsideDown)
        return isPortrait ? (base.height, base.width) : base
    }

    /// 录制完成（主线程回调）：保存到相册 + 复位状态
    private func handleRecordingFinished(urls: [URL]) {
        stopElapsedTimer()
        isRecording = false
        guard !urls.isEmpty else { return }
        PhotoLibrarySaver.saveVideos(at: urls) { [weak self] saved, failed in
            guard let self else { return }
            if failed == 0 {
                self.showDegradationBanner("已保存 \(saved) 段视频到相册")
            } else if saved == 0 {
                self.error = .recordingFailed("视频保存失败，文件位于 \(urls.map(\.lastPathComponent).joined(separator: "、"))")
            } else {
                self.showDegradationBanner("已保存 \(saved) 段；另有 \(failed) 段保存失败")
            }
            // 保存完成后清理临时文件
            for url in urls {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private func handleRecordingFailed(_ err: Error) {
        stopElapsedTimer()
        isRecording = false
        error = (err as? CameraError) ?? .recordingFailed(err.localizedDescription)
    }

    private func startElapsedTimer() {
        recordingElapsed = 0
        elapsedTimer?.invalidate()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.recordingElapsed += 0.1
        }
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }

    // MARK: - 系统监控（高温/内存）

    private func handleThermalChange(_ level: SystemMonitor.Level) {
        switch level {
        case .warning:
            showDegradationBanner("设备温度偏高，建议暂停录制")
        case .critical:
            showDegradationBanner("设备温度过高，已停止录制")
            stopRecording()
        case .normal:
            break
        }
    }

    private func handleMemoryChange(_ level: SystemMonitor.Level) {
        switch level {
        case .warning:
            showDegradationBanner("内存压力较大，已自动降级到 1080P30")
            if preset != .hd30 {
                preset = .hd30
                applyConfiguration()
            }
        case .critical:
            showDegradationBanner("内存不足，已停止录制")
            stopRecording()
        case .normal:
            break
        }
    }

    private func showDegradationBanner(_ text: String) {
        degradationBanner = text
        // 4 秒后自动消失
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            if self?.degradationBanner == text {
                self?.degradationBanner = nil
            }
        }
    }

    // MARK: - 应用事件

    private func observeAppEvents() {
        // 退后台立即停止并保存（需求：录制期间退回后台停止录制并保存）
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.stopRecording()
        }
        // 会话被中断（如来电）→ 停止并保存
        NotificationCenter.default.addObserver(forName: AVCaptureSession.wasInterruptedNotification,
                                               object: nil, queue: .main) { [weak self] note in
            if let reason = (note.userInfo?[AVCaptureSession.interruptionReasonKey] as? NSNumber)?.intValue,
               reason == AVCaptureSession.InterruptionReason.audioDeviceInUseByAnotherClient.rawValue {
                self?.showDegradationBanner("录音设备被其他应用占用，已停止录制")
            }
            self?.stopRecording()
        }
        // 运行期错误 → 停止并提示
        NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification,
                                               object: nil, queue: .main) { [weak self] note in
            if let err = note.userInfo?[AVCaptureSession.errorKey] as? AVError {
                self?.handleRecordingFailed(err)
            }
        }
    }
}

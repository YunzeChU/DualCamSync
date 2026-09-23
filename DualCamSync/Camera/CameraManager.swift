import AVFoundation
import CoreMedia
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
    @Published var layout: PreviewLayout = .pictureInPicture   // 默认画中画
    @Published var mode: RecordingMode = .dualFiles
    @Published var dolbyVisionEnabled = false
    @Published var spatialAudioEnabled = true
    @Published var stabilizationEnabled = [true, true]
    @Published var focusLockState = [false, false]      // 每路对焦锁定
    @Published var exposureLockState = [false, false]   // 每路曝光锁定（与对焦独立）
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
    /// 内存告警等触发的"录制结束后降级目标"（录制中无法立即重配会话）
    private var pendingDowngrade: ResolutionPreset?

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
        mode == .dualFiles ? videoConnection(of: movieOutputA) : compositeVideoConnA
    }
    private var activeVideoConnB: AVCaptureConnection? {
        mode == .dualFiles ? videoConnection(of: movieOutputB) : compositeVideoConnB
    }

    /// 从任意捕获输出中取出"启用中的视频连接"
    /// 注意：AVCaptureConnection 没有 mediaType 属性，必须经 inputPorts 判断媒体类型
    private func videoConnection(of output: AVCaptureOutput?) -> AVCaptureConnection? {
        guard let output else { return nil }
        return output.connections.first {
            $0.isEnabled && ($0.inputPorts.first?.mediaType == .video)
        }
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
    /// 注意：iPhone 前置摄像头的 deviceType 是 .builtInTrueDepthCamera
    /// （不是 wideAngle），漏掉它会导致"前置+后置"组合选不到，必须包含。
    private func discoverCameras() {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera,
                          .builtInUltraWideCamera,
                          .builtInTelephotoCamera,
                          .builtInTrueDepthCamera],
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
        // 启动只依赖相机+麦克风；相册"写入"权限延迟到保存视频时再申请
        // （需求：相册只申请写入权限，且不能因相册被拒而打不开预览）
        AVCaptureDevice.requestAccess(for: .video) { videoOK in
            AVCaptureDevice.requestAccess(for: .audio) { audioOK in
                DispatchQueue.main.async {
                    completion(videoOK && audioOK)
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

        // 降级闭环：配置前先校验当前档位可用性，不可用先自动降级再配置，
        // 避免 applyFormat 直接抛错（需求：不支持的规格自动置灰/降级）
        ensurePresetSupported(for: camA.device, and: camB.device)

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
        let conn = AVCaptureConnection(inputPort: port, videoPreviewLayer: layer)
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
        let targetMode: AVCaptureMultichannelAudioMode = wantSpatial ? .firstOrderAmbisonics : .stereo
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
        modeBRecorder.onError = { [weak self] err, successURLs in
            self?.handleRecordingFailed(err, successURLs: successURLs)
        }
    }

    /// 关闭 MovieFileOutput 上不属于指定镜头的视频连接（音频连接保持启用）
    private func constrainMovieOutput(_ output: AVCaptureMovieFileOutput, keep: CameraOption?) {
        for conn in output.connections {
            guard let port = conn.inputPorts.first else { continue }
            if port.mediaType == .audio {
                conn.isEnabled = true
                continue
            }
            guard port.mediaType == .video else { continue }
            let belongs = (keep != nil
                && port.sourceDevicePosition == keep!.position
                && port.sourceDeviceType == keep!.device.deviceType)
            conn.isEnabled = belongs
            // 录制输出同样不镜像（前置不允许镜像）
            conn.automaticallyAdjustsVideoMirroring = false
            conn.isVideoMirrored = false
            // 默认 HEVC；杜比视界由 refreshDolbyCapability 覆盖
            if belongs {
                output.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.hevc], for: conn)
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
            guard let port = conn.inputPorts.first, port.mediaType == .video else { continue }
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

    /// 杜比视界 HEVC 码型
    /// iOS 26 SDK 未暴露 AVVideoCodecType 静态成员，用 rawValue("dvhe") 构造（等价常量）
    private static let dolbyVisionCodec = AVVideoCodecType(rawValue: "dvhe")

    /// 杜比视界能力探测 + 应用（仅双文件模式；合成路径不支持）
    /// 修复：能力不可用时同步关闭 dolbyVisionEnabled 开关，避免 UI 出现
    /// "开关开着但实际没开"的状态不一致。
    private func refreshDolbyCapability() {
        guard mode == .dualFiles, let outA = movieOutputA else {
            let wasAvailable = isDolbyVisionAvailable
            isDolbyVisionAvailable = false
            if dolbyVisionEnabled {
                dolbyVisionEnabled = false
                if wasAvailable { showDegradationBanner("杜比视界当前不可用，已自动关闭") }
            }
            return
        }
        isDolbyVisionAvailable = outA.availableVideoCodecTypes.contains { $0.rawValue == "dvhe" }
        if dolbyVisionEnabled && !isDolbyVisionAvailable {
            dolbyVisionEnabled = false
            showDegradationBanner("杜比视界当前不可用，已自动关闭")
        }
        applyDolbySetting()
    }

    /// 杜比视界/普通 HEVC 输出设置 + HDR 采集管线开关
    /// -------------------------------------------------------------
    /// HDR（杜比视界）录制要真正生效，除了把编码器切到 dvhe，
    /// 还必须让"采集 → 预览 → 录制"整条链路的视频 HDR 管线开启
    /// （AVCaptureConnection.isVideoHDREnabled），否则文件虽然带
    /// dvhe 容器、内容仍是 SDR，观感上不是 HDR。
    private func applyDolbySetting() {
        let useDolby = dolbyVisionEnabled && isDolbyVisionAvailable
        // 预览连接 + 录制连接统一开关视频 HDR 管线（设备不支持时是 no-op）
        for conn in [previewConnA, previewConnB, activeVideoConnA, activeVideoConnB] {
            conn?.isVideoHDREnabled = useDolby
        }
        guard mode == .dualFiles, let outA = movieOutputA, let outB = movieOutputB else { return }
        let codec: AVVideoCodecType = useDolby ? Self.dolbyVisionCodec : .hevc
        for out in [outA, outB] {
            for conn in out.connections where conn.isEnabled && conn.inputPorts.first?.mediaType == .video {
                out.setOutputSettings([AVVideoCodecKey: codec], for: conn)
            }
        }
    }

    /// 刷新各档位可用性（UI 置灰依据）
    /// 降级动作统一由 ensurePresetSupported 在配置前完成（闭环）。
    private func refreshCapabilities() {
        guard let camA = cameraA, let camB = cameraB else { return }
        var availability: [ResolutionPreset: Bool] = [:]
        for p in ResolutionPreset.allCases {
            availability[p] = CameraPairProbe.shared.supportsPreset(camA.device, p)
                && CameraPairProbe.shared.supportsPreset(camB.device, p)
        }
        presetAvailability = availability
    }

    /// 当前档位在两台设备上不可用时，自动降级到最高可用档位
    /// 在 applyConfiguration 配置前调用，保证 applyFormat 一定落在可用档位上。
    private func ensurePresetSupported(for deviceA: AVCaptureDevice,
                                       and deviceB: AVCaptureDevice) {
        if CameraPairProbe.shared.supportsPreset(deviceA, preset),
           CameraPairProbe.shared.supportsPreset(deviceB, preset) {
            return
        }
        let old = preset
        guard let fallback = ResolutionPreset.allCases.first(where: {
            CameraPairProbe.shared.supportsPreset(deviceA, $0)
                && CameraPairProbe.shared.supportsPreset(deviceB, $0)
        }) else { return }
        preset = fallback
        showDegradationBanner("当前镜头组合不支持 \(old.displayName)，已自动降级到 \(fallback.displayName)")
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
        // 不能与另一路选择同一台设备（同一输入无法同时挂两路）
        if let other, option.id == other.id {
            error = .comboUnsupported("\(option.fullName) 已用于另一路，请选择其他镜头")
            return
        }
        if let other, !CameraPairProbe.shared.canUseTogether(option, other) {
            error = .comboUnsupported("\(option.fullName) + \(other.fullName)")
            return
        }
        if slot == .a { cameraA = option } else { cameraB = option }
        // 换镜头后复位两路的对焦/曝光锁定（与曝光补偿）
        focusLockState = [false, false]
        exposureLockState = [false, false]
        exposureBias = [0, 0]
        applyConfiguration()
    }

    // MARK: - 曝光（每路独立）

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

    // MARK: - 对焦 / 曝光锁定（每路对焦、曝光各自独立）

    /// 设置面板用：锁定/解锁该路对焦（不影响曝光）
    func setFocusLock(_ locked: Bool, slot: CameraSlot) {
        guard !isRecording, focusLockState[slot.index] != locked else { return }
        focusLockState[slot.index] = locked
        applyLock(slot: slot)
    }

    /// 设置面板用：锁定/解锁该路曝光（不影响对焦）
    func setExposureLock(_ locked: Bool, slot: CameraSlot) {
        guard !isRecording, exposureLockState[slot.index] != locked else { return }
        exposureLockState[slot.index] = locked
        applyLock(slot: slot)
    }

    private func applyLock(slot: CameraSlot) {
        guard let device = device(for: slot) else { return }
        try? device.lockForConfiguration()
        // 对焦：锁定/连续自动对焦
        if focusLockState[slot.index] {
            if device.isFocusModeSupported(.locked) { device.focusMode = .locked }
        } else {
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
        }
        // 曝光：锁定/连续自动曝光（独立开关，可单独锁其一）
        if exposureLockState[slot.index] {
            if device.isExposureModeSupported(.locked) { device.exposureMode = .locked }
        } else {
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
        }
        device.unlockForConfiguration()
    }

    // MARK: - 录制

    /// 开始录制：按当前布局/方向/规格启动对应录制器
    func startRecording() {
        guard !isRecording, isMultiCamSupported, cameraA != nil, cameraB != nil else { return }
        // 会话未就绪时明确报错，避免"点了没反应"的错觉（按键必须立即有反馈）
        guard session.isRunning else {
            error = .recordingFailed("相机会话未就绪，请稍后重试")
            return
        }
        do {
            // 两路连接的方向已在 applyOrientation() 中跟随界面锁定，
            // 录制起点即当前方向；录制期间不再跟随旋转（成片方向固定）。
            switch mode {
            case .dualFiles:
                try modeBRecorder.start()
            case .composite:
                let target = targetOutputDimensions()
                try modeARecorder.start(outputSize: target,
                                        layout: layout,
                                        audioFormat: microphoneAudioFormat())
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

    /// 麦克风音频格式（供模式A提前创建 AAC 音轨）
    /// 采样率以设备 activeFormat 为准；声道数按需求**固定 2（立体声）**——
    /// 依赖 activeFormat 的声道数不可靠（multichannelAudioMode 生效后
    /// 实际采集声道可能与 activeFormat 不同），模式A需求即"固定立体声"。
    private func microphoneAudioFormat() -> (sampleRate: Double, channels: Int)? {
        guard let input = audioInput else { return nil }
        let fd = input.device.activeFormat.formatDescription
        guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd) else { return nil }
        return (asbd.pointee.mSampleRate, 2)
    }

    /// 录制完成（主线程回调）：保存到相册 + 复位状态
    private func handleRecordingFinished(urls: [URL]) {
        stopElapsedTimer()
        isRecording = false
        applyPendingDowngrade()   // 内存告警等触发的"录制结束后降级"在此闭环
        guard !urls.isEmpty else { return }
        PhotoLibrarySaver.saveVideos(at: urls) { [weak self] savedURLs, failedURLs in
            guard let self else { return }
            if failedURLs.isEmpty {
                self.showDegradationBanner("已保存 \(savedURLs.count) 段视频到相册")
            } else if savedURLs.isEmpty {
                self.error = .recordingFailed(
                    "视频保存失败，文件位于 \(failedURLs.map(\.lastPathComponent).joined(separator: "、"))（临时目录）")
            } else {
                self.showDegradationBanner(
                    "已保存 \(savedURLs.count) 段；另有 \(failedURLs.count) 段保存失败")
            }
            // 仅删除"保存成功"的临时文件；失败文件保留在临时目录，便于手动找回
            for url in savedURLs {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// 录制失败收尾：先保存一路可能已成功的文件，再上报错误
    private func handleRecordingFailed(_ err: Error, successURLs: [URL] = []) {
        stopElapsedTimer()
        isRecording = false
        applyPendingDowngrade()
        // 模式B一路失败、另一路成功：成功文件仍保存到相册（不丢弃）
        if !successURLs.isEmpty {
            PhotoLibrarySaver.saveVideos(at: successURLs) { [weak self] savedURLs, failedURLs in
                guard let self else { return }
                if failedURLs.isEmpty {
                    self.showDegradationBanner("一路录制失败；成功的一段已保存到相册")
                } else {
                    self.showDegradationBanner("一路录制失败；成功的一段也未能保存，文件位于临时目录")
                }
                for url in savedURLs {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
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
            // 内存告警几乎总在录制中触发；此时先停止录制并保存当前成片，
            // 再把降级挂起，等录制收尾（isRecording=false）后统一重配到 1080P30。
            showDegradationBanner("内存压力较大：已停止录制，结束后自动降级到 1080P30")
            if isRecording {
                pendingDowngrade = .hd30
                stopRecording()
            } else if preset != .hd30 {
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

    /// 录制收尾后执行挂起的降级（内存告警场景）
    private func applyPendingDowngrade() {
        guard let target = pendingDowngrade else { return }
        pendingDowngrade = nil
        guard preset != target else { return }
        preset = target
        applyConfiguration()
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
            // 通知 userInfo 键名（Objective-C 常量，Swift 未暴露为静态成员，直接用字符串字面量）
            if let reason = (note.userInfo?["AVCaptureSessionInterruptionReasonKey"] as? NSNumber)?.intValue,
               reason == AVCaptureSession.InterruptionReason.audioDeviceInUseByAnotherClient.rawValue {
                self?.showDegradationBanner("录音设备被其他应用占用，已停止录制")
            }
            self?.stopRecording()
        }
        // 运行期错误 → 停止并提示
        NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification,
                                               object: nil, queue: .main) { [weak self] note in
            // userInfo 中的错误是 NSError（Swift 桥接 as? AVError 在部分系统下会失败），
            // 统一按 NSError 读取，保证异常分支稳定。
            if let err = note.userInfo?["AVCaptureSessionErrorKey"] as? NSError {
                self?.handleRecordingFailed(err)
            }
        }
    }
}

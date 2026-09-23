import AVFoundation
import CoreLocation
import CoreMedia
import CoreVideo
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
    /// 每次会话重配都**重建全新实例** + 递增 previewGeneration 触发 SwiftUI
    /// 用 .id 强制重建预览容器——绕开多摄经典坑：teardown 移除连接后
    /// previewLayer.connection 残留，下一次 canAddConnection 失败 → 一路黑屏。
    /// private(set)：本文件可重建赋值，视图层只读。
    private(set) var previewLayerA: AVCaptureVideoPreviewLayer!
    private(set) var previewLayerB: AVCaptureVideoPreviewLayer!
    /// 预览层代际号：每次重建预览层 +1，CameraView 用 .id 强制重建预览容器
    @Published var previewGeneration = 0
    private var previewConnA: AVCaptureConnection?
    private var previewConnB: AVCaptureConnection?

    private static func makePreviewLayer(session: AVCaptureSession) -> AVCaptureVideoPreviewLayer {
        let layer = AVCaptureVideoPreviewLayer(sessionWithNoConnection: session)
        layer.videoGravity = .resizeAspectFill
        return layer
    }

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
    /// 成片收尾中（点停止后文件仍在异步写入/保存；期间禁止再次开始录制）
    @Published var isFinalizing = false
    @Published var recordingElapsed: TimeInterval = 0
    @Published var interfaceOrientation: UIInterfaceOrientation = .portrait

    /// 拍摄地点开关（保存视频时把定位写入视频元数据；需要定位权限）
    @Published var includeLocation = true

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

    // MARK: - 定位（拍摄地点）

    private let locationManager = CLLocationManager()
    private var lastLocation: CLLocation?

    /// 请求定位权限 + 单次获取位置（权限弹窗与应用启动同批出现，避免录制中打扰）
    private func requestLocationPermission() {
        locationManager.delegate = self
        // 拍摄地点不需要高精度，百米级即可，省电且无需高精度权限
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        locationManager.requestWhenInUseAuthorization()
    }

    // MARK: - 初始化

    override init() {
        super.init()
        // 预览层在 init 中创建（session 为声明时初始化的 let，此处可安全访问）
        previewLayerA = Self.makePreviewLayer(session: session)
        previewLayerB = Self.makePreviewLayer(session: session)
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

        requestLocationPermission()   // 定位权限与相机/麦克风权限同一批请求
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
        // 前置去重：iPhone 前置相机常被系统以多个虚拟设备暴露
        // （TrueDepth 与 WideAngle 可能指向同一颗物理前置），导致
        // 列表出现多个同名"前置"；同一"位置+镜头类型"只保留一个。
        var seenLens = Set<String>()
        list = list.filter { seenLens.insert("\($0.position.rawValue)|\($0.lensType.rawValue)").inserted }
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
            // 首启直接用 init 里创建的预览层；仅在后续重配（存在旧连接残留风险）时
            // 重建全新实例并递增 previewGeneration，触发 SwiftUI 换层。
            // 多摄经典坑：teardown 移除连接后，旧 previewLayer.connection 引用
            // 未清干净，下一次 canAddConnection 可能失败 → 一路黑屏。
            if previewGeneration > 0 {
                previewLayerA = Self.makePreviewLayer(session: session)
                previewLayerB = Self.makePreviewLayer(session: session)
                previewGeneration += 1
            }
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

            // 防抖 / 方向 / 杜比（输出编码器必须在 commit 前设置）
            applyStabilization()
            applyOrientation()
            refreshDolbyCapability()

            session.commitConfiguration()
            session.startRunning()
            refreshCapabilities()
            // commit + startRunning 之后：杜比开启时切 10-bit HDR 采集格式
            applyHDRFormatIfNeeded()

            // 预览连接建立失败不能静默：双摄预览只有一路，用户无法发现。
            // 细化到 A/B 哪一路失败、失败原因，便于定位。
            let aOK = previewConnA != nil
            let bOK = previewConnB != nil
            if !aOK || !bOK {
                error = .configurationFailed(
                    "预览层建立失败（A 路\(Self.describeFailure(previewConnA, lastFailure: lastPreviewFailureA))、"
                    + "B 路\(Self.describeFailure(previewConnB, lastFailure: lastPreviewFailureB))）")
            }
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
    /// 失败时记录具体原因（lastPreviewFailure*），错误提示区分
    /// "端口缺失"与"会话拒绝建连"两种情形，便于真机定位。
    private func makePreviewConnection(layer: AVCaptureVideoPreviewLayer,
                                       input: AVCaptureDeviceInput) -> AVCaptureConnection? {
        // 防御：若 layer 已存在连接（某些系统版本在 addInput 时可能
        // 自动为关联的预览层建连），直接复用，避免手动建连失败。
        if let existing = layer.connection {
            return existing
        }
        guard let port = input.ports.first(where: { $0.mediaType == .video }) else {
            if layer === previewLayerA { lastPreviewFailureA = "端口缺失" } else { lastPreviewFailureB = "端口缺失" }
            return nil
        }
        let conn = AVCaptureConnection(inputPort: port, videoPreviewLayer: layer)
        guard session.canAddConnection(conn) else {
            if layer === previewLayerA { lastPreviewFailureA = "会话拒绝建连" } else { lastPreviewFailureB = "会话拒绝建连" }
            return nil
        }
        // 前置不镜像（需求：前置摄像头不允许镜像）
        conn.automaticallyAdjustsVideoMirroring = false
        conn.isVideoMirrored = false
        session.addConnection(conn)
        if layer === previewLayerA { lastPreviewFailureA = nil } else { lastPreviewFailureB = nil }
        return conn
    }

    private var lastPreviewFailureA: String?
    private var lastPreviewFailureB: String?

    private static func describeFailure(_ conn: AVCaptureConnection?, lastFailure: String?) -> String {
        conn != nil ? "正常" : (lastFailure ?? "未知原因")
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
        // 设备配置类调用必须 lock；lock 失败绝不能继续（未锁定设备 unlock 会抛 NSException）
        guard (try? device.lockForConfiguration()) != nil else {
            throw CameraError.configurationFailed("设备配置锁获取失败（\(device.localizedName)）")
        }
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
        modeBRecorder.onError = { [weak self] err, successURLs, failedURLs in
            self?.handleRecordingFailed(err, successURLs: successURLs, failedURLs: failedURLs)
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
        // 前后置分别用各自的旋转基准（前置传感器竖装，基准与后置不同）
        previewConnA?.videoRotationAngle = Self.rotationAngle(
            for: interfaceOrientation, isFront: Self.isFrontConnection(previewConnA))
        previewConnB?.videoRotationAngle = Self.rotationAngle(
            for: interfaceOrientation, isFront: Self.isFrontConnection(previewConnB))
        // 录制连接（未在录制时更新；录制起点方向在 startRecording 里锁定）
        if !isRecording {
            activeVideoConnA?.videoRotationAngle = Self.rotationAngle(
                for: interfaceOrientation, isFront: Self.isFrontConnection(activeVideoConnA))
            activeVideoConnB?.videoRotationAngle = Self.rotationAngle(
                for: interfaceOrientation, isFront: Self.isFrontConnection(activeVideoConnB))
        }
    }

    /// 旋转角度映射。
    /// 注意：**前后置传感器安装方向不同**——后置横装（landscape）、**前置竖装（portrait）**。
    /// 同一界面方向下，前置连接必须用"后置角度 -90°"（等价 +270°），
    /// 否则竖拍时后置成片竖、前置成片横（用户实测：修复前竖拍前置一直是横的）。
    static func rotationAngle(for orientation: UIInterfaceOrientation, isFront: Bool = false) -> CGFloat {
        let back: CGFloat
        switch orientation {
        case .portrait:              back = 90
        case .portraitUpsideDown:    back = 270
        case .landscapeLeft:         back = 0
        case .landscapeRight:        back = 180
        default:                     back = 90
        }
        // 前置：传感器竖装，旋转基准与后置相差 -90°（mod 360）
        return isFront ? (back + 270).truncatingRemainder(dividingBy: 360) : back
    }

    /// 判断某条连接是否来自前置摄像头（用于选择旋转基准）
    private static func isFrontConnection(_ conn: AVCaptureConnection?) -> Bool {
        conn?.inputPorts.first?.sourceDevicePosition == .front
    }

    /// 杜比视界 HEVC 码型
    /// iOS 26 SDK 未暴露 AVVideoCodecType 静态成员，用 rawValue("dvhe") 构造（等价常量）
    private static let dolbyVisionCodec = AVVideoCodecType(rawValue: "dvhe")

    /// 杜比视界能力探测 + 输出编码器设置（**必须在 commitConfiguration 之前调用**）
    /// -----------------------------------------------------------------------
    /// 判据只有一条：两路设备都具备 10-bit HDR 采集格式。
    /// 注意：**不能**依赖 MovieFileOutput.availableVideoCodecTypes——
    /// 该列表在设备 activeFormat 还是 8-bit 时不含 dvhe，
    /// 会把支持杜比视界的设备（iPhone 17 Pro）误判为"不支持"导致开关永远灰。
    /// 另外 setOutputSettings 必须发生在会话配置阶段（commit 前），
    /// 运行中调用可能触发异常导致闪退——这就是"杜比点开后卡顿闪退"的根因之一。
    private func refreshDolbyCapability() {
        guard mode == .dualFiles, cameraA != nil, cameraB != nil else {
            let wasAvailable = isDolbyVisionAvailable
            isDolbyVisionAvailable = false
            if dolbyVisionEnabled {
                dolbyVisionEnabled = false
                if wasAvailable { showDegradationBanner("杜比视界当前不可用，已自动关闭") }
            }
            applyOutputCodec(useDolby: false)
            return
        }
        let deviceOK = [cameraA?.device, cameraB?.device]
            .compactMap { $0 }
            .allSatisfy(deviceSupportsHDRCapture)

        isDolbyVisionAvailable = deviceOK
        if dolbyVisionEnabled && !isDolbyVisionAvailable {
            dolbyVisionEnabled = false
            showDegradationBanner("杜比视界当前不可用，已自动关闭")
        }
        applyOutputCodec(useDolby: dolbyVisionEnabled && isDolbyVisionAvailable)
    }

    /// 设备是否有 10-bit HDR 采集格式（杜比视界内容由 10-bit 双平面格式承载）
    private func deviceSupportsHDRCapture(_ device: AVCaptureDevice) -> Bool {
        let targetVideoRange = UInt32(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
        let targetFullRange = UInt32(kCVPixelFormatType_420YpCbCr10BiPlanarFullRange)
        return device.formats.contains { format in
            let subtype = UInt32(CMFormatDescriptionGetMediaSubType(format.formatDescription))
            return subtype == targetVideoRange || subtype == targetFullRange
        }
    }

    /// 设置 MovieFileOutput 输出编码器（hevc / dvhe）。
    /// 只允许在会话配置阶段（commitConfiguration 之前）调用。
    private func applyOutputCodec(useDolby: Bool) {
        guard mode == .dualFiles, let outA = movieOutputA, let outB = movieOutputB else { return }
        let codec: AVVideoCodecType = useDolby ? Self.dolbyVisionCodec : .hevc
        for out in [outA, outB] {
            for conn in out.connections where conn.isEnabled && conn.inputPorts.first?.mediaType == .video {
                out.setOutputSettings([AVVideoCodecKey: codec], for: conn)
            }
        }
    }

    /// 杜比视界开启时：把两台设备 activeFormat 切到同档 10-bit HDR 格式。
    /// DV 的 HDR 内容由 10-bit 采集格式承载（编码器 dvhe 只是容器）——
    /// 若格式仍是 8-bit，成片即使带 dvhe 容器观感也是 SDR。
    /// 在 commit + startRunning 之后调用（activeFormat 变更不影响会话结构）。
    /// 注意：lockForConfiguration 返回 false 时**绝不能**调用 unlock——
    /// 未锁定的设备 unlock 会抛 NSException 直接闪退（杜比闪退根因之二）。
    private func applyHDRFormatIfNeeded() {
        guard dolbyVisionEnabled && isDolbyVisionAvailable else { return }
        for device in [cameraA?.device, cameraB?.device].compactMap({ $0 }) {
            let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
            guard let hdr = findHDRFormat(for: device, width: dims.width, height: dims.height),
                  hdr != device.activeFormat else { continue }
            guard (try? device.lockForConfiguration()) != nil else { continue }
            device.activeFormat = hdr
            // 切换 activeFormat 可能重置帧率，重新锁定到当前档位
            let duration = CMTime(value: 1, timescale: CMTimeScale(preset.fps))
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            device.unlockForConfiguration()
        }
    }

    /// 查找与当前宽高匹配、且支持目标帧率的 10-bit HDR 格式
    private func findHDRFormat(for device: AVCaptureDevice,
                               width: Int32, height: Int32) -> AVCaptureDevice.Format? {
        let targetFPS = Double(preset.fps)
        let targetVideoRange = UInt32(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
        let targetFullRange = UInt32(kCVPixelFormatType_420YpCbCr10BiPlanarFullRange)
        for format in device.formats {
            let desc = format.formatDescription
            // HDR 视频 = 10-bit 双平面（VideoRange / FullRange）
            let subtype = UInt32(CMFormatDescriptionGetMediaSubType(desc))
            guard subtype == targetVideoRange || subtype == targetFullRange else { continue }
            let dims = CMVideoFormatDescriptionGetDimensions(desc)
            guard dims.width == width, dims.height == height else { continue }
            guard format.videoSupportedFrameRateRanges.contains(where: { $0.maxFrameRate >= targetFPS - 0.5 }) else { continue }
            return format
        }
        return nil
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
    /// -------------------------------------------------------------
    /// 修复"调整曝光补偿直接闪退"：
    ///  1. Swift 标准库 min/max 遇到 NaN 会触发 precondition failure 崩溃，
    ///     设备未就绪时 min/maxExposureTargetBias 可能返回 NaN——改为
    ///     手动 if 比较（对 NaN 安全）+ 有限性校验，绝不再直接 min/max；
    ///  2. setExposureTargetBias 属于设备配置类调用：加 lockForConfiguration
    ///     包裹，避免部分机型/系统在未锁定状态下调用触发异常。
    func setExposureBias(_ value: Float, slot: CameraSlot) {
        guard let device = device(for: slot) else { return }
        var clamped = value
        if !clamped.isFinite { clamped = 0 }
        let lo = device.minExposureTargetBias
        let hi = device.maxExposureTargetBias
        if lo.isFinite && hi.isFinite && lo <= hi {
            if clamped < lo { clamped = lo }
            if clamped > hi { clamped = hi }
        }
        // lock 失败直接返回（绝不能对未锁定设备调用 unlock——NSException 闪退）
        guard (try? device.lockForConfiguration()) != nil else { return }
        device.setExposureTargetBias(clamped, completionHandler: nil)
        device.unlockForConfiguration()
        exposureBias[slot.index] = clamped
    }

    /// 该路曝光补偿可调范围（守卫：无效范围一律回退默认，避免 Slider 构造崩溃）
    func exposureBiasRange(for slot: CameraSlot) -> ClosedRange<Float> {
        guard let device = device(for: slot) else { return -2...2 }
        let lo = device.minExposureTargetBias
        let hi = device.maxExposureTargetBias
        guard lo.isFinite, hi.isFinite, lo <= hi else { return -2...2 }
        return lo...hi
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
        // lock 失败直接返回（未锁定设备 unlock 会抛 NSException 闪退）
        guard (try? device.lockForConfiguration()) != nil else { return }
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
        guard !isRecording, !isFinalizing, isMultiCamSupported, cameraA != nil, cameraB != nil else {
            if isFinalizing {
                // 上一段还在收尾（约 1 秒）：明确提示，避免"点了没反应"
                error = .recordingFailed("上一段视频正在保存，请稍候再录")
            }
            return
        }
        // 会话未就绪时明确报错，避免"点了没反应"的错觉（按键必须立即有反馈）
        guard session.isRunning else {
            error = .recordingFailed("相机会话未就绪，请稍后重试")
            return
        }
        do {
            // 录制前把两路录制输出的**全部启用视频连接**方向对齐到当前界面方向，
            // 保证 A/B 两路成片朝向一致、与预览一致（修复一路横一路竖）。
            lockOutputOrientations()
            applyOrientation()
            // 两路连接的方向已在上面锁定，录制起点即当前方向；
            // 录制期间不再跟随旋转（成片方向固定）。
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
    /// 点按立即复位 UI（按钮/计时），成片由录制器异步收尾并保存——
    /// 修复"点停止后要空等约 1 秒才终止"的卡顿感。
    func stopRecording() {
        guard isRecording else { return }
        isFinalizing = true
        stopElapsedTimer()
        isRecording = false
        switch mode {
        case .dualFiles: modeBRecorder.stop()
        case .composite: modeARecorder.stop()
        }
    }

    /// 录制前把两路 MovieFileOutput 的全部启用视频连接方向对齐到当前界面方向。
    /// 逐个遍历设置（不依赖 videoConnection(of:) 只取第一个连接），
    /// 前后置分别用各自旋转基准——从根上保证 A/B 成片朝向一致。
    private func lockOutputOrientations() {
        for out in [movieOutputA, movieOutputB].compactMap({ $0 }) {
            for conn in out.connections where conn.isEnabled {
                guard conn.inputPorts.first?.mediaType == .video else { continue }
                conn.videoRotationAngle = Self.rotationAngle(
                    for: interfaceOrientation, isFront: Self.isFrontConnection(conn))
            }
        }
    }

    /// 成片方向：竖屏时宽高对调
    private func targetOutputDimensions() -> (width: Int32, height: Int32) {
        let base = preset.landscapeDimensions
        let isPortrait = (interfaceOrientation == .portrait || interfaceOrientation == .portraitUpsideDown)
        return isPortrait ? (base.height, base.width) : base
    }

    /// 麦克风音频格式（供模式A判断"是否有麦克风"）
    /// 注意：模式A音轨的声道数以音频首帧真实 ASBD 为准（ModeARecorder 懒创建），
    /// 此处返回的实际声道数不再用于建轨，仅采样率/非 nil 用于判断有无麦克风。
    private func microphoneAudioFormat() -> (sampleRate: Double, channels: Int)? {
        guard let input = audioInput else { return nil }
        let fd = input.device.activeFormat.formatDescription
        guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd) else { return nil }
        return (asbd.pointee.mSampleRate, Int(asbd.pointee.mChannelsPerFrame))
    }

    /// 录制完成（主线程回调）：保存到相册 + 复位状态
    private func handleRecordingFinished(urls: [URL]) {
        stopElapsedTimer()
        isRecording = false
        isFinalizing = false
        applyPendingDowngrade()   // 内存告警等触发的"录制结束后降级"在此闭环
        guard !urls.isEmpty else { return }
        PhotoLibrarySaver.saveVideos(at: urls,
                                     location: includeLocation ? lastLocation : nil) { [weak self] savedURLs, failedURLs in
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
    /// - Parameters:
    ///   - successURLs: 已成功完成的文件（保存到相册后删除临时文件）
    ///   - failedURLs: 失败文件（保留在临时目录，错误提示带上路径；
    ///     系统 tmp 目录会在适当时候自动回收，不手动删除防误删）
    private func handleRecordingFailed(_ err: Error,
                                       successURLs: [URL] = [],
                                       failedURLs: [URL] = []) {
        stopElapsedTimer()
        isRecording = false
        isFinalizing = false
        applyPendingDowngrade()
        // 模式B一路失败、另一路成功：成功文件仍保存到相册（不丢弃）
        if !successURLs.isEmpty {
            PhotoLibrarySaver.saveVideos(at: successURLs,
                                         location: includeLocation ? lastLocation : nil) { [weak self] savedURLs, savedFailed in
                guard let self else { return }
                if savedFailed.isEmpty {
                    self.showDegradationBanner("一路录制失败；成功的一段已保存到相册")
                } else {
                    self.showDegradationBanner("一路录制失败；成功的一段也未能保存，文件位于临时目录")
                }
                for url in savedURLs {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
        // 错误提示附带失败文件路径（便于用户手动找回）
        var message = err.localizedDescription
        if !failedURLs.isEmpty {
            message += "；未保存文件位于临时目录："
                + failedURLs.map(\.lastPathComponent).joined(separator: "、")
        }
        error = .recordingFailed(message)
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

    /// 通知观察者 token 数组（deinit 统一移除，避免悬挂回调）
    private var observationTokens: [NSObjectProtocol] = []

    private func observeAppEvents() {
        // 退后台立即停止并保存（需求：录制期间退回后台停止录制并保存）
        observationTokens.append(
            NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                                   object: nil, queue: .main) { [weak self] _ in
                self?.stopRecording()
            })
        // 会话被中断（如来电）→ 停止并保存
        observationTokens.append(
            NotificationCenter.default.addObserver(forName: AVCaptureSession.wasInterruptedNotification,
                                                   object: nil, queue: .main) { [weak self] note in
                // 通知 userInfo 键名（Objective-C 常量，Swift 未暴露为静态成员，直接用字符串字面量）
                if let reason = (note.userInfo?["AVCaptureSessionInterruptionReasonKey"] as? NSNumber)?.intValue,
                   reason == AVCaptureSession.InterruptionReason.audioDeviceInUseByAnotherClient.rawValue {
                    self?.showDegradationBanner("录音设备被其他应用占用，已停止录制")
                }
                self?.stopRecording()
            })
        // 运行期错误 → 停止并提示
        observationTokens.append(
            NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification,
                                                   object: nil, queue: .main) { [weak self] note in
                // userInfo 中的错误是 NSError（Swift 桥接 as? AVError 在部分系统下会失败），
                // 统一按 NSError 读取，保证异常分支稳定。
                if let err = note.userInfo?["AVCaptureSessionErrorKey"] as? NSError {
                    self?.handleRecordingFailed(err)
                }
            })
    }

    /// 释放时停止会话并移除全部通知观察者
    deinit {
        session.stopRunning()
        for token in observationTokens {
            NotificationCenter.default.removeObserver(token)
        }
    }
}

// MARK: - 定位（拍摄地点写入视频元数据）

extension CameraManager: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            // 授权后单次获取一个位置即可（拍摄地点不需要持续跟踪）
            manager.requestLocation()
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        lastLocation = locations.last
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // 定位失败不阻塞录制与保存：视频正常保存，只是不带拍摄地点
    }
}

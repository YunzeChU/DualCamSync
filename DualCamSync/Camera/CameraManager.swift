import AVFoundation
import CoreLocation
import CoreMedia
import CoreVideo
import Photos
import SwiftUI
import UIKit
import Observation

/// 相机管理器：整个双摄功能的唯一权威来源
/// -------------------------------------------------------------
/// 职责：
///  1. 管理 AVCaptureMultiCamSession（任意双镜头组合、逐设备格式配置）
///  2. 两路预览层 + 每路独立对焦/曝光锁定/曝光补偿
///  3. 分辨率档位 / 杜比视界 / 防抖 / 空间音频 / 录制模式 配置
///  4. 异常容错：组合探测、自动降级、运行期错误兜底、高温/内存监控
///
/// 线程模型：本类主要在主线程使用；AVFoundation 回调统一转回主队列后
/// 再修改可观察状态，避免 SwiftUI 断言崩溃。
/// 使用 Observation 框架（iOS 26 推荐）：属性变化会直接驱动 SwiftUI 刷新。
/// 注意：@Observable 宏不能作用于 NSObject 子类（Swift 硬性限制），
/// 因此本类不继承 NSObject；CLLocationManagerDelegate 由内部辅助类承担。
@Observable
final class CameraManager {
    // MARK: - 会话与预览层

    /// 多摄会话（支持任意双镜头组合的核心）
    let session = AVCaptureMultiCamSession()

    /// 两路独立预览层（视图层通过 PreviewLayerView 包装渲染）
    /// 在 init 中一次性创建并**永不重建**（回到 v1.0 双路预览正常的实现；
    /// 真机验证：重建全新 layer 后手动建连会被 canAddConnection 拒绝）。
    /// private(set)：本文件可赋值，视图层只读。
    private(set) var previewLayerA: AVCaptureVideoPreviewLayer!
    private(set) var previewLayerB: AVCaptureVideoPreviewLayer!
    /// 重配次数计数（诊断横幅 GEN 用；不再用于重建预览层/容器）
    var previewGeneration = 0
    private var previewConnA: AVCaptureConnection?
    private var previewConnB: AVCaptureConnection?

    private static func makePreviewLayer(session: AVCaptureSession) -> AVCaptureVideoPreviewLayer {
        let layer = AVCaptureVideoPreviewLayer(sessionWithNoConnection: session)
        layer.videoGravity = .resizeAspectFill
        return layer
    }

    // MARK: - 对外状态（SwiftUI 驱动）

    var availableCameras: [CameraOption] = []
    var cameraA: CameraOption?
    var cameraB: CameraOption?
    var preset: ResolutionPreset = .uhd30
    var layout: PreviewLayout = .pictureInPicture   // 默认画中画
    var mode: RecordingMode = .dualFiles
    var dolbyVisionEnabled = false
    var spatialAudioEnabled = true
    var stabilizationEnabled = [true, true]
    var focusLockState = [false, false]      // 每路对焦锁定
    var exposureLockState = [false, false]   // 每路曝光锁定（与对焦独立）
    var exposureBias: [Float] = [0, 0]      // 每路曝光补偿

    var isRecording = false
    /// 成片收尾中（点停止后文件仍在异步写入/保存；期间禁止再次开始录制）
    var isFinalizing = false
    /// 收尾代际：每次 startRecording +1，录制器回调捕获当时的代际值。
    /// 防止"stopRecording 3 秒兜底复位 isFinalizing 后，用户已开始新录制，
    /// 而旧录制的 didFinish/finishWriting 回调迟到"时误停新录制/误复位状态。
    private var finalizeToken = 0
    var recordingElapsed: TimeInterval = 0
    var interfaceOrientation: UIInterfaceOrientation = .portrait

    /// 拍摄地点开关（保存视频时把定位写入视频元数据；需要定位权限）
    /// 默认关闭：不主动申请定位权限，只有用户打开开关并保存时才请求
    var includeLocation = false

    /// 各档位在"当前双摄组合"下的可用性（UI 置灰用）
    var presetAvailability: [ResolutionPreset: Bool] = [:]
    var isDolbyVisionAvailable = false
    /// 杜比能力诊断摘要（真机验证用，验证后可删）：两路 formats 统计
    var hdrFormatDiagnostics = ""
    /// 运行时实测：HDR 会话下首帧输出是否 10-bit（模式A 首帧校验后为 true；
    /// 模式B MovieFileOutput 无帧回调，保持 false 表示未校验）
    var hdrPipelineVerified = false
    var hdrPipelineOK = true
    var isSpatialAudioAvailable = false
    var isMultiCamSupported = true

    var error: CameraError?
    var degradationBanner: String?

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
    /// 本次会话合成输出是否实际为 10-bit HDR（attachCompositeOutputs 按
    /// "开关 && 格式可用"确定并记录）。录制时 ModeARecorder 以此决定杜比
    /// 写入——不能直接用 dolbyVisionEnabled：开关可能在同一次配置中被
    /// refreshDolbyCapability 自动关闭，而会话已是 10-bit；此时若按 SDR
    /// 启动（BGRA adaptor）接 P010 帧会导致 append 失败/黑帧。
    private(set) var compositeOutputIsHDR = false
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

    /// CLLocationManagerDelegate 辅助对象（CameraManager 不继承 NSObject，
    /// @Observable 宏禁止作用于 NSObject 子类；delegate 回调转发回主对象）
    private final class LocationDelegate: NSObject, CLLocationManagerDelegate {
        weak var manager: CameraManager?
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
            self.manager?.lastLocation = locations.last
        }
        func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
            // 定位失败不阻塞录制与保存：视频正常保存，只是不带拍摄地点
        }
    }

    private let locationManager = CLLocationManager()
    private var lastLocation: CLLocation?
    private let locationDelegate = LocationDelegate()

    /// 请求定位权限 + 单次获取位置。
    /// 只在"用户打开拍摄地点开关"或"保存时开关仍开且未授权"时调用，
    /// 不与应用启动同批弹窗（需求：权限延迟到保存场景，避免启动即打扰）。
    private func requestLocationIfNeeded() {
        switch locationManager.authorizationStatus {
        case .notDetermined, .denied, .restricted:
            locationManager.delegate = locationDelegate
            // 拍摄地点不需要高精度，百米级即可，省电且无需高精度权限
            locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
            locationManager.requestWhenInUseAuthorization()
        default:
            break   // 已授权则直接用 lastLocation（可能为 nil 时视频不带定位）
        }
    }

    // MARK: - 初始化

    init() {
        locationDelegate.manager = self
        locationManager.delegate = locationDelegate
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

        discoverCameras()
        // 恢复上次设置（镜头按 uniqueID 从可用列表找回；找不到保持 nil，
        // 由 pickDefaultCameras 兜底）。标量档位等由 applyConfiguration
        // 内的 ensurePresetSupported 在设备不支持下自动降级。
        restoreSettings()
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
        // 前置只保留一个：iPhone 17 系列前置以多个虚拟设备暴露
        // （TrueDepth / WideAngle 等，且可能解析出不同 lensType，导致
        // 下方 position|LensType 去重键不同、列表出现两个"前置"）。
        // UI 上前置始终只有一个选项。
        var frontSeen = false
        list = list.filter { option in
            if option.position == .front {
                if frontSeen { return false }
                frontSeen = true
            }
            return true
        }
        // 后置镜头去重：同一"位置+镜头类型"只保留一个（同上注释背景）
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
        // 录制中不允许改动会话结构；收尾中同样不允许（录制器还在异步写文件，
        // 此刻 teardownSession 会拆掉会话导致最后一帧丢失/回调错乱）
        guard !isRecording, !isFinalizing else { return }

        // 降级闭环：配置前先校验当前档位可用性，不可用先自动降级再配置，
        // 避免 applyFormat 直接抛错（需求：不支持的规格自动置灰/降级）
        ensurePresetSupported(for: camA.device, and: camB.device)

        session.beginConfiguration()
        teardownSession()
        // 重置杜比诊断状态：模式/档位/镜头切换后不残留上次会话旧值
        // （模式B 无帧校验、compositeOutputIsHDR 仅模式A 有效；外部审核 P1-4）
        hdrPipelineVerified = false
        hdrPipelineOK = true
        compositeOutputIsHDR = false
        do {
            let inputA = try AVCaptureDeviceInput(device: camA.device)
            let inputB = try AVCaptureDeviceInput(device: camB.device)
            guard session.canAddInput(inputA), session.canAddInput(inputB) else {
                throw CameraError.comboUnsupported("\(camA.fullName) + \(camB.fullName)")
            }
            session.addInput(inputA)
            session.addInput(inputB)

            // 录制输出（按模式）先挂：applyFormat 判定杜比可用性需要输出
            // 实例的编码器/像素格式能力（MovieFileOutput.availableVideoCodecTypes
            // / VideoDataOutput.availableVideoPixelFormatTypes），必须建好输出
            // 再切格式，保证 applyFormat 与 refreshDolbyCapability 判据同源
            // （外部审核 P1-1/P2-8：原顺序 applyFormat 先切 10-bit、refresh
            // 后判定 codec 不可用才关开关，导致"开关已关、采集仍 10-bit"错配）。
            switch mode {
            case .dualFiles:
                try attachDualFileOutputs(videoInputA: inputA, videoInputB: inputB)
            case .composite:
                attachCompositeOutputs(videoInputA: inputA, videoInputB: inputB)
            }

            // 多摄会话中每台设备可独立配置 activeFormat
            try applyFormat(device: camA.device, preset: preset)
            try applyFormat(device: camB.device, preset: preset)

            // 预览层连接（手动建连）
            // 预览层在 init 中一次性创建、**永不重建**（回到 v1.0 双路预览
            // 正常的实现）。多次真机验证：重建全新 previewLayer 实例后，
            // 手动 AVCaptureConnection 会被 canAddConnection 拒绝
            // （"会话拒绝连接，N 个视频端口均被拒"）；而首次创建的层
            // 在 addInput 后可正常建连。重配只走 teardown（移除旧连接）+
            // 同层重新建连，previewGeneration 仅作为重配次数计数供诊断。
            previewGeneration += 1
            previewConnA = makePreviewConnection(layer: previewLayerA, input: inputA)
            previewConnB = makePreviewConnection(layer: previewLayerB, input: inputB)

            // 音频输入（立体声 / 空间音频）
            try attachAudioInput()

            // 防抖 / 方向 / 杜比（输出编码器必须在 commit 前设置）
            applyStabilization()
            applyOrientation()
            refreshDolbyCapability()

            session.commitConfiguration()
            session.startRunning()
            refreshCapabilities()
            // 恢复的对焦锁/曝光锁/曝光补偿在此应用到设备（startRunning 后
            // 设置设备属性不需要重配会话；保证 UI 状态与设备一致——否则
            // 二次启动后 UI 显示"已锁定/EV+1.0"而设备实际没锁/没补偿）
            restoreDeviceCaptureStates()
            // 杜比的 10-bit HDR 格式已在 applyFormat（commit 前）切好；
            // 不再在 startRunning 后切换 activeFormat（多摄下会卡顿闪退）

            // 预览连接建立失败不能静默：双摄预览只有一路，用户无法发现。
            // 自愈：双摄首次配置存在系统时序问题，延迟重配一次通常可恢复双路；
            // 有次数上限。**首次失败不立即弹错**：若重试成功则不打扰用户，
            // 重试仍失败才上报（避免 alert 残留 + 实际已恢复的矛盾状态）。
            let aOK = previewConnA != nil
            let bOK = previewConnB != nil
            if !aOK || !bOK {
                if previewRetryCount < 1 {
                    previewRetryCount += 1
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                        self?.applyConfiguration()
                    }
                } else {
                    error = .configurationFailed(
                        "预览层建立失败（A 路\(Self.describeFailure(previewConnA, lastFailure: lastPreviewFailureA))、"
                        + "B 路\(Self.describeFailure(previewConnB, lastFailure: lastPreviewFailureB))）")
                }
            } else {
                previewRetryCount = 0
                // 建连成功后**再显式应用一次方向**：若本次重配存在"建连失败
                // → 0.4s 延迟重配"窗口，A 路连接角度可能未被设置（停在系统
                // 默认方向，与 B 差 180°——用户实测横屏时镜头 A 倒 180°）。
                // startRunning 后补设 videoRotationAngle 依然有效且安全。
                applyOrientation()
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
    /// 端口策略：**遍历该输入的全部视频端口逐个尝试**——
    /// 部分镜头（如超广角）的输入可能含辅助/虚拟视频端口，
    /// 用 first(where:) 选中它们时 canAddConnection 会拒绝 → 一路黑屏。
    private func makePreviewConnection(layer: AVCaptureVideoPreviewLayer,
                                       input: AVCaptureDeviceInput) -> AVCaptureConnection? {
        // 防御：若 layer 已存在连接（某些系统版本在 addInput 时可能
        // 自动为关联的预览层建连），直接复用，避免手动建连失败。
        if let existing = layer.connection {
            return existing
        }
        let videoPorts = input.ports.filter { $0.mediaType == .video }
        guard let firstPort = videoPorts.first else {
            if layer === previewLayerA { lastPreviewFailureA = "端口缺失" } else { lastPreviewFailureB = "端口缺失" }
            return nil
        }
        // 首选第一个视频端口（v1.0 双路预览正常即此实现）；
        // 失败时再遍历其余视频端口兜底（部分镜头含虚拟/辅助端口会拒连）
        let candidates = [firstPort] + videoPorts.dropFirst()
        for port in candidates {
            let conn = AVCaptureConnection(inputPort: port, videoPreviewLayer: layer)
            guard session.canAddConnection(conn) else { continue }
            // 前置不镜像（需求：前置摄像头不允许镜像）
            conn.automaticallyAdjustsVideoMirroring = false
            conn.isVideoMirrored = false
            session.addConnection(conn)
            if layer === previewLayerA { lastPreviewFailureA = nil } else { lastPreviewFailureB = nil }
            return conn
        }
        if layer === previewLayerA {
            lastPreviewFailureA = "会话拒绝建连（\(videoPorts.count) 个视频端口均被拒）"
        } else {
            lastPreviewFailureB = "会话拒绝建连（\(videoPorts.count) 个视频端口均被拒）"
        }
        return nil
    }

    private var lastPreviewFailureA: String?
    private var lastPreviewFailureB: String?
    /// 预览自愈重试计数（双摄首次配置时序问题，允许自动重配一次）
    private var previewRetryCount = 0

    // MARK: - 诊断（临时：真机定位 B 路预览 / 面板展开 / 录制 UI 刷新问题）
    /// 两路预览连接建立状态（含失败原因），供诊断横幅展示
    var previewConnStatus: (a: String, b: String) {
        (Self.describeFailure(previewConnA, lastFailure: lastPreviewFailureA),
         Self.describeFailure(previewConnB, lastFailure: lastPreviewFailureB))
    }
    /// 两路预览连接当前旋转角 / 镜像状态（诊断横幅 ANG 行用：
    /// 定位"横屏镜头 A 倒 180°"——若 A 角度为 -1 或与 B 不一致即方向未应用）
    var previewAngleA: CGFloat { previewConnA?.videoRotationAngle ?? -1 }
    var previewAngleB: CGFloat { previewConnB?.videoRotationAngle ?? -1 }
    var previewMirrorA: Bool { previewConnA?.isVideoMirrored ?? false }
    var previewMirrorB: Bool { previewConnB?.isVideoMirrored ?? false }
    /// 会话是否正在运行（诊断用）
    var isSessionRunning: Bool { session.isRunning }

    private static func describeFailure(_ conn: AVCaptureConnection?, lastFailure: String?) -> String {
        conn != nil ? "正常" : (lastFailure ?? "未知原因")
    }

    /// 逐设备配置分辨率/帧率
    private func applyFormat(device: AVCaptureDevice, preset: ResolutionPreset) throws {
        let dims = preset.landscapeDimensions
        let targetFPS = Double(preset.fps)
        // 杜比开启时优先选同尺寸/同帧率的 10-bit HDR 格式（DV 内容必须由
        // 10-bit 承载）。**必须在 commit 前完成格式切换**：真机验证在多摄
        // 会话 startRunning 后切换 activeFormat 会卡顿闪退（原实现把
        // applyHDRFormatIfNeeded 放在 commit+startRunning 之后调用，
        // 即"杜比一开就闪退"的直接原因）。
        var format: AVCaptureDevice.Format?
        // 判据与 hdrFormatAvailable（attach/refresh 共用）完全同源：
        // 开关开 && 杜比全链路可用（格式 + 当前模式 dvhe/P010 写入能力），
        // 才切 HDR 格式；任一不满足则两路统一回退 8-bit，杜比开关由
        // refreshDolbyCapability 关闭（避免"采集 10-bit、链路按 SDR"并存）。
        var isHDRFormat = false
        if dolbyVisionEnabled && dolbyCapabilityAvailable() {
            format = findHDRFormat(for: device, width: dims.width, height: dims.height)
            isHDRFormat = format != nil
        }
        if format == nil {
            format = device.formats.first(where: { f in
                let fd = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
                return fd.width == dims.width && fd.height == dims.height
                    && f.videoSupportedFrameRateRanges.contains {
                        $0.minFrameRate <= targetFPS && targetFPS <= $0.maxFrameRate
                    }
            })
        }
        guard let format else {
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
        // 杜比：显式使能硬件 HDR 采集并切 HLG/BT.2020 色域。色域是设备级
        // 属性（AVCaptureDevice.activeColorSpace，AVCaptureConnection 无
        // setActiveColorSpace），必须与 activeFormat 一起在 lock 内设置、
        // commit 前完成。isHDRFormat 与 findHDRFormat 完全同源：HDR 格式
        // 在多摄兼容子集内由系统保证可持续运行，且 activeColorSpace =
        // .HLG_BT2020 时 HDR 强制开启（Apple 文档），与系统相机同源行为。
        if dolbyVisionEnabled, isHDRFormat {
            device.activeColorSpace = .HLG_BT2020
            device.isVideoHDREnabled = true
        } else {
            // 显式复位 SDR（不依赖系统切换 activeFormat 时的隐式回退——
            // 行为未保证）：开过杜比再关（含自动关闭）后，8-bit 格式上
            // 不允许残留 HLG 色域/HDR 开关，否则 SDR 录制会按 HLG 解释
            // 8-bit 像素导致偏色发暗（外部审核 P1-2，唯一 SDR 回归点）。
            // .sRGB 为所有格式支持的基础色域，lock 内设置安全。
            device.activeColorSpace = .sRGB
            device.isVideoHDREnabled = false
        }
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

        // 杜比色域/10-bit 由 applyFormat 在设备级完成（activeColorSpace +
        // activeFormat 同锁设置）；dvhe 编码器由 refreshDolbyCapability
        // 按可用性设置（applyOutputCodec），此处无需连接级配置。
        modeBRecorder.attach(outputA: outA, outputB: outB)
        // 录制完成/失败回调由 startRecording 按"收尾代际"统一设置
        // （attach 阶段不设：回调只在本轮录制触发，且需捕获当时的 token）
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

        // 输出实例先落属性：dolbyCapabilityAvailable() 判定需要
        // availableVideoPixelFormatTypes（实例初始化即有，无需入会话；
        // 外部审核 P2-8——原实现此处用局部 outA/outB，与 applyFormat
        // 判据不同源）。
        videoDataOutputA = outA
        videoDataOutputB = outB
        audioDataOutput = outAudio

        // 杜比：请求 10-bit P010。判定与 applyFormat / refreshDolbyCapability
        // 完全同源（单一来源 dolbyCapabilityAvailable：格式 + P010 写入
        // 能力），避免"attach 按旧开关值请求 P010、refresh 因能力不足关闭
        // 开关"导致录制时 10-bit 采集/SDR 写入的格式错配。任一路不满足
        // 回退 BGRA（SDR 链路 32BGRA 一行不动），杜比开关由
        // refreshDolbyCapability 统一关闭。
        let useHDR = dolbyVisionEnabled && dolbyCapabilityAvailable()
        // 记录会话实际生效的杜比状态（录制端以此决定写入分支）
        compositeOutputIsHDR = useHDR
        let pixelFormat: OSType = useHDR
            ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            : kCVPixelFormatType_32BGRA
        for out in [outA, outB] {
            out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat]
            out.alwaysDiscardsLateVideoFrames = true
        }
        outA.setSampleBufferDelegate(modeARecorder, queue: modeARecorder.videoQueueA)
        outB.setSampleBufferDelegate(modeARecorder, queue: modeARecorder.videoQueueB)
        outAudio.setSampleBufferDelegate(modeARecorder, queue: modeARecorder.audioQueue)

        session.addOutput(outA)
        session.addOutput(outB)
        session.addOutput(outAudio)

        // 每个数据输出同样会自动为两路视频建连：关闭不属于自己的那路
        compositeVideoConnA = constrainDataOutput(outA, keep: cameraA)
        compositeVideoConnB = constrainDataOutput(outB, keep: cameraB)

        modeARecorder.attach(videoOutputA: outA, videoOutputB: outB,
                             audioOutput: outAudio,
                             connA: compositeVideoConnA, connB: compositeVideoConnB)
        // 运行时校验（模式A 才有帧回调）：HDR 会话下首帧实测输出像素格式，
        // 验证"请求 P010 是否真生效"。模式B MovieFileOutput 无帧回调，
        // 由系统编码器内部保证，不做此校验。
        modeARecorder.onHDRPipelineVerified = { [weak self] isP010 in
            guard let self else { return }
            let expectedHDR = self.compositeOutputIsHDR
            // HDR 会话必须输出 10-bit；SDR 会话意外输出 10-bit 也是链路错配信号
            let ok = expectedHDR ? isP010 : !isP010
            self.hdrPipelineVerified = true
            self.hdrPipelineOK = ok
            if expectedHDR && !isP010 {
                self.degradationBanner = "杜比采集未生效：输出非 10-bit，本段实际按 SDR 写入"
            }
        }
        // 录制完成/失败回调由 startRecording 按"收尾代际"统一设置
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
    /// 后置横屏映射必须用系统标准（landscapeLeft=180、landscapeRight=0）：
    /// 原实现 0/180 对调，导致后置横屏画面反 180°（用户实测：旋转后置
    /// 所有镜头预览全反、前置正常——前置靠 back+270 派生"负负得正"）。
    /// 前置因此不能继续从后置派生，改用独立映射表（数值 = 修复前实测
    /// 正常的组合：portrait=0 / PUD=180 / landscapeLeft=270 / landscapeRight=90）。
    static func rotationAngle(for orientation: UIInterfaceOrientation, isFront: Bool = false) -> CGFloat {
        let back: CGFloat
        switch orientation {
        case .portrait:              back = 90
        case .portraitUpsideDown:    back = 270
        case .landscapeLeft:         back = 180
        case .landscapeRight:        back = 0
        default:                     back = 90
        }
        guard isFront else { return back }
        // 前置：传感器竖装，独立映射（不能从后置派生）
        switch orientation {
        case .portrait:              return 0
        case .portraitUpsideDown:    return 180
        case .landscapeLeft:         return 270
        case .landscapeRight:        return 90
        default:                     return 0
        }
    }

    /// 判断某条连接是否来自前置摄像头（用于选择旋转基准）
    /// 遍历**全部视频端口**逐个判断：部分镜头输入含辅助/虚拟端口，
    /// 仅看 inputPorts.first 可能拿到非视频端口而误判为后置（前后置
    /// 旋转基准相差 90°，误判会让画面倒 180°——用户实测横屏 A 倒）。
    private static func isFrontConnection(_ conn: AVCaptureConnection?) -> Bool {
        guard let conn else { return false }
        for port in conn.inputPorts where port.mediaType == .video {
            switch port.sourceDevicePosition {
            case .front: return true
            case .back: return false
            default: continue
            }
        }
        return false
    }

    /// 杜比视界 HEVC 码型
    /// iOS 26 SDK 未暴露 AVVideoCodecType 静态成员，用 rawValue("dvhe") 构造（等价常量）
    private static let dolbyVisionCodec = AVVideoCodecType(rawValue: "dvhe")

    /// 杜比视界能力探测 + 输出编码器设置（**必须在 commitConfiguration 之前调用**）
    /// -----------------------------------------------------------------------
    /// 判据（全部满足才可用）：
    ///  1. 当前档位（preset 尺寸+帧率）两路都有 10-bit HDR 采集格式；
    /// 当前档位两路是否都有 HDR 采集格式（杜比判定核心条件；与
    /// applyFormat 实际切到的格式完全同源。HDR 格式判定使用官方能力标志
    /// isVideoHDRSupported + isMultiCamSupported + HLG/BT.2020 色域）
    private func hdrFormatAvailable() -> Bool {
        guard let camA = cameraA, let camB = cameraB else { return false }
        let dims = preset.landscapeDimensions
        return [camA.device, camB.device].allSatisfy {
            findHDRFormat(for: $0, width: dims.width, height: dims.height) != nil
        }
    }

    /// 杜比全链路可用性（**单一判定来源**：applyFormat / attachCompositeOutputs
    /// / refreshDolbyCapability 共用，避免任一环节"判据说可用、实际切不了/设
    /// 不了"的错配——外部审核 P1-1/P2-8）：
    ///  1. 当前档位两路都有 HDR 采集格式（hdrFormatAvailable）；
    ///  2. 当前模式的写入能力：
    ///     双文件：MovieFileOutput 可用编码器确实含 dvhe；
    ///     合成：VideoDataOutput 支持 P010 像素格式。
    /// 注意：调用方必须先完成输出挂载（attach 后、输出属性已赋值），否则
    /// 输出为 nil 时 allSatisfy 空数组恒 true（安全方向但不完整）。
    private func dolbyCapabilityAvailable() -> Bool {
        guard hdrFormatAvailable() else { return false }
        switch mode {
        case .dualFiles:
            return [movieOutputA, movieOutputB]
                .compactMap { $0 }
                .allSatisfy { $0.availableVideoCodecTypes.contains(Self.dolbyVisionCodec) }
        case .composite:
            return [videoDataOutputA, videoDataOutputB]
                .compactMap { $0 }
                .allSatisfy {
                    $0.availableVideoPixelFormatTypes
                        .contains(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
                }
        }
    }

    /// 刷新杜比可用性（UI 置灰依据 + 自动关闭闭环），并在会话配置阶段
    /// 应用对应输出编码器。
    /// 判据：
    ///  1. 当前档位（preset 尺寸+帧率）两路都有 10-bit HDR 采集格式；
    ///  2. 按模式区分写入能力——
    ///     双文件：MovieFileOutput 可用编码器列表确实含 dvhe；
    ///     合成：AVAssetWriter 走 HEVC Main10 + HDR 属性（无 dvhe 编码器
    ///     概念），只需数据输出支持 P010 像素格式。
    /// 双条件与 applyFormat（切 10-bit + 设备 HLG 色域）、
    /// attachCompositeOutputs（请求 P010）、applyOutputCodec（设 dvhe）
    /// 行为完全一致，避免"判据说支持、实际切不了/设不了"的错配——错配
    /// 会让 setOutputSettings(dvhe) 在 8-bit 连接上抛 NSException（真机
    /// 崩溃报告实锤）。
    /// setOutputSettings 与设备 activeFormat/activeColorSpace 都必须在
    /// 会话配置阶段（commit 前）完成，运行中调用会闪退。
    private func refreshDolbyCapability() {
        guard cameraA != nil, cameraB != nil else {
            let wasAvailable = isDolbyVisionAvailable
            isDolbyVisionAvailable = false
            if dolbyVisionEnabled {
                dolbyVisionEnabled = false
                persistSettings()   // 自动关闭落盘：下次启动不再恢复开启→再关→重复弹窗
                if wasAvailable { showDegradationBanner("杜比视界当前不可用，已自动关闭") }
            }
            applyOutputCodec(useDolby: false)
            return
        }
        // 全链路可用性：格式 + 当前模式写入能力（dvhe/P010），与
        // applyFormat / attachCompositeOutputs 完全同源（外部审核 P1-1）
        let available = dolbyCapabilityAvailable()
        isDolbyVisionAvailable = available
        hdrFormatDiagnostics = buildHDRDiagnostics()
        if dolbyVisionEnabled && !available {
            dolbyVisionEnabled = false
            persistSettings()   // 自动关闭落盘：下次启动不再恢复开启→再关→重复弹窗
            showDegradationBanner("当前档位不支持杜比视界，已自动关闭")
        }
        applyOutputCodec(useDolby: dolbyVisionEnabled && available)
    }

    /// 设置 MovieFileOutput 输出编码器（hevc / dvhe）。
    /// 只允许在会话配置阶段（commitConfiguration 之前）调用。
    /// 安全阀：AVCaptureMovieFileOutput 对**不支持的编码器**直接抛 NSException
    /// （真机崩溃报告：setOutputSettings(dvhe) → objc_exception_throw →
    /// SIGABRT），NSException 无法用 Swift do-catch 捕获，只能"预防"——
    /// 每个输出先查 availableVideoCodecTypes 是否含目标码型，不含则静默
    /// 退回 HEVC，保证杜比开关无论设备/档位如何都不会导致闪退。
    private func applyOutputCodec(useDolby: Bool) {
        guard mode == .dualFiles, let outA = movieOutputA, let outB = movieOutputB else { return }
        for out in [outA, outB] {
            let codec: AVVideoCodecType =
                (useDolby && out.availableVideoCodecTypes.contains(Self.dolbyVisionCodec))
                ? Self.dolbyVisionCodec : .hevc
            for conn in out.connections where conn.isEnabled && conn.inputPorts.first?.mediaType == .video {
                out.setOutputSettings([AVVideoCodecKey: codec], for: conn)
            }
        }
    }

    /// 查找与当前宽高匹配、且支持目标帧率的 10-bit HDR 格式
    /// 在当前档位（尺寸+帧率）下查找设备的 HDR 采集格式
    /// -------------------------------------------------------------
    /// 判据全部使用系统官方能力标志（不再依赖 pixel format 猜测——9/25
    /// "多摄下 10-bit 格式 0 次"即 pixel format 判据误判，导致杜比开关
    /// 全置灰；CamFusion 同机双路+杜比可用证明格式存在）：
    ///  1. isMultiCamSupported：多摄会话只允许该子集可持续运行（Apple
    ///     文档：isMultiCamSupported=false 的格式在多摄下不可设置）；
    ///  2. isVideoHDRSupported：格式支持 HDR 视频流（官方 HDR 能力标志）；
    ///  3. supportedColorSpaces 含 .HLG_BT2020：支持 HLG/BT.2020 色域
    ///     （activeColorSpace = .HLG_BT2020 时 HDR 强制开启，Apple 文档）。
    private func findHDRFormat(for device: AVCaptureDevice,
                               width: Int32, height: Int32) -> AVCaptureDevice.Format? {
        let targetFPS = Double(preset.fps)
        for format in device.formats {
            guard format.isMultiCamSupported else { continue }
            guard format.isVideoHDRSupported else { continue }
            guard format.supportedColorSpaces.contains(.HLG_BT2020) else { continue }
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard dims.width == width, dims.height == height else { continue }
            // 帧率区间包含（与 SDR fallback 的格式选择同谓词，外部审核 P2-7：
            // 只查 maxFrameRate 会让 31-120 的区间被误判为支持 30fps）
            guard format.videoSupportedFrameRateRanges.contains(where: {
                $0.minFrameRate <= targetFPS && targetFPS <= $0.maxFrameRate
            }) else { continue }
            return format
        }
        return nil
    }

    /// 两路 HDR 格式探测摘要（真机诊断用，验证后可删）：
    /// "镜头名 共N/多摄N/HDR N/档位HDR N"——总数 / 多摄兼容 / 官方 HDR
    /// 标志 / 当前档位（尺寸+帧率）可用的 HDR 格式数
    private func buildHDRDiagnostics() -> String {
        guard let camA = cameraA, let camB = cameraB else { return "镜头未就绪" }
        let dims = preset.landscapeDimensions
        func summary(_ device: AVCaptureDevice) -> String {
            let all = device.formats.count
            let multi = device.formats.filter { $0.isMultiCamSupported }.count
            let hdr = device.formats.filter { $0.isVideoHDRSupported }.count
            let matched = device.formats.filter { f in
                guard f.isMultiCamSupported, f.isVideoHDRSupported,
                      f.supportedColorSpaces.contains(.HLG_BT2020) else { return false }
                let fd = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
                return fd.width == dims.width && fd.height == dims.height
                    && f.videoSupportedFrameRateRanges.contains {
                        $0.minFrameRate <= Double(preset.fps) && Double(preset.fps) <= $0.maxFrameRate
                    }
            }.count
            return "\(device.localizedName) 共\(all)/多摄\(multi)/HDR\(hdr)/档位HDR\(matched)"
        }
        // 当前模式写入能力（外部审核 P1-5：dvhe 是否在 availableVideoCodecTypes
        // 中、P010 是否被数据输出支持，均需真机实测确认）
        let codecDiag: String
        switch mode {
        case .dualFiles:
            let dvheOK = [movieOutputA, movieOutputB].compactMap { $0 }.allSatisfy {
                $0.availableVideoCodecTypes.contains(Self.dolbyVisionCodec)
            }
            codecDiag = "模式B-dvhe:\(dvheOK ? "是" : "否")"
        case .composite:
            let p010OK = [videoDataOutputA, videoDataOutputB].compactMap { $0 }.allSatisfy {
                $0.availableVideoPixelFormatTypes
                    .contains(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
            }
            codecDiag = "模式A-P010:\(p010OK ? "是" : "否")"
        }
        return "\(summary(camA.device))；\(summary(camB.device))；\(codecDiag)"
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
        guard let fallback = ResolutionPreset.bestAvailablePreset(supports: {
            CameraPairProbe.shared.supportsPreset(deviceA, $0)
                && CameraPairProbe.shared.supportsPreset(deviceB, $0)
        }) else { return }
        preset = fallback
        showDegradationBanner("当前镜头组合不支持 \(old.displayName) \(old.frameRateText)，"
                              + "已自动降级到 \(fallback.displayName) \(fallback.frameRateText)")
    }

    // MARK: - 设置持久化

    /// 设置存储键（UserDefaults）
    private enum SettingsKey {
        static let preset = "settings.preset"
        static let layout = "settings.layout"
        static let mode = "settings.mode"
        static let dolbyVision = "settings.dolbyVision"
        static let spatialAudio = "settings.spatialAudio"
        static let stabilization = "settings.stabilization"
        static let focusLock = "settings.focusLock"
        static let exposureLock = "settings.exposureLock"
        static let exposureBias = "settings.exposureBias"
        static let includeLocation = "settings.includeLocation"
        static let cameraA = "settings.cameraA"
        static let cameraB = "settings.cameraB"
    }

    /// 把全部用户可调设置写入 UserDefaults（第二次打开保留上次状态）
    private func persistSettings() {
        let d = UserDefaults.standard
        d.set(preset.rawValue, forKey: SettingsKey.preset)
        d.set(layout.rawValue, forKey: SettingsKey.layout)
        d.set(mode.rawValue, forKey: SettingsKey.mode)
        d.set(dolbyVisionEnabled, forKey: SettingsKey.dolbyVision)
        d.set(spatialAudioEnabled, forKey: SettingsKey.spatialAudio)
        d.set(stabilizationEnabled, forKey: SettingsKey.stabilization)
        d.set(focusLockState, forKey: SettingsKey.focusLock)
        d.set(exposureLockState, forKey: SettingsKey.exposureLock)
        d.set(exposureBias, forKey: SettingsKey.exposureBias)
        d.set(includeLocation, forKey: SettingsKey.includeLocation)
        d.set(cameraA?.id, forKey: SettingsKey.cameraA)
        d.set(cameraB?.id, forKey: SettingsKey.cameraB)
    }

    /// 启动恢复：必须在 discoverCameras() 之后调用（镜头恢复依赖可用列表）
    private func restoreSettings() {
        let d = UserDefaults.standard
        if let raw = d.string(forKey: SettingsKey.preset),
           let v = ResolutionPreset(rawValue: raw) { preset = v }
        if let raw = d.string(forKey: SettingsKey.layout),
           let v = PreviewLayout(rawValue: raw) { layout = v }
        if let raw = d.string(forKey: SettingsKey.mode),
           let v = RecordingMode(rawValue: raw) { mode = v }
        // 杜比默认关；已开启过则恢复开启（探测不支持时 refreshDolbyCapability
        // 会自动关闭并提示）
        dolbyVisionEnabled = d.bool(forKey: SettingsKey.dolbyVision)
        // 空间音频默认开：未设置过时保持默认 true（bool(forKey:) 对未设置
        // 返回 false，会错误关闭，故用 object 判存在性）
        spatialAudioEnabled = d.object(forKey: SettingsKey.spatialAudio) as? Bool ?? true
        if let v = d.array(forKey: SettingsKey.stabilization) as? [NSNumber], v.count == 2 {
            stabilizationEnabled = v.map(\.boolValue)
        }
        if let v = d.array(forKey: SettingsKey.focusLock) as? [NSNumber], v.count == 2 {
            focusLockState = v.map(\.boolValue)
        }
        if let v = d.array(forKey: SettingsKey.exposureLock) as? [NSNumber], v.count == 2 {
            exposureLockState = v.map(\.boolValue)
        }
        if let v = d.array(forKey: SettingsKey.exposureBias) as? [NSNumber], v.count == 2 {
            exposureBias = v.map(\.floatValue)
        }
        if d.object(forKey: SettingsKey.includeLocation) != nil { includeLocation = d.bool(forKey: SettingsKey.includeLocation) }
        if let id = d.string(forKey: SettingsKey.cameraA),
           let opt = availableCameras.first(where: { $0.id == id }) { cameraA = opt }
        if let id = d.string(forKey: SettingsKey.cameraB),
           let opt = availableCameras.first(where: { $0.id == id }) { cameraB = opt }
    }

    // MARK: - 对外设置方法（全部在非录制状态下生效）

    func setPreset(_ newValue: ResolutionPreset) {
        guard !isRecording, !isFinalizing, preset != newValue else { return }
        preset = newValue
        applyConfiguration()
        persistSettings()
    }

    func setLayout(_ newValue: PreviewLayout) {
        guard !isRecording, !isFinalizing, layout != newValue else { return }
        layout = newValue
        persistSettings()
    }

    func setMode(_ newValue: RecordingMode) {
        guard !isRecording, !isFinalizing, mode != newValue else { return }
        mode = newValue
        applyConfiguration()
        persistSettings()
    }

    func setDolbyVision(_ enabled: Bool) {
        guard !isRecording, !isFinalizing, dolbyVisionEnabled != enabled else { return }
        dolbyVisionEnabled = enabled
        applyConfiguration()
        persistSettings()
    }

    func setSpatialAudio(_ enabled: Bool) {
        guard !isRecording, !isFinalizing, spatialAudioEnabled != enabled else { return }
        spatialAudioEnabled = enabled
        applyConfiguration()
        persistSettings()
    }

    func setStabilization(_ enabled: Bool, slot: CameraSlot) {
        guard !isRecording, !isFinalizing, stabilizationEnabled[slot.index] != enabled else { return }
        stabilizationEnabled[slot.index] = enabled
        applyStabilization()
        persistSettings()
    }

    /// 拍摄地点开关（打开时若未授权则立即请求一次定位权限）
    func setIncludeLocation(_ on: Bool) {
        includeLocation = on
        if on { requestLocationIfNeeded() }
        persistSettings()
    }

    /// 更换某路镜头（先做组合校验，不支持的组合直接拒绝并提示）
    func selectCamera(_ option: CameraOption, for slot: CameraSlot) {
        guard !isRecording, !isFinalizing else { return }
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
        persistSettings()
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
        // 曝光补偿滑块拖动高频触发，只写本键避免每次全量写盘
        UserDefaults.standard.set(exposureBias, forKey: SettingsKey.exposureBias)
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
        guard !isRecording, !isFinalizing, focusLockState[slot.index] != locked else { return }
        focusLockState[slot.index] = locked
        applyLock(slot: slot)
        persistSettings()
    }

    /// 设置面板用：锁定/解锁该路曝光（不影响对焦）
    func setExposureLock(_ locked: Bool, slot: CameraSlot) {
        guard !isRecording, !isFinalizing, exposureLockState[slot.index] != locked else { return }
        exposureLockState[slot.index] = locked
        applyLock(slot: slot)
        persistSettings()
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

    /// 把当前的对焦锁/曝光锁/曝光补偿状态应用到设备（保证 UI 与设备一致）。
    /// 调用点：①启动恢复后首次 applyConfiguration；②换镜头复位后。
    /// 必须在会话已配置（startRunning 后）调用；applyLock/setExposureBias
    /// 内部自带设备 lock/unlock 与支持性守卫，安全静默。
    private func restoreDeviceCaptureStates() {
        for slot in CameraSlot.allCases {
            if focusLockState[slot.index] || exposureLockState[slot.index] {
                applyLock(slot: slot)
            }
            if exposureBias[slot.index] != 0 {
                setExposureBias(exposureBias[slot.index], slot: slot)
            }
        }
    }

    // MARK: - 录制

    /// 画中画小窗位置（归一化 0~1：小窗中心相对屏宽/屏高的比例，y 从顶部算，
    /// 与 SwiftUI 预览坐标一致）。录制开始前由 CameraView 写入当前小窗
    /// 实际位置（默认避让位 + 拖动偏移）；录制中固定不更新——模式A合成时
    /// VideoCompositor.makePiP 按此位置摆放 B 路小窗，保证"成片小窗位置 =
    /// 录制开始时的预览位置"。默认值为竖屏默认避让位（右下偏上，距底 190、
    /// 距右 24，屏 390×844 下中心 ≈ (0.80, 0.66)），录制前总是被覆盖。
    var pipPosition: CGPoint = CGPoint(x: 0.805, y: 0.665)

    /// 画中画小窗圆角半径比例（= 预览小窗圆角 18pt / 预览小窗宽）。
    /// 录制开始前由 CameraView 写入，模式A合成时成片小窗圆角
    /// = 成片小窗宽 × 比例，与预览圆角视觉等比（预览 = 成片）。
    var pipCornerRadiusRatio: CGFloat = 0

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
            // 新代际：本次录制的回调只认当前 token（迟到旧回调一律忽略）
            finalizeToken += 1
            let token = finalizeToken
            switch mode {
            case .dualFiles:
                try modeBRecorder.start()
                modeBRecorder.onFinished = { [weak self] urls in
                    self?.handleRecordingFinished(urls: urls, token: token)
                }
                modeBRecorder.onError = { [weak self] err, successURLs, failedURLs in
                    self?.handleRecordingFailed(err, successURLs: successURLs,
                                                failedURLs: failedURLs, token: token)
                }
            case .composite:
                // 先启用两路视频 + 音频数据输出连接（source 端开始派发样本，
                // 供 ModeARecorder 帧配对 + 合成）。用 compositeVideoConnA/B
                // 精确定位 enabled 的视频连接（connection(with:) 可能返回
                // 被 constrainDataOutput 关闭的另一路连接）。
                compositeVideoConnA?.isEnabled = true
                compositeVideoConnB?.isEnabled = true
                audioDataOutput?.connection(with: .audio)?.isEnabled = true
                let target = targetOutputDimensions()
                try modeARecorder.start(outputSize: target,
                                        layout: layout,
                                        audioFormat: microphoneAudioFormat(),
                                        pipPosition: pipPosition,
                                        pipCornerRadiusRatio: pipCornerRadiusRatio,
                                        hdr: compositeOutputIsHDR)
                modeARecorder.onFinished = { [weak self] urls in
                    self?.handleRecordingFinished(urls: urls, token: token)
                }
                modeARecorder.onError = { [weak self] err in
                    self?.handleRecordingFailed(err, token: token)
                }
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
    /// 兜底：收尾回调（didFinishRecordingTo / finishWriting）异常丢失时
    /// 3 秒后强制复位 isFinalizing，避免"上一段视频正在保存"永久卡死
    /// （isFinalizing 卡死会把录制键、功能/设置键全部禁用 = "设置栏打不开"）。
    func stopRecording() {
        guard isRecording else { return }
        isFinalizing = true
        stopElapsedTimer()
        isRecording = false
        switch mode {
        case .dualFiles: modeBRecorder.stop()
        case .composite:
            // 先停两路视频 + 音频数据输出连接（源头断流）：不再派发新样本，
            // 让 recorder.stop() 的"排空已入队帧"有界可完成——
            // 若先置 isRecording=false 直接收尾，队列里已入队的末尾帧
            // 会被丢弃，成片结尾缺帧（真机"最后几秒定格/没录上"）；
            // 若不断流就排空，合成慢时新帧无限入队，sync 可能永不返回。
            // 预览层连接独立，不受影响；下次录制 startRecording 重新 enable。
            compositeVideoConnA?.isEnabled = false
            compositeVideoConnB?.isEnabled = false
            audioDataOutput?.connection(with: .audio)?.isEnabled = false
            modeARecorder.stop()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.isFinalizing else { return }
            self.isFinalizing = false
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
    /// - Parameter token: 录制代际；不等于当前 finalizeToken 的迟到回调直接忽略
    ///   （防"超时兜底复位后旧回调到达"破坏新录制状态机）
    private func handleRecordingFinished(urls: [URL], token: Int) {
        guard token == finalizeToken else { return }
        stopElapsedTimer()
        isRecording = false
        isFinalizing = false
        applyPendingDowngrade()   // 内存告警等触发的"录制结束后降级"在此闭环
        guard !urls.isEmpty else { return }
        if includeLocation { requestLocationIfNeeded() }   // 保存场景才请求定位
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
                                       failedURLs: [URL] = [],
                                       token: Int? = nil) {
        // 录制器回调带代际：不等于当前 finalizeToken 的迟到回调忽略；
        // runtimeError 通知等系统事件不带 token（token = nil）总是处理。
        if let token, token != finalizeToken { return }
        stopElapsedTimer()
        isRecording = false
        isFinalizing = false
        applyPendingDowngrade()
        // 模式B一路失败、另一路成功：成功文件仍保存到相册（不丢弃）
        if !successURLs.isEmpty {
            if includeLocation { requestLocationIfNeeded() }   // 保存场景才请求定位
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

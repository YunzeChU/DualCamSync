import AVFoundation
import CoreMedia
import CoreVideo   // CVPixelBufferGetPixelFormatType（运行时 HDR 校验）
import Foundation
import QuartzCore   // CACurrentMediaTime() 显式依赖（避免 SDK 间接导入差异）
import VideoToolbox // 杜比视界 HDR 压缩属性（HDRMetadataInsertionMode 等）

/// 模式A：合成单条录制器
/// -------------------------------------------------------------
/// 数据流：两路 AVCaptureVideoDataOutput + 一路 AVCaptureAudioDataOutput
///       -> 帧配对 -> VideoCompositor 实时合成（构图跟随录制前布局）
///       -> AVAssetWriter 写入单条 MP4（HEVC + AAC 立体声音轨）
///
/// 时间戳对齐：
///   AVCaptureMultiCamSession 会把所有设备时钟同步到 masterClock，
///   因此各路样本的 PTS 处于同一时间基准，直接写入即可保证
///   两路画面帧级对齐、音画不错位。
///
/// 声道策略：音轨在**音频首帧**按真实采集格式懒创建
///   （设备支持立体声则写入双声道 AAC；否则按实际声道写入，保证不失配不静音），
///   并通过 startSessionIfNeeded 的"等待音频就绪"保证建轨先于 startWriting。
final class ModeARecorder: NSObject,
    AVCaptureVideoDataOutputSampleBufferDelegate,
    AVCaptureAudioDataOutputSampleBufferDelegate {

    // MARK: - 队列（每路独立串行队列，保证帧序）

    let videoQueueA = DispatchQueue(label: "com.dualcamsync.videoA")
    let videoQueueB = DispatchQueue(label: "com.dualcamsync.videoB")
    let audioQueue  = DispatchQueue(label: "com.dualcamsync.audio")

    // MARK: - 会话输出引用（由 CameraManager 注入）

    private weak var videoOutputA: AVCaptureVideoDataOutput?
    private weak var videoOutputB: AVCaptureVideoDataOutput?
    private weak var audioOutput: AVCaptureAudioDataOutput?
    private var videoConnA: AVCaptureConnection?
    private var videoConnB: AVCaptureConnection?
    weak var manager: CameraManager?

    /// 一次性 HDR 运行时校验：delegate 常驻（不依赖录制状态），首帧实测
    /// 输出像素格式后上报主线程，供 CameraManager 判断"请求的 10-bit 是否
    /// 真生效"。会话重配（attach）时重置，保证每次配置后都校验一次。
    private var didVerifyHDRPipeline = false
    /// 主线程回调：实测输出是否为 10-bit（P010 VideoRange / FullRange）
    var onHDRPipelineVerified: ((Bool) -> Void)?

    // MARK: - 写入器

    private var writer: AVAssetWriter?
    private var videoWriterInput: AVAssetWriterInput?
    private var pixelAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var audioWriterInput: AVAssetWriterInput?
    private var outputURL: URL?

    private let compositor = VideoCompositor()

    // MARK: - 录制状态

    private(set) var isRecording = false
    private var outputSize: (width: Int32, height: Int32) = (1920, 1080)
    private var recordingLayout: PreviewLayout = .split
    private var recordingLandscape = true
    /// 录制开始时的画中画小窗位置（归一化，y 从顶部算；由 CameraManager
    /// 在 start 时传入，合成帧时传给 VideoCompositor.makePiP —— 保证
    /// "成片小窗位置 = 录制开始时的预览位置"）
    private var recordingPipPosition: CGPoint = CGPoint(x: 0.805, y: 0.665)
    /// 录制开始时的画中画小窗圆角比例（成片圆角 = 小窗宽 × 比例，
    /// 由 CameraManager 在 start 时传入；0 = 不加圆角）
    private var recordingPipCornerRadiusRatio: CGFloat = 0
    /// 写入会话起点（多队列并发，需加锁保护）
    private let startLock = NSLock()
    private var sessionStartTime: CMTime?
    private var isWriting = false

    /// 帧配对缓冲（两路帧到齐后再合成，防止错位）
    private let pairingLock = NSLock()
    private var pendingA: (buffer: CVPixelBuffer, pts: CMTime)?
    private var pendingB: (buffer: CVPixelBuffer, pts: CMTime)?

    /// B 路滑动历史（最近 N 帧）：停止排空期给"时间戳落后于实时 pendingB"
    /// 的积压 A 帧兜底配对。内存约束：4K BGRA 帧约 33MB，窗口只留 6 帧
    /// （0.2s），配合"积压自适应降级"（连续配对失败即关圆角）保证积压
    /// 不超过该窗口。录制结束即清空，释放对相机缓冲池的引用。
    private var bHistory: [(buffer: CVPixelBuffer, pts: CMTime)] = []
    private let bHistoryLimit = 6

    /// 停止排空标志（主线程写、A 队列读，经 pairingLock 保护）：
    /// 为 true 时配对失败改用 B 滑动历史兜底，把末尾帧写进文件。
    private var draining = false

    /// 积压自适应降级：A 路连续配对失败达到阈值（合成跟不上生产、队列
    /// 积压）时置位，成片小窗临时不加圆角——合成开销回落到与
    /// "9月无圆角版本"同等水平，消除积压源头。录制内不复位（防抖动）。
    private var consecutivePairFailures = 0
    private var performanceDegraded = false

    /// 启动协调：视频首帧就绪后，最多等待音频首帧 audioStartTimeout 秒
    /// （为按"音频真实声道数"懒创建音轨；超时则放弃音轨直接开写）。
    private var videoReady = false
    private var audioReady = false
    private var videoFirstArrival: CFTimeInterval?
    private let audioStartTimeout: CFTimeInterval = 0.5

    var onFinished: (([URL]) -> Void)?
    var onError: ((Error) -> Void)?

    // MARK: - 挂载/卸载

    func attach(videoOutputA: AVCaptureVideoDataOutput,
                videoOutputB: AVCaptureVideoDataOutput,
                audioOutput: AVCaptureAudioDataOutput,
                connA: AVCaptureConnection?,
                connB: AVCaptureConnection?) {
        self.videoOutputA = videoOutputA
        self.videoOutputB = videoOutputB
        self.audioOutput = audioOutput
        self.videoConnA = connA
        self.videoConnB = connB
        didVerifyHDRPipeline = false
    }

    func detach() {
        videoOutputA = nil
        videoOutputB = nil
        audioOutput = nil
        videoConnA = nil
        videoConnB = nil
    }

    // MARK: - 录制控制

    /// 开始录制：创建写入器（视频轨在此创建；音轨由音频首帧懒创建）
    /// - Parameters:
    ///   - audioFormat: 麦克风音频格式；**仅用于判断"是否有麦克风"**
    ///     （nil = 无麦克风，启动时直接视为音频就绪）。音轨本身按
    ///     音频首帧的真实 ASBD 创建（见 handleAudioSampleBuffer）。
    ///   - pipPosition: 画中画小窗位置（归一化 0~1，y 从顶部算），
    ///     模式A合成时 makePiP 按此摆放 B 路小窗。
    ///   - pipCornerRadiusRatio: 成片小窗圆角半径比例（= 预览小窗圆角
    ///     18pt / 预览小窗宽），保证成片小窗与预览一样是圆角矩形。
    ///   - hdr: 是否杜比视界录制（true 时采集为 10-bit P010、写入
    ///     HEVC Main10 + HLG/BT.2020 + 自动注入杜比元数据；false 为
    ///     现有 SDR 链路 BT.709）。
    func start(outputSize: (width: Int32, height: Int32),
               layout: PreviewLayout,
               audioFormat: (sampleRate: Double, channels: Int)?,
               pipPosition: CGPoint,
               pipCornerRadiusRatio: CGFloat,
               hdr: Bool) throws {
        guard !isRecording else {
            // 静默返回 = 录制键点了毫无反应；必须抛错让上层弹窗说明
            throw CameraError.recordingFailed("上一段视频仍在收尾，请稍候")
        }
        guard manager != nil else {
            throw CameraError.configurationFailed("录制器未就绪")
        }

        let dir = FileManager.default.temporaryDirectory
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let url = dir.appendingPathComponent("DCS_\(stamp)_composite.mp4")

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        // 视频输入：HEVC 硬件编码（SDR = BT.709；杜比 = Main10 + HLG/BT.2020）
        let bitrate = estimateVideoBitrate(width: outputSize.width, height: outputSize.height)
        let videoSettings: [String: Any]
        let adaptorPixelFormat: OSType
        if hdr {
            // 杜比视界：HEVC Main10 + BT.2020 色原/矩阵 + HLG 传递函数 +
            // 编码器自动注入杜比元数据（VideoToolbox HDRMetadataInsertionMode=Auto，
            // 与系统相机同源）。输入像素为 10-bit P010（采集端已切 10-bit 格式）。
            let compression: [String: Any] = [
                AVVideoAverageBitRateKey: bitrate,
                // HEVC profile/level 常量定义在 VideoToolbox/VTCompressionProperties.h
                // （AVFoundation 头文件注释原文），AVVideoProfileLevelKey 直接接受该值
                AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel,
                kVTCompressionPropertyKey_HDRMetadataInsertionMode as String: kVTHDRMetadataInsertionMode_Auto,
                kVTCompressionPropertyKey_PreserveDynamicHDRMetadata as String: true,
            ]
            videoSettings = [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: outputSize.width,
                AVVideoHeightKey: outputSize.height,
                AVVideoColorPropertiesKey: [
                    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
                ],
                AVVideoCompressionPropertiesKey: compression,
            ]
            adaptorPixelFormat = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        } else {
            videoSettings = [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: outputSize.width,
                AVVideoHeightKey: outputSize.height,
                // 显式声明输入像素颜色属性（BT.709）：合成器输出的是全范围
                // BGRA 像素（渲染 colorSpace = sRGB，原色与 BT.709 相同）。
                // 若不声明，编码器可能按错误矩阵/范围转换（默认 BT.601 +
                // limited），导致成片偏蓝偏暗、与预览不一致——真机实测
                // "封面正常、播放偏色"即颜色标记缺失的表现。
                AVVideoColorPropertiesKey: [
                    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
                ],
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: bitrate,
                    // 不显式指定 profile：交由系统按分辨率/帧率自动选择（HEVC Main/Main10）
                ],
            ]
            adaptorPixelFormat = kCVPixelFormatType_32BGRA
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: adaptorPixelFormat,
                kCVPixelBufferWidthKey as String: outputSize.width,
                kCVPixelBufferHeightKey as String: outputSize.height,
            ]
        )
        guard writer.canAdd(videoInput) else {
            throw CameraError.configurationFailed("无法添加视频轨")
        }
        writer.add(videoInput)

        // 音轨不在此提前创建：声道数必须以"真实采集到的音频样本"为准
        // （multichannelAudioMode 生效后，实际声道可能与 activeFormat 不同；
        // 固定 2 声道后丢弃非双声道样本会导致整段静音）。改为音频首帧
        // 回调按真实 ASBD 懒创建，仍在 startWriting 之前完成——
        // 由 startSessionIfNeeded 的"等待音频就绪"协调保证。
        self.writer = writer
        self.videoWriterInput = videoInput
        self.pixelAdaptor = adaptor
        self.outputURL = url
        self.outputSize = outputSize
        self.recordingLayout = layout
        self.recordingLandscape = outputSize.width > outputSize.height
        self.recordingPipPosition = pipPosition
        self.recordingPipCornerRadiusRatio = pipCornerRadiusRatio
        self.sessionStartTime = nil
        self.isWriting = false
        self.audioWriterInput = nil
        self.pendingA = nil
        self.pendingB = nil
        self.bHistory.removeAll(keepingCapacity: false)
        self.draining = false
        self.consecutivePairFailures = 0
        self.performanceDegraded = false
        self.videoReady = false
        self.audioReady = (audioFormat == nil)   // 无麦克风 → 无需等待音频
        self.videoFirstArrival = nil
        self.isRecording = true
    }

    /// 停止录制：先排空已入队样本（期间 isRecording 仍为 true），再收尾
    /// -------------------------------------------------------------
    /// 修复"结尾定格/最后几秒拍不到"（真机实测：合成/写入慢时 A 路视频
    /// 队列与音频队列会积压已入队的回调样本；若直接置 isRecording=false，
    /// 这些样本执行时被丢弃 → 视频末尾整段缺失）。
    ///
    /// 停止时序（由 CameraManager.stopRecording 先断开 A/B/音频输出连接）：
    ///   1. 置 draining=true：videoQueueA.sync 排空 A 路积压帧。积压帧的
    ///      时间戳落后于实时，正常配对必然失败，改用 B 路滑动历史
    ///      兜底配对写入（见 handleVideoSampleBuffer/nearestB）；
    ///   2. audioQueue.sync 排空音频（与视频末尾时间对齐）；
    ///   3. draining=false、isRecording=false，markAsFinished + finishWriting。
    /// 队列任务不依赖主线程，主线程 sync 等待无死锁；连接已断流，
    /// 排空期间无新样本入队，队列有界。
    func stop() {
        guard isRecording else { return }
        pairingLock.lock()
        draining = true
        pairingLock.unlock()
        videoQueueA.sync { }
        audioQueue.sync { }
        pairingLock.lock()
        draining = false
        pairingLock.unlock()
        isRecording = false

        // 没有任何帧写入（例如刚点录制立刻停止）：直接丢弃临时文件
        guard let writer, isWriting else {
            if let url = outputURL {
                try? FileManager.default.removeItem(at: url)
            }
            resetWriterState()
            DispatchQueue.main.async { [weak self] in
                self?.onFinished?([])
            }
            return
        }

        videoWriterInput?.markAsFinished()
        audioWriterInput?.markAsFinished()
        writer.finishWriting { [weak self] in
            guard let self, let url = self.outputURL else { return }
            let status = writer.status
            DispatchQueue.main.async {
                if status == .completed {
                    self.onFinished?([url])
                } else {
                    // 失败文件保留在临时目录，提示带上路径便于用户找回
                    self.onError?(CameraError.recordingFailed(
                        "写入失败 (\(status.rawValue))；未保存文件位于临时目录：\(url.lastPathComponent)"))
                }
            }
            self.resetWriterState()
        }
    }

    /// 清空写入器引用（保留 isRecording=false 状态）
    private func resetWriterState() {
        writer = nil
        videoWriterInput = nil
        pixelAdaptor = nil
        audioWriterInput = nil
        outputURL = nil
        sessionStartTime = nil
        isWriting = false
        // 释放 B 路滑动历史对相机缓冲池的引用（4K 帧约 33MB/帧）
        bHistory.removeAll(keepingCapacity: false)
    }

    /// 估算码率：1080P 约 12Mbps，4K 约 35Mbps，保证画质与体积平衡
    private func estimateVideoBitrate(width: Int32, height: Int32) -> Int {
        let pixels = Double(width) * Double(height)
        if pixels >= 3840 * 2160 { return 35_000_000 }
        if pixels >= 1920 * 1080 { return 12_000_000 }
        return 8_000_000
    }

    // MARK: - 视频/音频回调

    /// 视频与音频回调共用同一入口（两个协议的签名完全一致），按输出类型分流
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        if output is AVCaptureVideoDataOutput {
            handleVideoSampleBuffer(sampleBuffer, connection: connection)
        } else {
            handleAudioSampleBuffer(sampleBuffer, connection: connection)
        }
    }

    /// 视频回调：两路帧配对后合成一帧写入
    /// -------------------------------------------------------------
    /// 串行化设计（修复合成+写入并发）：
    ///   - B 路（videoQueueB）：只更新配对缓冲 + 滑动历史，不做合成/写入；
    ///   - A 路（videoQueueA）：独占"配对 → 清空缓冲 → 合成 → append"，
    ///     保证 CIContext.render 与 AVAssetWriter append 永远只在单条
    ///     串行队列上执行，不会并发。
    ///   - 配对成功后立即清空 pendingA/B，防止旧帧被重复配对。
    ///   - 配对失败分两种处理：
    ///       * 正常录制中（!draining）：连续失败说明合成跟不上生产、
    ///         A 队列积压（积压帧时间落后于实时 B，0.1s 窗口永远配不上），
    ///         达到阈值后触发"积压自适应降级"——临时关闭成片小窗圆角，
    ///         合成开销回到 9 月无圆角版本水平，从源头消除积压；
    ///       * 停止排空期（draining）：用 B 路滑动历史里时间最近的帧
    ///         兜底配对，把已积压的末尾帧救回文件（修"结尾定格"）。
    private func handleVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer,
                                        connection: AVCaptureConnection) {
        let isA = (connection === videoConnA)
        let isB = (connection === videoConnB)
        // 一次性运行时校验（不依赖录制状态：采集一直在跑，首帧即上报）。
        // 只在 A 队列执行——A/B 两路独立串行队列并发读写 didVerifyHDRPipeline
        // 构成数据竞争（外部审核 P1-3）；两路像素格式相同，校验一路即代表会话。
        if isA, !didVerifyHDRPipeline {
            didVerifyHDRPipeline = true
            if let pb = CMSampleBufferGetImageBuffer(sampleBuffer) {
                let fmt = CVPixelBufferGetPixelFormatType(pb)
                let is10Bit = fmt == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                    || fmt == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
                DispatchQueue.main.async { [weak self] in
                    self?.onHDRPipelineVerified?(is10Bit)
                }
            }
        }
        guard isRecording,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard isA || isB else { return }

        // B 路：只写配对缓冲 + 滑动历史（加锁），让 A 路队列串行消费
        if isB {
            pairingLock.lock()
            pendingB = (pixelBuffer, pts)
            bHistory.append((pixelBuffer, pts))
            if bHistory.count > bHistoryLimit {
                bHistory.removeFirst(bHistory.count - bHistoryLimit)
            }
            pairingLock.unlock()
            return
        }

        // A 路：配对成功后消费缓冲并合成写入
        pairingLock.lock()
        pendingA = (pixelBuffer, pts)
        guard let a = pendingA, let b = pendingB,
              abs(a.pts.seconds - b.pts.seconds) < 0.1 else {
            let isDraining = draining
            if isDraining {
                // 停止排空：积压 A 帧用 B 滑动历史兜底配对（时间戳最接近
                // 且窗口 0.1s 内），救回末尾帧；找不到则丢弃该帧。
                // 注：guard let 的 a/b 在 else 分支内不可见，此处用局部
                // 元组重建当前 A 帧（内容 = 刚写入 pendingA 的本帧）。
                pairingLock.unlock()
                let a = (buffer: pixelBuffer, pts: pts)
                if let b = nearestB(to: a.pts),
                   abs(a.pts.seconds - b.pts.seconds) < 0.1 {
                    writeComposed(a: a, b: b)
                }
            } else {
                // 正常录制中配对失败 = 合成/写入跟不上的积压信号
                consecutivePairFailures += 1
                if consecutivePairFailures >= 6, !performanceDegraded {
                    performanceDegraded = true
                }
                pairingLock.unlock()
            }
            return
        }
        // 配对成功：消费缓冲，防止旧帧被重复配对
        consecutivePairFailures = 0
        pendingA = nil
        pendingB = nil
        pairingLock.unlock()
        writeComposed(a: a, b: b)
    }

    /// 配对后统一走"标记就绪 → 启动会话 → 合成 → 写入"（A 路串行队列上）
    private func writeComposed(a: (buffer: CVPixelBuffer, pts: CMTime),
                               b: (buffer: CVPixelBuffer, pts: CMTime)) {
        let frameTime = a.pts

        // 标记视频就绪（供启动协调等待音频建轨；首帧时间记作等待起点）
        startLock.lock()
        videoReady = true
        if videoFirstArrival == nil { videoFirstArrival = CACurrentMediaTime() }
        startLock.unlock()

        startSessionIfNeeded(at: frameTime)

        // 积压自适应降级：合成跟不上时临时关圆角（仅本段录制生效）
        let cornerRatio = performanceDegraded ? 0 : recordingPipCornerRadiusRatio
        guard let composed = compositor.composite(frameA: a.buffer,
                                                  frameB: b.buffer,
                                                  layout: recordingLayout,
                                                  landscape: recordingLandscape,
                                                  pipPosition: recordingPipPosition,
                                                  pipCornerRadiusRatio: cornerRatio,
                                                  outputWidth: outputSize.width,
                                                  outputHeight: outputSize.height),
              let adaptor = pixelAdaptor,
              adaptor.assetWriterInput.isReadyForMoreMediaData else { return }
        adaptor.append(composed, withPresentationTime: frameTime)
    }

    /// 从 B 路滑动历史里找时间戳最接近的帧（停止排空期兜底配对用）
    private func nearestB(to pts: CMTime) -> (buffer: CVPixelBuffer, pts: CMTime)? {
        var best: (buffer: CVPixelBuffer, pts: CMTime)?
        var bestDiff = Double.greatestFiniteMagnitude
        for entry in bHistory {
            let diff = abs(entry.pts.seconds - pts.seconds)
            if diff < bestDiff {
                bestDiff = diff
                best = entry
            }
        }
        return best
    }

    /// 音频回调：按真实声道数懒创建 AAC 音轨并写入
    /// 注意：AVCaptureConnection 没有 mediaType，需经 inputPorts 判断
    private func handleAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer,
                                        connection: AVCaptureConnection) {
        guard isRecording, connection.inputPorts.first?.mediaType == .audio else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        // 音轨懒创建：按"真实采集到的音频样本"格式创建 AAC 输入
        // （声道=实际采集：立体声模式生效写双声道，否则写单声道，保证不静音）。
        // 必须在 startWriting 之前完成；若写入已开始（isWriting），
        // AVAssetWriter 不允许再添加输入，放弃音频只保留视频。
        if audioWriterInput == nil {
            startLock.lock()
            if !isWriting,
               let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc),
               let writer {
                let channels = Int(asbd.pointee.mChannelsPerFrame)
                let sampleRate = asbd.pointee.mSampleRate
                let settings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: sampleRate,
                    AVNumberOfChannelsKey: channels,
                    AVEncoderBitRateKey: 128_000,
                ]
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
                input.expectsMediaDataInRealTime = true
                if writer.canAdd(input) {
                    writer.add(input)
                    audioWriterInput = input
                }
            }
            // 无论建轨成败，音频都视为"settled"，不再阻塞写入启动
            audioReady = true
            startLock.unlock()
        }

        startSessionIfNeeded(at: pts)

        // 保证样本时间不早于会话起点（防止写入器拒绝）
        var outputPTS = pts
        var copied: CMSampleBuffer?
        if let start = sessionStartTime, pts < start {
            outputPTS = start
            var timing = CMSampleTimingInfo(duration: CMSampleBufferGetDuration(sampleBuffer),
                                            presentationTimeStamp: outputPTS,
                                            decodeTimeStamp: .invalid)
            CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault,
                                                  sampleBuffer: sampleBuffer,
                                                  sampleTimingEntryCount: 1,
                                                  sampleTimingArray: &timing,
                                                  sampleBufferOut: &copied)
        }
        let buffer = copied ?? sampleBuffer
        guard let audioWriterInput, audioWriterInput.isReadyForMoreMediaData else { return }
        audioWriterInput.append(buffer)
    }

    /// 以首个样本时间作为会话起点（先到先定，后续样本时间必然 ≥ 起点）
    /// 注意：视频A/视频B/音频三条队列并发调用，必须加锁保证只启动一次。
    ///
    /// 启动协调（修复"固定2声道丢弃非双声道导致整段静音"）：
    /// 音轨按音频首帧真实声道数懒创建，因此 startWriting 需要等待——
    ///   videoReady（视频首帧已配对） && ( audioReady（音轨已建 / 无麦克风）
    ///   || 等待音频超时 0.5s ) 才真正开写，
    /// 保证音轨创建始终在 startWriting 之前（AVAssetWriter 约束）。
    private func startSessionIfNeeded(at time: CMTime) {
        startLock.lock()
        defer { startLock.unlock() }
        guard !isWriting, let writer else { return }
        let audioSettled = audioReady
            || (videoFirstArrival != nil
                && CACurrentMediaTime() - (videoFirstArrival ?? 0) > audioStartTimeout)
        guard videoReady && audioSettled else { return }
        isWriting = true
        sessionStartTime = time
        writer.startWriting()
        writer.startSession(atSourceTime: time)
    }

    // MARK: - 丢帧统计（仅日志，不阻塞）

    func captureOutput(_ output: AVCaptureOutput,
                       didDrop sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        // 高负载时系统会主动丢帧（alwaysDiscardsLateVideoFrames=true），
        // 此处保留埋点位，便于后续排查性能问题。
    }
}

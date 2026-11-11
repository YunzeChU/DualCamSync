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
///   写入队列先接收音轨格式与视频配对，随后确定同一真实时间线的起点。
final class ModeARecorder: NSObject,
    AVCaptureVideoDataOutputSampleBufferDelegate,
    AVCaptureAudioDataOutputSampleBufferDelegate {

    // MARK: - Capture ingress and serialized composition/writing

    private let mediaQueue = DispatchQueue(label: "com.dualcamsync.media")
    // AVCapture delegate callbacks must remain cheap. Rendering a Core Image frame on
    // the delegate queue makes `alwaysDiscardsLateVideoFrames` discard camera samples
    // before this recorder can observe them. These queues only coalesce ingress; all
    // pairing, rendering, writing, and finalization remain serialized on mediaQueue.
    private let captureQueueA = DispatchQueue(label: "com.dualcamsync.captureA")
    private let captureQueueB = DispatchQueue(label: "com.dualcamsync.captureB")
    var videoQueueA: DispatchQueue { captureQueueA }
    var videoQueueB: DispatchQueue { captureQueueB }
    // Audio remains ordered on the writer queue. Coalescing AAC samples would create
    // an audio timeline with gaps, whereas the expensive work being isolated here is
    // the two video composition paths.
    var audioQueue: DispatchQueue { mediaQueue }
    private var generation = UUID()
    private var finishing = false
    private var finishWritingStarted = false
    private var accepting = false
    /// Connections are disabled by CameraManager before `stop()`, but AVCapture may
    /// already have a callback in flight when that happens. Keep accepting for this
    /// short, bounded quiescence period so that callback reaches the same drain as
    /// samples that were already queued on `mediaQueue`.
    private var awaitingInputQuiescence = false
    private var retryScheduled = false
    private var stopDeadline: CFTimeInterval?
    private typealias Frame = (buffer: CVPixelBuffer, pts: CMTime)
    private var framesA: [Frame] = []
    private var framesB: [Frame] = []
    private var audioSamples: [CMSampleBuffer] = []
    private var pairs: [(a: Frame, b: Frame)] = []
    private var lastVideoPTS: CMTime?
    private var lastAudioPTS: CMTime?
    private var unmatchedCount = 0
    private var backpressureCount = 0
    private var startupSkipped = 0
    private var pendingFailure: Error?
    private let inputQuiescenceDelay: DispatchTimeInterval = .milliseconds(150)

    /// Bounded handoff from AVCapture's callback queues to the slower compositor.
    /// When overloaded, replacing the pending sample (rather than queueing every
    /// sample) preserves the newest live image for the tail while bounding retained
    /// camera buffers to one sample per source.
    private enum IngressRoute { case videoA, videoB, audio }
    /// A single retained value bounds camera buffer ownership even if rendering is
    /// slower than capture. Timestamps remain those of the newest real sample.
    struct LatestVideoValue<Value> {
        private(set) var value: Value?
        private(set) var replacements = 0

        mutating func offer(_ value: Value) {
            if self.value != nil { replacements += 1 }
            self.value = value
        }
    }
    private struct PendingIngress {
        var latest = LatestVideoValue<(sample: CMSampleBuffer, connection: AVCaptureConnection)>()
        var scheduled = false
        var dropReasons: [String: Int] = [:]
    }
    private let ingressLock = NSLock()
    private weak var ingressOutputA: AVCaptureVideoDataOutput?
    private weak var ingressOutputB: AVCaptureVideoDataOutput?
    private weak var ingressAudioOutput: AVCaptureAudioDataOutput?
    private var ingressGeneration = UUID()
    private var ingressOpen = true
    private var ingressA = PendingIngress()
    private var ingressB = PendingIngress()

    // MARK: - Per-recording tail diagnostics

    private enum CaptureStream { case videoA, videoB, audio }

    private struct StreamTelemetry {
        var receivedCount = 0
        var pairedCount = 0
        var writtenCount = 0
        var lastReceivedPTS: CMTime?
        var lastPairedPTS: CMTime?
        var lastWrittenPTS: CMTime?
        var dropReasons: [String: Int] = [:]
    }

    private var telemetryA = StreamTelemetry()
    private var telemetryB = StreamTelemetry()
    private var telemetryAudio = StreamTelemetry()
    private var discardedA = 0
    private var discardedB = 0
    private var videoWriterNotReadyCount = 0
    private var audioWriterNotReadyCount = 0
    private var ingressCoalescedA = 0
    private var ingressCoalescedB = 0
    private var stopRequestedAt: CFTimeInterval?
    private var inputSealedAt: CFTimeInterval?

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

    /// Per-recording evidence, rather than a capability prediction: HDR recording is
    /// admitted only after each source has delivered a P010 sample to this recorder.
    private var firstHDRFormatA: OSType?
    private var firstHDRFormatB: OSType?
    private var didLogHDRInputVerification = false

    enum HDRInputValidation: Equatable {
        case p010
        case unexpectedPixelFormat(OSType)
    }

    static func validateHDRInputPixelFormat(_ format: OSType) -> HDRInputValidation {
        switch format {
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
            return .p010
        default:
            return .unexpectedPixelFormat(format)
        }
    }

    static func pixelFormatDiagnostic(_ format: OSType) -> String {
        let bytes = [
            UInt8((format >> 24) & 0xff), UInt8((format >> 16) & 0xff),
            UInt8((format >> 8) & 0xff), UInt8(format & 0xff)
        ]
        let fourCC = bytes.allSatisfy { (32...126).contains($0) }
            ? String(bytes: bytes, encoding: .ascii) ?? "????"
            : "non-printable"
        return "'\(fourCC)' (0x\(String(format: "%08X", format)))"
    }

    // MARK: - 写入器

    private var writer: AVAssetWriter?
    private var videoWriterInput: AVAssetWriterInput?
    private var pixelAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var audioWriterInput: AVAssetWriterInput?
    private var outputURL: URL?

    private let compositor = VideoCompositor()

    // MARK: - 录制状态

    private var isRecording = false
    private var outputSize: (width: Int32, height: Int32) = (1920, 1080)
    private var recordingLayout: PreviewLayout = .split
    private var recordingLandscape = true
    private var recordingHDR = false
    /// 录制开始时的画中画小窗位置（归一化，y 从顶部算；由 CameraManager
    /// 在 start 时传入，合成帧时传给 VideoCompositor.makePiP —— 保证
    /// "成片小窗位置 = 录制开始时的预览位置"）
    private var recordingPipPosition: CGPoint = CGPoint(x: 0.805, y: 0.665)
    /// 录制开始时的画中画小窗圆角比例（成片圆角 = 小窗宽 × 比例，
    /// 由 CameraManager 在 start 时传入；0 = 不加圆角）
    private var recordingPipCornerRadiusRatio: CGFloat = 0
    private var sessionStartTime: CMTime?
    private var isWriting = false
    private var audioReady = false
    private var videoFirstArrival: CFTimeInterval?
    // Startup is bounded both by wall time and retained real-frame count.
    private let audioStartTimeout: CFTimeInterval = 0.5

    var onFinished: (([URL]) -> Void)?
    var onError: ((Error) -> Void)?
    var onStarted: (() -> Void)?
    /// A valid partial file is still saved when capture stops because of an error.
    var onPartialFinished: ((URL, Error) -> Void)?

    // MARK: - 挂载/卸载

    func attach(videoOutputA: AVCaptureVideoDataOutput,
                videoOutputB: AVCaptureVideoDataOutput,
                audioOutput: AVCaptureAudioDataOutput,
                connA: AVCaptureConnection?,
                connB: AVCaptureConnection?) {
        mediaQueue.sync {
        self.videoOutputA = videoOutputA
        self.videoOutputB = videoOutputB
        self.audioOutput = audioOutput
        self.videoConnA = connA
        self.videoConnB = connB
        didVerifyHDRPipeline = false
        ingressLock.lock()
        ingressOutputA = videoOutputA
        ingressOutputB = videoOutputB
        ingressAudioOutput = audioOutput
        ingressGeneration = UUID(); ingressOpen = true
        ingressA = PendingIngress(); ingressB = PendingIngress()
        ingressLock.unlock()
        }
    }

    func detach() {
        mediaQueue.sync {
        videoOutputA = nil
        videoOutputB = nil
        audioOutput = nil
        videoConnA = nil
        videoConnB = nil
        ingressLock.lock()
        ingressOutputA = nil; ingressOutputB = nil; ingressAudioOutput = nil
        ingressGeneration = UUID(); ingressOpen = false
        ingressA = PendingIngress(); ingressB = PendingIngress()
        ingressLock.unlock()
        }
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
        try mediaQueue.sync {
        guard !isRecording, !finishing else {
            // 静默返回 = 录制键点了毫无反应；必须抛错让上层弹窗说明
            throw CameraError.recordingFailed("上一段视频仍在收尾，请稍候")
        }
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("DCS_\(UUID().uuidString)_composite.mp4")

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
                kVTCompressionPropertyKey_PreserveDynamicHDRMetadata as String: false,
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
        // 由 pump 的启动协调保证。
        self.writer = writer
        self.videoWriterInput = videoInput
        self.pixelAdaptor = adaptor
        self.outputURL = url
        self.outputSize = outputSize
        self.recordingLayout = layout
        self.recordingLandscape = outputSize.width > outputSize.height
        self.recordingHDR = hdr
        self.firstHDRFormatA = nil
        self.firstHDRFormatB = nil
        self.didLogHDRInputVerification = false
        self.recordingPipPosition = pipPosition
        self.recordingPipCornerRadiusRatio = pipCornerRadiusRatio
        self.sessionStartTime = nil
        self.isWriting = false
        self.audioWriterInput = nil
        self.audioReady = (audioFormat == nil)   // 无麦克风 → 无需等待音频
        self.videoFirstArrival = nil
        self.isRecording = true
        self.accepting = true
        self.generation = UUID()
        self.ingressLock.lock()
        self.ingressGeneration = UUID(); self.ingressOpen = true
        self.ingressA = PendingIngress(); self.ingressB = PendingIngress()
        self.ingressLock.unlock()
        self.framesA = []; self.framesB = []; self.pairs = []; self.audioSamples = []
        self.lastVideoPTS = nil; self.lastAudioPTS = nil
        self.unmatchedCount = 0; self.backpressureCount = 0
        self.startupSkipped = 0
        self.telemetryA = StreamTelemetry(); self.telemetryB = StreamTelemetry()
        self.telemetryAudio = StreamTelemetry()
        self.discardedA = 0; self.discardedB = 0
        self.videoWriterNotReadyCount = 0; self.audioWriterNotReadyCount = 0
        self.ingressCoalescedA = 0; self.ingressCoalescedB = 0
        self.stopRequestedAt = nil; self.inputSealedAt = nil
        self.stopDeadline = nil
        self.awaitingInputQuiescence = false
        self.finishWritingStarted = false
        self.retryScheduled = false
        self.pendingFailure = nil
        }
    }


    // CameraManager disables source connections before stop. Give in-flight callbacks
    // the existing handoff grace period, then require FIFO markers from both capture
    // queues before sealing input. The delay alone is not a queue-drain guarantee.
    func stop() {
        let requestedAt = CACurrentMediaTime()
        mediaQueue.async { [weak self] in
            guard let self, self.isRecording, !self.finishing else { return }
            self.finishing = true
            self.awaitingInputQuiescence = true
            self.stopRequestedAt = requestedAt
            self.stopDeadline = CACurrentMediaTime() + 3
            self.pump()
            let current = self.generation
            self.mediaQueue.asyncAfter(deadline: .now() + self.inputQuiescenceDelay) { [weak self] in
                guard let self, self.generation == current, self.finishing else { return }
                // FIFO markers establish that callbacks already on either capture
                // queue have handed off their newest sample. Never synchronously
                // wait on these queues from the writer domain.
                let callbacksDrained = DispatchGroup()
                callbacksDrained.enter()
                self.captureQueueA.async { callbacksDrained.leave() }
                callbacksDrained.enter()
                self.captureQueueB.async { callbacksDrained.leave() }
                callbacksDrained.notify(queue: self.mediaQueue) { [weak self] in
                    guard let self, self.generation == current, self.finishing else { return }
                    self.ingressLock.lock()
                    let token = self.ingressGeneration
                    self.ingressOpen = false
                    self.ingressLock.unlock()
                    self.drainIngress(.videoA, token: token)
                    self.drainIngress(.videoB, token: token)
                    self.awaitingInputQuiescence = false
                    self.accepting = false
                    self.inputSealedAt = CACurrentMediaTime()
                    self.pump()
                }
            }
        }
    }

    func abort(error: Error) {
        mediaQueue.async { [weak self] in self?.fail(error) }
    }

    private func clear() {
        ingressLock.lock()
        ingressGeneration = UUID(); ingressOpen = false
        ingressA = PendingIngress(); ingressB = PendingIngress()
        ingressLock.unlock()
        writer = nil; videoWriterInput = nil; audioWriterInput = nil
        pixelAdaptor = nil; outputURL = nil; sessionStartTime = nil
        isWriting = false
        framesA = []; framesB = []; pairs = []; audioSamples = []
    }

    private func routeLocked(for output: AVCaptureOutput) -> IngressRoute? {
        if let ingressOutputA, output === ingressOutputA { return .videoA }
        if let ingressOutputB, output === ingressOutputB { return .videoB }
        if let ingressAudioOutput, output === ingressAudioOutput { return .audio }
        return nil
    }

    private func enqueueIngress(_ route: IngressRoute,
                                sample: CMSampleBuffer,
                                connection: AVCaptureConnection,
                                token: UUID) {
        let shouldSchedule: Bool
        ingressLock.lock()
        guard token == ingressGeneration, ingressOpen else { ingressLock.unlock(); return }
        switch route {
        case .videoA:
            ingressA.latest.offer((sample, connection))
            shouldSchedule = !ingressA.scheduled; ingressA.scheduled = true
        case .videoB:
            ingressB.latest.offer((sample, connection))
            shouldSchedule = !ingressB.scheduled; ingressB.scheduled = true
        case .audio:
            shouldSchedule = false
        }
        ingressLock.unlock()
        guard shouldSchedule else { return }
        mediaQueue.async { [weak self] in self?.drainIngress(route, token: token) }
    }

    private func enqueueDroppedFrame(_ route: IngressRoute, reason: String, token: UUID) {
        let shouldSchedule: Bool
        ingressLock.lock()
        guard token == ingressGeneration, ingressOpen else { ingressLock.unlock(); return }
        switch route {
        case .videoA:
            ingressA.dropReasons[reason, default: 0] += 1
            shouldSchedule = !ingressA.scheduled; ingressA.scheduled = true
        case .videoB:
            ingressB.dropReasons[reason, default: 0] += 1
            shouldSchedule = !ingressB.scheduled; ingressB.scheduled = true
        case .audio:
            shouldSchedule = false
        }
        ingressLock.unlock()
        guard shouldSchedule else { return }
        mediaQueue.async { [weak self] in self?.drainIngress(route, token: token) }
    }

    private func drainIngress(_ route: IngressRoute, token: UUID) {
        dispatchPrecondition(condition: .onQueue(mediaQueue))
        let pending: PendingIngress
        ingressLock.lock()
        guard token == ingressGeneration else { ingressLock.unlock(); return }
        switch route {
        case .videoA:
            pending = ingressA; ingressA = PendingIngress()
        case .videoB:
            pending = ingressB; ingressB = PendingIngress()
        case .audio:
            ingressLock.unlock()
            return
        }
        ingressLock.unlock()
        switch route {
        case .videoA: ingressCoalescedA += pending.latest.replacements
        case .videoB: ingressCoalescedB += pending.latest.replacements
        case .audio: break
        }
        let captureStream: CaptureStream?
        switch route {
        case .videoA: captureStream = .videoA
        case .videoB: captureStream = .videoB
        case .audio: captureStream = nil
        }
        if let captureStream {
            for (reason, count) in pending.dropReasons {
                recordDropped(captureStream, reason: reason, count: count)
            }
        }
        guard let payload = pending.latest.value else { return }
        processCaptureOutput(payload.sample, from: payload.connection)
    }

    private func recordReceived(_ stream: CaptureStream, pts: CMTime) {
        switch stream {
        case .videoA:
            telemetryA.receivedCount += 1; telemetryA.lastReceivedPTS = pts
        case .videoB:
            telemetryB.receivedCount += 1; telemetryB.lastReceivedPTS = pts
        case .audio:
            telemetryAudio.receivedCount += 1; telemetryAudio.lastReceivedPTS = pts
        }
    }

    private func recordDropped(_ stream: CaptureStream, reason: String, count: Int = 1) {
        switch stream {
        case .videoA: telemetryA.dropReasons[reason, default: 0] += count
        case .videoB: telemetryB.dropReasons[reason, default: 0] += count
        case .audio: break
        }
    }

    static func droppedFrameReasonDescription(_ value: Any?) -> String {
        guard let value else { return "unknown" }
        let description = String(describing: value)
        return description.isEmpty ? "unknown" : description
    }

    private static func seconds(_ time: CMTime?) -> String {
        guard let time, time.isValid else { return "none" }
        return String(format: "%.3f", time.seconds)
    }

    private func telemetryDescription(_ telemetry: StreamTelemetry) -> String {
        let reasons = telemetry.dropReasons.keys.sorted().map {
            "\($0):\(telemetry.dropReasons[$0] ?? 0)"
        }.joined(separator: ",")
        return "received=\(telemetry.receivedCount),lastReceived=\(Self.seconds(telemetry.lastReceivedPTS)),paired=\(telemetry.pairedCount),lastPaired=\(Self.seconds(telemetry.lastPairedPTS)),written=\(telemetry.writtenCount),lastWritten=\(Self.seconds(telemetry.lastWrittenPTS)),drops={\(reasons)}"
    }

    private func logTailSummary(event: String, writerStatus: AVAssetWriter.Status? = nil,
                                writerError: Error? = nil) {
        let stopToSeal: String
        if let stopRequestedAt, let inputSealedAt {
            stopToSeal = String(format: "%.3f", inputSealedAt - stopRequestedAt)
        } else {
            stopToSeal = "none"
        }
        let status = writerStatus.map { String(describing: $0) } ?? "none"
        let error = writerError?.localizedDescription ?? "none"
        print("[ModeA][TailSummary] event=\(event) stopToSeal=\(stopToSeal) writerStatus=\(status) writerError=\(error) A{\(telemetryDescription(telemetryA))} B{\(telemetryDescription(telemetryB))} audio{\(telemetryDescription(telemetryAudio))} ingressCoalesced(A=\(ingressCoalescedA),B=\(ingressCoalescedB)) discardedA=\(discardedA) discardedB=\(discardedB) writerNotReady(video=\(videoWriterNotReadyCount),audio=\(audioWriterNotReadyCount)) unmatched=\(unmatchedCount) startupSkipped=\(startupSkipped)")
    }

    private func fail(_ error: Error) {
        guard isRecording || finishing else { return }
        if pendingFailure == nil { pendingFailure = error }
        accepting = false
        logTailSummary(event: "failure", writerStatus: writer?.status, writerError: error)
        // A completed writer may be awaiting its queued completion callback.
        // Preserve that callback and let it deliver the file with this error.
        guard !finishWritingStarted else { return }
        if let writer, writer.status == .writing, isWriting, lastVideoPTS != nil {
            // The encoder may still finalize already accepted samples. Preserve those
            // instead of cancelling a potentially useful recording on capture failure.
            finishing = true
            framesA.removeAll(); framesB.removeAll(); pairs.removeAll(); audioSamples.removeAll()
            finishCurrent()
            return
        }
        let callback = onError
        let file = outputURL?.lastPathComponent ?? "unknown"
        // No samples have started the writer in the common startup-abort case.
        // cancelWriting is synchronous and can wait for framework initialization;
        // an .unknown writer has no writing session to cancel. Releasing it is
        // sufficient, and must not hold up the recorder's restart notification.
        if writer?.status == .writing { writer?.cancelWriting() }
        print("[ModeA] failure file=\(file) error=\(error.localizedDescription)")
        accepting = false; isRecording = false; finishing = false
        generation = UUID()
        clear()
        DispatchQueue.main.async { callback?(error) }
    }

    private func finishCurrent() {
        guard finishing, !finishWritingStarted else { return }
        finishWritingStarted = true
        let current = generation
        let completed = onFinished
        let failed = onError
        let partial = onPartialFinished
        let url = outputURL
        guard let writer, isWriting else {
            logTailSummary(event: "finish-empty", writerStatus: writer?.status,
                           writerError: writer?.error)
            // A quick stop before the first pair never called startWriting.
            // Do not synchronously cancel that unused (.unknown) writer.
            if self.writer?.status == .writing { self.writer?.cancelWriting() }
            if let url { try? FileManager.default.removeItem(at: url) }
            isRecording = false; finishing = false
            clear()
            DispatchQueue.main.async { completed?([]) }
            return
        }
        logTailSummary(event: "finish-request", writerStatus: writer.status,
                       writerError: writer.error)
        videoWriterInput?.markAsFinished()
        audioWriterInput?.markAsFinished()
        writer.finishWriting { [weak self] in
            guard let self else { return }
            self.mediaQueue.async {
                guard self.generation == current else { return }
                let error = writer.error
                let captureError = self.pendingFailure
                let succeeded = writer.status == .completed && error == nil
                self.logTailSummary(event: "finish-complete", writerStatus: writer.status,
                                    writerError: error)
                self.isRecording = false; self.finishing = false
                self.clear()
                DispatchQueue.main.async {
                    if succeeded, let url, let captureError { partial?(url, captureError) }
                    else if succeeded, let url { completed?([url]) }
                    else { failed?(CameraError.recordingFailed(error?.localizedDescription ?? "合成文件写入失败")) }
                }
            }
        }
    }

    private func estimateVideoBitrate(width: Int32, height: Int32) -> Int {
        Double(width) * Double(height) >= 3840 * 2160 ? 35_000_000 : 12_000_000
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        ingressLock.lock()
        let route = routeLocked(for: output)
        let token = ingressGeneration
        ingressLock.unlock()
        guard let route else { return }
        if case .audio = route {
            processCaptureOutput(sampleBuffer, from: connection)
            return
        }
        enqueueIngress(route, sample: sampleBuffer, connection: connection, token: token)
    }

    private func processCaptureOutput(_ sampleBuffer: CMSampleBuffer,
                                      from connection: AVCaptureConnection) {
        dispatchPrecondition(condition: .onQueue(mediaQueue))
        let isA = connection === videoConnA
        if isA || connection === videoConnB {
            guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let stream: CaptureStream = isA ? .videoA : .videoB
            let samplePTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            recordReceived(stream, pts: samplePTS)
            if isA && !didVerifyHDRPipeline {
                didVerifyHDRPipeline = true
                let format = CVPixelBufferGetPixelFormatType(buffer)
                let tenBit = format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                    || format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
                let callback = onHDRPipelineVerified
                DispatchQueue.main.async { callback?(tenBit) }
            }
            guard accepting else { return }
            let format = CVPixelBufferGetPixelFormatType(buffer)
            let hdrValidation = Self.validateHDRInputPixelFormat(format)
            if recordingHDR {
                if isA, firstHDRFormatA == nil { firstHDRFormatA = format }
                if !isA, firstHDRFormatB == nil { firstHDRFormatB = format }
                guard hdrValidation == .p010 else {
                    let source = isA ? "A" : "B"
                    let detail = "HDR请求未生效：\(source)路首个视频样本为\(Self.pixelFormatDiagnostic(format))，期望P010 10-bit；已停止，未将该样本写入HDR文件"
                    print("[ModeA][HDR] \(detail)")
                    fail(CameraError.recordingFailed(detail))
                    return
                }
                if !didLogHDRInputVerification,
                   let formatA = firstHDRFormatA, let formatB = firstHDRFormatB {
                    didLogHDRInputVerification = true
                    print("[ModeA][HDR] capture input verified A=\(Self.pixelFormatDiagnostic(formatA)) B=\(Self.pixelFormatDiagnostic(formatB)); P010 accepted for this recording")
                }
            } else if hdrValidation == .p010 {
                let detail = "SDR写入设置收到P010视频样本（\(Self.pixelFormatDiagnostic(format))），已停止以避免颜色链路不一致"
                print("[ModeA] \(detail)")
                fail(CameraError.recordingFailed(detail))
                return
            }
            // Do not retain hundreds of MB while the microphone is warming up.
            // Recording media begins only once its real audio format is known.
            if !audioReady {
                startupSkipped += 1
                if videoFirstArrival == nil { videoFirstArrival = CACurrentMediaTime() }
                if CACurrentMediaTime() - (videoFirstArrival ?? 0) >= audioStartTimeout {
                    fail(CameraError.recordingFailed("麦克风启动超时，未开始录制"))
                }
                return
            }
            let frame = (buffer: buffer, pts: samplePTS)
            if isA { framesA.append(frame) } else { framesB.append(frame) }
            guard framesA.count <= 6, framesB.count <= 6 else {
                fail(CameraError.recordingFailed("两路采集持续不同步，已停止以避免尾部画面丢失")); return
            }
        } else {
            let samplePTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            recordReceived(.audio, pts: samplePTS)
            guard accepting else { return }
            if !audioReady, !isWriting,
               let description = CMSampleBufferGetFormatDescription(sampleBuffer),
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
               let writer {
                let settings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: asbd.pointee.mSampleRate,
                    AVNumberOfChannelsKey: Int(asbd.pointee.mChannelsPerFrame),
                    AVEncoderBitRateKey: 128_000
                ]
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
                input.expectsMediaDataInRealTime = true
                guard writer.canAdd(input) else {
                    fail(CameraError.recordingFailed("无法添加合成音轨")); return
                }
                writer.add(input); audioWriterInput = input; audioReady = true
            }
            if audioWriterInput != nil { audioSamples.append(sampleBuffer) }
        }
        pump()
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didDrop sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        ingressLock.lock()
        let route = routeLocked(for: output)
        let token = ingressGeneration
        ingressLock.unlock()
        guard let route else { return }
        if case .audio = route { return }
        let reason = Self.droppedFrameReasonDescription(
            CMGetAttachment(sampleBuffer, key: kCMSampleBufferAttachmentKey_DroppedFrameReason,
                            attachmentModeOut: nil))
        enqueueDroppedFrame(route, reason: reason, token: token)
    }

    private func schedulePump() {
        guard !retryScheduled else { return }
        retryScheduled = true
        let current = generation
        mediaQueue.asyncAfter(deadline: .now() + 0.01) { [weak self] in
            guard let self else { return }
            guard self.generation == current else { return }
            self.retryScheduled = false
            self.pump()
        }
    }

    /// A and B arrivals both complete pairs; retain real frames during writer backpressure.
    enum PairDecision: Equatable { case pair, discardA, discardB }
    static func pairingDecision(a: Double, b: Double) -> PairDecision {
        if abs(a - b) < 0.1 { return .pair }
        return a < b ? .discardA : .discardB
    }

    private func pump() {
        guard isRecording, !finishWritingStarted else { return }
        while let a = framesA.first, let b = framesB.first {
            let decision = Self.pairingDecision(a: a.pts.seconds, b: b.pts.seconds)
            if decision == .pair {
                pairs.append((a, b)); framesA.removeFirst(); framesB.removeFirst()
                telemetryA.pairedCount += 1; telemetryA.lastPairedPTS = a.pts
                telemetryB.pairedCount += 1; telemetryB.lastPairedPTS = b.pts
            } else {
                unmatchedCount += 1
                if decision == .discardA {
                    discardedA += 1; framesA.removeFirst()
                } else {
                    discardedB += 1; framesB.removeFirst()
                }
            }
        }
        guard pairs.count <= 6, audioSamples.count <= 100 else {
            fail(CameraError.recordingFailed("合成写入持续过慢，已停止；请降低规格后重试")); return
        }
        if !isWriting, let first = pairs.first {
            if videoFirstArrival == nil { videoFirstArrival = CACurrentMediaTime() }
            if !audioReady && CACurrentMediaTime() - (videoFirstArrival ?? 0) >= audioStartTimeout {
                fail(CameraError.recordingFailed("未收到麦克风样本，已停止以避免无声音或时间线错位")); return
            }
            if audioReady, let writer {
                // Audio may precede the first admitted pair. Keep only its nearby
                // startup samples; never anchor video to seconds-old microphone PTS.
                audioSamples.removeAll {
                    CMSampleBufferGetPresentationTimeStamp($0).seconds < first.a.pts.seconds - 0.1
                }
                let audioPTS = audioSamples.first.map { CMSampleBufferGetPresentationTimeStamp($0) }
                let start = audioPTS.map { CMTimeMinimum(first.a.pts, $0) } ?? first.a.pts
                guard writer.startWriting() else {
                    fail(writer.error ?? CameraError.recordingFailed("视频写入器启动失败")); return
                }
                writer.startSession(atSourceTime: start)
                sessionStartTime = start; isWriting = true
                let started = onStarted
                DispatchQueue.main.async { started?() }
            } else { schedulePump(); return }
        }
        if isWriting {
            while let pair = pairs.first {
                guard let input = videoWriterInput, input.isReadyForMoreMediaData else {
                    backpressureCount += 1; videoWriterNotReadyCount += 1; schedulePump(); break
                }
                guard let composed = compositor.composite(
                    frameA: pair.a.buffer, frameB: pair.b.buffer,
                    layout: recordingLayout, landscape: recordingLandscape,
                    pipPosition: recordingPipPosition,
                    pipCornerRadiusRatio: recordingPipCornerRadiusRatio,
                    outputWidth: outputSize.width, outputHeight: outputSize.height),
                    let adaptor = pixelAdaptor,
                    adaptor.append(composed, withPresentationTime: pair.a.pts) else {
                    fail(writer?.error ?? CameraError.recordingFailed("合成视频帧写入失败")); return
                }
                lastVideoPTS = pair.a.pts
                telemetryA.writtenCount += 1; telemetryA.lastWrittenPTS = pair.a.pts
                telemetryB.writtenCount += 1; telemetryB.lastWrittenPTS = pair.b.pts
                pairs.removeFirst()
            }
            while let sample = audioSamples.first {
                guard let input = audioWriterInput else { audioSamples.removeAll(); break }
                guard input.isReadyForMoreMediaData else {
                    audioWriterNotReadyCount += 1; schedulePump(); break
                }
                guard input.append(sample) else {
                    fail(writer?.error ?? CameraError.recordingFailed("音频写入失败")); return
                }
                lastAudioPTS = CMSampleBufferGetPresentationTimeStamp(sample)
                telemetryAudio.writtenCount += 1; telemetryAudio.lastWrittenPTS = lastAudioPTS
                audioSamples.removeFirst()
            }
        }
        if finishing, !awaitingInputQuiescence {
            if !isWriting && pairs.isEmpty {
                audioSamples.removeAll()
                finishCurrent()
                return
            }
            if pairs.isEmpty && audioSamples.isEmpty {
                unmatchedCount += framesA.count + framesB.count
                print("[ModeA] terminalUnpairedA=\(framesA.count) terminalUnpairedB=\(framesB.count)")
                // Source connections stop independently; a few unmatched callbacks must
                // not discard an otherwise valid recording. Counts remain diagnostic.
                framesA.removeAll(); framesB.removeAll()
                finishCurrent()
            } else if CACurrentMediaTime() >= (stopDeadline ?? .greatestFiniteMagnitude) {
                fail(CameraError.recordingFailed("停止后编码器未能排空，本段未保存"))
            } else { schedulePump() }
        }
    }
}

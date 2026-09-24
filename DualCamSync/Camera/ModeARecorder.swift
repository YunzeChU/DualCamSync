import AVFoundation
import CoreMedia
import Foundation

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
    /// 写入会话起点（多队列并发，需加锁保护）
    private let startLock = NSLock()
    private var sessionStartTime: CMTime?
    private var isWriting = false

    /// 帧配对缓冲（两路帧到齐后再合成，防止错位）
    private let pairingLock = NSLock()
    private var pendingA: (buffer: CVPixelBuffer, pts: CMTime)?
    private var pendingB: (buffer: CVPixelBuffer, pts: CMTime)?

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
    func start(outputSize: (width: Int32, height: Int32),
               layout: PreviewLayout,
               audioFormat: (sampleRate: Double, channels: Int)?) throws {
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

        // 视频输入：HEVC 硬件编码
        let bitrate = estimateVideoBitrate(width: outputSize.width, height: outputSize.height)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: outputSize.width,
            AVVideoHeightKey: outputSize.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                // 不显式指定 profile：交由系统按分辨率/帧率自动选择（HEVC Main/Main10）
            ],
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
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
        self.sessionStartTime = nil
        self.isWriting = false
        self.audioWriterInput = nil
        self.pendingA = nil
        self.pendingB = nil
        self.videoReady = false
        self.audioReady = (audioFormat == nil)   // 无麦克风 → 无需等待音频
        self.videoFirstArrival = nil
        self.isRecording = true
    }

    /// 停止录制：标记完成并异步收尾
    func stop() {
        guard isRecording else { return }
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
    ///   - B 路（videoQueueB）：只更新配对缓冲，不做合成/写入；
    ///   - A 路（videoQueueA）：独占"配对 → 清空缓冲 → 合成 → append"，
    ///     保证 CIContext.render 与 AVAssetWriter append 永远只在单条
    ///     串行队列上执行，不会并发。
    ///   - 配对成功后立即清空 pendingA/B，防止旧帧被重复配对。
    private func handleVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer,
                                        connection: AVCaptureConnection) {
        guard isRecording,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let isA = (connection === videoConnA)
        let isB = (connection === videoConnB)
        guard isA || isB else { return }

        // B 路：只写配对缓冲（加锁），让 A 路队列串行消费
        if isB {
            pairingLock.lock()
            pendingB = (pixelBuffer, pts)
            pairingLock.unlock()
            return
        }

        // A 路：配对成功后消费缓冲并合成写入
        pairingLock.lock()
        pendingA = (pixelBuffer, pts)
        guard let a = pendingA, let b = pendingB,
              abs(a.pts.seconds - b.pts.seconds) < 0.1 else {
            pairingLock.unlock()
            return
        }
        // 消费：清空配对缓冲，防止旧帧被重复配对
        pendingA = nil
        pendingB = nil
        let frameTime = a.pts
        let bufferA = a.buffer
        let bufferB = b.buffer
        pairingLock.unlock()

        // 标记视频就绪（供启动协调等待音频建轨；首帧时间记作等待起点）
        startLock.lock()
        videoReady = true
        if videoFirstArrival == nil { videoFirstArrival = CACurrentMediaTime() }
        startLock.unlock()

        startSessionIfNeeded(at: frameTime)

        guard let composed = compositor.composite(frameA: bufferA,
                                                  frameB: bufferB,
                                                  layout: recordingLayout,
                                                  landscape: recordingLandscape,
                                                  outputWidth: outputSize.width,
                                                  outputHeight: outputSize.height),
              let adaptor = pixelAdaptor,
              adaptor.assetWriterInput.isReadyForMoreMediaData else { return }
        adaptor.append(composed, withPresentationTime: frameTime)
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

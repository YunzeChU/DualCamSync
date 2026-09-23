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
/// 声道策略：以真实采集到的音频格式为准动态创建 writer 输入
///   （设备支持立体声则写入双声道 AAC；否则单声道），保证永不失配。
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

    /// 开始录制：创建写入器（视频轨 + 音轨均在此创建，等待首帧后写入）
    /// - Parameters:
    ///   - audioFormat: 麦克风真实采样率/声道数；**音轨必须在 startWriting()
    ///     之前 add**——AVAssetWriter 开始写入后不能再添加输入，
    ///     否则合成 MP4 会无声轨（修复：音轨不再依赖"首个音频样本"才创建）。
    func start(outputSize: (width: Int32, height: Int32),
               layout: PreviewLayout,
               audioFormat: (sampleRate: Double, channels: Int)?) throws {
        guard !isRecording else { return }
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

        // 音轨提前创建（startWriting 之前），按麦克风真实格式写 AAC。
        // 声道数以实际采集为准（空间音频/立体声模式下为 2 声道，双声道立体声）。
        var precreatedAudioInput: AVAssetWriterInput?
        if let audioFormat {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: audioFormat.sampleRate,
                AVNumberOfChannelsKey: audioFormat.channels,
                AVEncoderBitRateKey: 128_000,
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) {
                writer.add(input)
                precreatedAudioInput = input
            }
        }

        self.writer = writer
        self.videoWriterInput = videoInput
        self.pixelAdaptor = adaptor
        self.outputURL = url
        self.outputSize = outputSize
        self.recordingLayout = layout
        self.recordingLandscape = outputSize.width > outputSize.height
        self.sessionStartTime = nil
        self.isWriting = false
        self.audioWriterInput = precreatedAudioInput
        self.pendingA = nil
        self.pendingB = nil
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
                    self.onError?(CameraError.recordingFailed("写入失败 (\(status.rawValue))"))
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
    private func handleVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer,
                                        connection: AVCaptureConnection) {
        guard isRecording,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let isA = (connection === videoConnA)
        let isB = (connection === videoConnB)
        guard isA || isB else { return }

        // 帧配对：两路都到齐且时间接近才合成
        pairingLock.lock()
        if isA {
            pendingA = (pixelBuffer, pts)
        } else {
            pendingB = (pixelBuffer, pts)
        }
        guard let a = pendingA, let b = pendingB,
              abs(a.pts.seconds - b.pts.seconds) < 0.1 else {
            pairingLock.unlock()
            return
        }
        let frameTime = a.pts
        let bufferA = a.buffer
        let bufferB = b.buffer
        pairingLock.unlock()

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

    /// 音频回调：按真实声道数创建 AAC 音轨并写入
    /// 注意：AVCaptureConnection 没有 mediaType，需经 inputPorts 判断
    private func handleAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer,
                                        connection: AVCaptureConnection) {
        guard isRecording, connection.inputPorts.first?.mediaType == .audio else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        // 兜底：正常路径 start() 已提前创建音轨；此分支仅在
        // "写入尚未开始且音轨未就绪"时按真实声道数尝试创建。
        // 一旦写入已开始（isWriting），AVAssetWriter 不允许再添加输入，直接丢弃音频。
        if audioWriterInput == nil {
            guard !isWriting else { return }
            guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else { return }
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
            guard let writer, writer.canAdd(input) else { return }
            writer.add(input)
            audioWriterInput = input
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
    /// 注意：视频A/视频B/音频三条队列并发调用，必须加锁保证只启动一次
    private func startSessionIfNeeded(at time: CMTime) {
        startLock.lock()
        defer { startLock.unlock() }
        guard !isWriting, let writer else { return }
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

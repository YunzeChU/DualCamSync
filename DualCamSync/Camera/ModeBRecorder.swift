import AVFoundation
import Foundation

/// 模式B：双独立文件录制器
/// -------------------------------------------------------------
/// 使用两个 AVCaptureMovieFileOutput（各自只启用自己那路视频连接 + 共享音频），
/// 在"同一瞬间"分别调用 startRecording：
///   - 两路文件起点一致、共享同一会话时钟 => 时间戳同源对齐，帧级同步；
///   - 每个文件内的音视频混流由 AVFoundation 内部完成，音画同步由框架保证；
///   - 两路文件携带的是同一条麦克风音轨（与需求一致）。
///
/// 空间音频（First Order Ambisonics）在会话配置阶段由 CameraManager
/// 通过 multichannelAudioMode 开启，MovieFileOutput 自动写出
/// "空间音频轨 + 立体声兼容轨"，本类无需额外处理。
final class ModeBRecorder: NSObject, AVCaptureFileOutputRecordingDelegate {

    private var outputA: AVCaptureMovieFileOutput?
    private var outputB: AVCaptureMovieFileOutput?
    private var currentURLs: [URL] = []
    /// 两个输出可能在不同线程并发回调完成事件，计数与错误需加锁保护
    private let finishLock = NSLock()
    private var finishedCount = 0
    private var pendingError: Error?
    /// 已成功完成录制的文件（一路失败时，另一路成功文件仍应保存到相册）
    private var finishedSuccessURLs: [URL] = []

    /// 两路都录制完成（主线程回调）
    var onFinished: (([URL]) -> Void)?
    /// 任一路失败（主线程回调）；附带另一路成功文件与失败文件列表
    /// （失败文件保留在临时目录，错误提示需带上路径便于用户找回）
    var onError: ((Error, [URL], [URL]) -> Void)?

    var isRecording: Bool {
        outputA?.isRecording == true || outputB?.isRecording == true
    }

    // MARK: - 挂载/卸载

    func attach(outputA: AVCaptureMovieFileOutput, outputB: AVCaptureMovieFileOutput) {
        self.outputA = outputA
        self.outputB = outputB
    }

    func detach() {
        outputA = nil
        outputB = nil
    }

    // MARK: - 录制控制

    /// 同时启动两路录制（两路时间线同源，帧级对齐）
    /// 注意：startRecording(to:recordingDelegate:) 返回 **Void**（并非 Bool），
    /// 启动失败会经 didFinishRecordingTo 完成回调携带 error 上报。
    /// 因此"双输出启动校验"由 fileOutput 完成回调统一处理：
    /// 任一路报错立即停止另一路（避免一路失败另一路空录）。
    func start() throws {
        guard let outputA, let outputB else {
            // 静默返回 = 录制键点了毫无反应（用户反复反馈"录制键没有变化"）。
            // 必须抛错给上层弹窗说明原因。
            throw CameraError.recordingFailed("录制输出未就绪，请重新选择镜头组合")
        }
        guard !outputA.isRecording, !outputB.isRecording else {
            throw CameraError.recordingFailed("上一段视频仍在收尾，请稍候")
        }
        let dir = FileManager.default.temporaryDirectory
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let urlA = dir.appendingPathComponent("DCS_\(stamp)_A.mp4")
        let urlB = dir.appendingPathComponent("DCS_\(stamp)_B.mp4")
        currentURLs = [urlA, urlB]
        finishedCount = 0
        pendingError = nil
        finishedSuccessURLs = []
        outputA.startRecording(to: urlA, recordingDelegate: self)
        outputB.startRecording(to: urlB, recordingDelegate: self)
    }

    func stop() {
        outputA?.stopRecording()
        outputB?.stopRecording()
    }

    // MARK: - AVCaptureFileOutputRecordingDelegate

    func fileOutput(_ output: AVCaptureFileOutput,
                    didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection],
                    error: Error?) {
        // 两路完成回调可能并发：先入队计数，回到主线程后再统一回调一次
        finishLock.lock()
        if let error, pendingError == nil {
            pendingError = error
            // 任一路启动/录制失败：立即停止另一路（若仍在录制），
            // 成功完成的一段仍会走保存逻辑（onError 携带 successURLs）
            if output === outputA {
                outputB?.stopRecording()
            } else {
                outputA?.stopRecording()
            }
        } else if error == nil {
            finishedSuccessURLs.append(outputFileURL)
        }
        finishedCount += 1
        let allDone = finishedCount >= 2
        let err = pendingError
        let successURLs = finishedSuccessURLs
        finishLock.unlock()

        guard allDone else { return }
        DispatchQueue.main.async {
            if let err {
                // 失败文件 = 本次录制的两个文件 − 成功文件（URL 值类型可直接比较）
                let failedURLs = self.currentURLs.filter { !successURLs.contains($0) }
                self.onError?(err, successURLs, failedURLs)
            } else {
                self.onFinished?(self.currentURLs)
            }
        }
    }
}

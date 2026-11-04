import AVFoundation
import Foundation

/// 每段捕获独立输出、URL 和回调；保留原 MovieFileOutput 空间音频路径。
final class ModeBRecorder: NSObject, AVCaptureFileOutputRecordingDelegate {
    private var outputA: AVCaptureMovieFileOutput?
    private var outputB: AVCaptureMovieFileOutput?
    private let finishLock = NSLock()
    private var active: Context?
    private final class Context {
        let outputs: [AVCaptureMovieFileOutput]
        let urls: [URL]
        let finished: (([URL]) -> Void)?
        let failed: ((Error, [URL], [URL]) -> Void)?
        var completed = Set<Int>()
        var successful = Set<Int>()
        var error: Error?
        init(outputs: [AVCaptureMovieFileOutput], urls: [URL],
             finished: (([URL]) -> Void)?, failed: ((Error, [URL], [URL]) -> Void)?) {
            self.outputs = outputs
            self.urls = urls
            self.finished = finished
            self.failed = failed
        }
    }
    /// 开始时捕获，调用方必须在 start 前设置。
    var onFinished: (([URL]) -> Void)?
    var onError: ((Error, [URL], [URL]) -> Void)?
    var isRecording: Bool {
        finishLock.lock()
        defer { finishLock.unlock() }
        return active != nil
    }
    func attach(outputA: AVCaptureMovieFileOutput, outputB: AVCaptureMovieFileOutput) {
        self.outputA = outputA
        self.outputB = outputB
    }
    func detach() {
        outputA = nil
        outputB = nil
        // active 保留旧输出，直到其真实回调完成。
    }
    func start() throws {
        guard let outputA, let outputB else {
            throw CameraError.recordingFailed("录制输出未就绪，请重新选择镜头组合")
        }
        finishLock.lock()
        guard active == nil, !outputA.isRecording, !outputB.isRecording else {
            finishLock.unlock()
            throw CameraError.recordingFailed("上一段视频仍在收尾，请稍候")
        }
        let id = UUID().uuidString
        let dir = FileManager.default.temporaryDirectory
        let urls = ["A", "B"].map { dir.appendingPathComponent("DCS_\(id)_\($0).mp4") }
        active = Context(outputs: [outputA, outputB], urls: urls,
                         finished: onFinished, failed: onError)
        finishLock.unlock()
        outputA.startRecording(to: urls[0], recordingDelegate: self)
        outputB.startRecording(to: urls[1], recordingDelegate: self)
    }
    func stop() {
        finishLock.lock()
        let outputs = active?.outputs ?? []
        finishLock.unlock()
        outputs.forEach { $0.stopRecording() }
    }
    /// 等待真实完成回调，成功文件仍交付保存；不超时复用未知状态输出。
    func abort(error: Error) {
        finishLock.lock()
        if active?.error == nil { active?.error = error }
        let outputs = active?.outputs ?? []
        finishLock.unlock()
        outputs.forEach { $0.stopRecording() }
    }
    static func recordingSucceeded(error: Error?) -> Bool {
        guard let error else { return true }
        return ((error as NSError).userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? NSNumber)?.boolValue == true
    }
    func fileOutput(_ output: AVCaptureFileOutput,
                    didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection], error: Error?) {
        finishLock.lock()
        guard let context = active,
              let index = context.outputs.firstIndex(where: { $0 === output }),
              context.urls[index] == outputFileURL,
              context.completed.insert(index).inserted else {
            finishLock.unlock()
            return
        }
        var otherToStop: AVCaptureMovieFileOutput?
        if Self.recordingSucceeded(error: error) {
            context.successful.insert(index)
        } else {
            if context.error == nil { context.error = error }
            otherToStop = context.outputs[1 - index]
        }
        let allDone = context.completed.count == 2
        let successURLs = context.urls.enumerated().compactMap {
            context.successful.contains($0.offset) ? $0.element : nil
        }
        let failedURLs = context.urls.filter { !successURLs.contains($0) }
        let resultError = context.error
        if allDone { active = nil }
        finishLock.unlock()
        // 锁外调用，避免 AVFoundation 同步重入。
        otherToStop?.stopRecording()
        guard allDone else { return }
        DispatchQueue.main.async {
            if let resultError {
                context.failed?(resultError, successURLs, failedURLs)
            } else {
                context.finished?(successURLs)
            }
        }
    }
}

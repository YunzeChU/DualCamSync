import AVFoundation
import Foundation

/// 双摄组合能力探测器
/// -------------------------------------------------------------
/// 用一个"不运行"的 AVCaptureMultiCamSession 实例做 canAddInput 探测，
/// 判断任意两个镜头能否在硬件上同时开启，结果缓存后供选摄面板置灰。
///
/// 注意：canAddInput 只能反映输入级约束；个别组合在真正 startRunning
/// 时仍可能失败（带宽/功率），运行期错误由 CameraManager 统一兜底降级。
final class CameraPairProbe {
    static let shared = CameraPairProbe()

    private let probeSession = AVCaptureMultiCamSession()
    private var cache: [String: Bool] = [:]
    private let lock = NSLock()

    /// 判断 a 与 b 两个镜头能否同时加入多摄会话
    /// fail-open 策略：探测过程任何异常都按"可用"处理并缓存，
    /// 避免探测误判导致整个选摄列表被置灰、切换镜头按钮"点不动"。
    func canUseTogether(_ a: CameraOption, _ b: CameraOption) -> Bool {
        let key = [a.id, b.id].sorted().joined(separator: "|")
        lock.lock()
        let cached = cache[key]
        lock.unlock()
        if let cached { return cached }

        do {
            var result = false
            let inputA = try AVCaptureDeviceInput(device: a.device)
            let inputB = try AVCaptureDeviceInput(device: b.device)

            probeSession.beginConfiguration()
            if probeSession.canAddInput(inputA),
               probeSession.canAddInput(inputB) {
                probeSession.addInput(inputA)
                // 加入第一路后再探测第二路，最接近真实配置路径
                result = probeSession.canAddInput(inputB)
                probeSession.removeInput(inputA)
            }
            probeSession.commitConfiguration()

            lock.lock()
            cache[key] = result
            lock.unlock()
            return result
        } catch {
            // 探测异常（如设备繁忙/输入构造失败）→ 收尾会话配置后放行，
            // 交给运行期兜底，避免整个选摄列表被置灰、切换镜头按钮点不动。
            probeSession.commitConfiguration()
            lock.lock()
            cache[key] = true
            lock.unlock()
            return true
        }
    }

    /// 某台设备是否支持目标分辨率/帧率档位
    func supportsPreset(_ device: AVCaptureDevice, _ preset: ResolutionPreset) -> Bool {
        let dims = preset.landscapeDimensions
        return device.formats.contains { format in
            let fd = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return fd.width == dims.width && fd.height == dims.height
                && format.videoSupportedFrameRateRanges.contains { range in
                    range.minFrameRate <= Double(preset.fps) && Double(preset.fps) <= range.maxFrameRate
                }
        }
    }
}

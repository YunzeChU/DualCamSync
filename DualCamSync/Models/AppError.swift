import Foundation

/// 应用内错误枚举：每个错误都带有用户可读描述与"降级/处理"建议，
/// 用于需求第 10 条的异常容错与自动降级。
enum CameraError: LocalizedError {
    /// 设备不支持 AVCaptureMultiCamSession
    case multiCamUnsupported
    /// 找不到可用的摄像头/麦克风
    case captureDeviceUnavailable(String)
    /// 所选镜头组合不受硬件支持
    case comboUnsupported(String)
    /// 当前分辨率/帧率档位在所选镜头上不可用
    case presetUnsupported(ResolutionPreset)
    /// 杜比视界在当前位置不可用
    case dolbyUnavailable
    /// 权限被拒绝
    case permissionDenied
    /// 会话配置失败（附底层原因）
    case configurationFailed(String)
    /// 录制失败（附底层原因）
    case recordingFailed(String)

    var errorDescription: String? {
        switch self {
        case .multiCamUnsupported:
            return "设备不支持多摄像头同时采集 (AVCaptureMultiCamSession)"
        case .captureDeviceUnavailable(let name):
            return "无法使用相机：\(name)"
        case .comboUnsupported(let names):
            return "该镜头组合（\(names)）在当前设备上无法同时开启"
        case .presetUnsupported(let preset):
            return "所选镜头不支持 \(preset.displayName)"
        case .dolbyUnavailable:
            return "杜比视界在当前镜头组合/规格下不可用"
        case .permissionDenied:
            return "相机或麦克风权限被拒绝，请在设置中开启"
        case .configurationFailed(let detail):
            return "相机配置失败：\(detail)"
        case .recordingFailed(let detail):
            return "录制失败：\(detail)"
        }
    }

    /// 降级建议（UI 弹窗副标题）
    var recoverySuggestion: String? {
        switch self {
        case .multiCamUnsupported:
            return "请在支持多摄的设备上使用（iPhone XS/XR 及更新机型）"
        case .captureDeviceUnavailable:
            return "请检查设备摄像头是否可用"
        case .comboUnsupported:
            return "请重新选择镜头组合；不支持的组合已自动置灰"
        case .presetUnsupported:
            return "已自动切换到可用的较低规格"
        case .dolbyUnavailable:
            return "已自动关闭杜比视界"
        case .permissionDenied:
            return "请前往 设置 > 隐私 允许相机与麦克风访问"
        case .configurationFailed, .recordingFailed:
            return "请重试；若持续失败请重启应用"
        }
    }
}

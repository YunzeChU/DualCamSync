import AVFoundation
import Foundation

/// 录制分辨率/帧率档位（全局统一，两路摄像头同规格）
/// 注：4K60 档已移除——AVCaptureMultiCamSession 双路同时 4K60 会超出
/// 多摄会话带宽限制（Apple 官方能力矩阵不支持），实测不可用。
enum ResolutionPreset: String, CaseIterable, Identifiable {
    case uhd30 = "4K30"
    case hd60  = "1080P60"
    case hd30  = "1080P30"

    var id: String { rawValue }
    var displayName: String { rawValue }

    /// 目标帧率
    var fps: Int {
        switch self {
        case .uhd30: return 30
        case .hd60:  return 60
        case .hd30:  return 30
        }
    }

    /// 横屏（自然方向）下的基础分辨率，宽×高
    var landscapeDimensions: (width: Int32, height: Int32) {
        switch self {
        case .uhd30: return (3840, 2160)
        case .hd60, .hd30: return (1920, 1080)
        }
    }
}

/// 预览布局：上下/左右等分双屏 或 画中画
enum PreviewLayout: String, CaseIterable, Identifiable {
    case split            // 等分双屏
    case pictureInPicture // 画中画

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .split:            return "分屏"
        case .pictureInPicture: return "画中画"
        }
    }
    /// 设置面板/切换按钮用图标
    var systemImage: String {
        switch self {
        case .split:            return "rectangle.split.2x1"
        case .pictureInPicture: return "rectangle.inset.bottomright.filled"
        }
    }
}

/// 录制输出模式
enum RecordingMode: String, CaseIterable, Identifiable {
    case composite = "合成单条"  // 模式A：两路合成为一条 MP4（构图跟随预览布局）
    case dualFiles = "双独立文件" // 模式B：输出两条独立 MP4，同源时间戳对齐

    var id: String { rawValue }
    var displayName: String { rawValue }

    /// 模式说明（设置面板副标题）
    var detail: String {
        switch self {
        case .composite: return "两路画面实时合成为一条视频，带立体声音轨"
        case .dualFiles: return "两路各存一条 MP4，时间线同源对齐；支持空间音频"
        }
    }
}

/// 摄像头插槽（A 路 / B 路）
enum CameraSlot: String, CaseIterable, Identifiable {
    case a = "A"
    case b = "B"

    var id: String { rawValue }

    /// 与数组下标对应：0 = A，1 = B
    var index: Int {
        switch self {
        case .a: return 0
        case .b: return 1
        }
    }

    var displayName: String { rawValue }
}

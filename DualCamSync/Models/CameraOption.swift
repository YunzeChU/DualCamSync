import AVFoundation
import Foundation

/// 镜头类型（决定显示名与图标）
enum LensType: String, CaseIterable, Identifiable {
    case ultraWide   // 超广角（0.5x）
    case wide        // 广角（1x）
    case telephoto   // 长焦（2x/3x/5x）
    case front       // 前置

    var id: String { rawValue }

    /// 中文显示名（界面语言为中文优先）
    var displayName: String {
        switch self {
        case .ultraWide: return "超广角"
        case .wide:      return "广角"
        case .telephoto: return "长焦"
        case .front:     return "前置"
        }
    }

    /// SF Symbol 图标名，用于选摄面板/镜头角标
    var systemImage: String {
        switch self {
        case .ultraWide: return "circle.hexagongrid.fill"
        case .wide:      return "circle.fill"
        case .telephoto: return "circle.dashed"
        case .front:     return "person.crop.circle.fill"
        }
    }
}

/// 一路可选摄像头（对 AVCaptureDevice 的轻量包装，供 SwiftUI 使用）
struct CameraOption: Identifiable, Hashable {
    let device: AVCaptureDevice
    let position: AVCaptureDevice.Position
    let lensType: LensType

    /// 以设备 uniqueID 作为稳定标识（避免 AVCaptureDevice 引用参与 Hash）
    var id: String { device.uniqueID }

    /// 简短名称，如 "广角"
    var displayName: String { lensType.displayName }

    /// 完整名称，如 "后置 广角"
    var fullName: String {
        switch position {
        case .front: return "前置 \(lensType.displayName)"
        default:     return "后置 \(lensType.displayName)"
        }
    }

    var systemImage: String { lensType.systemImage }

    /// 由 AVCaptureDevice 解析为 CameraOption
    /// - 通过 deviceType + position 识别镜头类型：
    ///   - front 位置 → 前置
    ///   - 后置：超广角/广角/长焦按 deviceType 区分
    static func resolve(_ device: AVCaptureDevice) -> CameraOption {
        let position = device.position
        let type: LensType
        switch device.deviceType {
        case .builtInUltraWideCamera:      type = .ultraWide
        case .builtInTelephotoCamera:      type = .telephoto
        case .builtInWideAngleCamera where position == .front: type = .front
        default:                           type = .wide
        }
        return CameraOption(device: device, position: position, lensType: type)
    }
}

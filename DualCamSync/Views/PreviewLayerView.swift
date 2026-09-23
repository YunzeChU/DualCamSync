import AVFoundation
import SwiftUI

/// AVCaptureVideoPreviewLayer 的 SwiftUI 包装
/// -------------------------------------------------------------
/// 两路预览各自使用独立的预览层与连接（多摄会话必须手动建连，
/// 连接由 CameraManager 管理）；本视图只负责把 layer 放进视图层级、
/// 并跟随布局尺寸变化。
struct PreviewLayerView: UIViewRepresentable {

    /// 由 CameraManager 持有的预览层（生命周期归属 CameraManager）
    let layer: AVCaptureVideoPreviewLayer

    func makeUIView(context: Context) -> PreviewContainerView {
        let view = PreviewContainerView()
        layer.videoGravity = .resizeAspectFill
        view.previewLayer = layer
        return view
    }

    func updateUIView(_ uiView: PreviewContainerView, context: Context) {
        uiView.previewLayer = layer
    }

    static func dismantleUIView(_ uiView: PreviewContainerView, coordinator: ()) {
        uiView.previewLayer?.removeFromSuperlayer()
    }
}

/// 持有预览层的容器视图：在 layoutSubviews 中同步 layer 尺寸
final class PreviewContainerView: UIView {
    var previewLayer: AVCaptureVideoPreviewLayer? {
        didSet {
            guard let previewLayer else { return }
            if previewLayer.superlayer !== layer {
                layer.addSublayer(previewLayer)
            }
            previewLayer.frame = bounds
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer?.frame = bounds
    }
}

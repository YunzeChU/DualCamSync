import AVFoundation
import SwiftUI

/// AVCaptureVideoPreviewLayer 的 SwiftUI 包装
/// -------------------------------------------------------------
/// 两路预览各自使用独立的预览层与连接（多摄会话必须手动建连，
/// 连接由 CameraManager 管理）；本视图只负责把 layer 放进视图层级、
/// 并跟随布局尺寸变化。
///
/// 关键设计（修复"旋转/切换布局后黑屏"）：
///  1. 预览层由 CameraManager 共享持有，其生命周期不归属本视图；
///  2. dismantleUIView 必须为空——SwiftUI 在布局/旋转/切换结构时会
///     拆除旧容器并新建容器，若在拆除时 removeFromSuperlayer() 摘除
///     共享 layer，可能在新容器挂载前被移除，导致预览永久黑屏；
///  3. 容器 isUserInteractionEnabled = false：纯显示、不参与触摸，
///     杜绝预览视图拦截/抢占上方控件点击（修复"按键点不动/不灵敏"）。
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

    /// 注意：禁止在此摘除预览层。共享 layer 的挂载/移除统一由
    /// CameraManager 在配置阶段处理，本视图只负责"跟随哪个容器"。
    static func dismantleUIView(_ uiView: PreviewContainerView, coordinator: ()) {
        // 故意为空（见类注释第 2 条）
    }
}

/// 持有预览层的容器视图：在 layoutSubviews 中同步 layer 尺寸
final class PreviewContainerView: UIView {
    var previewLayer: AVCaptureVideoPreviewLayer? {
        didSet {
            guard let previewLayer else { return }
            previewLayer.videoGravity = .resizeAspectFill
            // 换层（CameraManager 每次会话重配都重建预览层，previewGeneration
            // 触发 SwiftUI 更新后走到这里）时先摘掉旧层——同一容器只挂当前预览层，
            // 避免旧层残留导致画面错乱/黑屏。
            if let old = oldValue, old !== previewLayer, old.superlayer === layer {
                old.removeFromSuperlayer()
            }
            if previewLayer.superlayer !== layer {
                layer.addSublayer(previewLayer)
            }
            previewLayer.frame = bounds
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        clipsToBounds = true
        // 纯显示容器：不拦截任何触摸，控件命中测试完全不受预览层影响
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 旋转/分屏切换时 frame 随布局更新；若已被旧容器拆除则重新挂载
        if let previewLayer, previewLayer.superlayer !== layer {
            layer.addSublayer(previewLayer)
        }
        previewLayer?.frame = bounds
    }
}

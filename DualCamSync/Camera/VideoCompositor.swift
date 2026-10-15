import CoreGraphics
import CoreImage
import CoreVideo
import Foundation

/// 双路画面实时合成器（Core Image 实现）
/// -------------------------------------------------------------
/// 输入：两路 BGRA CVPixelBuffer（方向已由连接层旋转好）
/// 输出：目标分辨率的 BGRA CVPixelBuffer，供 AVAssetWriter 像素适配器写入。
///
/// 支持两种构图：
///  - 等分分屏：竖屏上下等分 / 横屏左右等分（A 为主路，B 为副路）
///  - 画中画：A 全屏为底，B 悬浮于右下角
/// 所有镜头画面统一 aspect-fill 铺满目标区域（居中裁剪），与原生相机观感一致。
final class VideoCompositor {

    private let ciContext = CIContext(options: [CIContextOption.cacheIntermediates: false])
    private var pool: CVPixelBufferPool?
    private var poolWidth: Int32 = 0
    private var poolHeight: Int32 = 0

    /// 画中画小窗圆角遮罩缓存（尺寸+圆角固定，录制期间复用同一张，不逐帧生成）
    private var pipMaskCache: (key: String, mask: CIImage)?

    /// 合成一帧画面
    /// - Parameter pipCornerRadiusRatio: 成片小窗圆角半径比例
    ///   （= 预览小窗圆角 18pt / 预览小窗宽，由 CameraView 录制前写入）。
    ///   成片圆角 = 成片小窗宽 × ratio，保证与预览圆角视觉等比；传 0 表示不加圆角。
    func composite(frameA: CVPixelBuffer,
                   frameB: CVPixelBuffer,
                   layout: PreviewLayout,
                   landscape: Bool,
                   pipPosition: CGPoint,
                   pipCornerRadiusRatio: CGFloat,
                   outputWidth: Int32,
                   outputHeight: Int32) -> CVPixelBuffer? {
        let imageA = CIImage(cvPixelBuffer: frameA)
        let imageB = CIImage(cvPixelBuffer: frameB)
        let target = CGRect(x: 0, y: 0,
                            width: CGFloat(outputWidth),
                            height: CGFloat(outputHeight))

        let composed: CIImage
        switch layout {
        case .split:
            composed = makeSplit(a: imageA, b: imageB, landscape: landscape, target: target)
        case .pictureInPicture:
            composed = makePiP(main: imageA, pip: imageB, target: target,
                               pipPosition: pipPosition, cornerRadiusRatio: pipCornerRadiusRatio)
        }

        guard let output = poolPixelBuffer(width: outputWidth, height: outputHeight) else {
            return nil
        }
        // 渲染到像素缓冲（自动 GPU 加速）
        ciContext.render(composed, to: output, bounds: target,
                         colorSpace: CGColorSpaceCreateDeviceRGB())
        return output
    }

    // MARK: - 构图

    /// 等分双屏：竖屏 A上/B下，横屏 A左/B右
    private func makeSplit(a: CIImage, b: CIImage,
                           landscape: Bool, target: CGRect) -> CIImage {
        let half: CGRect
        let first: CGRect
        let second: CGRect
        if landscape {
            half = CGRect(x: 0, y: 0, width: target.width / 2, height: target.height)
            first = half
            second = CGRect(x: target.midX, y: 0, width: half.width, height: half.height)
        } else {
            half = CGRect(x: 0, y: 0, width: target.width, height: target.height / 2)
            // CIImage 坐标系原点在左下：y=midY 是画面上半、y=0 是下半。
            // 与预览一致：A 在上、B 在下（原实现 A 在下 B 在上，与预览
            // 上下颠倒——用户实测竖屏分屏合成视频与预览不一致）
            first = CGRect(x: 0, y: target.midY, width: half.width, height: half.height)
            second = half
        }
        let imageA = aspectFill(a, into: first)
        let imageB = aspectFill(b, into: second)
        return imageA.composited(over: imageB).cropped(to: target)
    }

    /// 画中画：主画面全屏，副画面悬浮小窗。
    /// 小窗宽度 = 目标宽 × 0.26、高度按目标画面比例——与预览小窗
    /// （CameraView.pipWindowSize：宽 = 屏宽 × 0.26、高按画面比例）一致，
    /// 满足需求"模式A合成时小窗大小与预览框一致"；B 路源画面
    /// aspectFill 铺满小窗即完成"上下内容裁切"。
    /// - Parameter pipPosition: 小窗中心相对目标画面的归一化位置
    ///   （0~1，y 从**顶部**算——与 SwiftUI 预览坐标一致；CIImage 原点在
    ///   左下，因此中心 y 需换算为 `(1 - y)`）。录制开始前由 CameraView
    ///   写入预览小窗实际位置，保证"成片小窗位置 = 录制开始时的预览位置"；
    ///   位置做了 clamp，保证小窗完整落在画面内。
    /// - Parameter cornerRadiusRatio: 小窗圆角半径比例（18 / 预览小窗宽）。
    ///   预览小窗是圆角矩形（SwiftUI `.clipShape(RoundedRectangle(18))`），
    ///   成片必须同样圆角才能"预览 = 成片"；Core Image 无路径裁剪，
    ///   用圆角 alpha 遮罩（CIBlendWithAlphaMask）实现。
    private func makePiP(main: CIImage, pip: CIImage, target: CGRect,
                         pipPosition: CGPoint, cornerRadiusRatio: CGFloat) -> CIImage {
        let mainImage = aspectFill(main, into: target)
        let subWidth = target.width * 0.26
        let subHeight = subWidth * (target.height / target.width)
        // 中心点（CIImage 坐标：y 从底部算）
        let centerX = target.width * min(max(pipPosition.x, 0), 1)
        let centerY = target.height * (1 - min(max(pipPosition.y, 0), 1))
        // 保证小窗完整可见（不越出画面边缘）
        let clampedX = min(max(centerX, subWidth / 2), target.width - subWidth / 2)
        let clampedY = min(max(centerY, subHeight / 2), target.height - subHeight / 2)
        let subRect = CGRect(x: clampedX - subWidth / 2,
                             y: clampedY - subHeight / 2,
                             width: subWidth,
                             height: subHeight)
        var pipImage = aspectFill(pip, into: subRect)
        // 圆角：与预览小窗视觉一致（半径按小窗宽度等比换算）
        if cornerRadiusRatio > 0 {
            let radius = subWidth * cornerRadiusRatio
            let mask = roundedRectMask(size: subRect.size, cornerRadius: radius)
            // 滤镜输入使用同一坐标系：把 mask（原点 0,0）平移到
            // pipImage.extent（= subRect）的原点，避免圆角错位
            let maskShifted = mask.transformed(by: CGAffineTransform(
                translationX: pipImage.extent.minX, y: pipImage.extent.minY))
            // 透明背景：圆角外区域显示它（透明 = 露出主画面）
            let clearBg = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0))
                .cropped(to: pipImage.extent)
            pipImage = pipImage.applyingFilter("CIBlendWithAlphaMask", parameters: [
                kCIInputBackgroundImageKey: clearBg,
                kCIInputMaskImageKey: maskShifted,
            ])
        }
        return pipImage.composited(over: mainImage).cropped(to: target)
    }

    /// 生成白色圆角矩形遮罩（黑底透明外，供 CIBlendWithAlphaMask 挖圆角）。
    /// 尺寸+圆角不变时复用缓存，避免每帧重画。
    private func roundedRectMask(size: CGSize, cornerRadius: CGFloat) -> CIImage {
        let width = max(Int(size.width.rounded(.up)), 1)
        let height = max(Int(size.height.rounded(.up)), 1)
        let radius = min(cornerRadius, CGFloat(min(width, height)) / 2)
        let key = "\(width)x\(height)-\(Int(radius.rounded()))"
        if let cache = pipMaskCache, cache.key == key {
            return cache.mask
        }
        var data = [UInt8](repeating: 0, count: width * height * 4)
        if let ctx = CGContext(data: &data, width: width, height: height,
                               bitsPerComponent: 8, bytesPerRow: width * 4,
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            let rect = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
            ctx.addPath(CGPath(roundedRect: rect,
                               cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.fillPath()
            if let cgImage = ctx.makeImage() {
                let mask = CIImage(cgImage: cgImage)
                pipMaskCache = (key, mask)
                return mask
            }
        }
        // 兜底：整块不透明（无圆角，功能仍可用）
        return CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 1))
            .cropped(to: CGRect(origin: .zero, size: size))
    }

    /// 将图片 aspect-fill 铺满目标矩形（缩放 + 居中裁剪）
    /// 修复：原先 cropRect 从 scaled 原点 (0,0) 开始裁，源画面宽高比
    /// 与目标不同时裁到左/下侧（不居中）。正确做法：超出目标尺寸的轴
    /// **两侧各裁一半**（居中），即先把 scaled 平移到目标矩形左上角对齐
    /// 后再"多退少补"，再裁到目标矩形。
    private func aspectFill(_ image: CIImage, into rect: CGRect) -> CIImage {
        guard image.extent.width > 0, image.extent.height > 0 else { return image }
        let scale = max(rect.width / image.extent.width,
                        rect.height / image.extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let sw = image.extent.width * scale
        let sh = image.extent.height * scale
        // 居中：超出目标尺寸的轴，两侧各裁一半（offset 为负表示往回收）
        let offsetX = rect.minX - (sw - rect.width) / 2
        let offsetY = rect.minY - (sh - rect.height) / 2
        let cropRect = CGRect(x: rect.minX, y: rect.minY,
                              width: rect.width, height: rect.height)
        return scaled
            .transformed(by: CGAffineTransform(translationX: offsetX, y: offsetY))
            .cropped(to: cropRect)
    }

    // MARK: - 输出缓冲池（避免每帧分配内存）

    private func poolPixelBuffer(width: Int32, height: Int32) -> CVPixelBuffer? {
        if pool == nil || poolWidth != width || poolHeight != height {
            pool = nil
            let attributes: [String: Any] = [
                kCVPixelBufferPoolMinimumBufferCountKey as String: 4,
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
            poolWidth = width
            poolHeight = height
        }
        guard let pool else { return nil }
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
        return pixelBuffer
    }
}

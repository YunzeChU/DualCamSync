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

    /// 合成一帧画面
    func composite(frameA: CVPixelBuffer,
                   frameB: CVPixelBuffer,
                   layout: PreviewLayout,
                   landscape: Bool,
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
            composed = makePiP(main: imageA, pip: imageB, target: target)
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
            // CIImage 坐标系原点在左下：first 在下方（A），second 在上方（B）
            first = half
            second = CGRect(x: 0, y: target.midY, width: half.width, height: half.height)
        }
        let imageA = aspectFill(a, into: first)
        let imageB = aspectFill(b, into: second)
        return imageA.composited(over: imageB).cropped(to: target)
    }

    /// 画中画：主画面全屏，副画面悬浮右下角（约占 1/3 边长）
    private func makePiP(main: CIImage, pip: CIImage, target: CGRect) -> CIImage {
        let mainImage = aspectFill(main, into: target)
        let margin: CGFloat = 24
        let subWidth = target.width / 3
        let subHeight = subWidth * (target.height / target.width)
        let subRect = CGRect(x: target.width - subWidth - margin,
                             y: margin,
                             width: subWidth,
                             height: subHeight)
        let pipImage = aspectFill(pip, into: subRect)
        return pipImage.composited(over: mainImage).cropped(to: target)
    }

    /// 将图片 aspect-fill 铺满目标矩形（缩放 + 居中裁剪）
    private func aspectFill(_ image: CIImage, into rect: CGRect) -> CIImage {
        guard image.extent.width > 0, image.extent.height > 0 else { return image }
        let scale = max(rect.width / image.extent.width,
                        rect.height / image.extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let cropRect = CGRect(x: rect.midX - rect.width / 2,
                              y: rect.midY - rect.height / 2,
                              width: rect.width,
                              height: rect.height)
        return scaled
            .transformed(by: CGAffineTransform(translationX: cropRect.minX, y: cropRect.minY))
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

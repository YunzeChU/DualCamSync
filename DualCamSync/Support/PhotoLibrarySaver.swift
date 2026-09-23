import Foundation
import Photos

/// 相册保存器
/// -------------------------------------------------------------
/// 只申请"写入"权限（NSPhotoLibraryAddUsageDescription，addOnly），
/// 不读取相册内容 —— 与需求"相册权限只申请写入权限"一致。
enum PhotoLibrarySaver {

    /// 将多个视频文件保存到系统相册
    /// - Parameters:
    ///   - urls: 本地视频文件路径（录制临时文件）
    ///   - completion: (保存成功的 URL 列表, 保存失败的 URL 列表)，主线程回调
    /// 返回"哪些成功/哪些失败"而非仅计数，调用方可据此只删除成功文件、
    /// 保留失败文件供用户手动找回（修复：保存失败后临时文件被误删）。
    static func saveVideos(at urls: [URL],
                           completion: @escaping (_ savedURLs: [URL], _ failedURLs: [URL]) -> Void) {
        guard !urls.isEmpty else {
            completion([], [])
            return
        }
        var savedURLs: [URL] = []
        var failedURLs: [URL] = []
        let counterQueue = DispatchQueue(label: "com.dualcamsync.photo-counter")

        let group = DispatchGroup()
        for url in urls {
            group.enter()
            PHPhotoLibrary.shared().performChanges({
                // 仅创建视频资产，不读取相册
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }) { success, _ in
                counterQueue.sync {
                    if success { savedURLs.append(url) } else { failedURLs.append(url) }
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let resultSaved = counterQueue.sync { savedURLs }
            let resultFailed = counterQueue.sync { failedURLs }
            completion(resultSaved, resultFailed)
        }
    }
}

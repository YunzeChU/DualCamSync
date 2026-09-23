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
    ///   - completion: (成功数, 失败数)，主线程回调
    static func saveVideos(at urls: [URL], completion: @escaping (Int, Int) -> Void) {
        guard !urls.isEmpty else {
            completion(0, 0)
            return
        }
        var saved = 0
        var failed = 0
        let counterQueue = DispatchQueue(label: "com.dualcamsync.photo-counter")

        let group = DispatchGroup()
        for url in urls {
            group.enter()
            PHPhotoLibrary.shared().performChanges({
                // 仅创建视频资产，不读取相册
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }) { success, _ in
                counterQueue.sync {
                    if success { saved += 1 } else { failed += 1 }
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let resultSaved = counterQueue.sync { saved }
            let resultFailed = counterQueue.sync { failed }
            completion(resultSaved, resultFailed)
        }
    }
}

import Foundation

/// 系统状态监控：设备温度（thermalState）与内存压力
/// -------------------------------------------------------------
/// 需求 10 的"设备高温 / 内存过高"异常容错：
///   - 温度 serious  -> 提示；critical -> 自动停止录制
///   - 内存 warning  -> 自动降级到 1080P30；critical -> 自动停止录制
/// 降级/停止动作由 CameraManager 根据回调执行。
final class SystemMonitor {

    enum Level: Equatable {
        case normal
        case warning
        case critical
    }

    private(set) var thermalLevel: Level = .normal
    private(set) var memoryLevel: Level = .normal

    /// 温度变化回调（主线程）
    var onThermalChange: ((Level) -> Void)?
    /// 内存压力回调（主线程）
    var onMemoryChange: ((Level) -> Void)?

    private var memorySource: DispatchSourceMemoryPressure?

    /// 开始监听（应用启动后调用一次）
    func start() {
        // 温度监听：系统通知 + 初始值
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(thermalStateChanged),
                                               name: ProcessInfo.thermalStateDidChangeNotification,
                                               object: nil)
        thermalStateChanged()

        // 内存压力监听：warning / critical 两个档位
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical],
                                                             queue: .main)
        source.setEventHandler { [weak self] in
            self?.memoryPressureChanged()
        }
        source.resume()
        memorySource = source
    }

    func stop() {
        memorySource?.cancel()
        memorySource = nil
        NotificationCenter.default.removeObserver(self,
                                                  name: ProcessInfo.thermalStateDidChangeNotification,
                                                  object: nil)
    }

    // MARK: - 温度

    @objc private func thermalStateChanged() {
        let state = ProcessInfo.processInfo.thermalState
        let level: Level
        switch state {
        case .nominal, .fair:
            level = .normal
        case .serious:
            level = .warning
        case .critical:
            level = .critical
        @unknown default:
            level = .normal
        }
        guard level != thermalLevel else { return }
        thermalLevel = level
        onThermalChange?(level)
    }

    // MARK: - 内存

    private func memoryPressureChanged() {
        guard let source = memorySource else { return }
        let data = source.data
        let level: Level
        if data.contains(.critical) {
            level = .critical
        } else if data.contains(.warning) {
            level = .warning
        } else {
            level = .normal
        }
        guard level != memoryLevel else { return }
        memoryLevel = level
        onMemoryChange?(level)
    }
}

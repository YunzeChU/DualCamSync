# DualCamSync

iOS 原生双摄像头同时录制 App（SwiftUI + `AVCaptureMultiCamSession` + iOS 26 Liquid Glass 液态玻璃）。

> 最低部署版本 **iOS 26**，使用 **Xcode 26** 编译；玻璃控件使用原生 `.glassEffect()` 液态玻璃材质（禁止模拟磨砂）。

[![iOS](https://img.shields.io/badge/iOS-26.0-black)]()
[![Swift](https://img.shields.io/badge/Swift-5.0-orange)]()
[![CI](https://github.com/YunzeChU/DualCamSync/actions/workflows/build-ipa.yml/badge.svg)](https://github.com/YunzeChU/DualCamSync/actions)
[![AI](https://img.shields.io/badge/AI-Developed-6a5acd)]()
[![License](https://img.shields.io/badge/License-MIT-green)](LICENSE)

---

## 功能一览

| 功能 | 说明 |
|---|---|
| 任意双镜头组合 | 广角+超广角、广角+长焦、前置+后置…均可，运行时探测硬件能力，不支持的组合自动置灰 |
| 双路实时预览 | 分屏（竖屏上下/横屏左右）/ 画中画（主全屏+副窗），一键切换；**PIP 小窗可拖动**、默认位置在左上角（竖屏顶 60/左 16，横屏顶 24/左 24） |
| 每路独立控制 | 对焦锁定、曝光锁定、曝光补偿滑块（A/B 两路独立，互不影响） |
| 分辨率/帧率 | 4K30 / 1080P60 / 1080P30，全局统一，不支持档位自动置灰并自动降级（4K60 档已移除：多摄双路 4K60 超出带宽限制） |
| 杜比视界 | 能力探测 + 双条件判据（10-bit 采集格式 + dvhe 编码器），不支持自动置灰禁用，并带防闪退安全阀（多摄会话不提供 10-bit 采集格式，当前所有镜头组合均不可用，见"已知限制"） |
| 视频防抖 | A/B 两路分别开启/关闭 |
| 空间音频 | 双文件模式原生支持（First Order Ambisonics + 立体声兼容轨），自动能力探测 |
| 录制模式 A | 两路合成为**单条 MP4**（构图跟随录制前预览布局：**成片小窗位置 = 录制开始时的预览位置，拍后固定；小窗圆角与预览一致**），HEVC + 立体声 AAC |
| 录制模式 B | 输出**两条独立 MP4**，同一会话时钟、同一时刻启动，时间戳同源帧级对齐 |
| 自动保存 | 录制结束自动存入系统相册（仅申请写入权限） |
| 拍摄地点 | 开关打开时把拍摄地点写入视频元数据（仅保存在本地相册，不上传；未授权定位则不写入） |
| 方向系统 | 横竖屏不锁、录制中锁方向（OrientationLockView）；后置用系统标准角度映射、前置独立映射（iPhone 前置传感器竖装），旋转后画面始终正向 |
| 异常容错 | 不支持多摄/组合/规格/杜比、权限拒绝、内存压力、设备高温 → 弹窗提示 + 自动降级 + 置灰 |

---

## 目录结构

```
DualCamSync/
├── project.yml                        # XcodeGen 工程定义（唯一事实来源）
├── .github/workflows/build-ipa.yml    # GitHub Actions：云端 Xcode 26 编译出 IPA
├── scripts/make_icon.py               # App 图标生成脚本（纯 Python，可重跑）
└── DualCamSync/
    ├── App/                           # 应用入口
    ├── Models/                        # CameraOption / 分辨率档位 / 错误枚举
    ├── Camera/                        # 核心相机层
    │   ├── CameraManager.swift        #   双摄会话管理器（配置/预览/对焦曝光/容错）
    │   ├── CameraPairProbe.swift      #   双摄组合与规格能力探测（置灰依据）
    │   ├── ModeBRecorder.swift        #   模式B：双文件（MovieFileOutput）
    │   ├── ModeARecorder.swift        #   模式A：合成单条（AVAssetWriter）
    │   └── VideoCompositor.swift      #   CI 实时合成器（分屏/PiP）
    ├── Views/                         # SwiftUI 界面
    │   ├── CameraView.swift           #   主界面 + 横竖屏自适应布局
    │   ├── ControlBar.swift           #   快门/功能键/设置键（玻璃按钮）
    │   ├── FunctionPanel.swift        #   功能面板（镜头/布局/模式/分辨率）
    │   ├── SettingsPanel.swift        #   设置面板
    │   ├── Glass.swift                #   .glassEffect() 统一修饰器
    │   ├── OrientationLockView.swift  #   录制中锁界面方向
    │   └── PreviewLayerView.swift     #   预览层包装（纯显示，不拦截触摸）
    ├── Support/                       # 系统监控 / 相册保存 / 方向锁
    └── Resources/Info.plist           # 权限描述文本等
```

---

## 构建（本地）

需要 macOS + Xcode 26（含 iOS 26 SDK）+ XcodeGen：

```bash
brew install xcodegen      # 首次
xcodegen generate          # 生成 DualCamSync.xcodeproj
open DualCamSync.xcodeproj
```

> 工程默认**不做代码签名**（个人真机测试走爱思助手签名，见下）。
> 若你想在 Xcode 里用自己的免费/付费团队直接跑真机：
> 在 Signing & Capabilities 勾选自动签名即可（本工程不需要任何 entitlement）。

---

## 云端编译出 IPA（GitHub Actions）

1. 把本目录推到 GitHub 仓库的 `main` 分支（或手动触发 Actions）。
2. Actions 使用官方 `macos-26` runner（预装 Xcode 26），执行：
   `xcodegen generate` → `xcodebuild ... CODE_SIGNING_ALLOWED=NO build` → 打包 `DualCamSync.ipa`。
3. 在 Actions 运行页的 Artifacts 里下载 `DualCamSync-unsigned-ipa`。

### 爱思助手签名安装（个人免费签名）

1. 下载 IPA 到电脑，打开爱思助手并连接 iPhone（需 iOS 26 及以上）。
2. 进入「应用游戏 → 导入安装」选择该 IPA。
3. 按提示登录 Apple ID，自动完成免费签名与安装。
4. **免费签名有效期 7 天**，到期后用爱思助手重新导入安装一次即可（App 内数据会保留）。
5. 首次打开如提示"未受信任的开发者"：设置 → 通用 → VPN与设备管理 → 信任该开发者。

> 若以后购买企业/个人签名证书，把证书在爱思助手里切换签名方式即可，工程无需改动。

---

## 关键实现说明

### 双摄会话
- 使用 `AVCaptureMultiCamSession`，两路 `AVCaptureDeviceInput` 在会话内逐设备配置 `activeFormat`（档位全局统一，两路同规格）。
- 预览层用 `AVCaptureVideoPreviewLayer(sessionWithNoConnection:)` + **手动** `addConnection`（多摄会话禁止自动建连）。
- 镜头组合是否支持由 `CameraPairProbe` 用独立会话做 `canAddInput` 探测并缓存，选摄面板据此置灰。

### 时间戳对齐（模式B）
- 两个 `AVCaptureMovieFileOutput` 在**同一瞬间** `startRecording`，共享同一会话时钟 → 两文件起点一致、逐帧对齐；每文件内音视频混流由 AVFoundation 内部完成，天然不漂移。

### 音画同步（模式A）
- `AVCaptureMultiCamSession` 把所有设备时钟同步到 `masterClock`，各路样本 PTS 处于同一时间基准，写入 `AVAssetWriter` 即帧级对齐；首样本时间作为 `startSession(atSourceTime:)` 起点。

### 空间音频 / 立体声
- 双文件模式：`audioInput.multichannelAudioMode = .firstOrderAmbisonics`（需 `isMultichannelAudioModeSupported` 探测），MovieFileOutput 自动写出「空间音频轨 + 立体声兼容轨」。
- 合成模式：以真实采集声道数动态创建 AAC 输入（双声道立体声优先），保证写入不失败。

### 液态玻璃
- 玻璃控件经 `Views/Glass.swift` 的 `.glassEffect(.regular)` + 大圆角实现，底层双摄画面实时透过玻璃动态模糊折射；菜单弹出/收起使用 `.spring` 弹簧动画。
- **面板不套玻璃底**：真机验证 `glassEffect` 背景在面板容器上渲染为胶囊形、`clipShape` 无法裁成圆角矩形，因此 `glassPanel` 不添加背景、也不用任何替代材质，面板内容直接浮在预览画面上。
- 玻璃键命中修复：`glassEffect` 的 UIKit 命中层（UIGlassEffectView）在 body 重算后可能不同步，导致按钮收不到触摸；`GlassIconButton` 采用**玻璃装饰与命中载体分离**（玻璃圆纯装饰 `.allowsHitTesting(false)`，普通 Button 承担命中）。

### UI 刷新通道（iOS 26.6.1 真机实测）
- 普通 `@State` 变化在初始态不触发子树重算（面板打不开、小窗拖不动，第一次点录制键才"一次性补上"）；`@State` 包装的 `@Observable` 属性变化可靠触发刷新。
- 因此面板开关与小窗位置等 UI 状态全部迁入 `@Observable CameraUIState`，走与 `CameraManager` 相同的可靠刷新通道。

### 方向系统
- 后置摄像头横屏角度用系统标准映射（`landscapeLeft=180`、`landscapeRight=0`）；前置传感器竖装，用独立映射表（`portrait=0 / 倒置=180 / landscapeLeft=270 / landscapeRight=90`），不从此后置派生。
- 录制中通过 `OrientationLockView` 锁住开始方向，停止后恢复；旋转后用 `geo.size` 变化 + 延迟方向通知双重兜底同步。

### 镜头枚举
- 前置镜头（iPhone 17 系列以多个虚拟设备暴露：TrueDepth / WideAngle）在 UI 上**只保留一个"前置"选项**，后置按"位置+镜头类型"去重。

---

## 已知限制（符合预期，非缺陷）

| 项 | 说明 |
|---|---|
| 杜比视界 | **多摄会话（`AVCaptureMultiCamSession`）不提供 10-bit HDR 采集格式**，所有镜头组合均不可用，选项自动置灰（含防闪退安全阀：编码器不支持 dvhe 时静默回退 HEVC） |
| 空间音频 | 仅双文件模式（MovieFileOutput 原生支持）；合成模式固定立体声 |
| 免费签名 | 7 天有效期，到期重签；两台设备共用同一 Apple ID 签名会互相顶掉，请保持单一设备 |

---

## 后续迭代建议

- [x] 画中画副窗口可拖动（位置记忆 + 越界 clamp + 录制中固定）
- [ ] 画中画副窗口缩放
- [ ] 合成模式接入 iOS 26 的 FOA 空间音频（2×AudioDataOutput + `AVCaptureSpatialAudioMetadataSampleGenerator`）
- [ ] 录制中实时波形/电平表
- [ ] 手动 ISO / 快门优先
- [ ] 拍摄后预览页（原生相机"照片角落缩略图"）

# DualCamSync 结项记录

## 冻结产品基线

- 产品提交：`49f0ac5`。
- 构建：[CI 43023968187](https://github.com/YunzeChU/DualCamSync/actions/runs/43023968187)，41 项 XCTest、设备 Release 构建和 IPA 打包通过。
- 交付 artifact：[DualCamSync-unsigned-ipa 13856596856](https://github.com/YunzeChU/DualCamSync/actions/runs/43023968187/artifacts/13856596856)。
- 安装时以 IPA 同包 `build-provenance.json` 与应用启动 revision 日志核对实际 commit、run ID 和 build。

本文档及同批 README/VERIFICATION 更新只整理结项说明，不变更冻结的产品代码。后续文档提交的 SHA 与 CI 不应被误记为新的产品验收基线。

## 用户确认的范围

- 当前实测范围内，HDR 成片正常，使用 HEVC 编码。
- 连续录制的计时器从 `00:00` 开始，停止后不会残留上一段时长。
- 合成单条视频尾部约 1 秒的差异被用户接受为当前产品边界，本次结项不再继续修复。该接受不表示尾部差异已消除，也不表示各镜头、档位和压力条件下逐帧完整。
- HDR/HEVC 证据不等同于已验证 Dolby Vision 动态元数据。若要作 Dolby Vision 文件级声明，必须检查对应原片的配置记录和动态元数据。

## 结项后维护项

以下事项未在本次结项中修复或验证，不应写作已完成：

- 内存 warning 收尾时的档位状态一致性。
- 保存失败后的恢复路径。
- 极短录制未生成文件时的用户提示。
- 模式 B 异常结束、长时间漂移与文件级逐帧对齐覆盖。

这些事项属于后续维护范围；若重新启动开发，应以新的问题记录、提交、CI 和真机证据单独验收。

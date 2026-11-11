import XCTest
import UIKit
import CoreMedia
import CoreVideo
@testable import DualCamSync

final class CameraLogicTests: XCTestCase {

    func testStoppingEitherRecordingModeClearsElapsedBeforeFinalizing() {
        for mode in [RecordingMode.composite, .dualFiles] {
            let camera = CameraManager()
            camera.mode = mode
            camera.isRecording = true
            camera.recordingElapsed = 12.3

            camera.stopRecording()

            XCTAssertEqual(camera.recordingElapsed, 0)
            XCTAssertFalse(camera.isRecording)
            XCTAssertTrue(camera.isFinalizing)
        }
    }

    func testStoppingDuringCompositeStartupClearsElapsedWithoutWriterCallback() {
        let camera = CameraManager()
        camera.mode = .composite
        camera.isRecording = true
        camera.isStarting = true
        camera.recordingElapsed = 8.1

        camera.stopRecording()

        XCTAssertEqual(camera.recordingElapsed, 0)
        XCTAssertFalse(camera.isStarting)
    }

    func testIdleRecordingAttemptClearsPreviousElapsedEvenWhenUnavailable() {
        let camera = CameraManager()
        camera.isMultiCamSupported = false
        camera.recordingElapsed = 21

        camera.startRecording()

        XCTAssertEqual(camera.recordingElapsed, 0)
        XCTAssertFalse(camera.isRecording)
    }

    func testDuplicateStartDoesNotResetCurrentRecordingTimer() {
        let camera = CameraManager()
        camera.isRecording = true
        camera.recordingElapsed = 4.2

        camera.startRecording()

        XCTAssertEqual(camera.recordingElapsed, 4.2)
        XCTAssertTrue(camera.isRecording)
    }

    // MARK: - 方向映射（后置标准映射 / 前置独立映射，防横屏 180° 复发）

    func testRearPortraitAngle() {
        XCTAssertEqual(CameraManager.rotationAngle(for: .portrait), 90)
    }

    func testRearUpsideDownAngle() {
        XCTAssertEqual(CameraManager.rotationAngle(for: .portraitUpsideDown), 270)
    }

    func testRearLandscapeLeftAngle() {
        XCTAssertEqual(CameraManager.rotationAngle(for: .landscapeLeft), 180)
    }

    func testRearLandscapeRightAngle() {
        XCTAssertEqual(CameraManager.rotationAngle(for: .landscapeRight), 0)
    }

    func testFrontPortraitAngle() {
        XCTAssertEqual(CameraManager.rotationAngle(for: .portrait, isFront: true), 0)
    }

    func testFrontUpsideDownAngle() {
        XCTAssertEqual(CameraManager.rotationAngle(for: .portraitUpsideDown, isFront: true), 180)
    }

    func testFrontLandscapeLeftAngle() {
        XCTAssertEqual(CameraManager.rotationAngle(for: .landscapeLeft, isFront: true), 270)
    }

    func testFrontLandscapeRightAngle() {
        XCTAssertEqual(CameraManager.rotationAngle(for: .landscapeRight, isFront: true), 90)
    }

    // MARK: - 分辨率档位定义

    func testPresetDisplayNameAndFPS() {
        XCTAssertEqual(ResolutionPreset.uhd30.displayName, "4K")
        XCTAssertEqual(ResolutionPreset.hd60.displayName, "1080P")
        XCTAssertEqual(ResolutionPreset.hd60.frameRateText, "60 FPS")
        XCTAssertEqual(ResolutionPreset.hd30.fps, 30)
    }

    func testPresetLandscapeDimensions() {
        let uhd = ResolutionPreset.uhd30.landscapeDimensions
        XCTAssertEqual(uhd.width, 3840)
        XCTAssertEqual(uhd.height, 2160)
        let hd = ResolutionPreset.hd30.landscapeDimensions
        XCTAssertEqual(hd.width, 1920)
        XCTAssertEqual(hd.height, 1080)
    }

    // MARK: - 档位降级（与 ensurePresetSupported 同源逻辑的纯函数化）

    func testBestAvailablePresetPrefersHighest() {
        let supports: (ResolutionPreset) -> Bool = { _ in true }
        XCTAssertEqual(ResolutionPreset.bestAvailablePreset(supports: supports), .uhd30)
    }

    func testBestAvailablePresetSkipsUnavailable4K() {
        let supports: (ResolutionPreset) -> Bool = { $0 != .uhd30 }
        XCTAssertEqual(ResolutionPreset.bestAvailablePreset(supports: supports), .hd60)
    }

    func testBestAvailablePresetFallsBackToLowest() {
        let supports: (ResolutionPreset) -> Bool = { $0 == .hd30 }
        XCTAssertEqual(ResolutionPreset.bestAvailablePreset(supports: supports), .hd30)
    }

    func testBestAvailablePresetReturnsNilWhenNoneSupported() {
        let supports: (ResolutionPreset) -> Bool = { _ in false }
        XCTAssertNil(ResolutionPreset.bestAvailablePreset(supports: supports))
    }

    // MARK: - HDR output policy

    func testCompositeP010SelectionAcceptsBothRangesAndRejectsSDR() {
        let videoRange = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        let fullRange = kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        XCTAssertEqual(CameraManager.preferredP010Format(in: [fullRange]), fullRange)
        XCTAssertEqual(CameraManager.preferredP010Format(in: [fullRange, videoRange]), videoRange)
        XCTAssertNil(CameraManager.preferredP010Format(in: [kCVPixelFormatType_32BGRA]))
        XCTAssertNil(CameraManager.preferredP010Format(in: []))
    }

    func testMovieCodecDiagnosticIncludesAvailabilityAndEffectiveSetting() {
        let diagnostic = CameraManager.movieCodecDiagnostic([
            .init(slot: .a, availableCodecs: ["hvc1", "ap4h"],
                  effectiveCodec: "ap4h", hasOutputSettings: true,
                  outputSettingKeys: ["AVVideoCodecKey"], acceptsCodecSetting: true),
            .init(slot: .b, availableCodecs: ["hvc1"],
                  effectiveCodec: nil, hasOutputSettings: false,
                  outputSettingKeys: [], acceptsCodecSetting: false),
        ], label: "当前")
        XCTAssertTrue(diagnostic.contains("A{可用=hvc1,ap4h"))
        XCTAssertTrue(diagnostic.contains("当前=ap4h"))
        XCTAssertTrue(diagnostic.contains("B{可用=hvc1"))
        XCTAssertTrue(diagnostic.contains("当前=系统未声明"))
        XCTAssertTrue(diagnostic.contains("codecKey=否"))
    }

    func testMovieHDRSubtypePolicyRejectsProResAndPrefersX420() {
        let proRes422HQ: FourCharCode = 0x61706368 // apch
        let x422: FourCharCode = 0x78343232
        let x420: FourCharCode = 0x78343230
        XCTAssertFalse(CameraManager.isMovieHDRSubtypeEligible(proRes422HQ))
        XCTAssertFalse(CameraManager.isMovieHDRSubtypeEligible(x422))
        XCTAssertTrue(CameraManager.isMovieHDRSubtypeEligible(x420))
        XCTAssertLessThan(CameraManager.movieHDRSubtypePriority(x420),
                          CameraManager.movieHDRSubtypePriority(0x34323076))
    }

    // MARK: - 双路 HDR 能力与 SDR 回退诊断

    func testHLGFormatsRemainEligibleWithoutLegacyVideoHDRFlag() {
        let result = CameraManager.assessHDRCapability(
            preset: .hd30, mode: .dualFiles,
            formatsA: [hdrFormat(width: 1920, height: 1080, hdr: false)],
            formatsB: [hdrFormat(width: 1920, height: 1080, hdr: false)]
        )
        XCTAssertTrue(result.isAvailable)
    }

    private func hdrFormat(width: Int32 = 3840, height: Int32 = 2160,
                           minFPS: Double = 24, maxFPS: Double = 30,
                           multiCam: Bool = true, hdr: Bool = true,
                           hlg: Bool = true) -> CameraManager.HDRFormatCapability {
        .init(width: width, height: height, minimumFPS: minFPS, maximumFPS: maxFPS,
              supportsMultiCam: multiCam, supportsVideoHDR: hdr,
              supportsHLGBT2020: hlg)
    }

    func testHDRCapabilityRequiresBothRoutesToMatchPresetAndHLG() {
        let supported = hdrFormat()
        let result = CameraManager.assessHDRCapability(
            preset: .uhd30, mode: .dualFiles,
            formatsA: [supported], formatsB: [hdrFormat(hlg: false)]
        )
        XCTAssertEqual(result.reason, .noHLGBT2020(.b))
        XCTAssertFalse(result.isAvailable)
        XCTAssertTrue(result.sdrFallbackReason.contains("B 路"))
    }

    func testHDRCapabilityReportsRequestedFrameRateBeforeHDR() {
        let result = CameraManager.assessHDRCapability(
            preset: .hd60, mode: .dualFiles,
            formatsA: [hdrFormat(width: 1920, height: 1080, maxFPS: 30)],
            formatsB: [hdrFormat(width: 1920, height: 1080, minFPS: 60, maxFPS: 60)]
        )
        XCTAssertEqual(result.reason, .noRequestedFormat(.a))
    }

    func testCompositeHDRCapabilityRequiresP010FromBothOutputs() {
        let supported = hdrFormat()
        let result = CameraManager.assessHDRCapability(
            preset: .uhd30, mode: .composite,
            formatsA: [supported], formatsB: [supported],
            compositeP010Support: [true, false]
        )
        XCTAssertEqual(result.reason, .noP010Output(.b))
        XCTAssertFalse(result.isAvailable)
    }

    func testDualFileHDRCapabilityDoesNotRequireP010DataOutput() {
        let supported = hdrFormat()
        let result = CameraManager.assessHDRCapability(
            preset: .uhd30, mode: .dualFiles,
            formatsA: [supported], formatsB: [supported]
        )
        XCTAssertEqual(result.reason, .ready)
        XCTAssertTrue(result.isAvailable)
    }

    // MARK: - 错误文案（防 UI 提示被改丢）

    func testErrorMessagesAreMeaningful() {
        let errors: [CameraError] = [
            .multiCamUnsupported,
            .permissionDenied,
            .comboUnsupported("广角+长焦"),
            .presetUnsupported(.uhd30),
            .dolbyUnavailable,
            .configurationFailed("detail"),
            .recordingFailed("detail"),
            .captureDeviceUnavailable("camera")
        ]
        for error in errors {
            XCTAssertFalse((error.errorDescription ?? "").isEmpty, "\(error) 缺少错误描述")
            XCTAssertFalse((error.recoverySuggestion ?? "").isEmpty, "\(error) 缺少降级建议")
        }
    }
}

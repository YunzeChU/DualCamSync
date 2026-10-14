import XCTest
import UIKit
@testable import DualCamSync

final class CameraLogicTests: XCTestCase {

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

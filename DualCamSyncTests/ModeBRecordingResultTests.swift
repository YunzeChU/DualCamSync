import AVFoundation
import XCTest
@testable import DualCamSync

final class ModeBRecordingResultTests: XCTestCase {
    func testNoErrorIsSuccessful() {
        XCTAssertTrue(ModeBRecorder.recordingSucceeded(error: nil))
    }

    func testFrameworkErrorMayStillRepresentUsableMovie() {
        let error = NSError(domain: AVFoundationErrorDomain, code: -11807,
                            userInfo: [AVErrorRecordingSuccessfullyFinishedKey: NSNumber(value: true)])
        XCTAssertTrue(ModeBRecorder.recordingSucceeded(error: error))
    }

    func testUnmarkedAndExplicitFailureAreNotSuccessful() {
        XCTAssertFalse(ModeBRecorder.recordingSucceeded(
            error: NSError(domain: AVFoundationErrorDomain, code: -11800)))
        XCTAssertFalse(ModeBRecorder.recordingSucceeded(
            error: NSError(domain: AVFoundationErrorDomain, code: -11800,
                           userInfo: [AVErrorRecordingSuccessfullyFinishedKey: NSNumber(value: false)])))
    }
}

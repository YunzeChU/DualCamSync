import CoreVideo
import XCTest
@testable import DualCamSync

final class ModeARecorderTests: XCTestCase {
    private func startEmpty(_ recorder: ModeARecorder) throws {
        try recorder.start(outputSize: (16, 16), layout: .split, audioFormat: nil,
                           pipPosition: .zero, pipCornerRadiusRatio: 0, hdr: false)
    }

    func testStopWithoutFramesCompletesOnceAndAllowsRestart() throws {
        let recorder = ModeARecorder()
        let first = expectation(description: "first empty recording")
        first.assertForOverFulfill = true
        recorder.onFinished = { urls in
            XCTAssertTrue(urls.isEmpty)
            first.fulfill()
        }
        try startEmpty(recorder)
        recorder.stop()
        recorder.stop()
        wait(for: [first], timeout: 2)
        let second = expectation(description: "second empty recording")
        recorder.onFinished = { _ in second.fulfill() }
        try startEmpty(recorder)
        recorder.stop()
        wait(for: [second], timeout: 2)
    }

    func testStopWaitsForInFlightCaptureCallbacksBeforeFinalizing() throws {
        let recorder = ModeARecorder()
        let completed = expectation(description: "empty recording finalizes after input quiescence")
        let startedAt = Date()
        recorder.onFinished = { _ in
            // A callback can be handed off by AVCapture immediately after its connection is
            // disabled. The recorder must leave a bounded window for it rather than finish
            // the writer at the stop marker.
            XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(startedAt), 0.10)
            completed.fulfill()
        }
        try startEmpty(recorder)
        recorder.stop()
        wait(for: [completed], timeout: 2)
    }

    func testAbortBeforeFirstFrameReportsOnceAndAllowsRestart() throws {
        let recorder = ModeARecorder()
        let failed = expectation(description: "one error")
        failed.assertForOverFulfill = true
        recorder.onError = { _ in failed.fulfill() }
        try startEmpty(recorder)
        recorder.abort(error: CameraError.recordingFailed("injected failure"))
        recorder.abort(error: CameraError.recordingFailed("duplicate failure"))
        wait(for: [failed], timeout: 2)
        let finished = expectation(description: "restart")
        recorder.onFinished = { _ in finished.fulfill() }
        try startEmpty(recorder)
        recorder.stop()
        wait(for: [finished], timeout: 2)
    }

    func testPairingToleratesEitherArrivalOrder() {
        XCTAssertEqual(ModeARecorder.pairingDecision(a: 2, b: 2.033), .pair)
        XCTAssertEqual(ModeARecorder.pairingDecision(a: 2.033, b: 2), .pair)
    }

    func testOutOfWindowDiscardsOnlyOlderSource() {
        XCTAssertEqual(ModeARecorder.pairingDecision(a: 2, b: 2.2), .discardA)
        XCTAssertEqual(ModeARecorder.pairingDecision(a: 2.2, b: 2), .discardB)
        XCTAssertEqual(ModeARecorder.pairingDecision(a: 0, b: 0.1), .discardA)
    }

    func testAllSampleCallbacksShareWriterExecutionDomain() {
        let recorder = ModeARecorder()
        XCTAssertTrue(recorder.videoQueueA === recorder.videoQueueB)
        XCTAssertTrue(recorder.videoQueueA === recorder.audioQueue)
    }

    func testHDRValidationAcceptsOnlyP010InputFormats() {
        XCTAssertEqual(ModeARecorder.validateHDRInputPixelFormat(
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange), .p010)
        XCTAssertEqual(ModeARecorder.validateHDRInputPixelFormat(
            kCVPixelFormatType_420YpCbCr10BiPlanarFullRange), .p010)
        XCTAssertEqual(ModeARecorder.validateHDRInputPixelFormat(
            kCVPixelFormatType_32BGRA), .unexpectedPixelFormat(kCVPixelFormatType_32BGRA))
    }

    func testHDRPixelFormatDiagnosticIncludesFourCCAndHexValue() {
        let diagnostic = ModeARecorder.pixelFormatDiagnostic(kCVPixelFormatType_32BGRA)
        XCTAssertTrue(diagnostic.contains("BGRA"))
        XCTAssertTrue(diagnostic.contains("0x"))
    }

    func testDroppedFrameReasonUsesSystemReasonOrClearUnknownFallback() {
        XCTAssertEqual(ModeARecorder.droppedFrameReasonDescription("lateFrame"), "lateFrame")
        XCTAssertEqual(ModeARecorder.droppedFrameReasonDescription(nil), "unknown")
    }
}

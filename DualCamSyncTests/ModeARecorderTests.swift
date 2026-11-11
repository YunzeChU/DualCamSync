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
        // Reuse the same recorder through repeated startup aborts. Framework
        // teardown of an unused writer must not delay its terminal callback or
        // leave a pending abort that terminates the next recording.
        for attempt in 0..<3 {
            let failed = expectation(description: "one startup error \(attempt)")
            failed.assertForOverFulfill = true
            recorder.onError = { _ in failed.fulfill() }
            try startEmpty(recorder)
            recorder.abort(error: CameraError.recordingFailed("injected failure"))
            recorder.abort(error: CameraError.recordingFailed("duplicate failure"))
            wait(for: [failed], timeout: 2)
            let finished = expectation(description: "restart \(attempt)")
            finished.assertForOverFulfill = true
            recorder.onFinished = { urls in
                XCTAssertTrue(urls.isEmpty)
                finished.fulfill()
            }
            try startEmpty(recorder)
            recorder.stop()
            wait(for: [finished], timeout: 2)
        }
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

    func testVideoCaptureCallbacksAreIsolatedFromWriterDomain() {
        let recorder = ModeARecorder()
        XCTAssertFalse(recorder.videoQueueA === recorder.videoQueueB)
        XCTAssertFalse(recorder.videoQueueA === recorder.audioQueue)
        XCTAssertFalse(recorder.videoQueueB === recorder.audioQueue)
    }

    func testOverloadedVideoHandoffRetainsNewestValueAndReleasesOldBuffer() {
        var handoff = ModeARecorder.LatestVideoValue<NSObject>()
        var first: NSObject? = NSObject()
        weak var oldBuffer = first
        handoff.offer(first!)
        first = nil
        XCTAssertNotNil(oldBuffer)
        let newest = NSObject()
        for _ in 0..<1_000 { handoff.offer(newest) }
        XCTAssertNil(oldBuffer, "Overload must not retain a growing queue of camera buffers")
        XCTAssertTrue(handoff.value === newest)
        XCTAssertEqual(handoff.replacements, 1_000)
    }

    func testStopWaitsForCaptureQueueMarkerBeyondGracePeriod() throws {
        let recorder = ModeARecorder()
        let captureGate = DispatchSemaphore(value: 0)
        let entered = expectation(description: "capture callback in flight")
        recorder.videoQueueB.async {
            entered.fulfill()
            captureGate.wait()
        }
        defer { captureGate.signal() }
        wait(for: [entered], timeout: 1)
        let finished = expectation(description: "finished after capture handoff")
        let start = Date()
        recorder.onFinished = { _ in
            XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.28)
            finished.fulfill()
        }
        try startEmpty(recorder)
        recorder.stop()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.30) { captureGate.signal() }
        wait(for: [finished], timeout: 2)
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

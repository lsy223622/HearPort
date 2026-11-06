import XCTest
@testable import HearPortReceiver

final class PlaybackRecoveryTests: XCTestCase {
    func testRecoveryRequiresSuccessfulPlaybackAndCannotRenewAfterExpiry() {
        var window = PlaybackRecoveryWindow()
        XCTAssertFalse(window.begin(eligible: true))
        window.playbackStarted()
        XCTAssertTrue(window.begin(eligible: true))
        XCTAssertFalse(window.begin(eligible: true))
        window.end()
        XCTAssertFalse(window.begin(eligible: true))
        window.playbackStarted()
        XCTAssertTrue(window.begin(eligible: true))
    }

    func testManualStopOrIneligibleLossCannotStartRecovery() {
        var window = PlaybackRecoveryWindow()
        window.playbackStarted()
        XCTAssertFalse(window.begin(eligible: false))
        XCTAssertFalse(window.begin(eligible: true))
        window.playbackStarted()
        window.end()
        XCTAssertFalse(window.begin(eligible: true))
    }

    func testInterruptionOnlyResumesWithSystemPermission() {
        var recovery = AudioPlaybackRecovery()
        recovery.start()
        recovery.interrupt()
        XCTAssertFalse(recovery.canRecoverAutomatically)
        XCTAssertFalse(recovery.endInterruption(shouldResume: false))
        XCTAssertFalse(recovery.canRecoverAutomatically)
        // A route notification or duplicate end must not undo a denied resume.
        XCTAssertFalse(recovery.endInterruption(shouldResume: true))
        recovery.start()
        recovery.interrupt()
        XCTAssertTrue(recovery.endInterruption(shouldResume: true))
        XCTAssertTrue(recovery.canRecoverAutomatically)
    }

    func testStopPreventsDelayedInterruptionFromRestartingAudio() {
        var recovery = AudioPlaybackRecovery()
        recovery.start()
        recovery.interrupt()
        recovery.stop()
        XCTAssertFalse(recovery.endInterruption(shouldResume: true))
        XCTAssertFalse(recovery.canRecoverAutomatically)
    }

    func testMediaResetRequiresExplicitPlaybackEvenAfterInterruptionEnd() {
        var recovery = AudioPlaybackRecovery()
        recovery.start()
        recovery.interrupt()
        recovery.mediaServicesReset()
        XCTAssertFalse(recovery.endInterruption(shouldResume: true))
        XCTAssertFalse(recovery.canRecoverAutomatically)
        recovery.start()
        XCTAssertTrue(recovery.canRecoverAutomatically)
    }
}

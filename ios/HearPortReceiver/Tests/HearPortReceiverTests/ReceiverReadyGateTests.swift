import XCTest
@testable import HearPortReceiver

final class ReceiverReadyGateTests: XCTestCase {
    func testAudioReadinessWaitsForBothWritesInEitherOrderAndNotifiesOnce() {
        for receiverFirst in [true, false] {
            var gate = ReceiverReadyGate()
            XCTAssertFalse(gate.takeNotification(networkProbe: false))
            gate.receiverReadyWritten = receiverFirst
            gate.audioStreamAcknowledged = !receiverFirst
            XCTAssertFalse(gate.takeNotification(networkProbe: false))
            gate.receiverReadyWritten = true
            gate.audioStreamAcknowledged = true
            XCTAssertTrue(gate.takeNotification(networkProbe: false))
            XCTAssertFalse(gate.takeNotification(networkProbe: false))
        }
    }

    func testNetworkProbeDoesNotNeedAnAudioStream() {
        var gate = ReceiverReadyGate()
        XCTAssertFalse(gate.takeNotification(networkProbe: true))
        gate.receiverReadyWritten = true
        XCTAssertTrue(gate.takeNotification(networkProbe: true))
        XCTAssertFalse(gate.takeNotification(networkProbe: true))
    }

    func testNewConnectionCannotReusePreviousReadiness() {
        var gate = ReceiverReadyGate()
        gate.receiverReadyWritten = true; gate.audioStreamAcknowledged = true
        XCTAssertTrue(gate.takeNotification(networkProbe: false))
        gate = ReceiverReadyGate()
        gate.receiverReadyWritten = true
        XCTAssertFalse(gate.takeNotification(networkProbe: false))
        gate.audioStreamAcknowledged = true
        XCTAssertTrue(gate.takeNotification(networkProbe: false))
    }
}

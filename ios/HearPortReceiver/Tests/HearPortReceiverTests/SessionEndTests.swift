import Foundation
import XCTest
@testable import HearPortReceiver
final class SessionEndTests: XCTestCase {
    func testStopAndAcknowledgmentGoldenVectors() throws {
        let stop = Data([0xea,2,2,8,1]), ack = Data([0xf2,2,0])
        XCTAssertEqual(try ControlEnvelope.decode(stop).message, .sessionEnd(reason: 1))
        XCTAssertEqual(try ControlEnvelope(.sessionEnd(reason: 1)).encoded(), stop)
        XCTAssertEqual(try ControlEnvelope.decode(ack).message, .sessionEndAck)
        XCTAssertThrowsError(try ControlEnvelope.decode(Data([0xea,2,2,8,3])))
    }
}

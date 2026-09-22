#if canImport(Network)
import Foundation
import Network
import XCTest
@testable import HearPortReceiver

final class QuicTransportTests: XCTestCase {
    private final class EchoState: @unchecked Sendable {
        private let lock = NSLock()
        private var decoder = ControlFrameDecoder()
        private var count = 0

        func append(_ data: Data) throws -> [(Int, Data)] {
            lock.lock()
            defer { lock.unlock() }
            return try decoder.append(data).map { frame in
                count += 1
                return (count, frame)
            }
        }
    }

    func testControlRoundTripsAndAudioShareOneConnection() throws {
        guard ProcessInfo.processInfo.environment["HEARPORT_QUIC_INTEGRATION"] == "1" else {
            throw XCTSkip("Requires the loopback QUIC echo server")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let diagnostics = HearPortDiagnostics(directory: directory)
        diagnostics.level = .debug
        let transport = HearPortQuicTransport(diagnostics: diagnostics)
        let control = expectation(description: "Two control messages echoed on one stream")
        let audio = expectation(description: "968-byte audio datagram received")
        let first = Data([1, 2, 3])
        let second = Data([4, 5, 6])
        let echoes = EchoState()
        transport.onStateChange = { state in
            if state == .ready {
                do { try transport.sendControl(first) }
                catch { XCTFail("Control send failed: \(error)") }
            }
        }
        transport.onControlData = { data in
            do {
                for (messages, frame) in try echoes.append(data) {
                    XCTAssertEqual(frame, messages == 1 ? first : second)
                    if messages == 1 {
                        try transport.sendControl(second)
                    } else if messages == 2 {
                        control.fulfill()
                    }
                }
            } catch { XCTFail("Control echo failed: \(error)") }
        }
        transport.onAudioDatagram = { data in
            XCTAssertEqual(data, Data([0, 0, 0, 1]) + Data(repeating: 0, count: 964))
            audio.fulfill()
        }
        defer {
            transport.cancel()
            print(diagnostics.recentLines().joined(separator: "\n"))
        }
        transport.connect(host: "127.0.0.1", port: 44330,
                          tlsPolicy: .pairing(onPeerSPKIHash: { _ in }))
        wait(for: [control, audio], timeout: 15)
    }
}
#endif

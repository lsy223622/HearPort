import Foundation
import XCTest
@testable import HearPortReceiver
final class USBPacketTunnelTests: XCTestCase {
    func testFragmentedAndCoalescedPackets() throws {
        let golden = Data([72,80,85,81,1,0,0,2,7,8])
        XCTAssertEqual(try encodeUSBPacket(Data([7,8])), golden)
        var decoder = USBPacketDecoder()
        var packets: [Data] = []
        for byte in golden { packets += try decoder.append(Data([byte])) }
        XCTAssertEqual(packets, [Data([7,8])]); XCTAssertTrue(decoder.complete)
        XCTAssertEqual(try decoder.append(golden + golden), [Data([7,8]), Data([7,8])])
    }
    func testInvalidHeadersAndPartialEOF() throws {
        for invalid in [Data([72,80,85,81,2,0,0,1,7]), Data([72,80,85,81,1,0,0,0])] {
            var decoder = USBPacketDecoder()
            XCTAssertThrowsError(try decoder.append(invalid))
        }
        var decoder = USBPacketDecoder()
        _ = try decoder.append(Data([72,80,85,81,1,0,0,2,7]))
        XCTAssertFalse(decoder.complete)
    }
    func testInFlightWritesRemainChargedAndExpire() throws {
        var queue = USBPacketWriteQueue()
        XCTAssertTrue(queue.push(Data(repeating: 0, count: 32768), at: 1))
        XCTAssertTrue(queue.push(Data(repeating: 0, count: 32768), at: 1))
        XCTAssertFalse(queue.push(Data([1]), at: 2))
        XCTAssertEqual(queue.bytes, 65536)
        XCTAssertTrue(queue.expired(at: 101_000_001, maximumNanoseconds: 100_000_000))
        queue.completed(); XCTAssertEqual(queue.bytes, 32768)
    }
}

#if canImport(Network)
extension USBPacketTunnelTests {
    func testEncryptedQUICControlAndBothAudioModesThroughUSB() throws {
        guard ProcessInfo.processInfo.environment["HEARPORT_QUIC_INTEGRATION"] == "1" else { throw XCTSkip("Requires the loopback QUIC peer") }
        let diagnostics = HearPortDiagnostics(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let tunnel = USBPacketTunnel(diagnostics: diagnostics)
        let transport = HearPortQuicTransport(diagnostics: diagnostics, audioMode: .reliable)
        let audio = expectation(description: "Datagram and reliable audio through USB"); audio.expectedFulfillmentCount = 2
        let first = try MusicTestRound(encoded: Data([3,1,8,0,0,120,0,0,0,0,0,0,0,0,0,2]))
        let second = try MusicTestRound(encoded: Data([3,3,8,3,0,120,0,0,0,1,119,0,0,0,0,4]))
        transport.onStateChange = { state in
            if state == .ready {
                transport.acceptCoordinatedAudio(); transport.enableMusicTest()
                transport.expectReliableAudio(streamID: 1, latestReceivedSequence: { nil })
                transport.prepareMusicRound(first)
                try? transport.sendControl(Data("MUSIC_TEST_1".utf8))
            } else if state == .failed { XCTFail("USB QUIC failed") }
        }
        transport.onReliableAudioGeneration = { _, generation in generation == 4 }
        transport.onAudioDatagram = { data in
            guard let record = try? TimedAudioRecord(encoded: data) else { XCTFail("Invalid USB audio record"); return }
            XCTAssertTrue(record.sequence == 0 || record.sequence == 96000); audio.fulfill()
            if record.sequence == 0 {
                transport.prepareMusicRound(second)
                try? transport.sendControl(Data("MUSIC_TEST_2".utf8))
            }
        }
        tunnel.onAvailable = { port in transport.connect(host: "127.0.0.1", port: port, tlsPolicy: .pairing(onPeerSPKIHash: { _ in })) }
        tunnel.start(); wait(for: [audio], timeout: 20)
        transport.cancel()
        let stopped = expectation(description: "USB tunnel stopped")
        tunnel.stop { stopped.fulfill() }; wait(for: [stopped], timeout: 3)
    }
    func testUSBTunnelPreservesCertificatePinRejection() throws {
        guard ProcessInfo.processInfo.environment["HEARPORT_QUIC_INTEGRATION"] == "1" else { throw XCTSkip("Requires the loopback QUIC peer") }
        let tunnel = USBPacketTunnel()
        let transport = HearPortQuicTransport()
        let rejected = expectation(description: "USB identity mismatch rejected")
        rejected.assertForOverFulfill = false
        transport.onStateChange = { state in
            if state == .failed { rejected.fulfill() }
            if state == .ready { XCTFail("USB bypassed certificate pinning") }
        }
        tunnel.onAvailable = { port in transport.connect(host: "127.0.0.1", port: port, tlsPolicy: .remembered(spkiSHA256: Data(repeating: 0, count: 32))) }
        tunnel.start(); wait(for: [rejected], timeout: 20)
        transport.cancel()
        let stopped = expectation(description: "USB tunnel stopped")
        tunnel.stop { stopped.fulfill() }; wait(for: [stopped], timeout: 3)
    }
}
#endif

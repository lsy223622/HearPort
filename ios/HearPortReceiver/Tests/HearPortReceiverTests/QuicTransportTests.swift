#if canImport(Network)
import Foundation
import Network
import XCTest
@testable import HearPortReceiver

final class QuicTransportTests: XCTestCase {
    func testInitialConnectDoesNotPublishAClosedSession() {
        let transport = HearPortQuicTransport()
        let closed = expectation(description: "No close event for initial state reset")
        closed.isInverted = true
        transport.onStateChange = { state in if state == .closed { closed.fulfill() } }
        transport.connect(host: "127.0.0.1", port: 44330, tlsPolicy: .pairing(onPeerSPKIHash: { _ in }))
        wait(for: [closed], timeout: 0.1)
        transport.onStateChange = nil
        transport.cancel()
    }
    func testMusicTestSwitchesDatagramReliableDatagramOnOneConnection() throws {
        guard ProcessInfo.processInfo.environment["HEARPORT_QUIC_INTEGRATION"] == "1" else {
            throw XCTSkip("Requires the loopback QUIC echo server")
        }
        let transport = HearPortQuicTransport(diagnostics: HearPortDiagnostics(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            audioMode: .reliable)
        let audio = expectation(description: "Three music transport rounds")
        audio.expectedFulfillmentCount = 3
        let first = try MusicTestRound(encoded: Data([3,1,8,0,0,120,0,0,0,0,0,0,0,0,0,2]))
        let second = try MusicTestRound(encoded: Data([3,3,8,3,0,120,0,0,0,1,119,0,0,0,0,4]))
        let third = try MusicTestRound(encoded: Data([3,7,8,2,0,120,0,0,0,4,101,0,0,0,0,6]))
        transport.onStateChange = { state in
            if state == .ready {
                transport.acceptCoordinatedAudio()
                transport.enableMusicTest()
                transport.expectReliableAudio(streamID: 1, latestReceivedSequence: { nil })
                transport.prepareMusicRound(first)
                try? transport.sendControl(Data("MUSIC_TEST_1".utf8))
            } else if state == .failed { XCTFail("Music mode switch closed the connection") }
        }
        transport.onReliableAudioGeneration = { _, generation in
            XCTAssertEqual(generation, 4)
            return true
        }
        transport.onAudioDatagram = { data in
            guard let record = try? TimedAudioRecord(encoded: data) else {
                XCTFail("Invalid timed music record"); return
            }
            audio.fulfill()
            if record.sequence == 0 {
                transport.prepareMusicRound(second)
                try? transport.sendControl(Data("MUSIC_TEST_2".utf8))
            } else if record.sequence == 96_000 {
                transport.prepareMusicRound(third)
                try? transport.sendControl(Data("MUSIC_TEST_3".utf8))
            } else { XCTAssertEqual(record.sequence, 288_000) }
        }
        defer { transport.cancel() }
        transport.connect(host: "127.0.0.1", port: 44330,
                          tlsPolicy: .pairing(onPeerSPKIHash: { _ in }))
        wait(for: [audio], timeout: 15)
    }

    func testNetworkProbeReceivesBothModesAndQueueHeartbeats() throws {
        guard ProcessInfo.processInfo.environment["HEARPORT_QUIC_INTEGRATION"] == "1" else {
            throw XCTSkip("Requires the loopback QUIC echo server")
        }
        let diagnostics = HearPortDiagnostics(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let transport = HearPortQuicTransport(diagnostics: diagnostics)
        let datagram = expectation(description: "Datagram probe")
        let reliable = expectation(description: "Reliable stream probe")
        let heartbeat = expectation(description: "Receive queue heartbeat")
        heartbeat.assertForOverFulfill = false
        transport.onStateChange = { state in
            if state == .ready {
                transport.enableNetworkProbe()
                transport.expectReliableAudio(streamID: 1, latestReceivedSequence: { nil })
                transport.noteProbeGeneration(1)
                try? transport.sendControl(Data("NETWORK_PROBE".utf8))
            }
        }
        transport.onProbePacket = { data, at, bytes, count in
            XCTAssertGreaterThan(at, 0)
            XCTAssertGreaterThan(bytes, 0)
            XCTAssertGreaterThan(count, 0)
            if data.count == 488 {
                reliable.fulfill()
            } else {
                XCTAssertEqual(data.count, 968)
                datagram.fulfill()
            }
        }
        transport.onProbeHeartbeat = { at, scheduledAt in
            XCTAssertGreaterThan(at, 0)
            XCTAssertGreaterThan(scheduledAt, 0)
            heartbeat.fulfill()
        }
        transport.onAudioDatagram = { _ in XCTFail("Probe data reached the audio handler") }
        defer { transport.cancel() }
        transport.connect(host: "127.0.0.1", port: 44330,
                          tlsPolicy: .pairing(onPeerSPKIHash: { _ in }))
        wait(for: [datagram, reliable, heartbeat], timeout: 15)
    }

    private final class AudioCycleState: @unchecked Sendable {
        private let lock = NSLock()
        private var nextSequence: UInt32 = 0

        func accept(_ sequence: UInt32) -> UInt32? {
            lock.lock()
            defer { lock.unlock() }
            guard sequence == nextSequence else { return nil }
            nextSequence += 1
            return nextSequence
        }
    }

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

    func testReliableAudioGenerationsUseIncomingStreams() throws {
        guard ProcessInfo.processInfo.environment["HEARPORT_QUIC_INTEGRATION"] == "1" else {
            throw XCTSkip("Requires the loopback QUIC echo server")
        }
        let diagnostics = HearPortDiagnostics(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let transport = HearPortQuicTransport(diagnostics: diagnostics, audioMode: .reliable)
        let audio = expectation(description: "Two reliable audio generations")
        audio.expectedFulfillmentCount = 2
        transport.onStateChange = { state in
            if state == .ready {
                transport.acceptReliableAudio()
                transport.expectReliableAudio(streamID: 1, latestReceivedSequence: { nil })
                try? transport.sendControl(Data("RELIABLE_1".utf8))
            }
        }
        transport.onReliableAudioGeneration = { streamID, generation in
            XCTAssertEqual(streamID, 1)
            XCTAssertTrue(generation == 1 || generation == 2)
            return true
        }
        transport.onAudioDatagram = { data in
            let packet = try? AudioDatagram(encoded: data)
            XCTAssertEqual(packet?.streamID, 1)
            audio.fulfill()
            if packet?.sequence == 0 {
                try? transport.sendControl(Data("RELIABLE_2".utf8))
            } else {
                XCTAssertEqual(packet?.sequence, 1)
            }
        }
        defer { transport.cancel() }
        transport.connect(host: "127.0.0.1", port: 44330,
                          tlsPolicy: .pairing(onPeerSPKIHash: { _ in }))
        wait(for: [audio], timeout: 15)
    }

    func testInterruptedReliableRecordDoesNotCloseConnection() throws {
        guard ProcessInfo.processInfo.environment["HEARPORT_QUIC_INTEGRATION"] == "1" else {
            throw XCTSkip("Requires the loopback QUIC echo server")
        }
        let diagnostics = HearPortDiagnostics(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let transport = HearPortQuicTransport(diagnostics: diagnostics, audioMode: .reliable)
        let audio = expectation(description: "Audio resumes on the replacement stream")
        audio.expectedFulfillmentCount = 2
        transport.onStateChange = { state in
            if state == .ready {
                transport.acceptReliableAudio()
                transport.expectReliableAudio(streamID: 1, latestReceivedSequence: { nil })
                try? transport.sendControl(Data("RELIABLE_ABORT_1".utf8))
            } else if state == .failed {
                XCTFail("Interrupted old audio stream closed the connection")
            }
        }
        transport.onReliableAudioGeneration = { streamID, generation in
            XCTAssertEqual(streamID, 1)
            XCTAssertTrue(generation == 1 || generation == 2)
            return true
        }
        transport.onAudioDatagram = { data in
            guard let packet = try? AudioDatagram(encoded: data) else {
                XCTFail("Invalid audio packet")
                return
            }
            XCTAssertEqual(packet.streamID, 1)
            XCTAssertTrue(packet.sequence == 0 || packet.sequence == 1)
            audio.fulfill()
        }
        defer { transport.cancel() }
        transport.connect(host: "127.0.0.1", port: 44330,
                          tlsPolicy: .pairing(onPeerSPKIHash: { _ in }))
        wait(for: [audio], timeout: 15)
    }

    func testReliableAudioCanCycleBeyondInitialStreamLimit() throws {
        guard ProcessInfo.processInfo.environment["HEARPORT_QUIC_INTEGRATION"] == "1" else {
            throw XCTSkip("Requires the loopback QUIC echo server")
        }
        let diagnostics = HearPortDiagnostics(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let transport = HearPortQuicTransport(diagnostics: diagnostics, audioMode: .reliable)
        let audio = expectation(description: "Ten successive reliable audio streams")
        audio.expectedFulfillmentCount = 10
        let cycle = AudioCycleState()
        transport.onStateChange = { state in
            if state == .ready {
                transport.acceptReliableAudio()
                transport.expectReliableAudio(streamID: 1, latestReceivedSequence: { nil })
                try? transport.sendControl(Data("RELIABLE_CYCLE_1".utf8))
            } else if state == .failed {
                XCTFail("Reliable audio stream cycle closed the connection")
            }
        }
        transport.onReliableAudioGeneration = { streamID, generation in
            XCTAssertEqual(streamID, 1)
            XCTAssertTrue((1...10).contains(generation))
            return true
        }
        transport.onAudioDatagram = { data in
            guard let packet = try? AudioDatagram(encoded: data) else {
                XCTFail("Invalid audio packet")
                return
            }
            guard let nextSequence = cycle.accept(packet.sequence) else {
                XCTFail("Reliable audio sequence was missing or out of order")
                return
            }
            audio.fulfill()
            if nextSequence < 10 {
                try? transport.sendControl(Data("RELIABLE_CYCLE_\(nextSequence + 1)".utf8))
            }
        }
        defer { transport.cancel() }
        transport.connect(host: "127.0.0.1", port: 44330,
                          tlsPolicy: .pairing(onPeerSPKIHash: { _ in }))
        wait(for: [audio], timeout: 15)
    }
}
#endif

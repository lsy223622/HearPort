import Foundation

public enum ControlMessageError: Error, Equatable {
    case emptyEnvelope
    case malformedVarint
    case malformedField
    case unknownField(UInt32)
    case invalidMessage
    case invalidUTF8
    case tooLarge
}

public enum ErrorCode: UInt32, Equatable, Sendable {
    case protocolError = 1
    case datagramUnsupported = 2
    case authFailed = 3
    case pairingClosed = 4
    case streamState = 5
    case audioUnavailable = 6
    case internalError = 7
}

public enum ControlMessage: Equatable, Sendable {
    case connectRequest(authMode: AuthMode, peerID: Data)
    case sessionReady
    case error(code: ErrorCode, message: String)
    case pairSpakeA(Data)
    case pairSpakeB(Data)
    case pairConfirmA(Data)
    case pairConfirmB(Data)
    case pairCredential(peerID: Data, pairSecret: Data)
    case authChallenge(Data)
    case authResponse(peerID: Data, mac: Data)
    case startStream(UInt32)
    case startStreamAck(UInt32)

    public var diagnosticName: String {
        switch self {
        case .connectRequest: return "connect_request"
        case .sessionReady: return "session_ready"
        case .error: return "error"
        case .pairSpakeA: return "pair_spake_a"
        case .pairSpakeB: return "pair_spake_b"
        case .pairConfirmA: return "pair_confirm_a"
        case .pairConfirmB: return "pair_confirm_b"
        case .pairCredential: return "pair_credential"
        case .authChallenge: return "auth_challenge"
        case .authResponse: return "auth_response"
        case .startStream: return "start_stream"
        case .startStreamAck: return "start_stream_ack"
        }
    }
}

public struct ControlEnvelope: Equatable, Sendable {
    public let message: ControlMessage

    public init(_ message: ControlMessage) {
        self.message = message
    }

    public func encoded() throws -> Data {
        let body: Data
        let field: UInt32
        switch message {
        case let .connectRequest(authMode, peerID):
            guard (authMode == .remembered && peerID.count == 16) ||
                    (authMode != .remembered && peerID.isEmpty) else {
                throw ControlMessageError.invalidMessage
            }
            var writer = ProtoWriter()
            writer.writeVarintField(1, value: authMode.rawValue)
            if !peerID.isEmpty { writer.writeBytesField(2, value: peerID) }
            body = writer.data
            field = 1
        case .sessionReady:
            body = Data()
            field = 2
        case let .error(code, message):
            var writer = ProtoWriter()
            writer.writeVarintField(1, value: code.rawValue)
            if !message.isEmpty { writer.writeBytesField(2, value: Data(message.utf8)) }
            body = writer.data
            field = 3
        case let .pairSpakeA(point):
            guard point.count == 65 else { throw ControlMessageError.invalidMessage }
            body = Self.singleBytesBody(point)
            field = 10
        case let .pairSpakeB(point):
            guard point.count == 65 else { throw ControlMessageError.invalidMessage }
            body = Self.singleBytesBody(point)
            field = 11
        case let .pairConfirmA(confirmation):
            guard confirmation.count == 32 else { throw ControlMessageError.invalidMessage }
            body = Self.singleBytesBody(confirmation)
            field = 12
        case let .pairConfirmB(confirmation):
            guard confirmation.count == 32 else { throw ControlMessageError.invalidMessage }
            body = Self.singleBytesBody(confirmation)
            field = 13
        case let .pairCredential(peerID, pairSecret):
            guard peerID.count == 16, pairSecret.count == 32 else {
                throw ControlMessageError.invalidMessage
            }
            var writer = ProtoWriter()
            writer.writeBytesField(1, value: peerID)
            writer.writeBytesField(2, value: pairSecret)
            body = writer.data
            field = 14
        case let .authChallenge(nonce):
            guard nonce.count == 32 else { throw ControlMessageError.invalidMessage }
            body = Self.singleBytesBody(nonce)
            field = 20
        case let .authResponse(peerID, mac):
            guard peerID.count == 16, mac.count == 32 else {
                throw ControlMessageError.invalidMessage
            }
            var writer = ProtoWriter()
            writer.writeBytesField(1, value: peerID)
            writer.writeBytesField(2, value: mac)
            body = writer.data
            field = 21
        case let .startStream(streamID):
            guard streamID != 0 else { throw ControlMessageError.invalidMessage }
            var writer = ProtoWriter()
            writer.writeVarintField(1, value: streamID)
            body = writer.data
            field = 30
        case let .startStreamAck(streamID):
            guard streamID != 0 else { throw ControlMessageError.invalidMessage }
            var writer = ProtoWriter()
            writer.writeVarintField(1, value: streamID)
            body = writer.data
            field = 31
        }
        var writer = ProtoWriter()
        writer.writeBytesField(field, value: body)
        guard writer.data.count <= ControlFraming.maxPayloadBytes else {
            throw ControlMessageError.tooLarge
        }
        return writer.data
    }

    public static func decode(_ data: Data) throws -> ControlEnvelope {
        guard !data.isEmpty, data.count <= ControlFraming.maxPayloadBytes else {
            throw ControlMessageError.emptyEnvelope
        }
        var reader = ProtoReader(data)
        var selected: (field: UInt32, body: Data)?
        var lastUnknownField: UInt32?
        while !reader.isAtEnd {
            let outer = try reader.readField()
            guard case let .bytes(body) = outer.value else {
                continue
            }
            switch outer.field {
            case 1, 2, 3, 10, 11, 12, 13, 14, 20, 21, 30, 31:
                selected = (outer.field, body)
            default:
                lastUnknownField = outer.field
            }
        }
        guard let selected else {
            throw ControlMessageError.unknownField(lastUnknownField ?? 0)
        }
        let message: ControlMessage
        switch selected.field {
        case 1: message = try parseConnect(selected.body)
        case 2: message = try parseEmpty(selected.body, .sessionReady)
        case 3: message = try parseError(selected.body)
        case 10: message = try parseSingleBytes(selected.body, expectedLength: 65, make: ControlMessage.pairSpakeA)
        case 11: message = try parseSingleBytes(selected.body, expectedLength: 65, make: ControlMessage.pairSpakeB)
        case 12: message = try parseSingleBytes(selected.body, expectedLength: 32, make: ControlMessage.pairConfirmA)
        case 13: message = try parseSingleBytes(selected.body, expectedLength: 32, make: ControlMessage.pairConfirmB)
        case 14: message = try parseCredential(selected.body, make: ControlMessage.pairCredential)
        case 20: message = try parseSingleBytes(selected.body, expectedLength: 32, make: ControlMessage.authChallenge)
        case 21: message = try parseCredential(selected.body, make: ControlMessage.authResponse)
        case 30: message = try parseStream(selected.body, make: ControlMessage.startStream)
        case 31: message = try parseStream(selected.body, make: ControlMessage.startStreamAck)
        default: throw ControlMessageError.unknownField(selected.field)
        }
        return ControlEnvelope(message)
    }

    private static func singleBytesBody(_ value: Data) -> Data {
        var writer = ProtoWriter()
        writer.writeBytesField(1, value: value)
        return writer.data
    }

    private static func parseFields(_ data: Data) throws -> [UInt32: ProtoField] {
        var reader = ProtoReader(data)
        var fields: [UInt32: ProtoField] = [:]
        while !reader.isAtEnd {
            let field = try reader.readField()
            if case .ignored = field.value {
                continue
            }
            fields[field.field] = field.value
        }
        return fields
    }

    private static func parseConnect(_ data: Data) throws -> ControlMessage {
        let fields = try parseFields(data)
        guard case let .varint(rawMode)? = fields[1],
              let mode = AuthMode(rawValue: rawMode) else {
            throw ControlMessageError.invalidMessage
        }
        let peerID: Data
        if case let .bytes(value)? = fields[2] {
            peerID = value
        } else if fields[2] == nil {
            peerID = Data()
        } else {
            throw ControlMessageError.invalidMessage
        }
        guard (mode == .remembered && peerID.count == 16) ||
                (mode != .remembered && peerID.isEmpty) else {
            throw ControlMessageError.invalidMessage
        }
        return .connectRequest(authMode: mode, peerID: peerID)
    }

    private static func parseEmpty(_ data: Data, _ message: ControlMessage) throws -> ControlMessage {
        _ = try parseFields(data)
        return message
    }

    private static func parseError(_ data: Data) throws -> ControlMessage {
        let fields = try parseFields(data)
        guard case let .varint(rawCode)? = fields[1],
              let code = ErrorCode(rawValue: rawCode) else {
            throw ControlMessageError.invalidMessage
        }
        let message: String
        if case let .bytes(value)? = fields[2] {
            guard let decoded = String(data: value, encoding: .utf8) else {
                throw ControlMessageError.invalidUTF8
            }
            message = decoded
        } else if fields[2] == nil {
            message = ""
        } else {
            throw ControlMessageError.invalidMessage
        }
        return .error(code: code, message: message)
    }

    private static func parseSingleBytes(
        _ data: Data,
        expectedLength: Int,
        make: (Data) -> ControlMessage
    ) throws -> ControlMessage {
        let fields = try parseFields(data)
        guard case let .bytes(value)? = fields[1],
              value.count == expectedLength else {
            throw ControlMessageError.invalidMessage
        }
        return make(value)
    }

    private static func parseCredential(
        _ data: Data,
        make: (Data, Data) -> ControlMessage
    ) throws -> ControlMessage {
        let fields = try parseFields(data)
        guard case let .bytes(first)? = fields[1],
              case let .bytes(second)? = fields[2] else {
            throw ControlMessageError.invalidMessage
        }
        return make(first, second)
    }

    private static func parseStream(
        _ data: Data,
        make: (UInt32) -> ControlMessage
    ) throws -> ControlMessage {
        let fields = try parseFields(data)
        guard case let .varint(streamID)? = fields[1],
              streamID != 0 else {
            throw ControlMessageError.invalidMessage
        }
        return make(streamID)
    }
}

private enum ProtoField {
    case varint(UInt32)
    case bytes(Data)
    case ignored
}

private struct ProtoWriter {
    var data = Data()

    mutating func writeVarint(_ value: UInt32) {
        var remaining = value
        while remaining >= 0x80 {
            data.append(UInt8((remaining & 0x7f) | 0x80))
            remaining >>= 7
        }
        data.append(UInt8(remaining))
    }

    mutating func writeVarintField(_ field: UInt32, value: UInt32) {
        writeVarint((field << 3) | 0)
        writeVarint(value)
    }

    mutating func writeBytesField(_ field: UInt32, value: Data) {
        writeVarint((field << 3) | 2)
        writeVarint(UInt32(value.count))
        data.append(value)
    }
}

private struct ProtoReader {
    let bytes: [UInt8]
    var offset = 0

    init(_ data: Data) { bytes = Array(data) }

    var isAtEnd: Bool { offset == bytes.count }

    mutating func readVarint() throws -> UInt32 {
        var value: UInt32 = 0
        for index in 0..<5 {
            guard offset < bytes.count else { throw ControlMessageError.malformedVarint }
            let byte = bytes[offset]
            offset += 1
            if index == 4 && byte > 0x0f { throw ControlMessageError.malformedVarint }
            value |= UInt32(byte & 0x7f) << UInt32(index * 7)
            if byte & 0x80 == 0 { return value }
        }
        throw ControlMessageError.malformedVarint
    }

    mutating func readField() throws -> (field: UInt32, value: ProtoField) {
        let tag = try readVarint()
        guard tag != 0 else { throw ControlMessageError.malformedField }
        let field = tag >> 3
        let wire = UInt8(tag & 0x07)
        guard field != 0 else { throw ControlMessageError.malformedField }
        switch wire {
        case 0:
            return (field, .varint(try readVarint()))
        case 1:
            guard offset + 8 <= bytes.count else { throw ControlMessageError.malformedField }
            offset += 8
            return (field, .ignored)
        case 2:
            let length = Int(try readVarint())
            guard length <= ControlFraming.maxPayloadBytes,
                  offset + length <= bytes.count else {
                throw ControlMessageError.malformedField
            }
            let value = Data(bytes[offset..<(offset + length)])
            offset += length
            return (field, .bytes(value))
        case 3:
            try skipField(wire)
            return (field, .ignored)
        case 5:
            guard offset + 4 <= bytes.count else { throw ControlMessageError.malformedField }
            offset += 4
            return (field, .ignored)
        default:
            throw ControlMessageError.malformedField
        }
    }

    private mutating func skipField(_ wire: UInt8) throws {
        switch wire {
        case 0:
            _ = try readVarint()
        case 1:
            guard offset + 8 <= bytes.count else { throw ControlMessageError.malformedField }
            offset += 8
        case 2:
            let length = Int(try readVarint())
            guard length <= ControlFraming.maxPayloadBytes,
                  offset + length <= bytes.count else {
                throw ControlMessageError.malformedField
            }
            offset += length
        case 3:
            while true {
                let tag = try readVarint()
                guard tag != 0 else { throw ControlMessageError.malformedField }
                let nestedWire = UInt8(tag & 0x07)
                if nestedWire == 4 { return }
                try skipField(nestedWire)
            }
        case 5:
            guard offset + 4 <= bytes.count else { throw ControlMessageError.malformedField }
            offset += 4
        default:
            throw ControlMessageError.malformedField
        }
    }
}

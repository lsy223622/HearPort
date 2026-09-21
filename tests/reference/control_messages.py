"""Dependency-free reference codec for the canonical ControlEnvelope schema."""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum


MAX_MESSAGE = 65536


class ControlMessageError(ValueError):
    pass


class AuthMode(str, Enum):
    REMEMBERED = "REMEMBERED"
    PAIR = "PAIR"
    ONE_TIME = "ONE_TIME"


class MessageType(str, Enum):
    CONNECT_REQUEST = "connect_request"
    SESSION_READY = "session_ready"
    ERROR = "error"
    PAIR_SPAKE_A = "pair_spake_a"
    PAIR_SPAKE_B = "pair_spake_b"
    PAIR_CONFIRM_A = "pair_confirm_a"
    PAIR_CONFIRM_B = "pair_confirm_b"
    PAIR_CREDENTIAL = "pair_credential"
    AUTH_CHALLENGE = "auth_challenge"
    AUTH_RESPONSE = "auth_response"
    START_STREAM = "start_stream"
    START_STREAM_ACK = "start_stream_ack"


@dataclass(frozen=True)
class ControlEnvelope:
    type: MessageType
    auth_mode: AuthMode | None = None
    bytes1: bytes = b""
    bytes2: bytes = b""
    stream_id: int = 0
    error_code: int | None = None
    error_message: str = ""


def _varint(value: int) -> bytes:
    if value < 0 or value > 0xFFFFFFFF:
        raise ControlMessageError("varint is outside uint32")
    result = bytearray()
    while value >= 0x80:
        result.append((value & 0x7F) | 0x80)
        value >>= 7
    result.append(value)
    return bytes(result)


def _field(field: int, wire: int, value: bytes) -> bytes:
    return _varint((field << 3) | wire) + value


def _bytes_field(field: int, value: bytes) -> bytes:
    return _field(field, 2, _varint(len(value)) + value)


def _validate(message: ControlEnvelope) -> None:
    if message.type == MessageType.CONNECT_REQUEST:
        if message.auth_mode is None:
            raise ControlMessageError("connect request is missing auth mode")
        if message.auth_mode == AuthMode.REMEMBERED and len(message.bytes1) != 16:
            raise ControlMessageError("remembered peer id must be 16 bytes")
        if message.auth_mode != AuthMode.REMEMBERED and message.bytes1:
            raise ControlMessageError("pair/one-time peer id must be empty")
        return
    if message.type in (MessageType.PAIR_SPAKE_A, MessageType.PAIR_SPAKE_B):
        if len(message.bytes1) != 65:
            raise ControlMessageError("SPAKE2 point must be 65 bytes")
        return
    if message.type in (MessageType.PAIR_CONFIRM_A, MessageType.PAIR_CONFIRM_B):
        if len(message.bytes1) != 32:
            raise ControlMessageError("confirmation must be 32 bytes")
        return
    if message.type == MessageType.PAIR_CREDENTIAL:
        if len(message.bytes1) != 16 or len(message.bytes2) != 32:
            raise ControlMessageError("credential has invalid lengths")
        return
    if message.type == MessageType.AUTH_CHALLENGE:
        if len(message.bytes1) != 32:
            raise ControlMessageError("challenge nonce must be 32 bytes")
        return
    if message.type == MessageType.AUTH_RESPONSE:
        if len(message.bytes1) != 16 or len(message.bytes2) != 32:
            raise ControlMessageError("auth response has invalid lengths")
        return
    if message.type in (MessageType.START_STREAM, MessageType.START_STREAM_ACK):
        if message.stream_id == 0 or message.stream_id > 0xFFFFFFFF:
            raise ControlMessageError("stream id must be non-zero uint32")
        return
    if message.type == MessageType.ERROR:
        if message.error_code is None or not 1 <= message.error_code <= 7:
            raise ControlMessageError("invalid error code")
        return


_ENVELOPE_FIELDS = {
    MessageType.CONNECT_REQUEST: 1,
    MessageType.SESSION_READY: 2,
    MessageType.ERROR: 3,
    MessageType.PAIR_SPAKE_A: 10,
    MessageType.PAIR_SPAKE_B: 11,
    MessageType.PAIR_CONFIRM_A: 12,
    MessageType.PAIR_CONFIRM_B: 13,
    MessageType.PAIR_CREDENTIAL: 14,
    MessageType.AUTH_CHALLENGE: 20,
    MessageType.AUTH_RESPONSE: 21,
    MessageType.START_STREAM: 30,
    MessageType.START_STREAM_ACK: 31,
}


def encode_control_envelope(message: ControlEnvelope) -> bytes:
    _validate(message)
    if message.type == MessageType.CONNECT_REQUEST:
        auth_value = {
            AuthMode.REMEMBERED: 1,
            AuthMode.PAIR: 2,
            AuthMode.ONE_TIME: 3,
        }[message.auth_mode]
        body = _field(1, 0, _varint(auth_value))
        if message.bytes1:
            body += _bytes_field(2, message.bytes1)
    elif message.type == MessageType.SESSION_READY:
        body = b""
    elif message.type == MessageType.ERROR:
        body = _field(1, 0, _varint(message.error_code))
        if message.error_message:
            body += _bytes_field(2, message.error_message.encode("utf-8"))
    elif message.type in {
        MessageType.PAIR_SPAKE_A,
        MessageType.PAIR_SPAKE_B,
        MessageType.PAIR_CONFIRM_A,
        MessageType.PAIR_CONFIRM_B,
        MessageType.AUTH_CHALLENGE,
    }:
        body = _bytes_field(1, message.bytes1)
    elif message.type in {MessageType.PAIR_CREDENTIAL, MessageType.AUTH_RESPONSE}:
        body = _bytes_field(1, message.bytes1) + _bytes_field(2, message.bytes2)
    elif message.type in {MessageType.START_STREAM, MessageType.START_STREAM_ACK}:
        body = _field(1, 0, _varint(message.stream_id))
    else:
        raise ControlMessageError("unknown control message")
    result = _bytes_field(_ENVELOPE_FIELDS[message.type], body)
    if len(result) > MAX_MESSAGE:
        raise ControlMessageError("control envelope is too large")
    return result


def _read_varint(data: bytes, offset: int) -> tuple[int, int]:
    value = 0
    for index in range(5):
        if offset >= len(data):
            raise ControlMessageError("truncated varint")
        byte = data[offset]
        offset += 1
        if index == 4 and byte > 0x0F:
            raise ControlMessageError("uint32 varint overflow")
        value |= (byte & 0x7F) << (index * 7)
        if not byte & 0x80:
            return value, offset
    raise ControlMessageError("unterminated varint")


def _read_field(data: bytes, offset: int) -> tuple[int, int, bytes, int]:
    tag, offset = _read_varint(data, offset)
    if tag == 0:
        raise ControlMessageError("zero protobuf tag")
    field, wire = tag >> 3, tag & 7
    if wire == 0:
        value, offset = _read_varint(data, offset)
        return field, wire, value.to_bytes(4, "little"), offset
    if wire == 2:
        length, offset = _read_varint(data, offset)
        end = offset + length
        if end > len(data) or length > MAX_MESSAGE:
            raise ControlMessageError("truncated bytes field")
        return field, wire, data[offset:end], end
    raise ControlMessageError("unsupported protobuf wire type")


def _parse_body(message_type: MessageType, body: bytes) -> ControlEnvelope:
    fields: dict[int, tuple[int, bytes]] = {}
    offset = 0
    while offset < len(body):
        field, wire, value, offset = _read_field(body, offset)
        if field in fields:
            raise ControlMessageError("duplicate protobuf field")
        fields[field] = (wire, value)

    if message_type == MessageType.SESSION_READY:
        if fields:
            raise ControlMessageError("SessionReady must be empty")
        message = ControlEnvelope(message_type)
    elif message_type == MessageType.CONNECT_REQUEST:
        if 1 not in fields or fields[1][0] != 0:
            raise ControlMessageError("missing auth mode")
        auth_value = int.from_bytes(fields[1][1], "little")
        modes = {1: AuthMode.REMEMBERED, 2: AuthMode.PAIR, 3: AuthMode.ONE_TIME}
        if auth_value not in modes:
            raise ControlMessageError("invalid auth mode")
        peer_id = fields.get(2, (2, b""))[1]
        if 2 in fields and fields[2][0] != 2:
            raise ControlMessageError("invalid peer id field")
        message = ControlEnvelope(message_type, auth_mode=modes[auth_value], bytes1=peer_id)
    elif message_type == MessageType.ERROR:
        if 1 not in fields or fields[1][0] != 0:
            raise ControlMessageError("missing error code")
        code = int.from_bytes(fields[1][1], "little")
        text = fields.get(2, (2, b""))[1]
        if 2 in fields and fields[2][0] != 2:
            raise ControlMessageError("invalid error text field")
        try:
            error_message = text.decode("utf-8")
        except UnicodeDecodeError as exc:
            raise ControlMessageError("error text is not UTF-8") from exc
        message = ControlEnvelope(message_type, error_code=code, error_message=error_message)
    elif message_type in {
        MessageType.PAIR_SPAKE_A,
        MessageType.PAIR_SPAKE_B,
        MessageType.PAIR_CONFIRM_A,
        MessageType.PAIR_CONFIRM_B,
        MessageType.AUTH_CHALLENGE,
    }:
        if set(fields) != {1} or fields[1][0] != 2:
            raise ControlMessageError("invalid single-bytes message")
        message = ControlEnvelope(message_type, bytes1=fields[1][1])
    elif message_type in {MessageType.PAIR_CREDENTIAL, MessageType.AUTH_RESPONSE}:
        if set(fields) != {1, 2} or any(wire != 2 for wire, _ in fields.values()):
            raise ControlMessageError("invalid two-bytes message")
        message = ControlEnvelope(message_type, bytes1=fields[1][1], bytes2=fields[2][1])
    elif message_type in {MessageType.START_STREAM, MessageType.START_STREAM_ACK}:
        if set(fields) != {1} or fields[1][0] != 0:
            raise ControlMessageError("invalid stream message")
        message = ControlEnvelope(message_type, stream_id=int.from_bytes(fields[1][1], "little"))
    else:
        raise ControlMessageError("unknown control message")
    _validate(message)
    return message


def decode_control_envelope(data: bytes) -> ControlEnvelope:
    if not data or len(data) > MAX_MESSAGE:
        raise ControlMessageError("invalid envelope length")
    field, wire, body, offset = _read_field(data, 0)
    if offset != len(data) or wire != 2:
        raise ControlMessageError("envelope must contain exactly one message")
    try:
        message_type = next(kind for kind, number in _ENVELOPE_FIELDS.items() if number == field)
    except StopIteration as exc:
        raise ControlMessageError("unknown envelope field") from exc
    return _parse_body(message_type, body)

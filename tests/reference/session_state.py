class ProtocolError(ValueError):
    pass


class SessionState:
    def __init__(self):
        self.phase = "awaiting_connect"
        self.auth_mode = None
        self.pending_stream_id = None
        self.active_stream_id = None

    def receive(self, message: dict) -> str:
        if self.phase != "awaiting_connect":
            raise ProtocolError("ConnectRequest is only legal as the first message")
        if message.get("type") != "connect_request":
            raise ProtocolError("first message must be ConnectRequest")
        auth_mode = message.get("auth_mode")
        peer_id = message.get("peer_id", b"")
        if auth_mode not in {"REMEMBERED", "PAIR", "ONE_TIME"}:
            raise ProtocolError("AUTH_MODE_UNSPECIFIED is invalid")
        if auth_mode == "REMEMBERED" and len(peer_id) != 16:
            raise ProtocolError("remembered peer_id must be exactly 16 bytes")
        if auth_mode != "REMEMBERED" and peer_id:
            raise ProtocolError("pair/one-time peer_id must be empty")
        self.auth_mode = auth_mode
        self.phase = "authenticating"
        return "accepted"

    def mark_authenticated(self) -> None:
        if self.phase != "authenticating":
            raise ProtocolError("authentication is not pending")
        self.phase = "ready"

    def begin_stream(self, stream_id: int) -> None:
        if self.phase not in {"ready", "active"}:
            raise ProtocolError("stream cannot start before authentication")
        if stream_id == 0:
            raise ProtocolError("stream_id must be non-zero")
        self.pending_stream_id = stream_id
        self.active_stream_id = None
        self.phase = "pending_stream"

    def ack_written(self, stream_id: int) -> str:
        if self.phase != "pending_stream" or stream_id != self.pending_stream_id:
            return "protocol_error"
        self.active_stream_id = stream_id
        self.pending_stream_id = None
        self.phase = "active"
        return "active"

    def accept_audio(self, packet) -> str:
        if self.phase == "pending_stream":
            return "pending_audio_discarded"
        if self.phase == "active" and packet.stream_id == self.active_stream_id:
            return "accepted"
        return "old_stream_discarded"

    def reset_stream(self, stream_id: int) -> None:
        self.begin_stream(stream_id)

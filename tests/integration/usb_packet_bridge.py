"""Loopback PC side of the USB packet tunnel for Network.framework CI tests."""
import asyncio
import struct

HEADER = struct.Struct("!4sBBH")


class ReplyForwarder(asyncio.DatagramProtocol):
    def __init__(self, writer):
        self.writer = writer

    def datagram_received(self, data, _):
        if self.writer.is_closing():
            return
        if not 1 <= len(data) <= 65535 or self.writer.transport.get_write_buffer_size() > 65536:
            self.writer.close()
            return
        frame = HEADER.pack(b"HPUQ", 1, 0, len(data)) + data
        self.writer.write(frame[:3])
        self.writer.write(frame[3:])


async def usb_packet_bridge():
    while True:
        writer = None
        udp = None
        try:
            reader, writer = await asyncio.open_connection("127.0.0.1", 52138)
            udp, _ = await asyncio.get_running_loop().create_datagram_endpoint(
                lambda: ReplyForwarder(writer), remote_addr=("127.0.0.1", 44330))
            while True:
                magic, version, reserved, size = HEADER.unpack(await reader.readexactly(8))
                if magic != b"HPUQ" or version != 1 or reserved or not size:
                    raise ValueError("invalid USB packet header")
                udp.sendto(await reader.readexactly(size))
        except (OSError, EOFError, ValueError, asyncio.IncompleteReadError):
            await asyncio.sleep(0.1)
        finally:
            if udp:
                udp.close()
            if writer:
                writer.close()
                try:
                    await writer.wait_closed()
                except OSError:
                    pass

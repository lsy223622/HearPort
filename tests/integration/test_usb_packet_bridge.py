import asyncio
import unittest
from unittest.mock import AsyncMock, Mock, patch

from usb_packet_bridge import usb_packet_bridge


class USBPacketBridgeTests(unittest.IsolatedAsyncioTestCase):
    async def test_reconnects_after_reset_during_close(self):
        reader, writer, udp = Mock(), Mock(), Mock()
        reader.readexactly = AsyncMock(side_effect=ConnectionResetError("peer reset"))
        writer.wait_closed = AsyncMock(side_effect=ConnectionResetError("peer reset"))
        connect = AsyncMock(side_effect=[(reader, writer), asyncio.CancelledError()])
        loop = asyncio.get_running_loop()
        with patch("usb_packet_bridge.asyncio.open_connection", connect), patch.object(
            loop, "create_datagram_endpoint", AsyncMock(return_value=(udp, None))
        ):
            with self.assertRaises(asyncio.CancelledError):
                await asyncio.wait_for(usb_packet_bridge(), timeout=1)
        self.assertEqual(connect.await_count, 2)
        udp.close.assert_called_once()
        writer.close.assert_called_once()


if __name__ == "__main__":
    unittest.main()

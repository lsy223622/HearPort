"""Check the real sender's fragmented control receive using a local certificate.

Requires aioquic==1.3.0 and a built sender with its MsQuic DLL.
The one-time exchange stops before PIN confirmation and persists no credentials.
"""

import argparse
import asyncio
import ssl
import subprocess
from pathlib import Path

from aioquic.asyncio import connect
from aioquic.quic.configuration import QuicConfiguration


async def probe(args):
    process = subprocess.Popen(
        [str(Path(args.sender).resolve()), f"--port={args.port}", "--open-pairing",
         f"--cert-sha1={args.cert_sha1}", f"--cert-spki-sha256={args.cert_spki_sha256}"],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        creationflags=subprocess.CREATE_NO_WINDOW)
    try:
        await asyncio.sleep(1)
        configuration = QuicConfiguration(
            is_client=True, alpn_protocols=["hearport/1"],
            max_datagram_frame_size=65535, verify_mode=ssl.CERT_NONE)
        async with connect("127.0.0.1", args.port, configuration=configuration) as client:
            reader, writer = await client.create_stream()
            # Fragment the length prefix to exercise multiple RECEIVE callbacks.
            writer.write(bytes.fromhex("000000"))
            await asyncio.sleep(0.05)
            writer.write(bytes.fromhex("040a020803"))
            header = await asyncio.wait_for(reader.readexactly(4), timeout=3)
            size = int.from_bytes(header, "big")
            assert size == 69, f"Expected PairSpakeA envelope, received {size} bytes"
            body = await asyncio.wait_for(reader.readexactly(size), timeout=3)
            assert body[:5] == bytes.fromhex("52430a4104"), "Invalid PairSpakeA envelope"
            assert process.poll() is None, "Sender exited while handling control data"
            print("PASS: fragmented ConnectRequest returned a complete PairSpakeA")
    finally:
        try:
            output, _ = process.communicate(b"\n", timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.communicate()
            raise AssertionError("Sender did not shut down")
        for line in output.decode(errors="replace").splitlines():
            if not line.startswith("Pairing PIN:"):
                print(line)
        assert process.returncode == 0, f"Sender exit code: {process.returncode:#x}"


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sender", required=True)
    parser.add_argument("--cert-sha1", required=True)
    parser.add_argument("--cert-spki-sha256", required=True)
    parser.add_argument("--port", type=int, default=44331)
    asyncio.run(probe(parser.parse_args()))

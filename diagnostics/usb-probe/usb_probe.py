"""Disposable USB feasibility probe. Requires Apple's device service on Windows."""
import argparse
import ctypes
import json
import os
from pathlib import Path
import plistlib
import secrets
import socket
import struct
import threading
import time
import zlib

DATA, PING, PONG, FINISH, SUMMARY, HELLO = range(1, 7)
HEADER = struct.Struct("!4sBBHIIQII")


def encode_frame(kind, sequence, timestamp, payload=b""):
    if len(payload) > 65536:
        raise ValueError("probe payload too large")
    return HEADER.pack(b"HPU1", 1, kind, 0, sequence, len(payload), timestamp,
                       zlib.crc32(payload), 0) + payload


class FrameDecoder:
    def __init__(self):
        self.buffer = bytearray()

    def append(self, data):
        self.buffer.extend(data)
        frames = []
        while len(self.buffer) >= HEADER.size:
            magic, version, kind, reserved, seq, size, at, crc, tail = HEADER.unpack_from(self.buffer)
            if magic != b"HPU1" or version != 1 or kind not in range(1, 7) or reserved or tail or size > 65536:
                raise ValueError("invalid probe header")
            if len(self.buffer) < HEADER.size + size:
                break
            payload = bytes(self.buffer[HEADER.size:HEADER.size + size])
            if zlib.crc32(payload) != crc:
                raise ValueError("probe checksum mismatch")
            del self.buffer[:HEADER.size + size]
            frames.append((kind, seq, at, payload))
        return frames


def receive_exact(stream, count):
    data = bytearray()
    while len(data) < count:
        chunk = stream.recv(count - len(data))
        if not chunk:
            raise ConnectionError("USB connection closed")
        data.extend(chunk)
    return bytes(data)


def mux_request(stream, message):
    payload = plistlib.dumps(dict(message, ClientVersionString="HearPort USB Probe",
                                 ProgName="HearPort USB Probe", kLibUSBMuxVersion=3))
    stream.sendall(struct.pack("<IIII", len(payload) + 16, 1, 8, 1) + payload)
    size, version, kind, tag = struct.unpack("<IIII", receive_exact(stream, 16))
    if not 16 <= size <= 1048576 or version != 1 or kind != 8 or tag != 1:
        raise ValueError("invalid Apple device service response")
    return plistlib.loads(receive_exact(stream, size - 16))


def connect_usb(port):
    with socket.create_connection(("127.0.0.1", 27015), timeout=2) as stream:
        reply = mux_request(stream, {"MessageType": "ListDevices"})
    devices = [d for d in reply.get("DeviceList", []) if d.get("Properties", {}).get("ConnectionType") == "USB"]
    if len(devices) != 1:
        raise ConnectionError(f"需要且只连接一台 USB 设备；目前发现 {len(devices)} 台")
    stream = socket.create_connection(("127.0.0.1", 27015), timeout=2)
    try:
        reply = mux_request(stream, {"MessageType": "Connect", "DeviceID": devices[0]["DeviceID"],
                                     "PortNumber": socket.htons(port)})
        if reply.get("Number") != 0:
            raise ConnectionError("无法连接探针：请在 iPad 打开 USB Probe 并点开始监听，必要时解锁并信任电脑")
        stream.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        return stream
    except Exception:
        stream.close()
        raise


def percentiles(values):
    values = sorted(values)
    return {str(q): values[int((len(values) - 1) * q / 100)] if values else None for q in (50, 95, 99, 100)}


def run_session(stream, seconds, log):
    stopped = threading.Event()
    summary_received = threading.Event()
    state = {"last_reply": time.perf_counter(), "pongs": 0, "received": 0, "receiver": None, "error": None}
    rtt, processing, send_time, pacing = [], [], [], []

    def reader():
        decoder = FrameDecoder()
        try:
            while not stopped.is_set():
                data = stream.recv(65536)
                now = time.perf_counter_ns()
                if not data:
                    raise ConnectionError("iPad 关闭了 USB 通道")
                for kind, seq, sent, payload in decoder.append(data):
                    state["last_reply"] = time.perf_counter()
                    if kind == HELLO:
                        hello = json.loads(payload)
                        log("device_hello", **hello)
                        print("iPad 已连接：", hello, flush=True)
                    elif kind == PONG:
                        fields = struct.unpack("!10Q", payload)
                        recv_at, replied_at, received, wire_bytes, missing, duplicate, errors, phase, last_host, last_device = fields
                        rtt.append(max(0, now - sent - (replied_at - recv_at)) / 1e6)
                        processing.append((replied_at - recv_at) / 1e6)
                        state.update(pongs=state["pongs"] + 1, received=received,
                                     receiver={"received": received, "wire_bytes": wire_bytes, "sequence_gaps": missing,
                                               "duplicates": duplicate, "crc_errors": errors, "phase": phase})
                    elif kind == SUMMARY:
                        state["receiver"] = json.loads(payload)
                        log("device_summary", **state["receiver"])
                        summary_received.set()
                    else:
                        raise ValueError("unexpected response kind")
        except Exception as error:
            if not stopped.is_set():
                state["error"] = str(error)
                stopped.set()

    thread = threading.Thread(target=reader, daemon=True)
    thread.start()
    blocks = [secrets.token_bytes(960) for _ in range(256)]
    began = time.perf_counter_ns()
    due, ping_due, report_due = began, began, began + 1000000000
    end = began + int(seconds * 1e9)
    sequence = ping = skipped = 0
    try:
        while not stopped.is_set() and time.perf_counter_ns() < end:
            now = time.perf_counter_ns()
            if now < due:
                time.sleep((due - now) / 1e9)
            now = time.perf_counter_ns()
            pacing.append(max(0, now - due) / 1e6)
            frame = encode_frame(DATA, sequence, now, blocks[sequence % len(blocks)])
            stream.sendall(frame)
            sent = time.perf_counter_ns()
            send_time.append((sent - now) / 1e6)
            sequence += 1
            due += 2500000
            if sent > due + 2500000:
                skipped += (sent - due) // 2500000
                due = sent + 2500000
            if sent >= ping_due:
                stream.sendall(encode_frame(PING, ping, time.perf_counter_ns()))
                ping += 1
                ping_due = sent + 100000000
            if time.perf_counter() - state["last_reply"] > 3:
                raise TimeoutError("超过 3 秒未收到 iPad 回复，可能锁屏挂起、拔线或接收阻塞")
            if sent >= report_due:
                row = dict(sent=sequence, receiver=state["receiver"], elapsed_seconds=(sent - began) / 1e9,
                           rtt_last_ms=rtt[-1] if rtt else None, host_skipped_slots=skipped)
                log("progress", **row)
                print(f"{row['elapsed_seconds']:.0f}s · 已发 {sequence} · iPad 已收 {state['received']} · RTT {row['rtt_last_ms']} ms", flush=True)
                report_due = sent + 1000000000
        if state["error"]:
            raise ConnectionError(state["error"])
        stream.sendall(encode_frame(FINISH, sequence, time.perf_counter_ns()))
        if not summary_received.wait(3):
            raise TimeoutError("未收到 iPad 最终计数，结果不完整")
        complete = state["receiver"].get("received") == sequence and not state["receiver"].get("crc_errors")
        row = dict(complete=complete, sent=sequence, receiver=state["receiver"], elapsed_seconds=(time.perf_counter_ns() - began) / 1e9,
                   rtt_ms=percentiles(rtt), device_processing_ms=percentiles(processing), send_call_ms=percentiles(send_time),
                   pacing_lateness_ms=percentiles(pacing), host_skipped_slots=skipped)
        log("session_result", **row)
        print(json.dumps(row, ensure_ascii=False, indent=2), flush=True)
        return complete
    finally:
        stopped.set()
        try:
            stream.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        stream.close()
        thread.join(timeout=3)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seconds", type=int, default=180)
    parser.add_argument("--wait", type=int, default=120, help="等待首次连接或拔线重连的秒数")
    parser.add_argument("--port", type=int, default=52138)
    parser.add_argument("--output", type=Path, default=Path("out/usb-probe"))
    args = parser.parse_args()
    if not 1 <= args.seconds <= 3600 or not 1 <= args.wait <= 3600 or not 1 <= args.port <= 65535:
        parser.error("invalid duration, wait or port")
    args.output.mkdir(parents=True, exist_ok=True)
    path = args.output / time.strftime("usb-probe-%Y%m%d-%H%M%S.jsonl")
    with path.open("w", encoding="utf-8", buffering=1) as output:
        log_lock = threading.Lock()
        def log(event, **fields):
            with log_lock:
                output.write(json.dumps(dict(event=event, at_ns=time.perf_counter_ns(), **fields), ensure_ascii=False) + "\n")
        log("probe_start", seconds=args.seconds, packets_per_second=400, payload_bytes=960, frame_bytes=992)
        print("日志：", path.resolve(), "；等待 iPad USB Probe…", flush=True)
        timer = ctypes.windll.winmm if os.name == "nt" else None
        if timer:
            timer.timeBeginPeriod(1)
        deadline = time.perf_counter() + args.wait
        last_error = None
        try:
            while time.perf_counter() < deadline:
                try:
                    stream = connect_usb(args.port)
                except (OSError, ValueError) as error:
                    if str(error) != last_error:
                        print(str(error), flush=True)
                        last_error = str(error)
                    time.sleep(1)
                    continue
                log("connected")
                try:
                    return 0 if run_session(stream, args.seconds, log) else 1
                except (OSError, ValueError) as error:
                    log("interrupted", error=str(error))
                    print("测试中断：", error, "；等待重连，重连后重新计时。", flush=True)
                    deadline = time.perf_counter() + args.wait
                    last_error = None
            log("connection_timeout")
            return 1
        except KeyboardInterrupt:
            log("operator_stop")
            return 130
        finally:
            if timer:
                timer.timeEndPeriod(1)


if __name__ == "__main__":
    raise SystemExit(main())

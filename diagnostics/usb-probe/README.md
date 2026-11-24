# USB Feasibility Probe

> [!NOTE]
> This is a **standalone, disposable transport probe** separate from the main HearPort app. It sends generated test bytes over Apple's USB multiplexer (`usbmux`) to a loopback listener on `127.0.0.1:52138` — it carries **no** personal audio, pairing credentials, TLS, or HearPort authentication.

---

## Quick Start

1. **Install the probe app**  
   Download `HearPortUSBProbe-unsigned.ipa` from the manual **USB feasibility probe** GitHub Actions workflow, then sign and sideload it alongside HearPort.
2. **Connect via USB**  
   Plug in a data-capable USB cable, unlock the iPad, and tap **Trust** if prompted. Make sure Apple's Mobile Device Service is running on Windows (attach only one Apple USB device).
3. **Start the iPad listener**  
   Open **HearPort USB Probe** on your iPad and tap **开始监听** (*Start Listening*).
4. **Run the Windows probe script**  
   Run `Run-USB-Probe.cmd` (requires Python 3.11+). It waits up to 10 minutes for the app, then runs a 3-minute test session and writes logs to `out/usb-probe/`.

For custom timings (e.g., 5-minute run with a 2-minute wait):

```powershell
python diagnostics/usb-probe/usb_probe.py --seconds 300 --wait 120
```

---

## Protocol & Measurements

- **Traffic pattern**: Streams 400 generated 960-byte payloads per second (each prefixed with a 32-byte header, sequence number, and CRC32), plus 10 ping/pong exchanges per second to measure host-observed RTT minus iPad reply processing time (this is **not** one-way or acoustic latency).
- **Host isolation**: The host script filters out network-discovered devices and logs sender pacing/blocking separately so PC scheduling jitter isn't blamed on USB.
- **Session completion & reconnects**: A run is only marked complete once final receiver counts arrive. Disconnects or 3-second reply stalls are logged, after which the host waits for reconnection and restarts the session; press `Ctrl+C` to stop manually.
- **iPad logs & screen state**: Tap **导出 iPad 探针日志** (*Export iPad Probe Log*) to export iPad lifecycle events. Screen keep-awake is on by default (manual lock/unlock can be tested separately, though suspension in this audio-less probe does not predict background audio behavior).

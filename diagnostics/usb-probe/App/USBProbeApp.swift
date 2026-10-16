import SwiftUI
import Network
import USBProbeCore

@main
@MainActor
struct USBProbeApp: App {
    @StateObject private var model = ProbeModel()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                Form {
                    Section("USB 通道可行性验证") {
                        Text(model.status)
                        Text("端口 52138 · 仅在设备本地监听")
                        Text("Windows 经苹果设备服务连接；请使用支持数据传输的 USB 线。")
                        Button(model.running ? "停止监听" : "开始监听") { model.toggle() }
                        Toggle("测试时保持亮屏", isOn: $model.keepAwake)
                            .onChange(of: model.keepAwake) { _ in model.updateIdleTimer() }
                    }
                    Section("当前连接") {
                        LabeledContent("接收包数", value: "\(model.received)")
                        LabeledContent("序号缺口", value: "\(model.gaps)")
                        LabeledContent("校验错误", value: "\(model.errors)")
                        LabeledContent("接收速率", value: String(format: "%.3f Mbit/s", model.megabits))
                        Text("Windows 端记录往返延迟、发包调度和发送阻塞时间。")
                    }
                    Section("生命周期检查") {
                        Text("可以手动锁屏、返回 App，或拔线后重新插入。连接恢复后 Windows 探针会重新计时。")
                        Text("锁屏阶段用于观察普通 App 的挂起行为；正式音频播放的后台能力需在接入播放后验证。")
                    }
                    Section("本地记录") {
                        if let url = model.logURL { ShareLink("导出 iPad 探针日志", item: url) }
                        Text(model.build)
                            .font(.caption).textSelection(.enabled)
                    }
                }
                .navigationTitle("HearPort USB Probe")
            }
            .onChange(of: phase) { value in
                model.service.lifecycle(value == .active ? 0 : value == .inactive ? 1 : 2)
            }
        }
    }
}

@MainActor
final class ProbeModel: ObservableObject {
    @Published var status = "等待开始监听"
    @Published var running = false
    @Published var keepAwake = true
    @Published var received: UInt64 = 0
    @Published var gaps: UInt64 = 0
    @Published var errors: UInt64 = 0
    @Published var megabits = 0.0
    @Published var logURL: URL?
    let build = Bundle.main.object(forInfoDictionaryKey: "ProbeBuildID") as? String ?? "local"
    let service = ProbeService()
    init() {
        service.update = { [weak self] status, running, stats, rate, log in
            DispatchQueue.main.async {
                guard let self else { return }
                self.status = status; self.running = running
                self.received = stats.received; self.gaps = stats.gaps; self.errors = stats.errors
                self.megabits = rate; self.logURL = log; self.updateIdleTimer()
            }
        }
    }
    func toggle() { if running { service.stop() } else { service.start(build: build) } }
    func updateIdleTimer() { UIApplication.shared.isIdleTimerDisabled = running && keepAwake }
}

private struct ProbeStats {
    var received: UInt64 = 0, wireBytes: UInt64 = 0, gaps: UInt64 = 0, duplicate: UInt64 = 0, errors: UInt64 = 0
    var expected: UInt32 = 0, lastHost: UInt64 = 0, lastDevice: UInt64 = 0
    var json: [String: Any] { ["received": received, "wire_bytes": wireBytes, "sequence_gaps": gaps,
                               "duplicates": duplicate, "crc_errors": errors] }
}

final class ProbeService {
    fileprivate var update: ((String, Bool, ProbeStats, Double, URL?) -> Void)?
    private let queue = DispatchQueue(label: "HearPort.USBProbe")
    private var listener: NWListener?
    private var connection: NWConnection?
    private var decoder = ProbeFrameDecoder()
    private var timer: DispatchSourceTimer?
    private var stats = ProbeStats()
    private var status = "等待开始监听"
    private var phase: UInt64 = 0, previousBytes: UInt64 = 0
    private var previousAt: UInt64 = 0
    private var rate = 0.0
    private var finished = false
    private var logFile: FileHandle?
    private var logURL: URL?
    private var build = "local"
    private func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    func start(build: String) {
        queue.async {
            guard self.listener == nil else { return }
            self.build = build
            do {
                let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let url = directory.appendingPathComponent("USBProbe.jsonl")
                if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
                self.logFile = try FileHandle(forWritingTo: url)
                try self.logFile?.seekToEnd()
                self.logURL = url
                self.record("listener_start", ["build": build, "phase": self.phase])
                let parameters = NWParameters.tcp
                parameters.allowLocalEndpointReuse = true
                parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: 52138)
                let listener = try NWListener(using: parameters)
                self.listener = listener
                listener.stateUpdateHandler = { [weak self, weak listener] state in
                    guard let self, let listener, self.listener === listener else { return }
                    switch state {
                    case .ready: self.status = "已监听，等待 Windows USB 连接"; self.record("listener_ready"); self.publish()
                    case .failed(let error): self.record("listener_failed", ["error": "\(error)"]); self.stopOnQueue("监听失败：\(error)")
                    default: break
                    }
                }
                listener.newConnectionHandler = { [weak self] in self?.accept($0) }
                listener.start(queue: self.queue)
                let timer = DispatchSource.makeTimerSource(queue: self.queue)
                timer.schedule(deadline: .now() + 1, repeating: 1)
                timer.setEventHandler { [weak self] in
                    guard let self else { return }
                    let at = self.now()
                    self.rate = self.previousAt > 0 ? Double(self.stats.wireBytes - self.previousBytes) * 8_000 / Double(at - self.previousAt) : 0
                    self.previousBytes = self.stats.wireBytes; self.previousAt = at
                    if self.connection != nil { self.record("progress", self.stats.json.merging(["phase": self.phase]) { _, new in new }) }
                    self.publish()
                }
                self.timer = timer; timer.resume(); self.publish()
            } catch { self.stopOnQueue("无法启动：\(error)") }
        }
    }

    func stop() { queue.async { self.stopOnQueue("监听已停止") } }
    func lifecycle(_ phase: UInt64) {
        queue.async { self.phase = phase; self.record("lifecycle", ["phase": phase]) }
    }
    private func stopOnQueue(_ message: String) {
        record("listener_stop", ["reason": message])
        timer?.cancel(); timer = nil
        connection?.cancel(); connection = nil
        listener?.cancel(); listener = nil
        status = message; publish()
        try? logFile?.close(); logFile = nil
    }
    private func accept(_ stream: NWConnection) {
        guard connection == nil else { stream.cancel(); return }
        connection = stream; decoder = ProbeFrameDecoder(); stats = ProbeStats(); finished = false
        previousAt = now(); previousBytes = 0
        stream.stateUpdateHandler = { [weak self, weak stream] state in
            guard let self, let stream, self.connection === stream else { return }
            switch state {
            case .ready:
                self.status = "USB 已连接，正在接收测试数据"
                self.record("connected")
                let hello: [String: Any] = ["build": self.build, "port": 52138, "phase": self.phase,
                                            "os": ProcessInfo.processInfo.operatingSystemVersionString]
                self.send(.hello, stream: stream, payload: (try? JSONSerialization.data(withJSONObject: hello)) ?? Data())
                self.receive(stream); self.publish()
            case .failed(let error): self.disconnect(stream, reason: "\(error)")
            case .cancelled: self.disconnect(stream, reason: "cancelled")
            default: break
            }
        }
        stream.start(queue: queue)
    }
    private func receive(_ stream: NWConnection) {
        stream.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self, weak stream] data, _, complete, error in
            guard let self, let stream, self.connection === stream else { return }
            let receivedAt = self.now()
            do {
                for frame in try self.decoder.append(data ?? Data()) {
                    switch frame.kind {
                    case .data:
                        guard frame.payload.count == 960, !self.finished else { throw ProbeFrameError.invalidHeader }
                        if frame.sequence < self.stats.expected { self.stats.duplicate += 1 }
                        else {
                            self.stats.gaps += UInt64(frame.sequence - self.stats.expected)
                            self.stats.expected = frame.sequence + 1
                            self.stats.received += 1; self.stats.wireBytes += UInt64(frame.payload.count + 32)
                            self.stats.lastHost = frame.timestamp; self.stats.lastDevice = receivedAt
                        }
                    case .ping:
                        guard frame.payload.isEmpty else { throw ProbeFrameError.invalidHeader }
                        var payload = Data()
                        for value in [receivedAt,self.now(),self.stats.received,self.stats.wireBytes,self.stats.gaps,
                                      self.stats.duplicate,self.stats.errors,self.phase,self.stats.lastHost,self.stats.lastDevice] {
                            var big = value.bigEndian
                            withUnsafeBytes(of: &big) { payload.append(contentsOf: $0) }
                        }
                        self.send(.pong, stream: stream, sequence: frame.sequence, timestamp: frame.timestamp, payload: payload)
                    case .finish:
                        guard frame.payload.isEmpty else { throw ProbeFrameError.invalidHeader }
                        self.finished = true; self.status = "本轮计数已回传，等待下一次连接"
                        self.record("complete", self.stats.json)
                        self.send(.summary, stream: stream, payload: try JSONSerialization.data(withJSONObject: self.stats.json))
                        self.publish()
                    default: throw ProbeFrameError.invalidHeader
                    }
                }
                if complete || error != nil { self.disconnect(stream, reason: error.map { "\($0)" } ?? "peer_closed") }
                else { self.receive(stream) }
            } catch {
                self.stats.errors += 1; self.record("frame_error", ["error": "\(error)"])
                self.disconnect(stream, reason: "帧校验或格式错误")
            }
        }
    }
    private func send(_ kind: ProbeFrame.Kind, stream: NWConnection, sequence: UInt32 = 0, timestamp: UInt64 = 0, payload: Data) {
        do {
            let data = try ProbeFrame(kind: kind, sequence: sequence, timestamp: timestamp, payload: payload).encoded()
            stream.send(content: data, completion: .contentProcessed { [weak self, weak stream] error in
                if let error, let self, let stream { self.disconnect(stream, reason: "\(error)") }
            })
        } catch { disconnect(stream, reason: "\(error)") }
    }
    private func disconnect(_ stream: NWConnection, reason: String) {
        guard connection === stream else { return }
        record("disconnected", ["reason": reason, "completed": finished])
        connection = nil; stream.cancel()
        if !finished { status = "连接中断，等待重新插线或返回 App" }
        publish()
    }
    private func publish() { update?(status, listener != nil, stats, rate, logURL) }
    private func record(_ event: String, _ fields: [String: Any] = [:]) {
        let row = fields.merging(["event": event, "at_ns": now()]) { _, new in new }
        if var data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) {
            data.append(10); try? logFile?.write(contentsOf: data)
        }
    }
}

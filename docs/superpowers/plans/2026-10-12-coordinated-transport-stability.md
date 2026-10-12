# HearPort 传输稳定性协同实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在现有 Wi-Fi 场景和用户选择的总延迟预算内，实现自适应缓冲、动态源消费、有限恢复及可比较的随机数据测试。

**Architecture:** 沿用 Windows SenderService/MsQuic 和 iPad receiver/Jitter/render ring。源样本时间、播放期限与恢复状态共用，可靠流和 Datagram 分别管理修复。时钟修正与保持音高的时间伸缩分开估计，最终源速度统一约束。

**Tech Stack:** C++20、Swift Package、C11 atomics、Python unittest、MsQuic、Network.framework、现有 GitHub Actions。

**Spec:** `docs/superpowers/specs/2026-10-12-coordinated-transport-stability-design.md`。

## Global Constraints

- 在主工作区开发，保持现有配对、安全、控制连接和自动诊断上传结构。
- 总延迟由用户选择；正常目标小于上限，所有队列、前视和输出共用预算。
- 当前传输实验保持随机数据，真实音频验证另用固定样本；Opus 不进入本轮。
- 现有 ±0.1% 是时钟重采样参数，不限制新的缓冲动态变速。
- 所有恢复按源样本位置定案一次，过期修复不能阻塞新内容。
- 每组随机数据测试仍为 30 秒，顺序打乱与重复保留。测试总时长由计划计算，不能写死为 610 秒。
- Swift 和 iOS archive 在 GitHub Actions 验证；Windows 和分析器在本机验证。安装及听感不等于 CI 编译结果。
- FEC、重传、重复是分别验证的候选，不同时无条件启用。PCM16/24、拥塞算法、DSCP/ECN、独立短流和交织保留为条件性后续实验，本轮不默认改变音质或传输栈。

## Review Focus

- 乱序包在准备期限前到达时，不能已被播放准备逻辑提前补成静音。
- 换代、缓冲估计和处理状态重置后，旧包、旧反馈和旧修复不能影响新代际。
- 用户较小预算不足以容纳时间伸缩前视时，不能静默增加等待。
- 突发空窗或持续带宽不足时，延迟不能因慢放、修复或反馈冷却而无限增长。
- 包尺寸、时长和修复负载变化时，时间阈值与对照的源数据率不能失真。

## 执行顺序与验收

任务 1–6 构成可实际运行的共用控制；任务 7 接入 Datagram 修复候选；任务 8 把随机测试、诊断和分析串成下一轮可使用的程序。依次实施，单项验证后组合验证。

先增加保护真实行为的测试并观察失败，再实现；不为文档、常量和纯转发增加测试。每完成一个任务记录验证命令、结果和实际决策。最后检查跨任务接口与整体 diff，删除无关改动。

## Task 1: 预算与时钟映射

**Files:** 新建 `ios/HearPortReceiver/Sources/HearPortReceiver/PlayoutController.swift`、`ClockMapping.swift` 及 `Tests/HearPortReceiverTests/PlayoutControllerTests.swift`；修改 `JitterBufferConfiguration.swift`。

**Interfaces:**
- `PlayoutBudget(targetMilliseconds: Double, maximumMilliseconds: Double, outputReserveMilliseconds: Double)`，校验最小有效预算，目标不超过上限。
- `ClockMapping.observe(localSent: UInt64, remoteReceived: UInt64, remoteSent: UInt64, localReceived: UInt64)`；`map(remoteNanoseconds: UInt64) -> UInt64?`，同时提供不确定度与新鲜度。
- `PlayoutController.observeArrival(sourceFrame: UInt64, capturedAt: UInt64, receivedAt: UInt64)`；`decision(now: UInt64, nextSourceFrame: UInt64, playableFrames: Int, stagedSourceFrames: Int) -> PlayoutDecision`。
- `PlayoutDecision` 表达目标源时长、消费修正、准备期限及 normal/wait/conceal/resync。具体源缺口是否可修复由任务 7 在期限内处理。

- [ ] 添加时钟偏移、漂移、异常 RTT、过期映射测试；对称 10 ms RTT 样本只应产生可解释的映射和不确定度，不把 RTT/2 当实测单向延迟。
- [ ] 添加预算测试：最大 100 ms、剩余输出 10 ms 时准备时间为采集映射时间加 90 ms；处理前视增加后准备时间相应提前。
- [ ] 添加持续空窗、自适应目标回落及 stagedFrames 计费测试，确保上限不因目标变更重置。
- [ ] 实现因果到达统计、较快上调/缓慢回落、比例消费控制、死区与变化速率限制。测试幅度 2/5/10%，20% 仅为模型上界。
- [ ] 执行目标 Swift 测试；本机无 Swift 时保留明确未执行状态，在任务 8 的 Actions 中取得实际结果。

## Task 2: 时间与预算的控制协议

**Files:** 修改 `protocol/hearport-v1.proto`、`core/include/hearport/wire/control_message.h`、`core/src/wire/control_message.cpp`、`core/tests/control_message_tests.cpp`、Swift `ControlMessages.swift`、`ReceiverCoreTests.swift`、`ReceiverControlSession.swift` 和 Windows `sender_service.cpp`。

**Interfaces:**
- 协商 `coordinatedAudio = 0x10`，用于承载新媒体格式和控制消息；旧格式只在未协商时使用，避免安装先后顺序造成错误解析。
- 新控制消息：`AudioSetup`（envelope 40：stream_id、target_ms、maximum_ms、output_reserve_ms）、`ClockRequest`（41：request_id、local_sent_ns）、`ClockResponse`（42：request_id、local_sent_ns、remote_received_ns、remote_sent_ns）。时间字段使用 uint64。
- 扩展 `AudioProgress`：保留原字段 1–3，增加播放源位置、反馈生成时间和有效缓冲时长，消费者验证代际及新鲜度。
- 参数由 iPad 用户配置并发送，Windows 返回已接受配置；启动媒体前完成配置和初始时钟交换。

- [ ] 添加 C++/Swift 的固定字节向量与双向解码测试，包括 uint64、大时间值、字段缺失、非法预算和旧格式。
- [ ] 添加未知特性未协商时不发送新媒体格式、错误代际反馈无效的测试。
- [ ] 实现编码与现有握手状态衔接，时钟交换低频且限量，断线清理计时器。
- [ ] 验证 C++ control message 测试；Swift 编码测试在 Actions 验证。

## Task 3: 源样本时间及媒体记录

**Files:** 修改 Windows `wasapi_capture.h/.cpp`、`packetizer.h/.cpp`、`sender_service.h/.cpp`；扩展 C++ `wire/audio_datagram.h/.cpp` 和 Swift `AudioDatagram.swift`、`ReliableAudioRecords.swift`，更新对应 codec、packetizer、可靠记录测试。

**Interfaces:**
- 现有 `AudioDatagram` 保留；协商后使用 `TimedAudioRecord`。
- 新记录 32 字节大端头：stream_id u32、generation u32、sequence u32、frame_count u16、kind u16、captured_at_ns u64、source_frame u64，后接该区间的有效数据。普通 float32 120 帧双声道记录总长 992 字节。
- 测试模式根据实际包时长产生源位置与计划时刻；真实音频从 WASAPI QPC/采集位置计算首样本时间，经 normalizer 与 packetizer 传递。
- 可靠流按记录长度完整组装，不能把一次读回调或 StreamSend 当作一个记录。代际切换保留源位置连续。

- [ ] 添加捕获块拆分后每包首样本时间递增、跨块残留及采样率转换的测试。
- [ ] 添加新媒体头、分片/粘连读取、错误长度/代际、序号回绕与 uint64 源位置测试。
- [ ] 实现正常媒体格式和新格式的协商选择，路径尺寸不足时在提交前明确处理；不会依赖 IP 分片。
- [ ] 在现有 debug trace 中记录真实首样本时间与源位置。
- [ ] 执行 Windows audio/wire/record 目标测试和 Swift Actions 测试。

## Task 4: 发送队列期限与可靠流恢复

**Files:** 修改 Windows `sender_service.h/.cpp`、`quic_server.h`、`quic_server_msquic.cpp`、`reliable_audio_lag.h`、`reliable_audio_lag_tests.cpp`；新增 `windows/tests/audio_deadline_tests.cpp` 并接入 `windows/CMakeLists.txt`。

**Interfaces:**
- `ReliableAudioLag` 接受已协商的时间预算、源帧进度和反馈生成时刻；返回是否必须换代，不再用固定包数作为时间。
- 发送任务携带源时间、字节数及期限。API 受理、Datagram SENT、最终状态、可靠发送完成分别统计。
- 可靠流仍由 QUIC 重传；旧代际取消后保留控制连接。

- [ ] 添加有限发送队列测试：旧数据过期后被移除，仍有价值的更新音频可提交；包时长改变不改变时间判断。
- [ ] 添加过期反馈、序号回绕、无收到进度、冷却期间已过期音频及换代失败测试。
- [ ] 保持 MsQuic pacing，限制应用提交突发，不新增攒批等待；限制受理后待发送的数据量。
- [ ] 根据剩余期限、反馈延后与恢复成本判定换代，记录跳过源区间及理由。
- [ ] 构建 Windows sender/GUI，并执行 deadline、lag、debug trace 目标测试。

## Task 5: 按期限准备音频与统一恢复

**Files:** 修改 Swift `JitterBuffer.swift`、`QuicReceiver.swift`、`RenderRingBuffer.swift`、`RealtimeAudioMetrics.swift`；修改 `ReceiverCoreTests.swift`、`LockFreeReceiverTests.swift`、`RealtimeDiagnosticsTests.swift`。

**Interfaces:**
- Jitter 按源区间提供连续有效时长、含空洞的跨度与下一缺口，不能仅以 packets.count 判定就绪。
- `pumpLocked` 消费任务 1 的决策；只有到准备截止时间才把缺口定案为补偿。
- render 中已准备帧关联源位置/进度；总年龄包含 Jitter、处理和输出待播区间。
- normal/wait/conceal/resync 为一个恢复状态，代际切换清理旧任务，一次预充填。

- [ ] 添加后续包先到、缺失包在期限前到达仍能播放的回归测试。
- [ ] 添加超过目标但可加速恢复时保留音频、超过期限才跳过的测试。
- [ ] 添加长空窗后拒绝旧内容、重新收到数据只预充填一次的测试。
- [ ] 实现合并预算与恢复决策，保留现有 ring 与网络线程边界。
- [ ] 更新诊断，区分原始、修复、补偿、跳过及真正欠载，执行对应 Swift 测试。

## Task 6: 动态时间伸缩与音乐衔接

**Files:** 新建 Swift `StreamingTimeStretch.swift` 及 `StreamingTimeStretchTests.swift`；修改 `DriftController.swift`、`AudioSessionController.swift`、`QuicReceiver.swift`。

**Interfaces:**
- `StreamingTimeStretch.process(_ interleavedStereo: [Float], correction: Double) -> [Float]`；保存跨块状态，报告真实输入/输出源帧关系与前视。
- 采用相关性搜索与重叠衔接，双声道共用位置；源消费修正超过 0.1% 由时间伸缩实现，硬件输出采样率正常。
- 全局控制限定时钟修正与伸缩合成后的速度及持续时间。缓冲不足以容纳处理时不增加隐藏等待，返回正常处理或恢复决策。

- [ ] 添加持续正弦测试：加减速改变输出长度，音高基本保持；与直接重采样形成可观察区别。
- [ ] 添加双声道同相/反相、跨块连续、静音、起音瞬态、不足前视及 reset 测试。
- [ ] 实现低前视算法、短缺口预测/衰减和恢复衔接，报告处理积压，不把前视另加到目标后面。
- [ ] 将估计与重型准备工作留在回调外，回调继续消费 ring；数据中断时冻结时钟漂移估计。
- [ ] 执行 Swift 信号与接收测试；记录未通过听感实测的幅度，不能宣称音乐透明。

## Task 7: Datagram 有限修复候选

**Files:** 新建 C++ `core/include/hearport/repair_window.h`、`core/src/repair_window.cpp`、`core/tests/repair_window_tests.cpp` 和 Swift `RepairWindow.swift`、`RepairWindowTests.swift`；修改发送端、接收端、协议记录解析与对应 CMake。

**Interfaces:**
- 修复候选为 none、短窗口 XOR FEC、一次选择性重传、有限重复。可靠模式使用 none，由 QUIC 恢复。
- FEC 第一组候选为 4 个等长原始包配 1 个校验包；原始包立即发出。带组源位置、代际与长度信息；仅一个缺失可由此校验恢复。
- `RepairRequest`（envelope 43）批量携带当前代际缺失序号与剩余期限；发送缓存按时间淘汰。
- 同一缺口只有一份恢复记录，修复及时完成后取消剩余任务。总原始/修复/反馈发送受统一速率与提交预算约束。

- [ ] 添加任意单包缺失恢复、两包缺失无法误恢复、尺寸不符、旧代际、重复与晚到包测试。
- [ ] 添加乱序宽限、一次请求、过期不重传、FEC 已恢复后不再请求的测试。
- [ ] 添加原始数据率接近可持续交付率时限制冗余，以及长空窗不无限加冗余的测试。
- [ ] 实现各候选与 Datagram 收发，单变量启用；FEC/retry 不形成第二个等待时钟。
- [ ] 执行 C++/Swift repair 与 codec 目标测试，实际负载净收益由任务 8 的传输测试验证。

## Task 8: 测试计划、日志、配置和构建

**Files:** 修改 Windows `network_probe.h/.cpp`、`network_probe_tests.cpp`、`debug_session_trace.h/.cpp`、`debug_session_trace_tests.cpp`、`gui_main.cpp`；Swift `DebugSessionDiagnostics.swift`、`DebugSessionDiagnosticsTests.swift`、`HearPortApp.swift`；Python `diagnostics/analyze_network_probe.py`、`tests/test_network_probe_analysis.py`；必要时修改 `protocol_constants.json` 与协议说明。

**Interfaces:**
- UI 配置最大总延迟与正常目标；内部其它模块使用已协商预算，避免增加一组彼此独立的缓冲/重传延迟开关。
- 测试 manifest 明确每组包尺寸、包率、源时长、控制策略、修复候选和重复编号；两端使用同一个计划描述，避免继续复制静态推导。
- 测试报告新增源时间与实际控制字段；分析器保留旧报告读入并区分旧模型与新控制实测。
- 自动测试时仍关闭实际音频，使用有界虚拟源消费者执行同一控制决策；真正的发送反馈/换代启用情况明确记录。

- [ ] 添加两端一致的随机计划与总时长测试，保留 30 秒一组、打乱及重复；运行计划超过允许范围时在启动前处理。
- [ ] 添加相同源数据率对照、源空洞不能算有效缓冲、重复不能算额外音频、未来数据不能污染在线控制的分析测试。
- [ ] 增加完整阶段诊断：提交、SENT、最终状态、回调、准备、模拟播放、控制生效与修复负载；核对记录丢弃数和上传完整性。
- [ ] 保留一键启动、概览实时进度、自动回日志，进度根据实际 manifest 计算。
- [ ] 本机运行针对性 CTest 与 `python -m unittest tests.test_network_probe_analysis -v`，检查 diff。
- [ ] 提交/推送并运行现有 `ios-receiver.yml`，确认 Swift package 与 unsigned IPA 两个 jobs 成功；下载构建结果与元数据。
- [ ] 对代码进行一次独立整体审查，修复影响期限、源进度、线程安全或记录完整性的发现。
- [ ] 报告已实现功能、实测/模拟界限及下一轮相同环境测试入口；音乐透明度及声学上限以实际安装测试验证。

## 验证命令

Windows 使用现有 `out/build/vs2022-x64-msquic-vs`，从其 CMakeCache 获取实际 CMake 路径，避免猜测系统 PATH：

```powershell
& $cmakePath --build out/build/vs2022-x64-msquic-vs --config Debug --target hearport_sender hearport_sender_gui
& $ctestPath --test-dir out/build/vs2022-x64-msquic-vs -C Debug --output-on-failure -R 'hearport_(control_message|wire_codec|windows_audio|audio_deadline|reliable_audio_lag|debug_session_trace|network_probe|repair_window)_tests'
python -m unittest tests.test_network_probe_analysis -v
git diff --check
gh workflow run ios-receiver.yml --ref main
```

先确认当前 branch，若它不是 main，Actions 使用实际推送分支。新增测试目标与上述名称一致；Swift 由现有 workflow 的 `swift test` 和 Xcode archive 执行。目标验证完成后只为具体未解决风险追加检查。

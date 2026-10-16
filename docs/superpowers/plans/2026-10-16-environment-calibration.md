# 当前环境校准与参数推荐实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在程序中完成随机流量采样、同轨迹评估、三档选择、真实复核和两端结果展示。

**Architecture:** Windows管理测试轮次和发送预算；iPad采集元数据并复用播放控制器评估候选。复核使用真实双向反馈，报告和三档配置沿用现有回收和设置体系。

**Tech Stack:** C++20/Win32/MsQuic、Swift5.9/iOS16/SwiftUI、现有手写控制消息编码、CMake、GitHub Actions。

**Spec:** `docs/superpowers/specs/2026-10-16-environment-calibration-design.md`（用户已确认）

## Global Constraints

- 主工作区实施，保留现有网络、音乐和实时诊断；不开发新的音频补偿。
- 48kHz双声道float32，每包120帧、400包/秒、TimedAudioRecord992字节、单包匀速发送。
- 每组30/60/120秒；四组采样，三档去重后各正序/反序复核，组间5秒，最后10秒。
- 所有候选共用采样记录、时钟条件和起止范围；被动评估不发反馈。
- 延迟上限不超过用户选择及协议2000ms上限；输出预留统一占用总预算。
- 低延迟观测目标≤0.5%且最长缺口≤40ms；平衡≤0.1%且最长≤20ms；稳定优先按不可用源时长、最长缺口、源年龄依次选择。
- 实际网络、iPad与音频输出条件仍需实机验证；构建/回放不能替代这些证据。
- 音频、个人路径、原始日志留本地；结果不记录SSID。

## Review Focus

1. 发送期限/可靠换代改变输入时，回放不能被标记为真实复核——任务3/4验证。
2. 某组完全收不到包或时钟未建立时，不能生成零缺口推荐——任务2/3验证。
3. 等待、补偿和源跳过不能重复累计缺失源；尾部不能凭空视为丢包——任务2验证。
4. 退出、切后台、断线和回传失败不能发布完整推荐或应用半份设置——任务3/4验证。
5. 用户当前上限小于候选所需预留、三档重复或均未达目标时，UI和任务数必须一致——任务1/2/4验证。

## 定向验证命令

Windows新增目标命名为`hearport_calibration_tests`，沿用已配置目录：

```powershell
cmake --build out/build/vs2022-x64-msquic-vs --config Debug --target hearport_calibration_tests hearport_network_probe_tests hearport_reliable_audio_lag_tests hearport_sender_gui
ctest --test-dir out/build/vs2022-x64-msquic-vs -C Debug -R 'hearport_(calibration|network_probe|reliable_audio_lag)_tests' --output-on-failure
```

macOS Actions在`ios/HearPortReceiver`运行`swift test --filter EnvironmentCalibration`，并在消费者接口变化时运行`swift test --filter CoordinatedProbeTests`。测试新增时先确认对应断言失败，随后实现并验证通过；最终仍走已有iOS完整测试/归档门禁。

## Task 1: 校准计划与两端编码

**Files:** 新增`windows/include/hearport/windows/calibration.h`、`windows/src/calibration.cpp`、`windows/tests/calibration_tests.cpp`、`ios/HearPortReceiver/Sources/HearPortReceiver/EnvironmentCalibration.swift`、`ios/HearPortReceiver/Tests/HearPortReceiverTests/EnvironmentCalibrationTests.swift`；修改`core/include/hearport/wire/control_message.h`、Swift `ControlMessages.swift`、`windows/CMakeLists.txt`。

**Interfaces:** 两端能力位`environmentCalibration=64`。C++ `CalibrationOptions{seconds,maximum_ms}`、`CalibrationBudget{target_ms,maximum_ms}`；Swift同义模型。`MakeCalibrationBudgets(maximum_ms,output_reserve_ms)`/`calibrationBudgets(maximum:outputReserve:)`产生完全一致的去重候选。

`CalibrationMessage`使用现有`probeManifest`承载，首字节4，第二字节为种类：setup=0、round=1、ack=2、analyze=3、selection=4、progress=5。其余整数按字段声明顺序大端编码；变长列表先写UInt16条目数，所有消息必须完全消费输入、保留位为0。

- setup字段：UInt32 planID、UInt16 seconds、UInt16 maximum。
- round字段：UInt32 planID、UInt8 phase(0采样/1复核)、UInt8 index、UInt8 count、UInt8 profileMask、UInt8 reliable、UInt8 reserved、UInt16 seconds/target/maximum/outputReserve、UInt32 firstSequence/generation、UInt64 firstSourceFrame。
- ack字段：UInt32 planID、UInt8 phase/index；analyze仅UInt32 planID。
- selection字段：UInt32 planID、列表；每项UInt8 profileMask/reliable、UInt16 target/maximum/outputReserve。profileMask三个位表示低延迟/平衡/稳定优先，重复配置合并掩码。
- progress字段：UInt32 planID、UInt16 completed/total。
- round的index/count限制1...10，seconds为30/60/120，复核掩码1...7、采样为0；计划、流ID和会话关联。

- [ ] 先写候选与编码测试：相同输入两端候选一致；预算格点包含用户上限；target>reserve且target≤maximum−5；截断/额外字节/非法阶段/超上限被拒绝。

  Swift测试`testCandidateBudgetsRespectReserveAndIncludeUserCeiling`断言：maximum=95/reserve=11时最大候选为95，target都为5的倍数且11<target≤maximum−5；maximum=20/reserve=20时结果为空。`testCalibrationMessageMatchesSharedFixtureAndRejectsTrailingBytes`断言两端共享fixture完全一致，额外附加一个0字节必须解码失败。
- [ ] 在本地C++目标及Actions Swift目标观察测试失败，分别保留对应命令输出。
- [ ] 实现候选生成和编码；最大值格点按设计稿，每个target向上取整到5ms，非法组合排除，候选按maximum/target排序。
- [ ] 共享一个合成计划十六进制fixture，在C++/Swift测试中逐字节断言相同；不要引入JSON/通用协议新依赖。
- [ ] 运行新增目标及原有控制消息测试，通过后提交。

## Task 2: 元数据回放、指标与三档选择

**Files:** 新增`EnvironmentCalibrationReplay.swift`及相应`EnvironmentCalibrationReplayTests.swift`；修改`CoordinatedProbe.swift`以允许校准传入每组时长和元数据，现有默认30秒调用保持相同行为。

**Interfaces:** `CalibrationPacket`包含round、receivedAt、capturedAt、uncertainty、sequence、generation、sourceFrame、frameCount及kind，不包含随机负载。`CalibrationRoundTrace`包含轮次配置、接收事件、消费tick时间、完整性、clock状态及起止边界。

`CalibrationReplay.evaluate(trace:budget:) -> CalibrationMeasurement`复用独立`ProbeConsumer`；`CalibrationSelector.select(measurements:) -> [CalibrationRecommendation]`返回三档的配置、观测指标和达标状态；`CalibrationAnalysis`携带各轮候选记录、固定期限曲线、分块结果及输入指纹。

`CalibrationMeasurement`包含消费源帧、及时原音帧、等待/补偿/跳过的互斥不可用源区间、最长缺口、启动等待、源年龄分位及最大值、变速分布、数据完整性。分位数采用排序后`floor((n−1)*q)`；空样本为缺失值，不能当作0ms。

记账区分两条时间轴：源不可用量取补偿/跳过源区间的并集；输出中断取运行中等待/不可用输出时间区间的并集。两者分别展示，不能相加。选择器使用两者占各自有效观测范围比例的较大值作为“缺口占比”，两条时间轴最长缺口的较大值作为“最长缺口”；启动等待和不可观察尾部均单独列出。

相同传输/预算的两次采样按有效范围加权汇总占比，最长值取两轮最大，源年龄P95从两轮源年龄样本合并后的分布计算。结果仍保留每轮指标，任一轮无有效时钟或数据不完整时不能标记为完整推荐；复核仍按轮单独展示。

- [ ] 先写真实风险用例：相同轨迹候选输入指纹一致；加宽固定期限不能恢复未接收数据；一个40ms缺口不能由平均分块变为四个10ms缺口；记录截断尾部不算永久丢失；缺少clock/全部未接收不能得到有效推荐。
- [ ] 写因果性与记账用例：未来到达事件不影响过去决策；一次源跳过只计一次；重复包不增加覆盖；跨代保留与原消费者一致。
- [ ] 写选择测试：低延迟/平衡阈值边界、无达标候选、三档相同、相同效果取更低预算，以及排序确定性。

  `testSelectorUsesVisibleTargetsAndMergesIdenticalRecommendations`使用三条完整观测：A=(P95=35ms,不可用0.4%,最长30ms)、B=(65ms,0.08%,15ms)、C=(100ms,0.01%,10ms)，断言低延迟=A、平衡=B、稳定优先=C；只有C时三档合并为一个配置且掩码为7。`testNoClockOrNoReceivedPacketsCannotProduceVerifiedRecommendation`断言三档均无有效推荐。
- [ ] 观察测试失败后实现回放、固定期限覆盖和选择；评估只保存元数据，不拷贝每个候选的负载，不产生音频输出。
- [ ] 保留各30秒轮次和5秒连续块；用固定种子对配对块差异作重采样展示波动，不据零观测/区间重叠宣称稀有故障概率或等效。
- [ ] 运行新回放/选择测试和现有`CoordinatedProbeTests`，通过后提交。

## Task 3: 校准会话与真实复核

**Files:** 修改`sender_service.h/.cpp`、`sender_authentication.h/.cpp`、`ReceiverControlSession.swift`、`DebugSessionDiagnostics.swift`；在上述校准模型文件中定义阶段状态，不重构其他测试。

**Interfaces:** `SenderService::ConfigureCalibration(CalibrationOptions)`仅启动前可调用；`HandleCalibrationMessage`校验当前phase/planID/index，`calibration_progress()`返回阶段和已完成/总组数。

iPad `onCalibrationProgress`供UI观察；`DebugSessionDiagnostics`提供采样快照和完成的`CalibrationAnalysis`，报告生成读取一致快照。采样完成后Windows发analyze，iPad计算并发selection，Windows由已知候选生成复核轮次。

- [ ] 先写状态用例：非本会话/乱序ack不能推进；旧端缺少能力位时明确拒绝；被动实例反馈计数0；实际复核配置与selection一致；后台/中断/全部无数据不进入完成状态。
- [ ] 两端只在校准模式声明/要求新能力；setup在现有StartStream/AudioSetup前提供测试上限，输出预留继续由iPad获取并回报。
- [ ] 在现有ProbeWorker增加校准分支，使用同一随机负载生成/SendProbe/trace路径。每组先协商round并等待ack，再按该组预算设置发送期限、ReliableLag及代际；采样顺序ABBA/BAAB由planID确定。
- [ ] 采样权威消费者使用采样预算并独占反馈；其他候选只在分析阶段回放。每组边界、完全无数据和时钟无效均记录，旧代际数据不进入下一组。
- [ ] 分析在接收锁外独立队列串行运行，逐候选报告进度，可取消；分析阶段暂停测试数据，仅保留必要连接/时钟更新。分析等待上限120秒，超时结束并保存部分诊断。
- [ ] 校准会话使用现有3600秒诊断保护上限，工作线程完成实际任务后主动结束；GUI预计时长由任务数计算。默认最多10组，复核候选按profileMask合并并正序/反序重复。
- [ ] selection只接受该上限/预留下合法候选；新复核结果独立保存，不再回流调参。阶段异常沿用诊断结束/回传流程。
- [ ] 运行状态、预算和ReliableLag相关定向测试，通过后提交。

## Task 4: 报告、持久化及两端界面

**Files:** 修改`gui_main.cpp`、`HearPortApp.swift`、en/zh-Hans `Localizable.strings`、`DebugSessionDiagnostics.swift`；新增`CalibrationResultsView.swift`仅放校准结果SwiftUI视图。

**Interfaces:** iPad的`CalibrationResult`为Codable，包含会话、测试时间、设备/输出条件、上限、三档结果、曲线、两次复核、完整性和限制。完成后以UserDefaults Data保存最近一次结果。诊断文本新增独立版本节`calibration_summary_v1`、`calibration_curve_v1`、`calibration_validation_v1`；Windows只解析这些明确节，不扫描自由格式日志推断推荐。

- [ ] 先写报告/应用用例：不完整会话不能替换已保存完整结果；应用三项参数一致更新且下次连接生效；未知/缺字段结果不能被当作完整推荐；零观测显示“本次未观察到”。
- [ ] Windows网络测试设置增加用途、最大上限和每组时长，输入框沿用现有样式；进度在概览显示阶段，回传阶段两端明确显示回传状态。
- [ ] 两端展示采样参考曲线与独立复核；区别正常目标/最大预算/观测源年龄，提供三档指标、达标状态和限制。Windows沿用GDI绘制曲线，不增加Web服务或Python运行时。
- [ ] iPad设置增加校准结果入口和三档应用按钮；使用现有模式/正常目标/最大延迟设置，保存后下次连接生效；传输选项名称使用Datagram/Reliable。
- [ ] 仅完整报告落盘后使用既有确认回收；被取消的会话显示中断，不覆盖已完成结果，也不显示完成推荐。
- [ ] 运行报告/偏好测试并构建Windows GUI、iOS Release，检查文字布局和控件状态，通过后提交。

## Task 5: 集中验证与交付

**Files:** 仅修改直接相关的现有测试/工作流；需要时新增手动`environment-calibration.yml`运行定向Swift校准测试，保留最终`ios-receiver.yml`实际归档流程。

- [ ] 本地CMake定向运行calibration、network_probe、reliable_audio_lag、control_message目标，在calibration状态用例中覆盖sender_authentication协商；不为本功能启动全工作区E2E。
- [ ] Actions核对Swift校准、现有探测和控制用例，完成iPad Release IPA，下载并核对版本、构建ID与校验值。
- [ ] 用固定合成轨迹验证每档输入一致、重跑结果一致；确认真正复核阶段使用独立输入且没有被标记为配对因果改善。
- [ ] 对整个分支做一次新上下文代码审查，修复阻断/重要缺陷；检查最终diff仅涉及校准需求。无需逐小改动分派实现者和审查者。
- [ ] 交付Windows程序与iPad包、操作入口及尚需实机验证的清单；未在真实设备跑完时不声称校准效果已通过。

## 执行方式

建议在当前会话直接实施：这些任务依赖同一套两端接口，主工作区执行并集中验证可减少上下文和合并成本；完成后仅安排一次独立审查。开始实施前确认本计划覆盖已批准设计，之后连续执行，不逐项向用户询问是否继续。

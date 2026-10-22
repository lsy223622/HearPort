# 自动连接与 iPad 快捷指令验证

## 日常使用

Windows 设置中启用“登录后自动启动”，程序在当前用户登录后启动到托盘并开启发送服务。已经启用时，手动运行移动后的 HearPort 会把本应用的旧启动路径修复为当前路径。关闭的启动项不会被自动启用；Windows 任务管理器中的“启动应用”禁用状态仍由系统管理。

iPad 设置中“自动恢复连接”使用已配对电脑。网络或 USB 恢复、回到前台、电脑停止后重新可用时继续尝试。手动断开暂停当前进程中的自动恢复；点击连接或运行连接快捷动作重新启用。已验证电脑明确拒绝凭据时停止自动重试，凭据保留供用户手动处理。

未播放音频的 iPad App 可能被系统挂起。恢复发现依赖系统给 App 执行机会；快捷指令是尝试获取执行机会的入口，不是无限后台服务。iPad 重启后首次解锁、局域网权限、USB 信任/有线配件权限仍适用。

## 内置动作

安装新版本后先打开一次 HearPort 并完成配对，然后在“快捷指令 → App → HearPort”查找动作。

| 动作 | 执行方式 | 用途 |
| --- | --- | --- |
| 播放电脑音频 | `AudioPlaybackIntent`，本 SDK 元数据标为 iPadOS 17.2 起 | 优先验证的无界面播放入口 |
| 后台连接 | 普通 `AppIntent`，iPadOS 16 起 | 与音频专用动作比较系统执行行为 |
| 打开并连接 | 前台 AppIntent | 解锁/打开 App 可接受时的明确入口 |
| 断开电脑音频 | 音频动作，iPadOS 17.2 起 | 停止播放并暂停本进程自动恢复 |
| 读取连接状态 | 后台动作 | 返回 JSON 状态，并记录诊断 |
| 记录自动化触发 | 后台动作 | 在链式快捷指令起点插入诊断标记 |

三种连接动作均可选择“自动（USB 优先）”“仅网络”“仅 USB”。仅 USB 不回退 Wi-Fi；仅网络不升级 USB。重复执行同一路线动作复用正在建立/已建立的连接。其他路线已工作、诊断测试进行中时返回原因，不抢占。

本版本内置十个 App Shortcuts：音频连接和普通后台连接各预置自动/网络/USB 三种，另有前台连接、断开、状态和触发标记。它们随 App 安装，不依赖 `.shortcut` 文件签名。设置 → 快捷指令与自动化中的系统按钮可打开本 App 的快捷指令页。

### 建议配置的原生快捷指令

在“快捷指令”中新建下列三个快捷指令（也可直接运行 App 自动提供的动作）：

1. **HearPort Wi-Fi**：播放电脑音频（仅网络）。
2. **HearPort USB**：播放电脑音频（仅 USB）。
3. **HearPort 后台对照**：后台连接（按场景选路线）。

另外用“打开并连接”作为前台对照。首次冷启动验证直接运行待测连接动作；不要在前面加“记录自动化触发”，因为前置动作可能先唤醒 App，改变冷启动条件。诊断标记应单独作为触发对照；运行后可另读连接状态。验证时保持电脑播放同一段可听音频，避免把音源静音当成启动失败。

在“自动化”中分别设置“加入指定 Wi-Fi”和“充电器已连接”触发上述指令；选择“立即运行”（系统版本允许时）。充电触发也会响应普通充电器，而且可能早于电脑 USB 数据连接就绪，所以 USB 动作返回等待并不代表失败。触发器必须在 iPad 上由用户配置和授权，App 无法代建个人自动化。

## URL 前台对照包

Actions 的 `HearPort-shortcuts` artifact 包含五个固定 URL 快捷指令、源文件和 `signing-results.json`。仅根目录签名成功的 `.shortcut` 才标为可导入；`sources/` 是未签名生成源。

2026-10-22 首次 CI 实测：五个文件的签名都被系统以“必须登录 iCloud”拒绝。GitHub 运行器没有个人 iCloud 账户，因此当前包中的生成源不能直接当成可导入文件。内置 App Shortcuts 可直接使用；URL 对照也可以在 iPad 上新建“URL → 打开 URL”两步指令，不需要 Mac。

| URL | 操作 |
| --- | --- |
| `hearport://connect` | 自动路线连接 |
| `hearport://connect?route=network` | 仅网络连接 |
| `hearport://connect?route=usb` | 仅 USB 连接 |
| `hearport://disconnect` | 断开并暂停自动恢复 |
| `hearport://status` | 打开连接详情 |

URL 打开 App 属于前台路径。它在解锁设备上成功不能证明后台音频动作也能成功。URL 不接受主机、PIN、凭据和回调参数。

## 一次集中实机验证

每个场景先断开，再运行一个连接入口。依次比较音频动作、普通后台动作、前台动作、URL；前台动作可能要求解锁，这本身就是结果。

| 场景 | 重点记录 |
| --- | --- |
| App 前台、电脑可用 | 所有入口能否连接并出声 |
| 回桌面但不强退，随后锁屏 | 音频/后台动作是否无需解锁出声 |
| 手动强退后触发 | 系统是否实际调用动作/启动进程，不能由前两项推断 |
| iPad 重启且已首次解锁 | 进程冷启动和 Keychain 可用性 |
| 重启后尚未首次解锁 | 是否被系统/凭据权限阻挡，不据此删除配对 |
| Wi-Fi 自动化触发，电脑随后开启 | 等待能否在执行机会仍存在时恢复 |
| USB 插入、普通充电器插入 | 数据路线与充电触发分别验证 |
| 已连接时反复触发 | 不重建、不短暂断音、不重复引擎 |
| 手动断开后网络波动 | 不立即自动连接；明确快捷动作可以恢复 |
| 电脑临时停止/重启 | 可用后恢复；诊断正常完成不擅自重开 |

每项记录：触发方式、前后台/锁屏状态、系统是否提示、实际出声、约耗时。全部完成后导出 iPad 诊断即可，不需要每项都回传一次。

## 分阶段结果解释

动作返回 JSON 中 `result` 可以是：`received_audio_rendered`（收到音频并进入渲染）、`engine_started`（引擎已启动）、`waiting`、`pair_in_app`、`credential_unavailable`、`authentication_rejected`、`audio_failed`、`another_route_active`、`another_request_active`、`test_running`、`cancelled`、`disconnected`。

日志 `automation_stage` 含请求 ID、进程 ID、系统/构建、界面是否已出现、App 状态、进程和动作耗时。阶段包括 `action_entered`、`connection_attempt`、`peer_authenticated`、`session_ready`、`audio_engine_started`、`received_audio_rendered`、`action_returned`。没有收到的音频不会凭引擎启动被标为出声；真实静音也可能已经渲染，但听感仍需实机确认。

若触发后完全没有新进程/动作记录，只能确认 App 没有记录到执行，不能据此区分系统未触发、未获调度或签名/权限问题。若已有 `action_entered`，则继续按认证、会话、输出阶段定位。CI 编译和快捷指令签名分别只证明构建与分发，均不证明 iPad 锁屏执行通过。

导出后可在本地执行 `python diagnostics/analyze_automation.py <导出的日志>`，按请求汇总阶段和耗时。空结果表示没有可分析记录，不会自动判定系统触发失败；`audible_sound` 始终留给实机确认。不要把原始日志提交公开仓库。

Apple 参考：[App Shortcuts](https://developer.apple.com/documentation/appintents/app-shortcuts)、[AudioPlaybackIntent](https://developer.apple.com/documentation/appintents/audioplaybackintent)、[个人自动化设置触发器](https://support.apple.com/guide/shortcuts/apde31e9638b/ios)、[无需确认的自动化](https://support.apple.com/guide/shortcuts/apd602971e63/ios)、[快捷指令签名](https://support.apple.com/guide/shortcuts-mac/apd455c82f02/mac)、[USB 配件访问](https://support.apple.com/en-us/111806)。

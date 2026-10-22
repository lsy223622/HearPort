# Connection Automation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 完成已授权的连接恢复、Windows 登录启动修复和 iPad 快捷指令验证入口。

**Architecture:** 一个进程级 ReceiverRuntime 复用现有连接与音频方法，界面和自动化共享状态。可测试的纯策略约束恢复、路线和 URL；Windows 只修复已启用的本应用启动项。

**Tech Stack:** Swift 5.9 / SwiftUI / AppIntents / Network；Win32 C++；Python；GitHub Actions。

**Spec:** docs/superpowers/specs/2026-10-22-connection-automation-design.md

## Global Constraints

- iOS 16；unsigned IPA；两端发布产物由 Actions 生成。
- 主工作区连续实施；不删除因波动暂不可用的配对凭据。
- 不用静音保活，不宣称 CI 等同锁屏实机验证。

## Review Focus

- 手动断开后前台/网络恢复不能立即重连。
- 身份拒绝停止重试，但不删除 Keychain。
- 重复快捷动作不能打断现有播放或诊断。
- USB 专用动作不能回退到无线。
- 后台冷启动不依赖 SwiftUI onAppear，且结果区分引擎启动与收到音频。

## Tasks

- [ ] 1. 添加连接意图、路线选择与 URL 解析回归测试；迁移共享运行状态；实现前台/路径恢复。
- [ ] 2. 校验并修复已启用的 Windows 启动命令；添加命令策略测试，不修改用户关闭的设置。
- [ ] 3. 实现兼容 iOS 16 的快捷动作、App Shortcuts、URL 入口和本地分阶段诊断；生成可重复的快捷指令测试包。
- [ ] 4. 集中运行本地测试与独立审查；Actions 构建两端并验证元数据/产物；更新使用与实机验证方法。

## Execution record

- 2026-10-22: 用户已授权计划后直接连续开发；实机系统触发需安装后在设备上配置，开发和可执行验证先一次完成。

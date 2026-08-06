# FastSCP 设计文档

> 日期:2026-08-06
> 目标:在 macOS 上,通过 Finder 右键快速把文件/文件夹用 SCP 传到目标服务器的指定路径。

## 目标与非目标

### 目标
- 在 Finder 里右键文件/文件夹,快速 SCP 到已配置的 SSH 服务器指定路径。
- 复用用户已有的 `~/.ssh/config`,无需重复配置服务器。
- 重复场景零摩擦:一键发送到"上次目标"。
- 需要换地方时,只弹一个很小的窗口选择目标路径。

### 非目标(YAGNI,v1 不做)
- 不做服务器自身的图形化管理界面。
- 不做密码输入框(依赖 ssh-agent/密钥;passphrase 未入 agent 的情况记为已知限制)。
- 不做断点续传(v1 用 `scp`;`rsync` 留作后续)。
- 不做"按源文件夹记忆不同目标",v1 用全局最近目标列表。

## 技术选型

| 决策点 | 选择 | 理由 |
|---|---|---|
| 右键集成 | Finder Sync 扩展 | macOS 上唯一受支持的自定义右键菜单方式 |
| SSH/传输实现 | shell out 到系统 `ssh`/`scp` | 完全继承 `~/.ssh/config`(user/host/port/identity/ProxyJump),零重复实现 |
| 服务器列表来源 | 解析 `~/.ssh/config` 的 `Host` 行 | 零重复配置 |
| 路径浏览 | `ssh <alias> 'ls -ap <path>'` 解析目录 | 轻量、通用 |
| 传输命令 | `scp -r <srcs> <alias>:<path>` | 用别名直接走 ssh config;解析 stderr 进度驱动进度条 |
| UI | SwiftUI + NSPanel | agent app,无 Dock 图标 |
| 工程生成 | xcodegen | 用 YAML 生成 `.xcodeproj`,避免手编 pbxproj |

## 架构

两个 target:

1. **`FastSCP`(主 App,`LSUIElement = true`)**
   - 无 Dock 图标、不在前台出现。
   - 职责:解析 `~/.ssh/config`;执行所有 SSH/SCP;提供唯一的小弹窗 UI;持久化最近目标。
2. **`FastSCPFinderSync`(Finder Sync 扩展)**
   - 职责:在 Finder 提供右键菜单;抓取选中路径;交给主 App。
   - 自己不做任何 SSH(沙盒限制 + 架构分层)。

### 交接(扩展 → 主 App)
扩展把选中的路径写入临时文件(每行一个),用自定义 URL scheme 唤起主 App:
- 一键/最近项:`fastscp://quick?list=<tmpfile>&target=<alias:path>`
- 选择目标:`fastscp://choose?list=<tmpfile>`

主 App 通过 `.onOpenURL` 接收并执行。扩展始终只做"菜单 + 抓路径 + 唤起"三件事。

## 交互流程

### 右键菜单(由扩展提供)
```
FastSCP ▸
  ├─ 发送到 server1:/var/www        ← 有"上次目标"时才显示,零弹窗
  ├─ 最近目标 ▸
  │    ├─ server2:/opt/app/logs
  │    └─ server1:/tmp
  └─ 选择目标…                       ← 只在换地方时弹小窗
```

### 一键快发流程
右键 → 点"发送到上次目标" → 后台 `scp` → 完成出系统通知。**全程无弹窗**。

### 选择目标流程
右键 → "选择目标…" → 弹一个小弹窗 → 选服务器 + 浏览/输入路径 → 发送。

## 唯一的小弹窗

约 360×440pt,无边框浮动 NSPanel,出现在鼠标附近。

```
┌─ 选择目标 ────────────────────┐
│ 服务器 [server1        ▾]      │  紧凑下拉,默认上次那台
│ 路径   [/var/www/        ] ↵  │  可直接输入/粘贴,回车跳转
│ ┌──────────────────────────┐ │
│ │ 📁 ..                     │ │  约 7 行可见,双击进入
│ │ 📁 html                   │ │  Cmd+↑ 或点 .. 返回上层
│ │ 📁 logs                   │ │
│ │ 📁 config                 │ │
│ │ ...                       │ │
│ └──────────────────────────┘ │
│ [  发送 3 项 → server1:/var/www  ] │  底部发送栏
└──────────────────────────────┘
```

交互细节:
- 双击文件夹 → 进入;`..` / `Cmd+↑` → 返回上层;`Esc` → 关闭。
- 路径输入框可键入绝对路径,回车跳转。
- 切换服务器下拉 → 路径浏览器重新列根目录(或该服务器上次停留路径)。
- 发送时底部栏原地变成进度条(同一弹窗),不另开窗;完成出通知。

## 记忆(最近目标)

每次成功发送后,把 `{alias, remotePath, timestamp}` 写入持久存储(`UserDefaults`)。
- 同一 (alias, remotePath) 去重,更新时间戳。
- 按时间戳倒序,上限 5 个。
- 最近一条 = 右键菜单"发送到 X"的一键项。

## 认证与错误处理

- **认证**:依赖 ssh-agent / 密钥(macOS 钥匙串,`AddKeysToAgent yes`)。已知限制:若密钥有 passphrase 且未加入 agent,GUI 无终端无法提示。
- **ssh/scp 失败**(主机不可达 / 认证失败 / 远程写权限不足):把 stderr 展示给用户(弹窗内内联,或一键场景走系统通知)。
- **`~/.ssh/config` 为空或无 Host**:显示"未配置服务器"+ "打开 ~/.ssh/config" 按钮。
- **传输中取消**:kill `Process`。

## 测试策略

可单测的核心(TDD):
- `~/.ssh/config` 解析器(给定样例文本,正确产出 Host 列表与字段)。
- `ls -ap` 输出解析器(给定样例,正确区分目录/文件、跳过 `./` `../`)。
- `scp` stderr 进度解析器(给定样例进度行,产出百分比/速率)。
- 最近目标去重 / 上限 / 排序逻辑。

GUI 与 Finder 集成:手动测试(真机右键 + 一台真实 SSH 服务器)。

## 工程结构(xcodegen)

```
FastSCP.xcodeproj            # 由 project.yml 生成
project.yml                  # xcodegen 工程定义(真源)
Sources/
  FastSCP/                   # 主 App target
    App/                     # 入口、onOpenURL、agent 配置
    Config/                  # ssh config 解析
  FastSCPFinderSync/         # Finder Sync 扩展 target
    FinderSync.swift
    Info.plist
  Shared/                    # 两个 target 共享(如 URL scheme 常量、最近目标模型)
Tests/
  FastSCPTests/              # XCTest,覆盖上述可测核心
docs/plans/
  2026-08-06-fast-scp-design.md
```

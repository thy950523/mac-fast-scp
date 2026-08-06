# FastSCP

> 在 macOS Finder 右键里,把选中的文件/文件夹一键 SCP 到 SSH 服务器。

## 功能简介

FastSCP 是一个 macOS 右键菜单扩展,目标是把"把东西传到服务器"这件事做到和 Finder 自己一样顺滑。

- 🖱 **Finder 右键菜单**:在任意文件/文件夹上右键 → `FastSCP ▸ ...`
- ⚡ **一键发送到上次目标**:记住你上次传到哪儿,下次右键直接点一下就发,**全程零弹窗**。
- 📋 **最近发送**:自动记住最近 5 次发送的目标,右键菜单里直接列出来。
- 🎯 **小弹窗选目标**:需要换地方时,弹一个 360×440 的小窗:服务器下拉 + 路径浏览(双击进入 / 返回上层 / 直接键入路径)+ 底部"发送"。
- 🔐 **零配置服务器列表**:直接读你已有的 `~/.ssh/config`,Host 别名直接当 SSH alias 用(系统 `scp`/`ssh` 自己解析 user/host/port/identity/ProxyJump),不维护第二份配置。
- 📊 **传输进度**:解析 `scp` stderr 显示百分比;`ssh-agent` + 密钥认证直接走系统。
- 🔕 **完成通知**:quick-send 没有面板,通过 macOS 通知告知成功/失败。

## 架构一览

两个进程,职责分明:

```
┌────────────────────────────┐         ┌──────────────────────────────┐
│ FastSCPFinderSync           │ 写文件  │ FastSCP (agent app,无 Dock 图标) │
│ (沙盒,Finder Sync extension)│────────▶│ 读文件 + 解析 fastscp:// URL  │
│ • 在 Finder 右键加菜单      │ fastscp://│ • 弹一个小面板             │
│ • 抓选中路径                │   URL  │ • 用 ssh / scp 传输          │
│ • 写批文件 + 唤起主 app     │◀────────│ • 记忆最近目标              │
└────────────────────────────┘   通知   └──────────────────────────────┘
```

共享代码(`~/.ssh/config` 解析、`ls -ap` 解析、`scp` 进度解析、最近目标逻辑)在 `FastSCPCore` framework,两个进程都链接,核心逻辑全部单元测试覆盖。

## 安装步骤

### 前置条件
- macOS 14.0(Sonoma)或更高
- Xcode 16+ 和命令行工具(`xcode-select --install`)
- [xcodegen](https://github.com/yonaskolb/XcodeGen):`brew install xcodegen`
- `~/.ssh/config` 里已经有可用的 `Host` 别名

### 从源码构建

```bash
# 1. 生成 Xcode 工程(从 project.yml 推导)
xcodegen generate

# 2. 编译
xcodebuild -project FastSCP.xcodeproj \
           -scheme FastSCP \
           -configuration Debug \
           build \
           CODE_SIGN_IDENTITY=- \
           CODE_SIGN_STYLE=Manual

# 3. 复制到 /Applications
#    (Finder Sync extension 从 /Applications 加载比从 DerivedData 更可靠)
DERIVED=$(xcodebuild -project FastSCP.xcodeproj -scheme FastSCP \
                   -showBuildSettings CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual 2>/dev/null \
              | awk -F' = ' '/BUILT_PRODUCTS_DIR/{print $2; exit}')
cp -R "$DERIVED/FastSCP.app" /Applications/

# 4. 注册到 LaunchServices(让系统认识 fastscp:// URL scheme)
APP=/Applications/FastSCP.app
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$APP"

# 5. 启动一次(无界面,只为了加载 extension)
open "$APP"
```

### 启用 Finder 右键菜单

1. 打开 **System Settings → Privacy & Security → Extensions → Finder Extensions**
2. 打开 **FastSCP Finder Extension** 的开关
3. 重启 Finder 让它加载新 extension:

   ```bash
   killall Finder
   ```

   > **关键**:有些 macOS 版本下,光 `open` app 不够让 Finder 加载 extension,必须 `killall Finder`(或登出再登入)。验证 extension 真的被加载:
   >```bash
   >/usr/bin/pluginkit -m -v | grep "com.zhuzhong.FastSCP.FinderSync"
   >```
   >输出以 `+` 开头才算加载成功(`+    com.zhuzhong.FastSCP.FinderSync(1.0)`)。如果没有 `+`,再 `killall Finder` 一次。

4. 在 Finder 里**右键任意文件或文件夹** → 看到 **FastSCP** 子菜单。第一次只有"传送到服务器…"(还没有历史记录)。

### 第一次使用

1. 右键 → `FastSCP ▸ 传送到服务器…` → 小弹窗出现
2. 服务器下拉选你 `~/.ssh/config` 里的某个 `Host` 别名(例如 `nana`)
3. 路径框直接键入绝对路径(例如 `/var/www`),回车;或者双击下面的目录列表进入
4. 点"发送 N 项 → nana:/var/www"
5. 成功后弹 macOS 通知。下次右键就出现"发送到 nana:/var/www"一键项

### 已知问题

| 现象 | 原因 / 解法 |
|---|---|
| System Settings 里看不到 extension | ad-hoc 签名限制 → 见下文"开发备注" |
| 通知不弹 | 系统通知权限被拒 → System Settings → Notifications → FastSCP |
| 服务器列表空 | `~/.ssh/config` 里没有 `Host` 块;`Host *` 通配会被忽略 |
| 双击文件夹没反应 | 某些全局手势拦截;用键盘 Tab 聚焦行后回车也可 |

## 二次开发

### 项目结构

```
project.yml                       # xcodegen 真源(改完跑 xcodegen generate)
Sources/
  FastSCPCore/                    # 共享 framework(可单测)
    Constants.swift               #   bundle id / url scheme / app group
    Models.swift                  #   SSHHost, RemoteEntry, RecentDestination
    SSHConfigParser.swift         #   解析 ~/.ssh/config
    LsParser.swift                #   解析 `ls -ap` 输出
    SCPProgressParser.swift       #   解析 scp 进度
    RecentDestinations.swift      #   去重+排序+上限的纯逻辑
    RecentStore.swift             #   读写磁盘
    SharedPaths.swift             #   容器路径解析(app/extension 共用)
  FastSCP/                        # 主 app(无沙盒,因为要起 ssh/scp 进程)
    Main.swift                    #   @main, NSApplicationDelegateAdaptor
    AppDelegate.swift             #   kAEGetURL 接收 → 路由
    URLCoordinator.swift          #   fastscp:// 解析
    SelectionStore.swift          #   读 extension 写的批文件
    SSHExecutor.swift             #   ssh / scp 的 Process 封装
    DestinationPanel.swift        #   小弹窗(VM + View + NSPanel)
    Notifier.swift                #   UNUserNotificationCenter 包装
  FastSCPFinderSync/              # Finder 扩展(沙盒)
    FinderSync.swift              #   右键菜单 + 抓路径 + 唤起 app
Tests/
  FastSCPCoreTests/               # 18 个单元测试
docs/plans/
  2026-08-06-fast-scp-design.md
  2026-08-06-fast-scp-implementation.md
```

### 跑测试

```bash
xcodebuild -project FastSCP.xcodeproj \
           -scheme FastSCPCoreTests \
           -configuration Debug \
           test \
           CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual
```

### 修改后重新生成工程

任何时候改了 `project.yml`(比如改了 target、依赖、entitlement),都要重跑:

```bash
xcodegen generate
```

### 开发备注 / 几个关键决定

1. **主 app 无沙盒,extension 有沙盒。**
   App Sandbox 不允许 app 起任意子进程,而 `ssh`/`scp` 必须由我们起。所以主 app 是无沙盒(`Sources/FastSCP/FastSCP.entitlements` 里 `app-sandbox: false`)。Finder Sync extension 沙盒是 Apple 强制的。

2. **不依赖 App Group,改用容器路径互通。**
   App Group 需要 Provisioning Profile(付费开发者账号)。本地 ad-hoc 签名配不上,所以 FastSCPCore 里的 `SharedPaths` 改用"无沙盒 app 写入 extension 容器目录"的方案:
   - Extension 里:`~/Library/Application Support/FastSCP/` = 它自己的容器
   - App 里:同一个文件的绝对路径 = `~/Library/Containers/<ext-bundle-id>/Data/Library/Application Support/FastSCP/`

   如果你有付费开发者账号,在 `project.yml` 里恢复 `com.apple.security.application-groups` 这个 entitlement 并加上 App Group,`SharedPaths` 会自动优先用 App Group 容器路径(`FileManager.default.containerURL(forSecurityApplicationGroupIdentifier:)`)。

3. **签名默认 ad-hoc。**
   命令行加了 `CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual`。Ad-hoc 签名能让开发期构建跑起来,但 Finder Sync extension 的加载可能因此被 macOS 拒掉。在 Xcode 里打开工程、选你自己的 Team 即可走正常签名流程。

4. **Bundle ID 与 URL scheme 集中定义。**
   - App: `com.zhuzhong.FastSCP`
   - Extension: `com.zhuzhong.FastSCP.FinderSync`
   - Framework: `com.zhuzhong.FastSCP.Core`
   - App Group: `group.com.zhuzhong.FastSCP`
   - URL scheme: `fastscp`

   改这些地方要同步更新 `Sources/FastSCPCore/Constants.swift` 和 `project.yml`。

5. **scp vs rsync。**
   v1 用 `scp`(任何 SSH 服务器都有)。`rsync --info=progress2` 进度更准但要求服务器端有 `rsync`,留给下一版。

## 开源协议

MIT — 详见 [LICENSE](LICENSE)。

任何个人和商业组织都可以免费使用、修改、分发本项目,保留版权声明即可。

## 作者

zhuzhong, 2026.
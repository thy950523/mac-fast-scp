# 开发与构建说明

面向想从源码构建或参与开发的人。用户文档见仓库根目录 [README.md](../README.md)。

## 前置条件

- macOS 14.0（Sonoma）或更高
- Xcode 16+ 和命令行工具：`xcode-select --install`
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)：`brew install xcodegen`
- `~/.ssh/config` 中至少有一个可用的 `Host` 别名

## 一键脚本

```bash
# 生成 Xcode 工程（改了 project.yml 后都要跑）
xcodegen generate

# 生成工程 → 跑核心测试 → Release 构建 → 安装到 /Applications → 注册扩展
./scripts/execute.sh

# 仅"构建 + 安装到 /Applications"（含重签名、清理重复扩展注册）
./scripts/install.sh
```

## 手动分步构建

```bash
# 1. 生成 Xcode 工程
xcodegen generate

# 2. 编译
xcodebuild -project FastSCP.xcodeproj \
           -scheme FastSCP \
           -configuration Debug \
           build \
           CODE_SIGN_IDENTITY=- \
           CODE_SIGN_STYLE=Manual

# 3. 复制到 /Applications
#    （Finder Sync extension 从 /Applications 加载比从 DerivedData 更可靠）
DERIVED=$(xcodebuild -project FastSCP.xcodeproj -scheme FastSCP \
                   -showBuildSettings CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual 2>/dev/null \
              | awk -F' = ' '/BUILT_PRODUCTS_DIR/{print $2; exit}')
cp -R "$DERIVED/FastSCP.app" /Applications/

# 4. 注册到 LaunchServices（让系统认识 fastscp:// URL scheme）
APP=/Applications/FastSCP.app
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$APP"

# 5. 启动一次（无界面，只为了加载 extension）
open "$APP"
```

### 启用 Finder 右键菜单

1. 打开 **系统设置 → 隐私与安全性 → 扩展 → Finder 扩展**
2. 打开 **FastSCP Finder Extension** 的开关
3. 重启 Finder 让扩展加载：

   ```bash
   killall Finder
   ```

   > **关键**：有些 macOS 版本下，光 `open` app 不够让 Finder 加载扩展，必须 `killall Finder`（或登出再登入）。验证扩展真的被加载：
   > ```bash
   > /usr/bin/pluginkit -m -v | grep "com.zhuzhong.FastSCP.FinderSync"
   > ```
   > 输出以 `+` 开头才算加载成功（`+    com.zhuzhong.FastSCP.FinderSync(1.0)`）。如果没有 `+`，再 `killall Finder` 一次。

## 跑测试

```bash
xcodebuild -project FastSCP.xcodeproj \
           -scheme FastSCPCoreTests \
           -configuration Debug \
           test \
           CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual
```

## 修改后重新生成工程

任何时候改了 `project.yml`（target、依赖、entitlement 等），都要重跑：

```bash
xcodegen generate
```

## 几个关键设计决定

1. **主 app 无沙盒，extension 有沙盒。**
   App Sandbox 不允许 app 起任意子进程，而 `ssh`/`scp` 必须由我们起。所以主 app 无沙盒（`Sources/FastSCP/FastSCP.entitlements` 里 `app-sandbox: false`）。Finder Sync extension 沙盒是 Apple 强制的。

2. **不依赖 App Group，改用容器路径互通。**
   App Group 需要 Provisioning Profile（付费开发者账号）。本地 ad-hoc 签名配不上，所以 `FastSCPCore` 里的 `SharedPaths` 改用"无沙盒 app 写入 extension 容器目录"的方案：
   - Extension 里：`~/Library/Application Support/FastSCP/` = 它自己的容器
   - App 里：同一个文件的绝对路径 = `~/Library/Containers/<ext-bundle-id>/Data/Library/Application Support/FastSCP/`

   如果你有付费开发者账号，在 `project.yml` 里恢复 `com.apple.security.application-groups` 这个 entitlement 并加上 App Group，`SharedPaths` 会自动优先用 App Group 容器路径（`FileManager.default.containerURL(forSecurityApplicationGroupIdentifier:)`）。

3. **签名默认 ad-hoc。**
   命令行加了 `CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual`。Ad-hoc 签名能让开发期构建跑起来，但 Finder Sync extension 的加载可能因此被 macOS 拒掉。在 Xcode 里打开工程、选你自己的 Team 即可走正常签名流程。

4. **Bundle ID 与 URL scheme 集中定义。**
   - App: `com.zhuzhong.FastSCP`
   - Extension: `com.zhuzhong.FastSCP.FinderSync`
   - Framework: `com.zhuzhong.FastSCP.Core`
   - App Group: `group.com.zhuzhong.FastSCP`
   - URL scheme: `fastscp`

   改这些地方要同步更新 `Sources/FastSCPCore/Constants.swift` 和 `project.yml`。

5. **scp vs rsync。**
   v1 用 `scp`（任何 SSH 服务器都有）。`rsync --info=progress2` 进度更准但要求服务器端有 `rsync`，留给下一版。

## 已知问题

| 现象 | 原因 / 解法 |
|---|---|
| 系统设置里看不到 extension | ad-hoc 签名限制 → 在 Xcode 选自己的 Team 重新签名 |
| 通知不弹 | 系统通知权限被拒 → 系统设置 → 通知 → FastSCP |
| 服务器列表空 | `~/.ssh/config` 里没有 `Host` 块；`Host *` 通配会被忽略 |
| 双击文件夹没反应 | 某些全局手势拦截；用键盘 Tab 聚焦行后回车也可 |

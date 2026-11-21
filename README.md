# Pocket SSH

Pocket SSH 是一个基于 Flutter 的 SSH 客户端，在手机上（以及 macOS、Windows 桌面上）提供交互式终端、SFTP 文件管理和一个可执行命令的 AI 终端助手。

- 应用名：Pocket SSH
- 包名 / Bundle ID：`app.pocketssh.pocket_ssh`（Android）、`app.pocketssh.pocketSsh`（iOS / macOS）
- 版本：`0.1.0+1`
- 支持平台：Android、iOS、macOS（10.15+）、Windows

## 功能

### 主机与会话

- 主机配置保存名称、地址、端口、用户名和分组，列表支持按名称、地址、分组搜索。
- 认证方式：密码、私钥（可选私钥口令）、无凭据。
- 可选“加密保存凭据”和“设备认证后才能读取已保存凭据”。
- 跳板机：把目标主机配置为经由另一台已保存主机连接。
- 本地端口转发：在终端菜单中为当前会话开启或停止转发，目标主机与端口可配置。
- 同一主机重复打开复用一个在线会话，避免重复建立连接。
- 连接前校验服务器主机密钥指纹，指纹与已记录值不一致时直接拒绝。

### 终端

- 基于 `xterm2` 的完整终端，可滚动回看（默认 5000 行）、可切换深浅配色、字体大小 11–24 px。
- 选中文本后可复制，复制/粘贴工具条不抢占终端焦点。
- 输出搜索与命中跳转。
- 命令草稿栏：先编辑再发送；遇到高风险命令（`rm -rf`、`mkfs`、`dd of=`、`shutdown`、`drop table` 等）或多行命令会先弹出确认对话框。
- 命令收藏与最近命令（最近命令默认不记录，可在设置中开启，上限 20 条）。
- 快捷键工具条：Esc、Tab、Ctrl+C、Ctrl+D、方向键。
- 屏幕常亮开关。

### SFTP 文件管理

- 浏览远程目录，支持上传、下载、重命名、新建目录、删除（删除前确认）。
- 大文件分块传输，带传输进度与失败重试。

### AI 终端助手

- 从终端选区或手动输入发起提问，选区内容中的私钥、URL 凭据、`authorization` / `token` / `api_key` 等字段会先脱敏。
- 支持 Chat Completions 与 Responses 两种接口；可自定义渠道名称、接口类型、模型名称和自定义请求头。
- 可获取服务端模型列表、测试模型连接。
- 上下文容量可配置（模型上下文窗口、最大输出、压缩阈值），超出阈值时自动压缩历史。
- 两种执行策略：
  - 审查模式：Agent 每次调用 `execute_command` 都要用户批准。
  - 危险模式：命令自动执行。
- 执行前会显示目标会话；连接断开或会话切换时取消进行中的请求。

### 安全与隐私

- 凭据与主机指纹存放在设备安全存储中：Android 使用 AndroidKeyStore 的 AES-GCM 加密后写入私有偏好，iOS/macOS/Windows 走 `flutter_secure_storage`。
- 可选设备锁（PIN / 图案 / 生物认证）在读取保存凭据前校验。
- 主机配置可在设置中导出为 JSON 复制到剪贴板，导出内容不含凭据和指纹；从剪贴板导入时不会覆盖已有主机。

## 快速开始

需要 Flutter 3.35 及以上、Dart 3.9 及以上。

```bash
flutter pub get
flutter run
```

静态检查与测试：

```bash
flutter analyze
flutter test
```

构建产物：

```bash
flutter build apk --target-platform android-arm64
flutter build ios --release --no-codesign
flutter build macos --release
flutter build windows --release
```

使用 AI 助手前，在“设置 → AI 助手”中填写网站地址（HTTP/HTTPS）、接口类型、模型名称和 API 密钥，可用“测试模型连接”验证。

## 项目结构

```
lib/
  main.dart                    应用入口、主机列表、文件页、设置页与主题
  core/
    app_store.dart             主机、收藏、AI 渠道、终端与安全设置的持久化
    sessions.dart              会话生命周期、跳板机、端口转发、SFTP 传输
    ssh_connection.dart        SSH 连接、认证、主机指纹回调
    host_trust.dart            指纹校验与变更检测
    host_backup.dart           主机配置导入导出
    device_bridge.dart         设备能力桥接（安全存储、文件选择、设备认证、常亮）
    agent_controller.dart      Agent 对话循环、工具调用、上下文压缩
    agent_protocol.dart        工具定义、流式解析、命令风险识别
    agent_transport.dart       Chat / Responses 请求与响应转换
    agent_remote.dart          远程命令执行
    agent_context.dart         上下文预算与压缩切分
    ai_endpoint.dart           AI 接口地址规范化、流式文本解析、模型列表与连通性检查
    ai_headers.dart            自定义请求头校验与脱敏
    app_palette.dart           配色与主题
  features/
    connection/connection_page.dart   主机编辑与凭据输入
    terminal/terminal_page.dart       终端界面、草稿、搜索、转发、快捷键
    terminal/terminal_selection.dart  终端选区手柄
    terminal/sftp_page.dart           SFTP 浏览与传输
    terminal/ai_panel.dart            AI 助手面板与命令审批
    terminal/agent_conversation.dart  Agent 对话渲染
    settings/glass_surface.dart       设置页表面样式
android/  iOS/  macOS/  windows/     各平台工程与原生桥接实现
test/                               单元与 Widget 测试
```

## 持续集成

`.github/workflows/platforms.yml` 在推送和 Pull Request 时运行：

1. `verify`：`flutter analyze` 与 `flutter test`，是后续构建的前置门槛。
2. 分支推送时并行构建 Android ARM64 debug 与性能包、iOS 未签名 IPA、macOS 应用、Windows x64 包，并计算 SHA256SUMS 作为构建产物上传。
3. 推送 `v*` 标签时额外发布 GitHub Release；若仓库变量 `SIGN_ANDROID_RELEASE=true`，会用 `ANDROID_KEYSTORE_*` 系列密钥构建签名版 APK。

CI 使用 Flutter 3.35.7 与 Java 17。Android 本地签名通过环境变量 `ANDROID_KEYSTORE_PATH`、`ANDROID_KEYSTORE_PASSWORD`、`ANDROID_KEY_ALIAS`、`ANDROID_KEY_PASSWORD` 提供，未设置时 release 构建不签名。

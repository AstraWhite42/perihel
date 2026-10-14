# 近星点

原生 macOS 菜单栏 Codex 订阅额度监控工具。作者：白星澈AstraWhite。

支持 Apple Silicon（M 系列芯片），最低目标系统为 macOS 13。需要本机 Codex CLI 和使用者自己的 ChatGPT 订阅登录。不包含 CLI 或登录凭据。

## 安装与连接

解压发布 ZIP，将“近星点.app”拖入“应用程序”目录后打开。首次运行会展开连接引导，检测 CLI 及登录状态。

如果没有 CLI，可打开引导中的官方安装说明；已安装 Homebrew 的用户也可执行：

```sh
brew install --cask codex
```

点击“打开终端登录”，用自己的 ChatGPT 账户完成浏览器授权；返回应用点击“重新检测”，成功后点击“开始使用”。API Key 登录不适用于订阅额度监控。非标准 CLI 安装可通过“选择已有 CLI”指定可执行文件；CLI 不兼容时更新后重新检测。可从齿轮菜单重新打开连接引导。

发布包仅使用本机临时签名，未进行 Developer ID 签名和 Apple 公证。首次打开可能需要在“系统设置 → 隐私与安全性”中按系统提示确认来源。安装、更新及常见问题见 [使用说明](docs/使用说明.txt)。

## 使用

菜单栏以星核能量环和百分比显示首个额度桶的主窗口剩余额度，优先选择 `codex` 桶。能量环有 8 格，按剩余额度每 12.5% 一格向上取整；零额度时全部变暗，未知额度时显示暗环及“—”。星核与循环箭头始终保留，图标自动适配菜单栏深浅色。齿轮菜单可关闭“菜单栏显示百分比”，仅保留动态图标；该选择会被保存。

点击菜单栏可查看全部额度窗口、实际与理论用量、窗口时间、重置倒计时和可用重置次数。进度条表示实际已用，刻度表示理论进度。齿轮菜单的“进度条分段”支持“按每日零点分段”（默认）、“每 24 小时分段”和“不分段”，选择会被保存。每日零点按系统时区及日历计算，首末段宽度与实际时长成比例，夏令时日期可能为 23 或 25 小时；每 24 小时模式从窗口开始时间起按固定 24 小时划分，不固定段数。日期标签过窄时省略，缺失窗口时间时回退为连续进度条；重置到期明细可展开。时间默认精确到分钟，悬停可查看完整时间。面板随内容自适应高度，超出上限时滚动。顶部 ⓘ 可查看版本、作者和额度说明。

默认每两分钟查询，打开面板和系统唤醒时补刷。窗口到期后每 30 秒重试，等待服务端确认新窗口。查询失败保留上次成功快照并显示错误；确认登录失效时清除快照并显示连接引导。百分比模式中的感叹号表示查询失败或窗口已到期。图标模式下可通过悬停和面板查看状态。

理论用量按当前时间在窗口中的进度计算，限制在 0–100%；理论剩余为其补数。开始时间由下次重置时间减去窗口长度推算。理论值仅为消费节奏参考，时间按系统时区显示。

## 数据与隐私

通过官方 `codex app-server` 的 `account/read` 检查登录状态，通过 `account/rateLimits/read` 获取额度。支持多个额度桶和主、次窗口。缺失字段显示“暂无数据”。可用重置次数以 `availableCount` 为准，到期明细可能不完整。额度百分比不能可靠换算为精确的剩余 token 数。

应用不保存凭据和额度快照，不向作者服务器上传数据，不发起模型推理，也不消耗重置机会。登录和凭据更新由本机 CLI 管理。应用保存自定义 CLI 路径、连接引导完成状态和百分比显示偏好和进度条分段方式。点击终端登录时仅生成不含凭据的临时命令文件。

接口文档：https://learn.chatgpt.com/docs/app-server

## 构建与版本管理

构建需要 Swift 6.0+（Xcode 或 Command Line Tools）。版本信息统一维护在 `version.json`：`version` 为显示版本，`build` 为正整数构建号，`bundleIdentifier` 为应用标识。发布新包时更新版本号，并递增构建号；同一显示版本重新发布也需递增构建号。运行时版本、CLI 客户端标识、Info.plist 和 ZIP 名称均从该文件生成。

```sh
./scripts/build-app.sh
open "dist/近星点.app"
./scripts/package.sh
```

构建固定使用 `arm64-apple-macosx13.0`，不生成 Intel 版本。打包脚本生成 `dist/近星点-版本-build构建号-AppleSilicon.zip` 和 SHA-256 校验文件。ZIP 仅包含应用和使用说明。当前为手动更新：退出应用后替换旧版。

图标由 `scripts/generate-icon.swift` 绘制，构建脚本生成各尺寸 PNG 和 ICNS 并打包。开发预览支持：

```sh
"dist/近星点.app/Contents/MacOS/TokenTank" --render-preview /tmp/panel.png --dark --expanded
"dist/近星点.app/Contents/MacOS/TokenTank" --render-preview /tmp/setup.png --setup
"dist/近星点.app/Contents/MacOS/TokenTank" --render-info /tmp/info.png
"dist/近星点.app/Contents/MacOS/TokenTank" --render-icon-levels /tmp/icons.png
```

## 验证

```sh
"dist/近星点.app/Contents/MacOS/TokenTank" --self-test
python3 tests/test_cli.py
"dist/近星点.app/Contents/MacOS/TokenTank" --probe
```

自检覆盖时间窗口、额度分格和设置持久化。模拟 CLI 测试覆盖缺少 CLI、无登录、API Key 登录、接口不兼容、凭据失效、网络故障及正常读取，不使用真实凭据。`--probe` 验证本机账户读取，只输出额度摘要。开发命令可用 `--cli-path /绝对路径/codex` 指定隔离的 CLI；不会保存该参数。

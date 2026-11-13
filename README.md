# 近星点（perihel）

近星点在 Mac 菜单栏或 Windows 托盘显示你的 Codex 订阅剩余额度。点击图标，可以查看距离下次重置还有多久，以及当前用量比匀速预算快了还是慢了。

## 安装与首次使用

### macOS

适用于配备 Apple Silicon（M 系列芯片）的 Mac，系统要求 macOS 13 或更高版本。

1. 从[发布页](https://github.com/AstraWhite42/perihel/releases)下载文件名以 `AppleSilicon.zip` 结尾的压缩包。
2. 解压，将「近星点.app」拖入「应用程序」，双击打开。
3. 首次打开会显示连接引导。以后点击屏幕顶部菜单栏的近星点图标即可打开面板。

### Windows 预览版

适用于 Windows 10 2004 或更高版本的 x64 电脑。

1. 将预览版的完整程序文件夹放到准备长期使用的位置。如果收到的是压缩包，先完整解压。
2. 双击文件夹里的 `Perihel.exe`。请保留同目录下的文件，程序运行时会用到它们。
3. 首次打开会显示连接引导。以后点击任务栏通知区域里的百分比或能量环即可打开面板；找不到时，展开「显示隐藏的图标」。

### 连接自己的 Codex 账户

1. 近星点会检测本机的 Codex CLI。如果尚未安装，点击引导中的安装说明；如果已经安装但未被识别，点击「选择 CLI」并指定程序路径。Windows 支持 `codex.exe` 和 npm 安装的 `codex.cmd`。
2. 如果 CLI 已经登录自己的 ChatGPT 订阅账户，直接点击「重新检测」。需要登录时，点击「打开终端登录」，按提示完成授权，再返回近星点重新检测。订阅额度需要使用 ChatGPT 账户登录。
3. 检测成功后，点击「开始使用」。卡片上最大的一项数字是剩余额度，右侧是重置倒计时。

### Mac 提示无法验证应用时

当前 Mac 版使用临时签名，尚未经过 Apple 公证。确认下载来源可信后，可在「系统设置 → 隐私与安全性」中按提示允许打开。其他处理步骤和更新方法见 [macOS 使用说明](docs/使用说明.md)。

## 查看额度

- **剩余与预算**：每张卡片对应一个额度窗口，优先显示 Codex 的 7 天窗口。进度条的填充是实际已用，竖线是按时间推算的理论已用。「领先预算 3.2%」表示实际用量比匀速预算多了 3.2 个百分点。点击预算文字可展开当前和今晚 24 时的理论用量。5 小时窗口只显示预算差值。
- **重置机会**：面板底部显示账户可用的重置次数和最近到期时间，点击可展开逐次明细。进度条上的橙色菱形表示机会到期，悬停可看具体时间。
- **公开重置预告**：Codex 周窗口会显示来自 [Codex Resets](https://codex-resets.com) 的公开消息。有效预告会在进度条上显示紫旗，并在明细中增加预告时点的理论用量。个人额度是否已经重置，以 CLI 读取的账户数据为准。
- **刷新**：打开面板或点击刷新按钮即可更新。近星点平时每两分钟查询一次，窗口到期后每 30 秒重试。遇到临时网络错误时，面板保留上次成功的数据；登录失效时会重新打开连接引导。

## 调整显示

点击面板右上角的齿轮。以下设置即时生效，退出后会自动保存。

| 设置 | 用途 |
| --- | --- |
| 菜单栏显示 / 托盘显示 | 可选剩余百分比、领先／落后百分比或仅图标。Mac 可在能量环旁显示数值。Windows 始终只占一个托盘图标位，百分比模式显示数字，「仅图标」显示能量环。 |
| 能量格熄灭方向 | 能量环的七格随剩余额度减少而逐格熄灭。默认从左上角三角形开始逆时针熄灭，也可改为顺时针。 |
| 进度条分段 | 默认按本地整点或零点分段，也可从窗口起点按等长时段划分，或选择「不分段」。 |
| 主题 | 默认使用系统原生主题。想让面板底色更实，可选「清晰底色」。两种主题均跟随系统深浅外观。 |

## 数据与隐私

近星点通过本机 Codex CLI 读取账户和额度，登录凭据由 CLI 管理。额度快照只保留在内存中，应用仅保存连接状态、CLI 路径和显示偏好。Windows 的设置文件位于 `%LOCALAPPDATA%\Perihel\settings.json`。

公开重置消息每五分钟独立检查一次，请求不携带账户信息、凭据或用量。查看额度不会发起模型推理或消耗重置机会。

## 开发者：构建与打包

两个客户端分别位于 `src/macos/`（Swift、SwiftUI）和 `src/windows/`（C#、WinUI 3）。根目录的 `version.json` 提供版本信息，构建产物统一输出到 `dist/`。

### macOS

构建需要 Swift 6.0+（Xcode 或 Command Line Tools）。版本信息统一维护在 `version.json`：`version` 为显示版本，`build` 为正整数构建号，`bundleIdentifier` 为应用标识。发布新包时更新版本号，并递增构建号；同一显示版本重新发布也需递增构建号。运行时版本、CLI 客户端标识、Info.plist 和 ZIP 名称均从该文件生成。

```sh
./scripts/build-app.sh
open "dist/近星点.app"
./scripts/package.sh
```

构建固定使用 `arm64-apple-macosx13.0`，不生成 Intel 版本。打包脚本生成 `dist/近星点-版本-build构建号-AppleSilicon.zip` 和 SHA-256 校验文件。ZIP 仅包含应用和使用说明。当前为手动更新：退出应用后替换旧版。

图标由 `src/macos/tools/generate-icon.swift` 绘制，构建脚本生成各尺寸 PNG 和 ICNS 并打包。开发预览支持：

```sh
"dist/近星点.app/Contents/MacOS/perihel" --render-preview /tmp/panel.png --dark --expanded
"dist/近星点.app/Contents/MacOS/perihel" --render-preview /tmp/setup.png --setup
"dist/近星点.app/Contents/MacOS/perihel" --render-info /tmp/info.png
"dist/近星点.app/Contents/MacOS/perihel" --render-icon-levels /tmp/icons.png
```

### macOS 诊断

`--probe` 读取本机账户并输出额度摘要，可用 `--cli-path /绝对路径/codex` 指定本次运行使用的 CLI。`--news-probe` 单独检查重置消息接口。渲染预览时可用 `--news-fixture /绝对路径/status.json` 载入本地消息样例。

### Windows

在 Windows x64 开发机上安装 .NET 10 SDK，从仓库根目录运行：

```powershell
dotnet publish src/windows -c Release -o dist/Windows-x64
.\dist\Windows-x64\Perihel.exe
```

`dist/Windows-x64` 包含程序和运行时。分发时请打包整个目录。调试时可用 `--cli-path "完整路径"` 临时指定 CLI，或用 `--news-fixture "完整路径"` 载入公开消息样例。

## 作者

白星澈AstraWhite

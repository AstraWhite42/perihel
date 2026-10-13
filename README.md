# Token Tank

原生 macOS 菜单栏 Codex 订阅额度监控工具。支持 macOS 13 及以上版本。

## 构建与运行

需要 Swift 6.0+（Xcode 或 Command Line Tools）及已通过 ChatGPT 账户登录的 Codex CLI。

```sh
codex login
./scripts/build-app.sh
open "dist/Token Tank.app"
```

可将 `.app` 拷贝到应用程序目录。应用采用本机临时签名，适合自用；其他机器上分发需要单独处理签名和公证。自动启动可在 macOS 的登录项中添加应用。

## 使用

菜单栏以仪表盘图标和百分比显示首个额度桶的主窗口剩余额度，优先选择 `codex` 桶。点击可查看全部额度窗口、实际与理论用量、窗口时间、重置倒计时和可用重置次数。进度条表示实际已用，刻度表示理论已用；重置明细可展开查看。时间默认精确到分钟，悬停可查看完整时间。面板随内容自适应高度，超出上限时滚动。点击顶部 ⓘ 可查看额度说明，说明框支持分段换行，可通过关闭按钮或点击外部关闭。

应用复用 Codex CLI 当前登录和默认配置。默认查找 Homebrew 安装位置和进程 PATH；非标准安装可通过右上角齿轮菜单中的“选择 Codex CLI”指定可执行文件。登录失效时，在终端重新执行 `codex login`，然后刷新。

每两分钟自动查询，展开菜单和系统唤醒时补刷。窗口到期后每 30 秒重试，等待服务端确认新窗口。查询失败会保留上次成功快照并显示错误；菜单栏的感叹号表示数据查询失败或窗口已到期。应用不保存凭据或额度快照，只保存自定义 CLI 路径。

理论已用百分比为当前时间在窗口中的进度，限制在 0–100%；理论剩余为其补数。窗口开始时间由下次重置时间减去窗口长度推算。理论值仅是消费节奏参考。时间按系统时区显示。

额度数据通过官方 `codex app-server` 的 `account/rateLimits/read` 获取，支持多个桶及主、次窗口。缺失数据显示“暂无数据”。重置次数以服务端 `availableCount` 为准，明细可能不完整。应用仅监控，不消耗重置机会，不发起模型推理。额度百分比不能换算为精确的剩余 token 数。

## 验证

```sh
"dist/Token Tank.app/Contents/MacOS/TokenTank" --self-test
"dist/Token Tank.app/Contents/MacOS/TokenTank" --probe
```

`--self-test` 校验时间窗口和预算计算；`--probe` 只读查询本机登录账户并输出简要额度，不输出凭据。

接口文档：https://learn.chatgpt.com/docs/app-server

面板预览可导出为 PNG，支持 `--dark` 和 `--expanded`：

```sh
"dist/Token Tank.app/Contents/MacOS/TokenTank" --render-preview /tmp/token-tank.png --dark --expanded
```

# Windows 每日调度

沿用 CCH 的“机器主动派发 + GitHub 兜底 + 每日去重”方式，主调度安装在现有 Windows 节点机器上，无需 Python、GitHub CLI、额外服务器或个人电脑常在线。

- Windows 任务 `FiberWindowsSmokeDispatch` 每天北京时间 **10:30** 请求运行 `main` 的 `fiber-node-maintenance.yml`。
- 任务使用显式 UTC 开始时间 **02:30Z**，不依赖 Windows 默认时区；此后每 5 分钟补查到北京时间 23:55，开机 2 分钟后也会检查当天是否到点。
- GitHub 原生 cron 在北京时间 **10:47** 提供独立兜底。
- Windows runner 持久化每日执行记录，两个入口只有一个会执行烟测和通知。调度器已收到 GitHub 接受结果后，当天后续检查直接退出。

10:30 是计划派发时间。Windows 离线、网络、GitHub API 故障或 runner 排队仍可能造成延迟；任务不会为准点跳过数据库校验或支付断言。

## 一次性启用

1. 将工程修改合入 `main`。
2. 创建 fine-grained GitHub token，仅授权 `sunchengzhu/fiber-windows-smoke`，授予 **Actions: Read and write**。在[仓库 Actions Secrets](https://github.com/sunchengzhu/fiber-windows-smoke/settings/secrets/actions)中保存为 `FIBER_SMOKE_DISPATCH_TOKEN`，不要粘贴到聊天、workflow 参数或提交中。
3. 在 Actions 运行 **Fiber Windows scheduler administration**，分支选择 `main`，`operation` 选择 **Install**。

也可以在本机终端交互式保存 Secret：

```sh
gh secret set FIBER_SMOKE_DISPATCH_TOKEN --repo sunchengzhu/fiber-windows-smoke
```

安装工作流由现有 Windows runner 执行，需要管理员权限，与现有服务安装/更新脚本相同。它将调度脚本复制到 checkout 外，使用 Windows DPAPI 的 LocalMachine 模式加密保存凭据，并将调度目录 ACL 限制为 SYSTEM 和 Administrators；任务以 SYSTEM 运行。任务不依赖 Actions 临时 `GITHUB_TOKEN`。

安装只执行只读 API 预检，不立即发送支付任务。首次计划时间显示在安装日志中；如果安装时当天 10:30 已过，则从次日 10:30 开始。预检证明凭据可读运行记录，不代表已验证派发写权限；首次实际派发需在任务日志和 Actions 页面确认。

## 持久状态与支付语义

默认文件位于：

```text
C:\fiber-node\automation\scheduler\Dispatch-DailyRun.ps1
C:\fiber-node\automation\daily-dispatch\github-token.dpapi
C:\fiber-node\automation\daily-dispatch\dispatcher.log
C:\fiber-node\automation\daily-dispatch\YYYY-MM-DD.json
C:\fiber-node\automation\daily-executions\YYYY-MM-DD.json
```

保留两个状态目录。`accepted` 只表示 GitHub 接受请求，不表示支付通过。POST 之前会先记录 `pending`；响应超时或结果不明时，后续检查只查询同日期、同分支及精确运行名称进行确认，不盲目重复 POST。无法确认时需人工检查，GitHub 兜底仍可通过共享执行门进入当天烟测。

服务器派发携带 `scheduled_date=YYYY-MM-DD`，与 GitHub schedule 一样按每日支付处理，尊重 `paymentFlow.enabled`。重复运行不重复通知；已认领的烟测即使失败也不会由补查任务自动重做支付。同一天显式重新运行原 run 保持原 run ID，可以重做；跨日恢复使用不填 `scheduled_date` 的普通手动运行。

每日任务只允许 `main`、当天日期且北京时间已到 10:30。GitHub 兜底从原 run 的 `created_at` 推导目标日期，防止昨天排队的任务占用今天的执行名额。普通手动运行不参与每日去重，仍由 `send_payment` 控制是否支付。

## 检查、暂停及更新

在 **Fiber Windows scheduler administration** 中：

- **Check**：读取任务状态、最近日志及已安装凭据的 API 读权限。
- **Install**：安装或更新脚本、凭据及计划任务，保留每日状态。
- **Pause**：禁用并停止 Windows 调度任务，保留状态和 GitHub cron 兜底。

Token 到期或撤销后，更新仓库 Secret 并重新运行 Install。不要复用 CCH 的专用 token；它可能只授权 CCH 仓库。

在 Windows 管理员 PowerShell 中也可查询：

```powershell
Get-ScheduledTask -TaskName FiberWindowsSmokeDispatch
Get-ScheduledTaskInfo -TaskName FiberWindowsSmokeDispatch
Get-Content C:\fiber-node\automation\daily-dispatch\dispatcher.log -Tail 20
```

回滚移除每日去重逻辑之前，应先暂停 Windows 调度任务。不要删除 `pending` 或执行记录来强制重试；先检查对应 GitHub run，再选择显式 rerun 或普通手动运行。

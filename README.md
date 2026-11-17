# Fiber Windows Smoke

在一台长期在线的 Windows x64 机器上运行两个 Fiber testnet 节点，并通过 self-hosted GitHub Actions runner 每天核对已安装版本、检查节点健康并执行真实支付冒烟测试。

## 支付拓扑

```text
1. Invoice:        Node B -- 0.02 CKB --> Node A
2. Keysend:        Node A -- 0.01 CKB --> CkbaNode-1
3. Routed Keysend: Node B -- 0.03 CKB + fee --> Node A --> CkbaNode-1
```

`CkbaNode-1` 是 Fiber 测试网公共节点。Node A 与 `CkbaNode-1` 有一条 channel，Node B 与 Node A 有一条 channel；两个本地节点都作为 Windows Service 长期运行。

## 每日 CI 做什么

Workflow：[`.github/workflows/fiber-node-maintenance.yml`](.github/workflows/fiber-node-maintenance.yml)

每天北京时间 **10:30** 由 Windows 任务计划程序主动触发，GitHub **10:47** 的 cron 作为兜底。安装方式见[定时调度说明](docs/daily-scheduler.md)。执行内容：

1. 检查所有 PowerShell 脚本语法并运行模块单元测试。
2. 核对两个节点已安装的 FNN、CLI 和运行中 RPC 的版本与 commit，并查询最新稳定版作为人工升级提示。
3. 检查两个 Windows 服务、RPC、peer 连接和两条 `ChannelReady` channel。
4. Node A 创建 `0.02 CKB` invoice，由 Node B 支付。
5. Node A 向测试网公共节点 `CkbaNode-1` keysend `0.01 CKB`。
6. Node B 通过 Node A 向 `CkbaNode-1` keysend `0.03 CKB`，验证 Node A 收取的转发手续费。
7. 将支付前后余额、手续费、Payment Hash 和资金流写入日志及 GitHub Job Summary。
8. 执行结束后向 Discord 发送汇总卡片，包括运行状态、节点版本、前置检查和三笔支付明细；失败时也发送。

每日 CI 不下载或替换二进制、不停启服务、不迁移数据库、不开新通道。版本基线集中在 [`config/tested-fiber-release.json`](config/tested-fiber-release.json)，目前是 **v0.10.1 / d9b6bbd**。Windows 上已有的 `releaseChannel`、`releaseTag` 字段不再控制升级，可在下次维护时移除。

版本报告区分两种情况：

- **Fiber version mismatch**：任一节点的 FNN tag/commit、CLI 版本或运行中 RPC tag/commit 与基线不同，CI 在支付前失败。GitHub Summary 和 Discord 标题直接标注版本不匹配，并保留 A/B 的全部可读实际版本、CI 预期和最新稳定版；一台检查失败不会遮住另一台信息。
- **New stable release**：GitHub 的最新正式版高于基线，报告醒目提示手工升级，当前基线的烟测仍继续执行。新版本提示本身不证明支付失败是版本造成的。

最新版本查询只读取 GitHub release 元数据，过滤 prerelease/draft；API 不可用时显示“Latest stable unknown”，不阻止已安装版本检查和烟测，也不声称当前已是最新。

### 人工升级

以后通过 Codex 发起升级：先确认明确的稳定版 tag、发布说明和迁移要求，停机备份两个节点的数据、密钥、配置和旧二进制，在副本上验证迁移，再更新正式节点并跑完整烟测。

普通二进制更新必须显式指定目标，例如在 Windows 管理员 PowerShell 中：

```powershell
scripts\Update-FiberBinary.ps1 -SettingsPath C:\fiber-node\automation\settings.json -ReleaseTag v0.10.1
scripts\Update-FiberBinary.ps1 -SettingsPath C:\fiber-node-b\automation\settings.json -ReleaseTag v0.10.1
```

该脚本仍会拒绝需要数据库迁移的更新；迁移由当次人工维护单独处理，禁止略过兼容性校验。初次安装 `Install-FiberService.ps1` 和 `Install-SecondNode.ps1` 也必须传入 `-ReleaseTag`。

升级时同时更新 `config/tested-fiber-release.json` 的 tag 和对应官方 commit；两台 FNN、各自 CLI、运行中 RPC 和 CI 基线都对齐后，再运行每日流程验证。仅改基线不会升级服务器；仅换服务器二进制也不能绕过 CI 的版本检查。

两个调度入口共用 Windows 上的每日执行记录，同一天只自动执行一次烟测及通知。失败后不会自动重复支付；同一天可以显式重新运行原 run，跨日恢复则使用普通手动运行。服务器离线、网络或 runner 排队仍可能推迟实际开跑时间。

## CI 如何判断成功

RPC 返回 `Success` 还不够。三笔支付都必须同时满足：

- 付款端余额精确减少配置金额；
- 收款端余额精确增加相同金额；
- 本地减少量等于远端增加量；
- 两笔直连支付手续费为 `0`；
- 路由支付手续费必须大于 `0`，并与 channel 实时费率计算结果完全一致；
- 路由支付的第一跳必须扣除“金额 + 手续费”，第二跳必须精确转出支付金额；
- 任意差值不符都会抛出错误并让 workflow 失败。

默认预期结果：

```text
B -> A       B -0.02 CKB   A +0.02 CKB
A -> CkbaNode-1  A -0.01 CKB   CkbaNode-1 +0.01 CKB
B -> A -> CkbaNode-1  B -(0.03 CKB + fee)   A +fee   CkbaNode-1 +0.03 CKB
```

## 手动运行

在 GitHub Actions 页面选择 `Fiber Windows daily smoke`，点击 **Run workflow**。通常手动验证使用：

```text
scheduled_date: 留空
send_payment:   true
send_discord_report: true
```

`send_payment` 会执行三笔真实支付：`0.02 + 0.01 + 0.03 CKB`，另加一笔动态计算的路由手续费。

`send_discord_report` 只控制手动运行是否发报告，默认关闭；定时运行始终尝试发送。该开关本身不会触发支付。

`scheduled_date` 由 Windows 调度器填写，用于每日去重；普通手动运行请留空。携带日期的每日任务按 `-Scheduled` 执行支付并尊重 `paymentFlow.enabled`，不需要勾选 `send_payment`。

## Discord 日报配置

目标频道 ID：`1549402632203018410`。使用与 `cch-daily-smoke` 相同的 Discord Webhook 卡片方式，**Discord 通知只需配置一个 Secret**（Windows 调度另需专用凭据，见[调度说明](docs/daily-scheduler.md)）：

1. 在 Discord 目标频道打开 **编辑频道 → 整合 → Webhooks → 新建 Webhook**，确认所选频道正确并复制 Webhook URL。创建者需要该频道的 **管理 Webhooks** 权限，详见 [Discord 官方说明](https://support.discord.com/hc/en-us/articles/228383668-Intro-to-Webhooks)。
2. 打开 [本仓库的 Actions Secrets 设置](https://github.com/sunchengzhu/fiber-windows-smoke/settings/secrets/actions)，选择 **New repository secret**：
   - Name：`DISCORD_WEBHOOK_URL`
   - Secret：上一步复制的完整 URL。
3. 包含本功能的代码进入 `main` 后，每日定时运行会自动发送。可手动勾选 `send_discord_report` 验证发送；`send_payment=false` 时只执行版本和健康检查，卡片明确显示未请求支付。如需完整支付明细，同时勾选 `send_payment`。

也可以在自己的终端交互式保存 Secret，避免把 URL 写入命令历史：

```sh
gh secret set DISCORD_WEBHOOK_URL --repo sunchengzhu/fiber-windows-smoke
```

Webhook URL 已绑定频道，频道 ID 本身不是发送凭据；不需要 Bot Token，也不需要在 Windows 上安装 Python 或额外配置凭据。发送前会校验 Webhook 对应的频道 ID，若不匹配则拒绝发送。不要将 URL 提交到仓库、粘贴进日志或聊天，也不要直接使用绑定到 CCH 频道的 Webhook。若以后更换频道，需要同时更新 workflow 中的 `DISCORD_CHANNEL_ID` 和 Secret。

### 报告内容与失败处理

- 支付脚本在成功或失败时都会把各笔支付的最后状态、已经验证的金额、余额、手续费和 Payment Hash 写到 GitHub Job Summary 和结构化步骤输出。Discord 直接复用这些结果，不会再执行支付或查询节点。
- 独立 Ubuntu 通知 job 在 Windows job 结束后发送简报：总体结果与耗时、北京时间的实际开始时间、版本、检查结论，以及三条资金流。A/B 的 FNN、CLI、RPC 均核对通过时，版本区合并为一行，例如 `A/B v0.10.1 · verified · latest stable`；有新版本或查询失败时也用一行说明。版本不匹配或信息缺失时才展开实际版本与 CI 预期对照，完整版本和 commit 始终保留在 GitHub Summary。分支/commit 仅在非 `main` 运行时展示，重跑会标注次数。
- 三笔支付合并到一个区块，每笔只显示类型、路径、金额和 CKB 手续费；前后余额、逐项断言、shannons/费率、Payment Hash 保留在执行日志和 GitHub Job Summary，点击卡片标题查看。只有三笔结果齐全时才显示余额与手续费验证通过。
- 主调度计划时间为北京时间 **10:30**，GitHub **10:47** cron 兜底可能延迟。触发方式与实际开始时间接在卡片顶部结果和耗时之后，不单设时间区块，也不强制另起一行，不将计划时刻当成实际执行时间。重复或过期任务跳过烟测及 Discord。
- 前置检查正常时只显示一句通过；异常时展示未通过、取消、跳过或状态未知的检查，正常步骤省略。
- 每轮在创建发票或付款前检查 A/B 目标 peer 的全部通道，包括已关闭通道用于诊断。只有 Ready、启用、允许出站的原生 CKB 通道才计入可用余额，并扣除已占用的出站 TLC；远端余额、关闭通道中的历史余额均不可花。预算检查覆盖整轮金额、最高路由费和单笔所需容量，每次发送前还会重新检查。检查不预留资金，也不保证远端路由，真实 RPC 错误仍会使烟测失败。
- 付款继续使用 Fiber 自动选路，不固定通道、不自动重试或开通道。余额断言比较付款前后同一组 Ready CKB 通道到目标 peer 的总额，通道顺序改变不影响结果；通道集合改变则无法通过精确验证。路由手续费按 A 上实际发生余额变化的第二跳通道核对，避免用列表第一条的费率判断其他通道的支付。
- 流程中途失败时，卡片显示具体阶段、错误来源及原因，并保留已经验证通过的支付；其余明确标为未发送、未开始、已结算但验证失败或结果未知。支付结果未知时应先通过日志中的 Payment Hash 核对，避免重复付款。只有三笔全部验证通过才显示 `3/3` 和余额、手续费验证通过。完整余额与通道清单保留在 GitHub Summary。
- 2026-11-17 失败的通道快照、产品行为核查和尚未确定的关闭原因见 [诊断记录](docs/2026-11-17-payment-liquidity.md)。修改脚本不会恢复已关闭通道的出站流动性。
- 定时运行遇到 `paymentFlow.enabled=false` 会显示支付已禁用；手动运行没有请求支付时会显示跳过。都不会显示 `3/3` 通过。该配置只限制定时支付，手动 `send_payment=true` 仍按原有行为执行支付。
- Secret 未配置、频道不匹配或 Discord 请求失败会在 **Send Discord report** 步骤显示错误，通知发送错误不会改变 Windows 烟测 job 的结论；报告不会触发 `@everyone` 等提及。

### 本地验证

以下检查均不访问 Fiber 节点、不发送 Discord 消息：

```sh
python3 -m unittest discover -s tests
python3 scripts/send_daily_smoke_report.py --dry-run
```

PowerShell 检查：

```powershell
tests\Test-PowerShellSyntax.ps1
tests\Test-Module.ps1
tests\Test-InstalledFiber.ps1
tests\Test-PaymentFlowReport.ps1
tests\Test-DailySchedule.ps1
tests\Test-DailyDispatch.ps1
```

`--dry-run` 只输出 JSON 卡片预览，可通过 `FIBER_REPORT_JOB_RESULT`、`FIBER_REPORT_STEPS_JSON` 和 GitHub 上下文环境变量输入运行数据；不提供输入时明确显示数据不可用。

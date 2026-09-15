# Fiber Windows Smoke

在一台长期在线的 Windows x64 机器上运行两个 Fiber testnet 节点，并通过 self-hosted GitHub Actions runner 每天执行升级、健康检查和真实支付冒烟测试。

## 支付拓扑

```text
1. Invoice:        Node B -- 0.02 CKB --> Node A
2. Keysend:        Node A -- 0.01 CKB --> CkbaNode-1
3. Routed Keysend: Node B -- 0.03 CKB + fee --> Node A --> CkbaNode-1
```

`CkbaNode-1` 是 Fiber 测试网公共节点。Node A 与 `CkbaNode-1` 有一条 channel，Node B 与 Node A 有一条 channel；两个本地节点都作为 Windows Service 长期运行。

## 每日 CI 做什么

Workflow：[`.github/workflows/fiber-node-maintenance.yml`](.github/workflows/fiber-node-maintenance.yml)

每天北京时间 **08:01** 自动执行：

1. 检查所有 PowerShell 脚本语法并运行模块单元测试。
2. 检查 Node A、Node B 是否有更新的 Fiber prerelease；有更新时校验 SHA-256、执行数据库兼容性预检并安全替换二进制。
3. 检查两个 Windows 服务、RPC、peer 连接和两条 `ChannelReady` channel。
4. Node A 创建 `0.02 CKB` invoice，由 Node B 支付。
5. Node A 向测试网公共节点 `CkbaNode-1` keysend `0.01 CKB`。
6. Node B 通过 Node A 向 `CkbaNode-1` keysend `0.03 CKB`，验证 Node A 收取的转发手续费。
7. 将支付前后余额、手续费、Payment Hash 和资金流写入日志及 GitHub Job Summary。
8. 执行结束后向 Discord 发送汇总卡片，包括运行状态、节点版本、前置检查和三笔支付明细；失败时也发送。

自动升级不会创建新 channel。需要数据库 migration 的版本会拒绝自动升级，不会直接修改现有数据。

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

在 GitHub Actions 页面选择 `Fiber Windows node maintenance`，点击 **Run workflow**。通常手动验证使用：

```text
ensure_channel: false
send_payment:   true
send_discord_report: true
```

`ensure_channel` 可能锁定链上 CKB，日常不要勾选；`send_payment` 会执行三笔真实支付：`0.02 + 0.01 + 0.03 CKB`，另加一笔动态计算的路由手续费。

`send_discord_report` 只控制手动运行是否发报告，默认关闭；定时运行始终尝试发送。该开关本身不会触发支付。

## Discord 日报配置

目标频道 ID：`1549402632203018410`。使用与 `cch-daily-smoke` 相同的 Discord Webhook 卡片方式，**只需配置一个 Secret**：

1. 在 Discord 目标频道打开 **编辑频道 → 整合 → Webhooks → 新建 Webhook**，确认所选频道正确并复制 Webhook URL。创建者需要该频道的 **管理 Webhooks** 权限，详见 [Discord 官方说明](https://support.discord.com/hc/en-us/articles/228383668-Intro-to-Webhooks)。
2. 打开 [本仓库的 Actions Secrets 设置](https://github.com/sunchengzhu/fiber-windows-smoke/settings/secrets/actions)，选择 **New repository secret**：
   - Name：`DISCORD_WEBHOOK_URL`
   - Secret：上一步复制的完整 URL。
3. 包含本功能的代码进入 `main` 后，每日定时运行会自动发送。可手动勾选 `send_discord_report` 验证发送；`send_payment=false` 时只执行原有升级和健康检查，卡片明确显示未请求支付。如需完整支付明细，同时勾选 `send_payment`。

也可以在自己的终端交互式保存 Secret，避免把 URL 写入命令历史：

```sh
gh secret set DISCORD_WEBHOOK_URL --repo sunchengzhu/fiber-windows-smoke
```

Webhook URL 已绑定频道，频道 ID 本身不是发送凭据；不需要 Bot Token，也不需要在 Windows 上安装 Python 或额外配置凭据。发送前会校验 Webhook 对应的频道 ID，若不匹配则拒绝发送。不要将 URL 提交到仓库、粘贴进日志或聊天，也不要直接使用绑定到 CCH 频道的 Webhook。若以后更换频道，需要同时更新 workflow 中的 `DISCORD_CHANNEL_ID` 和 Secret。

### 报告内容与失败处理

- 原支付脚本把已经通过断言的金额、余额、手续费和 Payment Hash 同时写到 GitHub Job Summary 和结构化步骤输出。Discord 直接复用这些结果，不会再执行支付或查询节点。
- 独立 Ubuntu 通知 job 在 Windows job 结束后发送简报：总体结果与耗时、北京时间的实际开始时间、FNN 版本、检查结论，以及三条资金流。A/B 版本相同则合并展示；分支/commit 仅在非 `main` 运行时展示，重跑会标注次数。
- 三笔支付合并到一个区块，每笔只显示类型、路径、金额和 CKB 手续费；前后余额、逐项断言、shannons/费率、Payment Hash 保留在执行日志和 GitHub Job Summary，点击卡片标题查看。只有三笔结果齐全时才显示余额与手续费验证通过。
- 计划时间为北京时间 **08:01**；GitHub 的 cron 可能延迟。卡片标注定时或手动触发及实际开始时间，不重复展示固定计划时间，也不将计划时刻当成实际执行时间。
- 前置检查正常时只显示一句通过；异常时展示未通过、取消、跳过或状态未知的检查，正常步骤省略。
- 支付全部完成并通过断言后才导出三笔明细。流程中途失败时，卡片显示失败步骤并提示明细未生成，通过 Actions 链接查看日志，不推测某一笔是否已经发送或通过。
- 定时运行遇到 `paymentFlow.enabled=false` 会显示支付已禁用；手动运行没有请求支付时会显示跳过。都不会显示 `3/3` 通过。该配置只限制定时支付，手动 `send_payment=true` 仍按原有行为执行支付。
- Secret 未配置、频道不匹配或 Discord 请求失败会在 **Send Discord report** 步骤显示错误，通知发送错误不会改变 Windows 烟测 job 的结论；报告不会触发 `@everyone` 等提及。

### 本地验证

以下检查均不访问 Fiber 节点、不发送 Discord 消息：

```sh
python3 -m unittest discover -s tests -p 'test_daily_smoke_report.py'
python3 scripts/send_daily_smoke_report.py --dry-run
```

PowerShell 检查：

```powershell
tests\Test-PowerShellSyntax.ps1
tests\Test-Module.ps1
tests\Test-PaymentFlowReport.ps1
```

`--dry-run` 只输出 JSON 卡片预览，可通过 `FIBER_REPORT_JOB_RESULT`、`FIBER_REPORT_STEPS_JSON` 和 GitHub 上下文环境变量输入运行数据；不提供输入时明确显示数据不可用。

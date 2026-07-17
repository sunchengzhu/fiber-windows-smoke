# Fiber Windows Smoke

在一台长期在线的 Windows x64 机器上运行两个 Fiber testnet 节点，安全更新 FNN，维护两条 CKB channel，并持续执行 invoice 与 keysend 支付检查。

这个项目参考 `fiber-jmeter-sample` 的部署顺序，但针对单台 Windows 机器做了以下调整：

- FNN 由 Windows Service 长期运行，不依赖 GitHub Actions job 存活。
- 使用官方 `fnn_<version>-x86_64-windows.tar.gz`，并校验 GitHub release asset 的 SHA-256 digest。
- 版本没有变化时不重启。
- 更新前使用新二进制执行 `--check-validate`；数据库需要迁移时拒绝替换。
- 更新失败会恢复旧的 `fnn.exe`、`fnn-cli.exe` 并重新启动服务。
- `Ensure-Channel.ps1` 是幂等的：已有 ready 或 pending channel 时绝不重复调用 `open_channel`。
- 定时 workflow 只更新和检查，不自动重新开 channel，避免意外再次锁定资金。

## 默认拓扑

节点 A 是已经安装的 `FiberNode`，保留它到官方 public node `fiber-testnet-public-bottle` 的现有 channel。节点 B 是同一台 Windows 上新增的 `FiberNodeB`：

```text
node B -- invoice payment 0.02 CKB --> node A -- keysend 0.01 CKB --> Bottle
```

两套节点完全隔离：

| 节点 | 服务 | 目录 | RPC | P2P |
| --- | --- | --- | --- | --- |
| A | `FiberNode` | `C:\fiber-node` | `127.0.0.1:8227` | `127.0.0.1:8228` |
| B | `FiberNodeB` | `C:\fiber-node-b` | `127.0.0.1:8327` | `127.0.0.1:8328` |

节点 A 的 public peer 配置：

- peer pubkey: `02b6d4e3ab86a2ca2fad6fae0ecb2e1e559e0b911939872a90abdda6d20302be71`
- funding amount: `499 CKB`，即 `49,900,000,000` shannons
- RPC: `http://127.0.0.1:8227`
- P2P 默认只监听 `127.0.0.1`，节点主动连接 public peer，不开放公网入站端口
- release channel: `prerelease`，即按发布时间选择最新已发布版本，包括 RC

`499 CKB` 是该 public node 当前自动接受 CKB channel 的最低 funding amount。执行开通前请再次核对 Fiber 仓库的 `docs/network-nodes.md`。

## 文件

| 文件 | 作用 |
| --- | --- |
| `scripts/Install-FiberService.ps1` | 首次下载 FNN、生成 CKB key、安装 WinSW 服务并启动节点 |
| `scripts/Update-FiberBinary.ps1` | 检查 release、校验下载、数据库预检、备份、更新和回滚 |
| `scripts/Ensure-Channel.ps1` | 连接 peer，幂等创建 channel，等待 `ChannelReady` |
| `scripts/Install-SecondNode.ps1` | 保留节点 A，在同一台 Windows 上安装独立节点 B |
| `scripts/Ensure-SecondNodeChannel.ps1` | 由节点 B 出资 5000 CKB，建立 B→A channel |
| `scripts/Send-PaymentFlow.ps1` | A 生成 invoice、B 支付 0.02 CKB，再由 A keysend 0.01 CKB 到 Bottle |
| `scripts/Test-PaymentTopology.ps1` | 一条命令检查两个服务和两条 channel |
| `scripts/Test-FiberNode.ps1` | 检查服务、RPC、版本、peer 和 ready channel |
| `config/node-settings.example.json` | Windows 机器配置模板 |

## 1. Windows 前置条件

- Windows 10/11 x64 或 Windows Server x64。
- Windows PowerShell 5.1 或 PowerShell 7。
- 管理员 PowerShell。
- `tar.exe` 可用；Windows 10/Server 2019 及以后通常自带。
- Microsoft Visual C++ 2015–2022 Redistributable x64。
- 机器能够访问 GitHub、CKB testnet RPC 和 Fiber bootnodes/public node。
- 系统盘预留足够空间存放 channel 数据和备份。

不要在允许不受信任 PR 执行代码的仓库中挂载这台 self-hosted runner。runner 能以管理员权限控制节点并读取节点目录。

## 2. 创建机器配置

在管理员 PowerShell 中：

```powershell
git clone https://github.com/YOUR_ACCOUNT/fiber-windows-smoke.git C:\fiber-windows-smoke
Set-Location C:\fiber-windows-smoke

Copy-Item config\node-settings.example.json config\node-settings.json
notepad config\node-settings.json
```

主要配置：

- `releaseChannel`: `prerelease` 表示跟随发布时间最新的版本，包括 RC；改成 `stable` 可只跟稳定版。
- `releaseTag`: 留空时自动选最新；也可以固定为 `v0.8.1`。
- `peer.pubkey`: channel 对端。
- `peer.address`: 可选 multiaddr。留空时通过本地 gossip graph 按 pubkey 解析。
- `peer.fundingAmountShannons`: 开通 channel 时锁定的本地资金。
- `peer.fundingFeeRate`: funding transaction fee rate。

当前版本先只支持 CKB channel。UDT channel 需要额外传入 type script 和余额检查，后续再加。

## 3. 安装长期运行的节点

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\scripts\Install-FiberService.ps1 -SettingsPath .\config\node-settings.json
```

脚本会：

1. 下载配置指定的 Fiber release。
2. 校验 release asset 的 GitHub SHA-256 digest。
3. 将二进制放到 `C:\fiber-node\bin`。
4. 从 release 中复制版本匹配的 testnet `config.yml`。
5. 将 P2P 改成 outbound-only，并保留 RPC 的 localhost 绑定。
6. 生成新的 CKB private key。
7. 下载并校验固定版本的 WinSW 2.12.0。
8. 要求输入并确认至少 12 字符的 key 加密密码。
9. 以 `LocalSystem` 安装自动启动的 `FiberNode` 服务。
10. 等待 RPC 健康并打印 pubkey 与 CKB address。

WinSW XML 必须保存 FNN 启动所需的 key password。脚本会用 Windows ACL 将 XML 和数据目录限制为 `SYSTEM` 与本机 Administrators。不要把 `C:\fiber-node` 同步到公共云盘。

安装完成后，立即备份整个 `C:\fiber-node\data`。其中 `data\fiber\sk`、`data\ckb\key` 和 channel store 都很重要。

## 4. 给节点地址充值

安装脚本最后会打印 `ckb_address`。向该 testnet 地址充值：

- 至少 `499 CKB` 用于 funding；
- 额外准备 funding/commitment transaction fee；
- 建议总计至少 `505 CKB`，不要刚好只充最低值。

等待充值交易确认后再开 channel。

## 5. 建立并检查 channel

首次显式执行：

```powershell
.\scripts\Ensure-Channel.ps1 -FundingAmountCkb 2000
```

`FundingAmountCkb` 使用直观的 CKB 单位；脚本会换算成 shannons、同步机器运行配置，然后开通 channel。省略该参数时使用 `node-settings.json` 中已有的金额。

流程是：

```text
node_info
  → list_channels(pubkey)
  → 已有 ChannelReady：直接成功
  → 已有 pending channel：只等待，不重复开通
  → connect_peer
  → open_channel
  → 轮询 list_channels，直到 ChannelReady
```

检查节点和 channel：

```powershell
.\scripts\Test-FiberNode.ps1 -SettingsPath .\config\node-settings.json
```

健康检查会以 CKB 为单位显示 local/remote 可用余额，并用 ASCII 流动性条和四位小数百分比展示两端占比，避免小额余额被显示成 `100% / 0%`。

如果正在等待链上确认，可以临时允许 pending：

```powershell
.\scripts\Test-FiberNode.ps1 -SettingsPath .\config\node-settings.json -AllowPending
```

## 6. 安装节点 B

不要删除或重装现有节点 A。它的服务、密钥、数据和到 Bottle 的 channel 都会原样保留。

管理员 PowerShell：

```powershell
.\scripts\Install-SecondNode.ps1
```

脚本自动读取节点 A 的 pubkey，生成 `config\node-b-settings.json`，然后安装独立的 `FiberNodeB`。输入并确认节点 B 自己的密钥密码。安装结束会打印节点 B 的 CKB 地址。

向节点 B 地址充值约 `5500 CKB`，等待链上确认，然后执行：

```powershell
.\scripts\Ensure-SecondNodeChannel.ps1
```

该命令只在 B→A channel 不存在时开通 `5000 CKB` 的 private one-way channel：B 可以向 A 支付，A 不能在这条 channel 上反向支付。重复执行不会重复锁定资金。检查完整拓扑：

```powershell
.\scripts\Test-PaymentTopology.ps1
```

默认使用紧凑模式，只显示两个节点的服务、版本、peer 数、Channel 状态、余额和占比，整个结果约 8 行。排查问题时可以查看 pubkey、CKB 地址和 Channel ID 等完整信息：

```powershell
.\scripts\Test-PaymentTopology.ps1 -Detailed
```

## 7. 手动执行完整资金流

```powershell
.\scripts\Send-PaymentFlow.ps1
```

每次运行严格执行两笔不同金额的支付：

1. 节点 A 调用 `new_invoice` 生成 `0.02 CKB` invoice，节点 B 支付给 A；
2. 节点 A 向 Bottle keysend `0.01 CKB`。

脚本逐笔等待 `Success`，并用醒目的 `BEFORE` / `AFTER - SUCCESS` 标题显示 channel 两端余额变化。GitHub Actions 运行时还会在 Job Summary 中生成一份 `B -> A -> Bottle` 资金流摘要。临时覆盖金额时可执行：

```powershell
.\scripts\Send-PaymentFlow.ps1 -InvoiceAmountCkb 0.02 -KeysendAmountCkb 0.01
```

## 8. 单独调试一种支付

默认向配置中的 public peer 发送 `0.01 CKB` keysend，并等待支付进入 `Success`：

```powershell
.\scripts\Send-DailyPayment.ps1
```

临时指定金额：

```powershell
.\scripts\Send-DailyPayment.ps1 -AmountCkb 0.1
```

支付一张由收款节点生成的新 invoice：

```powershell
.\scripts\Send-DailyPayment.ps1 -Mode Invoice -Invoice "<Fibt invoice>"
```

若 Windows 能通过内网、VPN 或 SSH 隧道安全访问另一台收款 FNN 的 RPC，可由脚本生成新 invoice 后连续发送 keysend 和 invoice 两笔：

```powershell
.\scripts\Send-DailyPayment.ps1 -Mode Both -InvoiceReceiverRpcUrl "http://127.0.0.1:8237"
```

脚本会检查 ready channel 和 local balance，显示 payment hash、fee，以及每笔支付前后的 local/remote CKB 余额。`dailyPayment.mode` 可设为 `Keysend`、`Invoice` 或 `Both`。invoice 每次都必须由收款节点新建，不能重复使用；不要将未鉴权的 FNN RPC 暴露到公网。

## 9. 手动测试更新

```powershell
.\scripts\Update-FiberBinary.ps1 -SettingsPath .\config\node-settings.json
```

备份保存在 `C:\fiber-node\backups\<UTC timestamp>-<release tag>`。数据库预检失败意味着目标版本可能要求 migration；脚本会恢复原服务，不会自动修改数据库。

## 10. GitHub Actions

在这台 Windows 机器上安装 repository-level self-hosted runner，并添加自定义 label：

```text
fiber-windows
```

将 runner 安装成 Windows Service，并确保运行账户是本机管理员或有权限控制 `FiberNode` 服务。安装节点时，机器配置已复制到：

```text
C:\fiber-node\automation\settings.json
```

workflow 每天北京时间 08:01 执行（GitHub Actions cron 使用 UTC，因此配置为当天 `00:01 UTC`）：

1. PowerShell 语法检查；
2. 小型模块测试；
3. 分别更新或确认节点 A、B 的 FNN 二进制；
4. 检查两个服务、RPC 和两条 channel；
5. 执行 B→A `0.02 CKB` invoice 支付和 A→Bottle `0.01 CKB` keysend，并等待两笔成功。

手动触发 workflow 时，`ensure_channel` 控制是否显式确保两条 channel，`send_payment` 控制是否执行完整支付流。定时任务永远不会自动花费链上资金创建新 channel，但会在已有 channel 上发送配置金额的支付。

后续要改成每小时检查，将 workflow cron 改成：

```yaml
- cron: "7 * * * *"
```

选择第 7 分钟可避开整点调度高峰。self-hosted runner 不消耗 GitHub-hosted runner minutes。

## 安全与恢复

- 不要提交 `config/node-settings.json`；它已经被 `.gitignore` 排除。
- 不要提交 CKB key、Fiber `sk`、store、WinSW XML 或 RPC token。
- RPC 保持 `127.0.0.1`；不要将管理 RPC 暴露到公网。
- 定期离线备份 `C:\fiber-node\data`，升级前备份二进制不能替代 channel 数据备份。
- 自动升级只处理“不需要数据库 migration”的版本；需要 migration 时人工备份并按照对应 migration guide 操作。
- 如果设置 RPC biscuit 鉴权，通过机器环境变量 `FNN_AUTH_TOKEN` 或 `authTokenFile` 提供 token。

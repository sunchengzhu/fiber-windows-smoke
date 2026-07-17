# Fiber Windows Smoke

在一台长期在线的 Windows x64 机器上运行 Fiber testnet 节点，安全更新 FNN，建立一条 CKB channel，并持续检查节点和 channel 状态。

这个项目参考 `fiber-jmeter-sample` 的部署顺序，但针对单台 Windows 机器做了以下调整：

- FNN 由 Windows Service 长期运行，不依赖 GitHub Actions job 存活。
- 使用官方 `fnn_<version>-x86_64-windows.tar.gz`，并校验 GitHub release asset 的 SHA-256 digest。
- 版本没有变化时不重启。
- 更新前使用新二进制执行 `--check-validate`；数据库需要迁移时拒绝替换。
- 更新失败会恢复旧的 `fnn.exe`、`fnn-cli.exe` 并重新启动服务。
- `Ensure-Channel.ps1` 是幂等的：已有 ready 或 pending channel 时绝不重复调用 `open_channel`。
- 定时 workflow 只更新和检查，不自动重新开 channel，避免意外再次锁定资金。

## 默认拓扑

默认配置使用 testnet、CKB channel 和官方 public node `fiber-testnet-public-bottle`：

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
.\scripts\Ensure-Channel.ps1 -SettingsPath .\config\node-settings.json
```

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

如果正在等待链上确认，可以临时允许 pending：

```powershell
.\scripts\Test-FiberNode.ps1 -SettingsPath .\config\node-settings.json -AllowPending
```

## 6. 手动测试更新

```powershell
.\scripts\Update-FiberBinary.ps1 -SettingsPath .\config\node-settings.json
```

备份保存在 `C:\fiber-node\backups\<UTC timestamp>-<release tag>`。数据库预检失败意味着目标版本可能要求 migration；脚本会恢复原服务，不会自动修改数据库。

## 7. GitHub Actions

在这台 Windows 机器上安装 repository-level self-hosted runner，并添加自定义 label：

```text
fiber-windows
```

将 runner 安装成 Windows Service，并确保运行账户是本机管理员或有权限控制 `FiberNode` 服务。安装节点时，机器配置已复制到：

```text
C:\fiber-node\automation\settings.json
```

workflow 每天北京时间 10:00 执行：

1. PowerShell 语法检查；
2. 小型模块测试；
3. 更新或确认 FNN 二进制；
4. 检查服务、RPC 和 channel。

手动触发 workflow 并勾选 `ensure_channel` 才会执行 `Ensure-Channel.ps1`。定时任务永远不会自动花费链上资金创建新 channel。

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

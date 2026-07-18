# Fiber Windows Smoke

在一台长期在线的 Windows x64 机器上运行两个 Fiber testnet 节点，并通过 self-hosted GitHub Actions runner 每天执行升级、健康检查和真实支付冒烟测试。

## 支付拓扑

```text
Node B -- 0.02 CKB Invoice --> Node A -- 0.01 CKB Keysend --> Bottle
Node B -- 0.03 CKB Routed Keysend + fee --> Node A --> Bottle
```

Node A 与 `fiber-testnet-public-bottle` 有一条 channel，Node B 与 Node A 有一条 channel；两个节点都作为 Windows Service 长期运行。

## 每日 CI 做什么

Workflow：[`.github/workflows/fiber-node-maintenance.yml`](.github/workflows/fiber-node-maintenance.yml)

每天北京时间 **08:01** 自动执行：

1. 检查所有 PowerShell 脚本语法并运行模块单元测试。
2. 检查 Node A、Node B 是否有更新的 Fiber prerelease；有更新时校验 SHA-256、执行数据库兼容性预检并安全替换二进制。
3. 检查两个 Windows 服务、RPC、peer 连接和两条 `ChannelReady` channel。
4. Node A 创建 `0.02 CKB` invoice，由 Node B 支付。
5. Node A 向 Bottle keysend `0.01 CKB`。
6. Node B 通过 Node A 向 Bottle keysend `0.03 CKB`，验证 Node A 收取的转发手续费。
7. 将支付前后余额、手续费、Payment Hash 和资金流写入日志及 GitHub Job Summary。

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
A -> Bottle  A -0.01 CKB   Bottle +0.01 CKB
B -> A -> Bottle  B -(0.03 CKB + fee)   A +fee   Bottle +0.03 CKB
```

## 手动运行

在 GitHub Actions 页面选择 `Fiber Windows node maintenance`，点击 **Run workflow**。通常手动验证使用：

```text
ensure_channel: false
send_payment:   true
```

`ensure_channel` 可能锁定链上 CKB，日常不要勾选；`send_payment` 会执行三笔真实支付：`0.02 + 0.01 + 0.03 CKB`，另加一笔动态计算的路由手续费。

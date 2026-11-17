# Payment liquidity investigation — 2026-11-17

The [failed daily run #185](https://github.com/sunchengzhu/fiber-windows-smoke/actions/runs/44003435981) completed the 0.02 CKB Invoice from B to A. The smoke script then rejected the 0.01 CKB Keysend from A to CkbaNode-1 before calling `send_payment`. The routed payment never started. Installed FNN/CLI/RPC versions matched the v0.10.1 baseline.

## Read-only channel audit

Queried `node_info` and `list_channels(include_closed=true)` on **both** nodes. A had three channels in total, B had one; the B-to-A channel appears from both endpoints. IDs below are abbreviated.

| Endpoint | Peer | Channel ID prefix | State | Local CKB | Remote CKB | Direction |
| --- | --- | --- | --- | --- | --- | --- |
| A | CkbaNode-1 | `0x8f7d54cbc846` | ChannelReady | 0 | 900 | Bidirectional, accepted by A |
| A | B | `0x06a25389cead` | ChannelReady | 3.42198 | 4897.57802 | One-way, A is the acceptor; receive-only |
| A | CkbaNode-1 | `0xebe1a74bc42b` | Closed / COOPERATIVE | 1898.3 | 153.7 | Historical outgoing channel; no spendable channel liquidity |
| B | A | `0x06a25389cead` | ChannelReady | 4897.57802 | 3.42198 | One-way, B is the initiator; outbound allowed |

The closed channel's final balances match the funded public-peer channel in the preceding successful daily run. Its shutdown transaction hash is `0xf49433cd9987d5dbf5052f6054e2e52d32829f8cced5e498f37cc499b62e3b50`. This is evidence of a cooperative close, but does **not** establish who initiated it or why. No retained local FNN runtime trace was found that identifies the initiator. The complete public RPC snapshot is saved on the Windows host at `C:\fiber-maintenance\channel-inventory-20261117.json`; no keys or RPC authentication tokens were exported.

At the time of this read-only audit, there was **no funded outgoing A-to-CkbaNode-1 channel**. Choosing another list entry could not restore payment capability. Closed channel balances must not be counted as usable liquidity, and the Ready channel's 900 CKB remote balance only enables receiving.

## Product behavior checked at the installed commit

Examined exact installed commit [`d9b6bbd74faf5b168244e3ddea5b6762a04e0a71`](https://github.com/nervosnetwork/fiber/tree/d9b6bbd74faf5b168244e3ddea5b6762a04e0a71), rather than a newer development checkout:

- [`list_channels`](https://github.com/nervosnetwork/fiber/blob/d9b6bbd74faf5b168244e3ddea5b6762a04e0a71/crates/fiber-lib/src/rpc/channel.rs) sorts by creation time descending. The first Ready channel is not a liquidity selection contract.
- The [router](https://github.com/nervosnetwork/fiber/blob/d9b6bbd74faf5b168244e3ddea5b6762a04e0a71/crates/fiber-lib/src/fiber/graph.rs) considers outgoing liquidity. An explicit `build_router` estimate on B can describe A's public outgoing edge without proving A has the private directional balance to forward a payment.
- [`send_payment(dry_run=true)`](https://github.com/nervosnetwork/fiber/blob/d9b6bbd74faf5b168244e3ddea5b6762a04e0a71/crates/fiber-lib/src/fiber/payment.rs) builds routes without storing a payment session or sending an onion packet. Calling this on A for the 0.01 CKB Keysend independently returned: `Failed to build route, Insufficient balance: max outbound liquidity 0 is insufficient, required amount: 1000000`.

The observed payment failure is therefore explained by actual missing outbound liquidity and agrees with Fiber's own automatic routing check. It is **not evidence of a Fiber payment execution bug**. The reason the former channel closed remains unresolved; this audit cannot rule out a separate product or operational issue behind that close.

## Smoke harness changes

The harness previously inspected the first Ready channel, checked only the next payment, and exported results only after all three payments and assertions succeeded. These choices hid the completed Invoice and made channel/order changes hard to diagnose.

The fix audits all channels to each configured peer, checks whole-round capacity before creating an invoice, rechecks immediately before each payment, and compares a stable set of Ready CKB channel balances. Product routing stays automatic. The second-hop fee policy is read from the channel that actually moved funds. Failures retain verified earlier payments and distinguish unsent payments, settled payments whose verification failed, and unknown outcomes.

This patch does not itself reopen/fund channels, retry payments, change node services, or upgrade Fiber. No GitHub Actions run, payment, or Discord message was triggered during the preceding read-only investigation and offline patch validation; the fixture tests exercise the payment scripts without reachable RPC/network implementations. The subsequent user-authorized testnet recovery is recorded separately below.

## Later user-authorized testnet recovery

After the user requested restoration and asked whether more funds were needed, the Windows node was confirmed to use `ckb_testnet`. A's funding wallet held **99798.29928754 testnet CKB in two ordinary native CKB live cells** (no type script and empty data). The old shutdown transaction was `committed`; matching its output lock's `code_hash`, `hash_type`, and `args` against A's funding lock confirmed that **1997.30000000 CKB had returned to A**. Existing funds were sufficient: no faucet claim, new deposit, or real-money purchase was needed.

CkbaNode-1 was connected and announced an auto-accept minimum of **400 CKB** (`0x9502f9000`). Recovery reused the machine's configured **2000 CKB** funding amount (`200000000000` shannons) and funding fee rate **100000 shannons/KB**. A single direct `open_channel` call requested a public, bidirectional channel (`public=true`, `one_way=false`); it was not retried. The new opening was tracked independently of the existing empty Ready channel.

| Recovery evidence | Value |
| --- | --- |
| Temporary channel ID | `0x3648597e46f2071d0ce4000b72244d12057d96ed38c53b10020ce939fb986081` |
| Final Ready channel ID | `0x740f301b14604063a33cc4d1bc93237a21551749b512d3cd0c0249bd18ec5a05` |
| Funding outpoint | `0x30c7e57cc000df2b25d88642ea628f8ccffdde05b49a395ddf1e8eef4f6d311600000000` |
| Initial local / remote balances | **1900 / 150 CKB** |
| Outgoing forwarding fee rate | **1000 millionths** (`0x3e8`) |

The new channel's 2000 CKB local funding includes its 100 CKB reserve, leaving 1900 CKB initial local channel liquidity. The existing 0/900 CKB receiving channel and the B-to-A channel were retained; neither was closed as part of recovery.

A manual `Send-PaymentFlow.ps1` run using an isolated copy of PR #17's immutable commit `174ebbda174e129a33ec410c906dca94846c8488` completed after the new channel became Ready. **All three payments and their production balance/fee assertions passed:**

| Scenario | Amount (testnet CKB) | Routing fee (testnet CKB) | Result |
| --- | --- | --- | --- |
| Invoice, B to A | 0.02 | 0 | Verified success |
| Keysend, A to CkbaNode-1 | 0.01 | 0 | Verified success |
| Routed Keysend, B to A to CkbaNode-1 | 0.03 | 0.00003 | Both hops and actual forwarding fee verified |

The full local Windows report, structured output (including payment hashes), and log are saved under `C:\fiber-maintenance\restored-payment-smoke-20261117` with `.md`, `.output`, and `.log` suffixes. An initial terminal input failure was confirmed to have produced no execution marker or payments before correcting the input; the successful payment flow was executed once. No GitHub Actions workflow or Discord notification was triggered. PR #17 remains separate from this operational recovery and is not automatically merged.

Restoring an outgoing channel resolves the observed absence of payment liquidity. It does **not** explain why the former channel cooperatively closed; that underlying cause remains unknown.

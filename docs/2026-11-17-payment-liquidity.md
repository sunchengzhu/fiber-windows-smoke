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

There is currently **no funded outgoing A-to-CkbaNode-1 channel**. Choosing another list entry cannot restore payment capability. Closed channel balances must not be counted as usable liquidity, and the Ready channel's 900 CKB remote balance only enables receiving.

## Product behavior checked at the installed commit

Examined exact installed commit [`d9b6bbd74faf5b168244e3ddea5b6762a04e0a71`](https://github.com/nervosnetwork/fiber/tree/d9b6bbd74faf5b168244e3ddea5b6762a04e0a71), rather than a newer development checkout:

- [`list_channels`](https://github.com/nervosnetwork/fiber/blob/d9b6bbd74faf5b168244e3ddea5b6762a04e0a71/crates/fiber-lib/src/rpc/channel.rs) sorts by creation time descending. The first Ready channel is not a liquidity selection contract.
- The [router](https://github.com/nervosnetwork/fiber/blob/d9b6bbd74faf5b168244e3ddea5b6762a04e0a71/crates/fiber-lib/src/fiber/graph.rs) considers outgoing liquidity. An explicit `build_router` estimate on B can describe A's public outgoing edge without proving A has the private directional balance to forward a payment.
- [`send_payment(dry_run=true)`](https://github.com/nervosnetwork/fiber/blob/d9b6bbd74faf5b168244e3ddea5b6762a04e0a71/crates/fiber-lib/src/fiber/payment.rs) builds routes without storing a payment session or sending an onion packet. Calling this on A for the 0.01 CKB Keysend independently returned: `Failed to build route, Insufficient balance: max outbound liquidity 0 is insufficient, required amount: 1000000`.

The observed payment failure is therefore explained by actual missing outbound liquidity and agrees with Fiber's own automatic routing check. It is **not evidence of a Fiber payment execution bug**. The reason the former channel closed remains unresolved; this audit cannot rule out a separate product or operational issue behind that close.

## Smoke harness changes

The harness previously inspected the first Ready channel, checked only the next payment, and exported results only after all three payments and assertions succeeded. These choices hid the completed Invoice and made channel/order changes hard to diagnose.

The fix audits all channels to each configured peer, checks whole-round capacity before creating an invoice, rechecks immediately before each payment, and compares a stable set of Ready CKB channel balances. Product routing stays automatic. The second-hop fee policy is read from the channel that actually moved funds. Failures retain verified earlier payments and distinguish unsent payments, settled payments whose verification failed, and unknown outcomes.

This patch does not reopen/fund channels, retry payments, change node services, or upgrade Fiber. Restoring outbound liquidity requires a separate deliberate maintenance action. No GitHub Actions run, real payment, or Discord message was triggered for this investigation or patch validation; local/offline fixture tests exercise the payment scripts without reachable RPC/network implementations.

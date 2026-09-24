# agentx-contracts

Smart contracts for **AGENTX** — proof-of-payment reputation and escrow for
[ERC-8004](https://eips.ethereum.org/EIPS/eip-8004) agents, settled on Monad.

ERC-8004 gives agents identity and a place to record reputation. It does not
give them money, and `giveFeedback()` is free for anyone to call. AGENTX makes
that feedback cost something: **only a settled on-chain payment can write it.**

```solidity
// ERC-8004 requires you to name whose feedback you count —
// getSummary reverts on an empty client list.
getSummary(agentId, [AGENTX_ESCROW], "agentx", "settled")
```

## What is here

| Contract | Role |
|---|---|
| `TaskEscrow` | Job state machine, settlement, and the sole writer of AGENTX feedback |
| `StakeVault` | Bonds keyed by ERC-8004 `agentId` — the custody ERC-8004 lacks |
| `AgentAccount` | Spending caps enforced **on-chain**, not on a server |
| `AgentAccountFactory` | ERC-1167 clones, deterministic via CREATE2 |
| `MockUSDC` | 6-decimal test token, testnet only |

Identity and reputation are **not** reimplemented — the ERC-8004 registries are
used directly. On Monad mainnet they are already deployed; on testnet they are
absent, so the reference implementation is deployed alongside the protocol.

## Live on Monad testnet

Deployed and verified, chain **10143**. `TaskEscrow` and `StakeVault` have
processed real settlements with reputation written; `AgentAccountFactory` is
deployed but has no instances yet — the demo signer uses an EOA under the
signer's own policy checks.

| Contract | Address |
|---|---|
| `MockUSDC` | [`0x1640c8ea1353c615783c09da4c51fcb457684a64`](https://testnet.monadexplorer.com/address/0x1640c8ea1353c615783c09da4c51fcb457684a64) |
| `MockIdentityRegistry` | [`0x784b42fe1307c70e61df82288f9084614a0ce4c0`](https://testnet.monadexplorer.com/address/0x784b42fe1307c70e61df82288f9084614a0ce4c0) |
| `MockReputationRegistry` | [`0x0ab928f0c62a8a357a5f18caa1c0847c3b1ba697`](https://testnet.monadexplorer.com/address/0x0ab928f0c62a8a357a5f18caa1c0847c3b1ba697) |
| `StakeVault` | [`0x03d5429d352a98d1163a55ab97d733fbf534c322`](https://testnet.monadexplorer.com/address/0x03d5429d352a98d1163a55ab97d733fbf534c322) |
| `TaskEscrow` | [`0x1b0959dfd32323e5a4749d5444c2e6435349027c`](https://testnet.monadexplorer.com/address/0x1b0959dfd32323e5a4749d5444c2e6435349027c) |
| `AgentAccountFactory` | [`0x51F75C30563d260FafF7dAB42ACf9fA57B82315D`](https://testnet.monadexplorer.com/address/0x51F75C30563d260FafF7dAB42ACf9fA57B82315D) |

## Quickstart

```bash
git clone --recurse-submodules git@github.com:gopaltalaviya/agentx-contracts.git
cd agentx-contracts
make build && make test
```

## Configuration

Every fact is declared in exactly one place:

| Domain | Source |
|---|---|
| Chain facts | `config/networks.json` |
| Protocol parameters | `config/params.<chainId>.json` |
| Deployed addresses | `deployments/<chainId>.json` — **generated** |
| Secrets | environment variables only |

No contract address is ever an env var, and no chain is ever hardcoded. The
same parameter files are read by the deploy script, the backend, and the UI, so
on-chain enforcement and off-chain validation cannot disagree.

## Commands

```bash
make build            # compile
make test             # unit + fuzz + invariant
make coverage
make verify-erc8004   # probe the ERC-8004 registries on every network
make deploy-testnet   # Monad testnet (10143)
make deploy-mainnet   # Monad mainnet (143) — requires typing the chain id
```

## Networks

| | Chain ID | ERC-8004 registries |
|---|---|---|
| Monad testnet | 10143 | deployed by us (absent upstream) |
| Monad mainnet | 143 | `0x8004A169…a432` / `0x8004BAa1…9b63` |

Verified on-chain 2026-09-22. The mainnet registries are ERC-1967 proxies;
`make verify-erc8004` fails if the implementation moves.

## Security properties

Stated as properties rather than adjectives, because each one is tested:

- **Every non-terminal state has a deadline and a permissionless exit.** No
  pair of agents can strand funds by going offline, and `pause()` does not
  stop any exit — only new jobs.
- **Spending caps are enforced here, not on a server.** A fully compromised
  signer still cannot exceed `perTaskCap`, `dailyCap`, or pay outside the
  allowlist. Session keys are capped at 24 hours on grant.
- **Transfer-in is measured as a balance delta.** A fee-on-transfer token
  reverts with `TokenDeliveredLess` instead of quietly leaving the escrow
  insolvent.
- **Feedback cannot break settlement.** The ERC-8004 registry is external and
  may revert or be upgraded badly; `giveFeedback` runs in a try/catch and
  emits `FeedbackFailed` rather than trapping a payment.
- **An agent cannot hire itself.** `SelfDealing()` — reputation farming needs
  at least two parties and a real payment.

120 tests: unit, fuzz, invariant and an adversarial suite. 100% branch
coverage on `TaskEscrow` and `StakeVault`, the two that hold money.

`via_ir = true` is required, not stylistic: ERC-8004's eleven-argument
`NewFeedback` event overflows the stack without it.

## What is not solved

Stated here rather than left for a reader to find:

- **Result quality is not cryptographically verified.** Schema conformance and
  hash integrity are; truth is not.
- **Disputes are centralised** to a multisig arbiter, which can act only on
  disputed jobs and cannot touch funds outside one.
- **`slash()` exists and is role-gated, but nothing calls it automatically.**
- **No cross-chain settlement.**

## License

MIT

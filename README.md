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
| `MockUSDC` | 6-decimal test token, testnet only |

Identity and reputation are **not** reimplemented — the ERC-8004 registries are
used directly. On Monad mainnet they are already deployed; on testnet they are
absent, so the reference implementation is deployed alongside the protocol.

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

## License

MIT

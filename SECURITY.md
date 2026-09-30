# Security

## Status: unaudited, testnet only

These contracts have **not** had an external audit. They are deployed on Monad
testnet (chain 10143) with test tokens and must not hold real funds until one
has been done. Mainnet deployment requires typing the chain id
(`make deploy-mainnet`) and refuses to deploy the mock token or the reference
ERC-8004 registries.

What has been done instead, and what it does and does not establish:

| | |
|---|---|
| Internal audit, 2026-09-30 | 3 High, 8 Medium, 12 Low. All fixed in v2; each fix has a test written against v1 first and seen to fail there (`test/unit/V2Findings.t.sol`). |
| Unit, fuzz, adversarial tests | 10,000 fuzz runs per property in CI |
| Invariants | escrow solvency (`balance == lockedTotal + owedTotal`), every dispute has an exit, the vault holds exactly its recorded bonds, a stolen session key never exceeds its caps — 512 runs × 64 calls in CI |
| Branch coverage | 100% StakeVault, AgentAccount, AgentAccountFactory; TaskEscrow 96.5% (the two uncovered branches are inside inline assembly, which forge cannot instrument, and are driven by unit tests) — enforced in CI |
| Static analysis | Slither (fails on medium) and solhint in CI; the remaining low/informational results are triaged inline with their reasons |

None of this is a substitute for an audit. It establishes that the stated
properties hold under the scenarios we thought of; an audit is for the ones we
did not.

## Threat model

The full model is `agentx-backend/docs/04-how-it-works.md` §9. The on-chain
parts, as properties:

- **Every non-terminal job state has a deadline and a permissionless exit** —
  including `DISPUTED` (`expireDispute`, since v2). No party, and not the
  arbiter, can strand funds by going offline. `pause()` stops new jobs only.
- **A payment that cannot be delivered is held, not lost.** A cleared wallet, a
  token-blacklisted address or a reverting identity registry credits `owed`;
  the agent's owner claims it with `claimOwed`.
- **Reputation costs a real fee.** Hires between two agents with the same owner
  revert (`SameOwner`); nothing below `minJobAmount` is accepted; every job pays
  at least `minFee`. This is a cost floor, not sybil-proofing: two owners with
  two bonds can still pay each other, at a fee per review.
- **A compromised session key is bounded by the account, on chain:** per-task
  and daily caps, a per-(target, selector) allowlist, no allowance-granting
  selector ever, a lifetime of at most 24 hours, and the owner's `revoke` and
  `sweep`. The daily window is fixed, not rolling: up to 2× the cap can be
  spent across a window boundary.
- **Admin changes are slow.** The default admin role transfers in two steps
  behind a delay (`AccessControlDefaultAdminRules`); an account's owner
  transfers in two steps.

Known limits, stated rather than left to be found: disputes are decided by one
arbiter key (the deployer's, on testnet); `slash` exists but nothing calls it
automatically; scoring is a damped mean, not a trimmed mean.

## Reporting a vulnerability

Please do not open a public issue. Use GitHub's private vulnerability reporting
on this repository ("Security" tab → "Report a vulnerability"), with the
contract, the function, and a reproduction if you have one. Testnet deployments
hold no real value, so there is no bounty; credit is given in the fix commit.

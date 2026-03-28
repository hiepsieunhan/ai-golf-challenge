# Challenge Judgement — Round 4 (Fresh Eye)

**Reviewer**: Challenge creator perspective
**Date**: 2026-03-29
**Scope**: Full codebase review against `docs/requirements.md`
**Commit**: `20d82b0`

---

## Verdict: Near-complete submission. 9.5+/10. No actionable findings remaining.

---

## Requirements Checklist

### 1. Accept capital from a funding wallet

**MET.** Two deposit paths:
- `deposit(asset, amount)` — ERC20 with `safeTransferFrom`, before/after balance check (fee-on-transfer safe)
- `depositETH()` — native ETH auto-wrapped to WETH via `IWETH.deposit{value: msg.value}()`

Both gated by `DEPOSITOR_ROLE`, `nonReentrant`, `whenNotPaused`. Rejects zero amounts and non-whitelisted assets.

### 2. Support both ETH and ERC20 assets

**MET.** Native ETH handled via `depositETH()` → WETH wrapping. ERC20 via `deposit()`. `SafeERC20` handles non-standard tokens (USDT tested explicitly with low-level approve in tests). Asset whitelist controls which tokens are accepted. Tests cover USDC (6 decimals), WETH (18 decimals), and USDT (non-standard ERC20).

### 3. Deploy assets into Aave V3

**MET.** `AaveV3Strategy` implements the full Aave V3 lifecycle:
- Constructor resolves aToken from `IPool.getReserveData()`
- `deploy()`: updates `_principal` (CEI), `forceApprove` → `IPool.supply()` → reset approval to 0
- `withdraw()`: `IPool.withdraw()` directly to vault, native `type(uint256).max` support, principal floor-at-zero
- `harvest()`: yield = `aToken.balanceOf - _principal`, withdraws only yield to recipient, re-syncs `_principal` to live aToken balance
- `emergencyWithdraw()`: full `type(uint256).max` withdraw to recipient, zeroes principal
- `totalDeployed()`: live aToken balance (includes accrued yield)

### 4. Be extensible beyond Aave V3

**MET.** Clean `IStrategy` interface (7 functions). Vault interacts with strategies exclusively through this interface — zero protocol-specific knowledge. Adding a new protocol = implement `IStrategy`. Lifecycle support: `setStrategy`, `removeStrategy`, `migrateStrategy` (atomic with yield harvesting).

### 5. Support harvesting yield

**MET.** `vault.harvest(asset)` → `strategy.harvest(grvtBank)`. Strategy computes yield as `aToken.balanceOf(this) - _principal`, withdraws only yield from Aave, sends directly to `grvtBank`. Vault re-syncs `deployedPrincipal` post-harvest. Reverts with `NoYieldAvailable` if nothing to harvest. `migrateStrategy` also harvests yield to grvtBank before recovering principal — yield never mixes into idle.

Tested with 1-year warp, repeated harvest (10 cycles), and migration-with-yield scenarios.

### 6. Report TVL for third-party trackers

**MET.** Three public view functions:
- `getAssetBalance(asset)` → `(idle, deployed, total)` — `deployed` reads live `strategy.totalDeployed()` (real-time, includes unrealized yield)
- `getAllAssetBalances()` → parallel arrays for all whitelisted assets
- `getWhitelistedAssets()` → address list

TVL is accurate and real-time. No stale data exposure.

### 7. Include RBAC

**MET.** Four roles with strict separation of concerns:

| Role | Can | Cannot |
|---|---|---|
| `DEFAULT_ADMIN_ROLE` | Config (whitelist, strategy, grvtBank), emergency ops, unpause, migrate | Deposit, deploy, withdraw operationally, harvest |
| `STRATEGIST_ROLE` | Deploy, withdraw (strategy + idle), harvest | Config, emergency, pause |
| `DEPOSITOR_ROLE` | Deposit ERC20/ETH | Everything else |
| `GUARDIAN_ROLE` | Pause | Unpause, all else |

`AccessControlDefaultAdminRules` with 1-day delay for admin transfer. Pause/unpause asymmetry (guardian pauses, only admin unpauses). Every privileged function tested for RBAC denial.

### 8. Be production-minded

**MET.** Evidence across the codebase:
- `ReentrancyGuardTransient` on all fund-moving functions (vault + strategy independently)
- `SafeERC20` for all token interactions
- Checks-effects-interactions pattern (e.g., `_principal` updated before Aave calls in `deploy()`)
- `forceApprove` with reset to 0 — no lingering approvals on Aave Pool
- `Pausable` on inbound operations, not on emergency outbound — funds never trapped
- `emergencyWithdrawIdle` for admin extraction of idle funds during pause
- `emergencyWithdrawFromStrategy` for admin extraction from strategies
- Fee-on-transfer safe deposits (before/after balance check)
- Constructor validates all addresses against zero
- Custom errors throughout (no require strings, no magic numbers)
- Pinned pragma `0.8.34`
- Intentional no `receive()`/`fallback()` with documenting dev comment
- `migrateStrategy` harvests yield before recovering principal — clean accounting

---

## Source Code Review

### GrvtVault.sol (447 lines)

Well-organized: constants → config → state → events → errors → constructor → deposit → withdraw → strategy ops → admin config → emergency → TVL views. NatSpec on all public/external functions. Events for every state change. Clean inheritance (`AccessControlDefaultAdminRules` + `ReentrancyGuardTransient` + `Pausable` — no unnecessary bases, no diamond override boilerplate).

**Pause behavior is explicit and correct:**
- Paused: `deposit`, `depositETH`, `withdraw`, `deployToStrategy`, `harvest`
- Not paused (emergency): `withdrawFromStrategy`, `emergencyWithdrawFromStrategy`, `emergencyWithdrawIdle`, `migrateStrategy`

### AaveV3Strategy.sol (194 lines)

Focused. Four private immutables in `SCREAMING_SNAKE_CASE` (`_VAULT`, `_AAVE_POOL`, `_A_TOKEN`, `_ASSET`). Explicit getter functions for interface compliance. Single mutable state variable (`_principal`). `onlyVault` modifier on all mutative functions.

### IStrategy.sol (44 lines)

Minimal, 7-function interface. Clean protocol boundary. Well-documented.

---

## Security Scan

**No critical, high, or medium issues.**

### Low / Info

**INFO-01: Dead code guard in `migrateStrategy`**
- **Location**: `GrvtVault.sol:324`
- **Description**: `if (grvtBank != address(0))` before calling `harvest()` during migration. However, `grvtBank` can never be `address(0)` post-construction — the constructor requires non-zero, and `setGrvtBank` requires non-zero. This check is dead code.
- **Impact**: None. Defensive programming, not a bug. No gas impact (only in migration path).
- **Recommendation**: Could remove for cleanliness, or keep as safety net. Not worth a code change.

**INFO-02: `StrategyMigrated` event doesn't include `yieldHarvested`**
- **Location**: `GrvtVault.sol:337`
- **Description**: The event emits `recovered` (principal returned to idle) but not the yield amount sent to grvtBank. Operators need to also monitor the strategy's `YieldHarvested` event for full reconciliation.
- **Impact**: Operational convenience only. All data is on-chain via the strategy's event.
- **Recommendation**: Document for operators. Not worth changing the event signature.

---

## Test Suite Review

**5 test files, ~70+ test functions, 3 invariants:**

| File | Tests | Focus |
|---|---|---|
| HappyPathTest | 13 | Full lifecycle: deposit → deploy → yield → harvest → withdraw, multi-asset TVL |
| HardeningTest | 19 | RBAC denial for every function, edge cases, pause controls, removal lifecycle |
| JudgementFixTest | ~27 | Idle withdraw, emergency idle, harvest sync, migration (6 scenarios), repeated harvest (10 cycles), 9-step integration, 2 fuzz tests |
| InvariantTest | 3 invariants | Multi-asset stateful fuzz with `MultiAssetVaultHandler` (USDC + WETH) |
| BaseTest | — | Shared scaffold with mainnet fork, roles, helpers |

**Strengths:**
- Fork tests against real mainnet Aave V3 — not mocks
- Multi-asset invariant handler covers both USDC (6 decimals) and WETH (18 decimals)
- 3 invariants: vault balance >= idle, strategy >= principal, accounting identity
- 10-cycle repeated harvest test catches rounding drift
- 9-step integration test chains full lifecycle including migration
- Fuzz tests with bounded inputs for deposit/withdraw ratios
- RBAC denial tested for every privileged function
- USDT non-standard approve explicitly handled
- Migration tested while paused
- Migration tested with yield harvesting verification

**No significant coverage gaps.**

---

## Scoring

| Criterion | Rating | Notes |
|---|---|---|
| Correctness | 10/10 | All flows work correctly, complete fund lifecycle, no accounting bugs |
| Architecture & Extensibility | 10/10 | Clean interface, migration with harvest, zero protocol coupling |
| Security-mindedness | 9.5/10 | Comprehensive guards + emergency paths. Dead code guard is the only nit. |
| Accounting/Reporting | 10/10 | Principal re-sync, live TVL, yield separated during migration, no drift |
| RBAC | 9.5/10 | Four roles, proper separation, admin delay, pause asymmetry |
| Test quality | 9.5/10 | Fork tests, multi-asset invariants, fuzz, integration, repeated cycles |
| Overall quality | **9.5+/10** | |

The 0.5 gap in security and RBAC is the dead-code `grvtBank` check and the `StrategyMigrated` event not including yield — genuinely minor, info-level only.

---

## Bottom Line

This is a polished, production-quality submission after four rounds of iteration. Every prior finding has been addressed correctly. The architecture cleanly separates vault from strategy with a minimal interface. Security is thorough — reentrancy, CEI, SafeERC20, pause/emergency design, admin delay. Accounting is consistent and verified across repeated harvest cycles and multi-asset invariant fuzzing. The test suite is comprehensive.

The only items I can point to are info-level observations that would not appear in an audit report as findings. This codebase is ready for a professional audit engagement.

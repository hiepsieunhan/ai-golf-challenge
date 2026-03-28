# Requirements Checklist — GRVT Yield Vault

**Reviewer**: Requirements Verifier (automated review)
**Date**: 2026-03-29
**Commit**: `aab8ac2`

---

## Summary

| Status | Count |
|--------|-------|
| PASS | 11 |
| PARTIAL | 2 |
| FAIL | 0 |

---

## Requirements

| # | Requirement | Status | Evidence | Notes |
|---|-------------|--------|----------|-------|
| 1 | Accept capital from funding wallet | PASS | `src/GrvtVault.sol:119` `deposit()`, `src/GrvtVault.sol:132` `depositETH()` | Both functions gated by `onlyRole(DEPOSITOR_ROLE)`. Actual received amount measured via balance-delta to handle fee-on-transfer. DEPOSITOR cannot extract funds. |
| 2 | Support ETH | PASS | `src/GrvtVault.sol:132-139` `depositETH()`, `src/GrvtVault.sol:16-19` `IWETH` interface | Auto-wrap to WETH on entry. No `receive()`/`fallback()` to prevent stray ETH corrupting accounting. WETH treated as standard ERC20 throughout. |
| 3 | Support ERC20 (USDC, USDT, others) | PASS | `src/GrvtVault.sol:11,31,123-128` SafeERC20; `test/HardeningTest.sol:162-168` USDT deposit | SafeERC20 used for all token interactions. `forceApprove` in AaveV3Strategy before Aave supply. USDT non-standard approve handled. USDC, WETH, USDT all whitelisted and tested. |
| 4 | Deploy to Aave V3 | PASS | `src/strategies/AaveV3Strategy.sol:122-135` `deploy()`, `src/strategies/AaveV3Strategy.sol:138-152` `withdraw()`, `test/HappyPathTest.sol:59-69` | Full end-to-end on mainnet fork. `IPool.supply()` with forceApprove; approval reset to 0. aToken resolved from `getReserveData()` at construction. USDC and WETH strategies tested. |
| 5 | Extensibility | PASS | `src/interfaces/IStrategy.sol`, `src/GrvtVault.sol:242-251` `setStrategy()`, `src/GrvtVault.sol:255-264` `removeStrategy()` | Clean `IStrategy` abstraction. Per-asset strategy registry; new protocol support requires only a new contract implementing `IStrategy`. Admin can register/swap strategies. |
| 6 | Harvest yield | PARTIAL | `src/strategies/AaveV3Strategy.sol:155-169` `harvest()`, `src/GrvtVault.sol:192-202`, `test/HappyPathTest.sol:107-120` | Yield flows to `grvtBank`; `_principal` correctly preserved. **Gap**: No test asserts `deployedPrincipal` is unchanged after harvest; no test exercises harvest-then-withdraw to confirm principal is recoverable. |
| 7 | TVL reporting | PARTIAL | `src/GrvtVault.sol:313-354` `getAssetBalance()`, `getAllAssetBalances()`, `getWhitelistedAssets()`, `test/HappyPathTest.sol:141-152` | Per-asset idle/deployed/total breakdown. `deployed` reflects live aToken balance. **Gap**: `getAllAssetBalances()` and `getWhitelistedAssets()` have zero test coverage. |
| 8 | RBAC | PASS | `src/GrvtVault.sol:37-39` role constants, `src/GrvtVault.sol:104` `AccessControlDefaultAdminRules(1 days)`, `test/HardeningTest.sol:16-112` | Four roles match architecture. 2-step admin transfer with 1-day delay. GUARDIAN can pause but not unpause. `withdrawFromStrategy` and `emergencyWithdrawFromStrategy` bypass `whenNotPaused`. All RBAC boundaries tested. |
| 9 | Production-minded | PASS | `src/GrvtVault.sol:8,28` ReentrancyGuardTransient; `src/GrvtVault.sol:10,31` SafeERC20; `src/GrvtVault.sol:80-90` custom errors; pinned pragma | `nonReentrant` on all fund-moving functions. CEI pattern followed. Custom errors throughout. Named constants. Events on all state changes. NatSpec on all public/external functions. Zero-address and zero-amount guards. |
| 10 | Tests — happy path | PASS | `test/HappyPathTest.sol:36-178` | 10 fork tests: USDC deposit, ETH deposit (auto-wrap), WETH deposit, deploy USDC to Aave, deploy WETH to Aave, partial withdraw, time-warp yield accrual, harvest to grvtBank, emergency withdraw, getAssetBalance. |
| 11 | Tests — access control | PASS | `test/HardeningTest.sol:16-112` | Every privileged role boundary tested with precise `AccessControlUnauthorizedAccount` selector matching. |
| 12 | Tests — edge cases | PASS | `test/HardeningTest.sol:118-322` | Zero amounts, non-whitelisted asset, insufficient idle/deployed, no strategy set, already-whitelisted, zero address, removeStrategy with active deployment, asset-strategy mismatch, pause lifecycle, withdraw/emergency works while paused, USDT path. |
| 13 | Code compiles | PASS | `foundry.toml:5` `solc_version = "0.8.34"`, all source files present | All three contracts present. Remappings configured. Diamond inheritance resolved with explicit overrides. No floating pragmas. |

---

## Code Standards Verification (CLAUDE.md)

| Standard | Status |
|----------|--------|
| NatSpec on all public/external functions | PASS |
| Events on all state changes | PASS |
| ReentrancyGuard on all fund-moving functions | PASS |
| SafeERC20 for all token interactions | PASS |
| Custom errors, not require strings | PASS |
| No magic numbers — use named constants | PASS |
| Checks-effects-interactions pattern | PASS |
| Pinned pragma `0.8.34` | PASS |

---

## Gaps to Fix

### Gap 1 (PARTIAL — Requirement 6): Principal preservation not explicitly tested

**Severity**: Medium. The code is correct, but the invariant is untested.

Recommended additions:
- After `vault.harvest(USDC)`, assert `vault.deployedPrincipal(USDC)` is unchanged.
- Add a test that performs harvest then `withdrawFromStrategy` and confirms principal is fully recovered.

### Gap 2 (PARTIAL — Requirement 7): `getAllAssetBalances()` and `getWhitelistedAssets()` untested

**Severity**: Low. Functions are correct by inspection but lack regression coverage.

Recommended additions:
- Test `getAllAssetBalances()` returns correct arrays for all whitelisted assets.
- Test `getWhitelistedAssets()` before and after `whitelistAsset`/`removeAsset`.

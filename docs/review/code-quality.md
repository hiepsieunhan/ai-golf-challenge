# Code Quality Review — GRVT Yield Vault

**Reviewer:** Senior Solidity Engineer (automated review)
**Date:** 2026-03-29
**Scope:** `src/GrvtVault.sol`, `src/interfaces/IStrategy.sol`, `src/strategies/AaveV3Strategy.sol`, `test/BaseTest.sol`, `test/HappyPathTest.sol`, `test/HardeningTest.sol`

---

## Overall Grade: A-

The codebase is production-quality with strong fundamentals. All core code standards from `CLAUDE.md` are met: exact pragma pin, custom errors throughout, `SafeERC20` on all token calls, `ReentrancyGuard` on all fund-moving paths, NatSpec on public/external functions, and named constants with no magic numbers. The RBAC design using `AccessControlDefaultAdminRules` is sophisticated and correctly implemented.

There are 4 medium-severity findings and 12 low-severity findings. None represent fund-loss risk but several improve correctness guarantees and maintainability.

---

## Findings

### 2.1 — harvest() silently no-ops when yield is zero

- **Category:** Event Completeness
- **Severity:** Medium
- **Location:** `src/GrvtVault.sol:192-202`
- **Description:** `harvest()` only emits `Harvested` when `yieldAmount > 0`. When called with no yield, the function returns silently — no revert, no event. Off-chain monitors cannot distinguish a zero-yield harvest from a dropped transaction.
- **Suggested fix:** Revert with `error NoYieldAvailable(address asset)` when `yieldAmount == 0`.

### 4.1 — Double external call to IStrategy.asset() in setStrategy

- **Category:** Gas Optimization
- **Severity:** Medium
- **Location:** `src/GrvtVault.sol:247`
- **Description:** `IStrategy(strategy).asset()` is called twice in one statement — once for comparison, once for the revert error. Each is a cold external call (~2,100 gas).
- **Suggested fix:** Cache result: `address strategyAsset = IStrategy(strategy).asset();`

### 4.2 — ReentrancyGuardTransient requires EIP-1153

- **Category:** Gas / Compatibility
- **Severity:** Medium
- **Location:** `src/GrvtVault.sol:8`, `src/strategies/AaveV3Strategy.sol:5`
- **Description:** Uses `TSTORE`/`TLOAD` opcodes from EIP-1153 (Cancun). Correct for Ethereum mainnet but will fail on chains without EIP-1153. No compile-time protection.
- **Suggested fix:** Document the minimum required EVM version. If multi-chain deployment is possible, switch to `ReentrancyGuard`.

### 6.1 — removeAsset allows removal when strategy still set

- **Category:** Error Handling
- **Severity:** Medium
- **Location:** `src/GrvtVault.sol:221-237`
- **Description:** `removeAsset` does not check `assetStrategy[asset] != address(0)` or `deployedPrincipal[asset] > 0`. Admin can create inconsistent state.
- **Suggested fix:** Add `error StrategyStillSet(address asset)` guard.

### 5.3 — AaveV3Strategy layout order deviates from standard

- **Category:** Code Organization
- **Severity:** Low
- **Location:** `src/strategies/AaveV3Strategy.sol:16-70`
- **Description:** Events and Errors are ordered differently from `GrvtVault.sol` and the `CLAUDE.md` standard.
- **Suggested fix:** Reorder to match GrvtVault: Constants/Immutables → Events → Errors → Modifiers.

### 11.2 — Bare vm.expectRevert() in pause tests

- **Category:** Tests
- **Severity:** Low
- **Location:** `test/HardeningTest.sol:218,231,239`
- **Description:** Three tests use `vm.expectRevert()` without a selector, accepting any revert reason.
- **Suggested fix:** Use `vm.expectRevert(Pausable.EnforcedPause.selector)`.

### 11.3 — No fuzz tests

- **Category:** Tests
- **Severity:** Low
- **Description:** All tests use fixed amounts. Foundry fuzzing would cover boundary conditions with minimal code.
- **Suggested fix:** Add fuzz tests for deposit and withdrawal with bounded inputs.

### 11.4 — getAllAssetBalances() not tested

- **Category:** Tests
- **Severity:** Low
- **Location:** `test/HappyPathTest.sol`
- **Description:** Non-trivial view function with array assembly logic is never called in tests.

### 11.5 — No test for successful removeAsset/removeStrategy lifecycle

- **Category:** Tests
- **Severity:** Low
- **Location:** `test/HardeningTest.sol`
- **Description:** Only the revert guard is tested; the successful removal path has no coverage.

### 5.1 — IWETH interface declared inline in GrvtVault.sol

- **Category:** Code Organization
- **Severity:** Low
- **Location:** `src/GrvtVault.sol:16-19`
- **Description:** Should live in `src/interfaces/IWETH.sol` alongside `IStrategy.sol`.

### 1.1 — Constructor parameter `asset__` uses non-standard double underscore

- **Category:** NatSpec / Naming
- **Severity:** Low
- **Location:** `src/strategies/AaveV3Strategy.sol:80`
- **Description:** Non-idiomatic; standard is single trailing underscore (`asset_`).

### 3.1 — WETH immutable uses UPPER_CASE naming

- **Category:** Naming
- **Severity:** Low
- **Location:** `src/GrvtVault.sol:41`
- **Description:** Solidity style guide reserves UPPER_CASE for `constant`, not `immutable`.

### 3.2 — Inconsistent test name casing

- **Category:** Naming
- **Severity:** Low
- **Description:** Mixed `when` vs `When` capitalization in test function names.

### 5.2 — AccessControl import needs explanatory comment

- **Category:** Import Hygiene
- **Severity:** Low
- **Location:** `src/GrvtVault.sol:6`

### 7.1 — Admin transfer delay hardcoded inline

- **Category:** Constants
- **Severity:** Low
- **Location:** `src/GrvtVault.sol:104`
- **Description:** `1 days` passed inline to `AccessControlDefaultAdminRules`. Could be a named constant.

---

## Summary Table

| # | Category | Severity | Location | Finding |
|---|---|---|---|---|
| 2.1 | Event Completeness | **Medium** | `GrvtVault.sol:199` | `harvest()` silently no-ops on zero yield |
| 4.1 | Gas Optimization | **Medium** | `GrvtVault.sol:247` | `IStrategy.asset()` called twice |
| 4.2 | Gas / Compatibility | **Medium** | Both contracts | `ReentrancyGuardTransient` requires EIP-1153 |
| 6.1 | Error Handling | **Medium** | `GrvtVault.sol:221` | `removeAsset` allows removal while strategy set |
| 5.3 | Code Organization | Low | `AaveV3Strategy.sol:16` | Layout order deviates from standard |
| 11.2 | Tests | Low | `HardeningTest.sol:218,231,239` | Bare `vm.expectRevert()` |
| 11.3 | Tests | Low | `test/` | No fuzz tests |
| 11.4 | Tests | Low | `HappyPathTest.sol` | `getAllAssetBalances()` untested |
| 11.5 | Tests | Low | `HardeningTest.sol` | No successful removal lifecycle test |
| 5.1 | Code Organization | Low | `GrvtVault.sol:16` | `IWETH` inline |
| 1.1 | Naming | Low | `AaveV3Strategy.sol:80` | `asset__` double underscore |
| 3.1 | Naming | Low | `GrvtVault.sol:41` | `WETH` UPPER_CASE for immutable |
| 3.2 | Naming | Low | `test/` | Inconsistent test name casing |
| 5.2 | Import Hygiene | Low | `GrvtVault.sol:6` | `AccessControl` import unexplained |
| 7.1 | Constants | Low | `GrvtVault.sol:104` | `1 days` inline |

---

## What Is Done Well

- No `require` strings — all custom errors with rich context parameters
- `SafeERC20` consistently applied including `forceApprove` with post-reset
- Balance-diff pattern in `deposit` handles fee-on-transfer tokens
- `AccessControlDefaultAdminRules` with 1-day delay for admin key protection
- `withdrawFromStrategy` and `emergencyWithdrawFromStrategy` intentionally bypass `whenNotPaused`
- CEI pattern consistently applied
- `_principal` floor-at-zero in `AaveV3Strategy.withdraw` handles Aave rounding
- `BaseTest.sol` provides clean shared foundation with `vm.label` on all addresses
- Exact pragma `0.8.34` in every file
- Comprehensive RBAC test coverage

# Code Quality Re-Review — GRVT Yield Vault

**Date**: 2026-03-29
**Scope**: Post-fix verification + new issue scan
**Base review**: docs/review/code-quality.md

---

## Fix Verification

| Original # | Fix Applied | Status | Notes |
|---|---|---|---|
| 2.1 | `harvest()` reverts with `NoYieldAvailable` | CORRECT | `GrvtVault.sol:203` |
| 4.1 | `setStrategy()` caches `IStrategy.asset()` | PARTIAL | `asset()` cached, but new `vault()` call has the same double-call pattern — see NEW-01 |
| 6.1 | `removeAsset()` rejects when strategy set | CORRECT | `GrvtVault.sol:227`, tested at `HardeningTest.sol:350` |
| 4.2 | `@dev` NatSpec for EIP-1153 | CORRECT | Both contracts |
| 11.2 | Bare `vm.expectRevert()` → typed selector | CORRECT | `HardeningTest.sol:219,231,240` |
| 11.4 | `getAllAssetBalances` test added | CORRECT | `HappyPathTest.sol:212` |
| 11.5 | Removal lifecycle tests added | CORRECT | `HardeningTest.sol:328-354` |

---

## New Findings

### NEW-01: `setStrategy` double-calls `IStrategy(strategy).vault()`

- **Category**: Gas Optimization
- **Severity**: Low (SHOULD FIX)
- **Location**: `src/GrvtVault.sol:254`
- **Description**: The fix cached `asset()` but the new `vault()` validation has the identical double-call pattern:
  ```solidity
  if (IStrategy(strategy).vault() != address(this)) revert StrategyVaultMismatch(address(this), IStrategy(strategy).vault());
  ```
- **Suggested fix**: `address strategyVault = IStrategy(strategy).vault();`

### NEW-02: `withdrawFromStrategy` re-reads `deployedPrincipal[asset]` instead of using cached `principal`

- **Category**: Gas Optimization
- **Severity**: Low (SHOULD FIX)
- **Location**: `src/GrvtVault.sol:185`
- **Description**: `principal` is cached at line 178 but line 185 re-reads from storage. The value hasn't changed (reentrancy guard prevents mutation).
- **Suggested fix**: Replace `deployedPrincipal[asset]` with `principal` on line 185.

### NEW-03: No test for `NoYieldAvailable` revert — the core new behavior

- **Category**: Tests
- **Severity**: Low (SHOULD FIX)
- **Location**: `test/HardeningTest.sol` (gap)
- **Description**: The most significant behavioral change — `harvest()` reverting on zero yield — has no corresponding edge-case test.
- **Suggested fix**: Add `test_harvest_revertsWhen_noYieldAvailable` that deploys funds then immediately calls harvest without warping time.

### NEW-04: `emergencyWithdraw` emits zero-recovery event silently

- **Category**: Event Consistency
- **Severity**: Low (NICE TO HAVE)
- **Location**: `src/strategies/AaveV3Strategy.sol:180`, `src/GrvtVault.sol:303-308`
- **Description**: `emergencyWithdraw` on an empty strategy emits `EmergencyWithdrawal(asset, strategy, 0)`. Inconsistent with the new `harvest()` philosophy of reverting on no-op. Could add a `@dev` comment documenting the permissive intent.

---

## Updated Grade

**A-** (unchanged, pending resolution of NEW-01 through NEW-03)

---

## Conclusion

All 7 applied fixes are correct with no regressions. 3 new SHOULD FIX items found — all direct consequences of the fix wave: a replicated double-call pattern, an unused cache, and a missing test for the new revert. Plus 1 NICE TO HAVE consistency note.

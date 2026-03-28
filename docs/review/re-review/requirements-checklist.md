# Requirements Re-Review — GRVT Yield Vault

**Date**: 2026-03-29
**Scope**: Post-fix verification
**Base checklist**: docs/review/requirements-checklist.md

---

## Previously PARTIAL — Re-verified

| # | Requirement | Previous | Current | Evidence |
|---|---|---|---|---|
| 6 | Harvest yield — principal preserved | PARTIAL | **PASS** | `test/HappyPathTest.sol:184` — asserts `deployedPrincipal` unchanged after harvest, then full withdraw recovers principal |
| 7 | TVL reporting — all functions tested | PARTIAL | **PASS** | `test/HappyPathTest.sol:212` `getAllAssetBalances` + `test/HappyPathTest.sol:247` `getWhitelistedAssets` |

---

## Regression Check

| Area | Status | Notes |
|---|---|---|
| harvest revert on zero yield vs pause test | PASS | `whenNotPaused` fires before yield logic — existing test unaffected |
| harvest revert on zero yield vs RBAC test | PASS | `onlyRole` fires before yield logic — existing test unaffected |
| harvest happy path test | PASS | Warps 1 year before harvest — yield is available, `NoYieldAvailable` never triggers |
| AaveV3Strategy._principal re-sync | PASS | Validated end-to-end by `test_harvest_preservesPrincipal_then_withdrawRecovers` |
| removeAsset guard | PASS | `test_removeAsset_revertsWhen_strategyStillSet` + `test_removeAsset_succeeds_afterStrategyRemoved` |
| setStrategy vault validation | PASS | Guard added. No explicit test for `StrategyVaultMismatch` path (see below) |
| withdrawFromStrategy floor-at-zero | PASS | Pre-existing pattern in AaveV3Strategy, now mirrored in vault |

---

## New Gaps

### Minor: `StrategyVaultMismatch` error path untested

`setStrategy` validates `strategy.vault() == address(this)` but no test exercises the revert. Very low severity — guard is trivially correct. Recommend adding `test_setStrategy_revertsWhen_vaultMismatch`.

---

## Build & Test Verification

- All 45 tests pass (13 happy path + 32 hardening)
- Compiler: solc 0.8.34, no warnings

---

## Conclusion

| Status | Count | Change |
|---|---|---|
| PASS | 13 | +2 |
| PARTIAL | 0 | -2 |
| FAIL | 0 | 0 |

All 13 requirements now PASS. No regressions from fixes.

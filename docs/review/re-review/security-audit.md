# Security Re-Review — GRVT Yield Vault

**Date**: 2026-03-29
**Scope**: Post-fix verification + new issue scan
**Base audit**: docs/review/security-audit.md

---

## Fix Verification

| Original ID | Fix Status | Notes |
|---|---|---|
| H-01: Harvest ignores Aave withdraw return value | **FIXED** | `AaveV3Strategy.harvest()` now captures `actualYield` from `IPool.withdraw()`, emits it, and returns it. Also re-syncs `_principal`. |
| M-01: setStrategy does not validate strategy vault | **FIXED** | `GrvtVault.setStrategy()` checks `IStrategy(strategy).vault() != address(this)`, reverts with `StrategyVaultMismatch`. |
| M-02: withdrawFromStrategy may underflow deployedPrincipal | **FIXED** | Floor-at-zero guard: `actual >= deployedPrincipal[asset]` zeroes the mapping. |
| M-03: No rescue token mechanism | **WONTFIX** | Deliberately skipped per team decision. |
| L-01: Principal drift from repeated harvests | **FIXED** | `_principal` re-synced to `aToken.balanceOf(address(this))` after each harvest. |
| L-02: removeAsset does not check for existing balances | **PARTIALLY FIXED** | Strategy check added (`StrategyStillSet`). Idle balance check not added — see NEW-01. |

---

## New Findings

### NEW-01: removeAsset still allows removal with non-zero idle balance

- **Severity**: LOW
- **Location**: `GrvtVault.sol:225`
- **Description**: The L-02 fix added `StrategyStillSet` guard, which transitively ensures `deployedPrincipal` is zero. However, `idleBalance[asset]` is not checked. An admin can remove an asset with idle funds, making them invisible to TVL reporting. Funds are recoverable by re-whitelisting.
- **Impact**: TVL under-reporting. No permanent fund loss.
- **Recommendation**: Add `if (idleBalance[asset] > 0) revert IdleBalanceRemaining(asset, idleBalance[asset]);`

### NEW-02: harvest reverts on zero yield — documentation note

- **Severity**: INFO
- **Location**: `GrvtVault.sol:203`
- **Description**: The new `NoYieldAvailable` revert means automated bots must pre-check `pendingYield()` before calling `harvest()`. This is a deliberate design choice, not a bug.
- **Recommendation**: Document for integrators.

## Conclusion

All fixes correctly implemented. No regressions. **0 critical, 0 high, 0 medium, 1 low, 1 info.**

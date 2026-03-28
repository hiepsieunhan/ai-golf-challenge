# Security Audit — GRVT Yield Vault

**Auditor**: Automated Senior Security Review
**Date**: 2026-03-29
**Scope**: All Solidity contracts in `src/`
**Commit**: `aab8ac2` (branch: `master`)

---

## Summary

| Severity | Count |
|----------|-------|
| CRITICAL | 0     |
| HIGH     | 1     |
| MEDIUM   | 3     |
| LOW      | 3     |
| INFO     | 4     |
| **Total** | **11** |

**Overall Assessment**: The codebase is well-structured with strong security fundamentals. RBAC is properly implemented with 4-role separation and 2-step admin transfer. ReentrancyGuard is applied to all fund-moving functions. SafeERC20 is used consistently. The checks-effects-interactions pattern is followed. The primary concerns are around harvest yield accounting (unchecked return value from Aave) and potential principal accounting drift over many harvest cycles.

No critical vulnerabilities were found. The vault is suitable for deployment with the recommended fixes applied.

---

## Findings

### H-01: Harvest ignores Aave `withdraw` return value, may report incorrect yield

- **Severity**: HIGH
- **Location**: `src/strategies/AaveV3Strategy.sol`, `harvest()`, line 164
- **Description**: The `harvest` function computes `yieldAmount = current - _principal` and then calls `IPool(aavePool).withdraw(_asset, yieldAmount, recipient)`. However, the return value of `IPool.withdraw` (the actual amount withdrawn) is discarded. The function returns the pre-computed `yieldAmount` rather than the actual amount sent to the recipient.

  In `AaveV3Strategy.withdraw()` (line 142), the return value IS correctly captured. But in `harvest()`, it is not.

  Aave V3 can withdraw a slightly different amount than requested due to internal rounding on aToken-to-underlying conversion. This means:
  1. The `yieldAmount` returned to `GrvtVault.harvest()` may not match what the recipient actually received.
  2. The `Harvested` event may log an inaccurate amount.
  3. Over time, rounding discrepancies accumulate (see L-01).

- **Impact**: Incorrect yield accounting reported to off-chain systems. In edge cases, attempting to withdraw `yieldAmount` could revert if Aave cannot supply exactly that amount.
- **Recommendation**: Capture the return value of `IPool.withdraw` and return it instead:
  ```solidity
  uint256 actualYield = IPool(aavePool).withdraw(_asset, yieldAmount, recipient);
  emit YieldHarvested(actualYield, recipient);
  return actualYield;
  ```

---

### M-01: `setStrategy` does not validate that the strategy's `vault()` matches `address(this)`

- **Severity**: MEDIUM
- **Location**: `src/GrvtVault.sol`, `setStrategy()`, lines 242-251
- **Description**: The `setStrategy` function validates that `IStrategy(strategy).asset() == asset` but does not check that `IStrategy(strategy).vault() == address(this)`. If an admin mistakenly registers a strategy bound to a different vault, all subsequent calls to `deploy()`, `withdraw()`, `harvest()`, and `emergencyWithdraw()` on that strategy would revert with `CallerNotVault`, blocking all strategy operations for that asset until reconfigured.

- **Impact**: Operational denial of service for the affected asset. No direct fund loss due to atomic transactions, but confusing failure mode.
- **Recommendation**: Add a vault address check in `setStrategy`:
  ```solidity
  if (IStrategy(strategy).vault() != address(this)) revert StrategyVaultMismatch();
  ```

---

### M-02: `withdrawFromStrategy` may underflow `deployedPrincipal` if strategy returns more than tracked

- **Severity**: MEDIUM
- **Location**: `src/GrvtVault.sol`, `withdrawFromStrategy()`, line 183
- **Description**: When `amount != type(uint256).max`, the vault does `deployedPrincipal[asset] -= actual`. The check on line 174 ensures `principal >= amount`, but `actual` (the return from the strategy) could differ from `amount`. While Aave V3's `withdraw` for a specific amount returns exactly that amount in practice, a different `IStrategy` implementation might return a different value. If `actual > principal`, Solidity 0.8 underflow protection causes a revert, blocking withdrawals.

- **Impact**: Potential denial of service on withdrawals with non-Aave strategies.
- **Recommendation**: Add a floor-at-zero guard:
  ```solidity
  if (actual >= deployedPrincipal[asset]) {
      deployedPrincipal[asset] = 0;
  } else {
      deployedPrincipal[asset] -= actual;
  }
  ```

---

### M-03: No mechanism to recover tokens sent directly to the vault outside of `deposit`

- **Severity**: MEDIUM
- **Location**: `src/GrvtVault.sol`, entire contract
- **Description**: If tokens are sent directly to the vault via a raw `transfer` (not through `deposit`), they are not tracked in `idleBalance` and are permanently stuck. The vault has no `sweep` or `rescueTokens` function. This includes airdropped tokens, mistaken transfers, and potential reward tokens from protocols.

- **Impact**: Permanent loss of any tokens sent directly to the vault outside the `deposit` function.
- **Recommendation**: Add an admin-only `rescueToken` function:
  ```solidity
  function rescueToken(address token, address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
      uint256 tracked = idleBalance[token];
      uint256 balance = IERC20(token).balanceOf(address(this));
      uint256 excess = balance - tracked;
      if (amount > excess) revert InsufficientExcess();
      IERC20(token).safeTransfer(to, amount);
  }
  ```

---

### L-01: Principal drift from repeated harvests due to Aave rounding

- **Severity**: LOW
- **Location**: `src/strategies/AaveV3Strategy.sol`, `harvest()`, lines 158-168
- **Description**: Each `harvest()` withdraws `yieldAmount = current - _principal`. Due to Aave's internal rounding, the actual withdrawal may differ by +/- 1 wei. Over N harvests, drift accumulates. After many harvests, a full principal withdrawal might fail.

- **Impact**: Very low practical impact (1 wei per harvest). After thousands of harvest cycles, a full `withdraw(_principal)` might revert.
- **Recommendation**: After each harvest, re-sync `_principal` to the actual remaining aToken balance:
  ```solidity
  uint256 actualYield = IPool(aavePool).withdraw(_asset, yieldAmount, recipient);
  _principal = IERC20(aToken).balanceOf(address(this));
  ```

---

### L-02: `removeAsset` does not check for existing idle balance or deployed principal

- **Severity**: LOW
- **Location**: `src/GrvtVault.sol`, `removeAsset()`, lines 221-237
- **Description**: An admin can remove an asset from the whitelist even if `idleBalance[asset] > 0` or `deployedPrincipal[asset] > 0`. Once removed from `_assetList`, the asset's balances disappear from `getAllAssetBalances()`, making funds invisible to TVL reporting.

- **Impact**: TVL under-reporting. Funds become invisible to monitoring systems.
- **Recommendation**: Check that both `idleBalance[asset]` and `deployedPrincipal[asset]` are zero before allowing removal.

---

### L-03: `getAllAssetBalances` gas cost scales linearly with asset count

- **Severity**: LOW
- **Location**: `src/GrvtVault.sol`, `getAllAssetBalances()`, line 341
- **Description**: For each whitelisted asset with a strategy, the function makes an external call to `IStrategy.totalDeployed()`. If the asset list grows very large, the gas cost could exceed block gas limits when called on-chain.

- **Impact**: Potential DoS for on-chain consumers. No impact for off-chain (eth_call) usage.
- **Recommendation**: Document the gas limitation. The asset whitelist is expected to be small (<20 assets), so this is informational.

---

### I-01: Strategy contracts have no pausability

- **Severity**: INFO
- **Description**: `AaveV3Strategy` has no pause mechanism. All pausing is handled at the vault level. Acceptable for Day 1 single-strategy-per-asset design.

### I-02: No `receive()` or `fallback()` — by design

- **Severity**: INFO
- **Description**: Native ETH sent directly to the vault reverts. This is the CORRECT behavior per the architecture document, preventing accidental ETH deposits from corrupting accounting.

### I-03: No protection against Aave reserve being frozen/deactivated

- **Severity**: INFO
- **Description**: If Aave governance freezes the reserve, `deploy()` will revert. This is a protocol-level risk. The emergency withdrawal path is sufficient mitigation since Aave allows withdrawals from frozen reserves.

### I-04: Dual AccessControl inheritance creates complex override chain

- **Severity**: INFO
- **Description**: The vault inherits from both `AccessControlEnumerable` and `AccessControlDefaultAdminRules`. The overrides are correctly resolved via C3 linearization, but the complexity increases audit burden for future changes.

---

## Audit Checklist

| Category | Result |
|----------|--------|
| Reentrancy | PASS — all fund-moving functions protected with `nonReentrant` |
| Access Control | PASS — 4-role RBAC with 2-step admin transfer |
| Input Validation | PASS — zero addresses/amounts rejected throughout |
| ERC20 Safety | PASS — SafeERC20 + forceApprove + approval reset |
| External Call Safety | PARTIAL — harvest ignores withdraw return value (H-01) |
| Integer Arithmetic | PASS — Solidity 0.8.34 checked math, no unchecked blocks |
| Strategy Trust | ACCEPTABLE — admin-only strategy registration with immutable binding |
| Yield Accounting | PARTIAL — rounding drift concern (L-01) |
| Emergency Controls | PASS — pause/unpause separation, emergency withdraw, exit paths bypass pause |
| Event Coverage | PASS — all state changes emit events |
| Frontrunning/MEV | PASS — no DEX swaps or price-dependent logic |

---

## Positive Observations

1. **Balance-delta pattern in `deposit`**: Correctly handles fee-on-transfer tokens.
2. **`forceApprove` + reset to 0**: Prevents approval race conditions, leaves no dangling approvals.
3. **Separation of `pause`/`unpause` roles**: Guardian can pause but not unpause, limiting damage from compromised monitoring bots.
4. **`withdrawFromStrategy` is not pausable**: Ensures funds can always be pulled from external protocols during emergencies.
5. **`AccessControlDefaultAdminRules` with 1-day delay**: Protects against immediate admin takeover.
6. **`ReentrancyGuardTransient`**: Gas-efficient reentrancy protection via EIP-1153.
7. **Immutable strategy binding**: `vault`, `aavePool`, `aToken`, `_asset` are all immutable, preventing post-deployment tampering.

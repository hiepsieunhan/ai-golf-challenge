# Vault Architecture Research

**Date:** 2026-03-28
**Scope:** Architecture patterns for the GRVT treasury yield vault — a treasury-managed, non-user-facing multi-asset vault that deploys into yield strategies (Day 1: Aave V3).

---

## 1. Vault Design Patterns — ERC-4626 vs Non-Tokenized Treasury Pattern

### What ERC-4626 Is

ERC-4626 (the Tokenized Vault Standard, finalized in 2022) defines a standard interface for yield-bearing vaults that issue ERC-20 share tokens to depositors. The vault holds a single underlying asset, and the share/asset exchange rate increases as yield accrues. The full interface includes: `deposit`, `mint`, `withdraw`, `redeem`, `totalAssets`, `convertToShares`, `convertToAssets`, and `previewX` simulation functions.

### Does It Apply to a Treasury Vault?

The GRVT vault has fundamentally different requirements:

| Dimension | ERC-4626 | GRVT Treasury Vault |
|---|---|---|
| Depositors | Public / external users | Single authorized funding wallet |
| Share tokens | Required (the standard IS a share token) | Not needed — no external ownership claims |
| Asset count | Single underlying asset per vault | Multiple assets (ETH, USDC, USDT, ...) |
| Withdrawal requests | Anyone who holds shares | Only authorized operators |
| TVL reporting | `totalAssets()` → single asset | Per-asset idle + deployed breakdown |

ERC-4626 is architecturally mismatched:

- It is single-asset; a multi-asset treasury vault would need one ERC-4626 contract per token, fragmenting the system.
- The share token machinery (mint, burn, `convertToShares`, inflation-attack mitigations via virtual shares) adds significant complexity that produces zero value when there is only one depositor with full control.
- The standard includes `previewDeposit`, `previewWithdraw`, `maxDeposit`, `maxRedeem`, etc. — all designed for public users interacting in adversarial conditions. These are dead weight here.

### Recommendation

**Do not implement ERC-4626.** Use a non-tokenized treasury pattern instead:

- A single vault contract holds all supported assets.
- Capital enters via authorized `deposit` calls (no share minting).
- The vault tracks balances internally with explicit accounting (`idleBalance[asset]`, `deployedBalance[asset]`).
- All state-changing functions are role-gated using OpenZeppelin `AccessControl`.
- TVL is reported as structured data per asset, not as a single `totalAssets()` number.

---

## 2. Multi-Asset Handling — Single Vault vs Vault-Per-Asset

### Trade-off Analysis

| Dimension | Vault-per-asset | Single multi-asset vault |
|---|---|---|
| Upgrade / add asset | Deploy new contract | Call `whitelistAsset()` |
| RBAC surface | Per-contract, must coordinate | Unified, easier to reason about |
| Accounting isolation | Natural — separate storage | Must be careful with per-asset mappings |
| TVL view | Aggregate off-chain across contracts | Single contract call returns all assets |
| Code reuse | Must deploy same code N times | One deployment |
| Complexity | Low per-contract, high operationally | Moderate per-contract |

For a treasury vault where GRVT controls all capital and the requirement is to "report TVL for third-party trackers" across assets, the single-vault model is strongly preferable.

### Recommended Data Structures

```solidity
/// @notice Per-asset configuration and accounting state
struct AssetConfig {
    bool whitelisted;           // is this asset accepted
    address strategy;           // active strategy address (address(0) = none)
    uint256 depositCap;         // max total the vault will hold, 0 = unlimited
    uint256 idleBalance;        // tokens sitting in the vault contract
    uint256 deployedBalance;    // tokens deployed into the active strategy
}

/// @notice Primary state mapping: asset address -> configuration + accounting
mapping(address => AssetConfig) public assetConfigs;

/// @notice Enumerable list of whitelisted assets for TVL iteration
address[] public whitelistedAssets;
```

The `idleBalance` is tracked explicitly rather than derived from `IERC20(asset).balanceOf(address(this))`. This prevents accounting drift from unsolicited token transfers. The canonical balance is whatever the vault's internal ledger says.

For `deployedBalance`, the vault records how many underlying units were sent to the strategy. Yield accrual is tracked separately during harvest.

---

## 3. Strategy Abstraction — Interface Patterns and Registration

### Recommended Interface for GRVT

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title IStrategy
/// @notice Interface that all yield strategies must implement
interface IStrategy {
    /// @notice Returns the ERC-20 asset this strategy operates on
    function asset() external view returns (address);

    /// @notice Deploys `amount` of `asset()` from the vault into the strategy
    function deploy(uint256 amount) external;

    /// @notice Withdraws `amount` of `asset()` from the strategy back to the vault
    function withdraw(uint256 amount) external returns (uint256 actualAmount);

    /// @notice Harvests accrued yield and transfers it to the designated recipient
    function harvest(address recipient) external returns (uint256 yieldAmount);

    /// @notice Returns total assets currently under management (principal + yield)
    function totalDeployed() external view returns (uint256);

    /// @notice Emergency: withdraw all assets regardless of state
    function emergencyWithdraw(address recipient) external;
}
```

This interface is asset-specific, stateless from the vault's perspective, and contains no protocol-specific leakage.

### Strategy Registration

The vault maintains the `strategy` field in `AssetConfig`. Changing a strategy is an admin action. Before `removeStrategy` can be called, the operator must withdraw all capital. The vault enforces this with a guard.

---

## 4. ETH Handling — WETH Wrapping Strategy

### The Three Options

| Option | Description | Verdict |
|---|---|---|
| A — Auto-wrap ETH to WETH on deposit | `WETH.deposit{value: msg.value}()` immediately | **Recommended** |
| B — Use Aave's WrappedTokenGateway | Extra intermediary, designed for EOA users | Not relevant |
| C — Maintain native ETH code path | Branching in every function | Too complex |

### Recommended Implementation

```solidity
address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

/// @notice Accept ETH deposits, auto-wrap to WETH
receive() external payable {
    IWETH(WETH).deposit{value: msg.value}();
    _recordDeposit(WETH, msg.value);
}
```

The vault records a deposit under the `WETH` asset key. All downstream logic runs through the standard ERC-20 path. WETH address must be a named constant, not a magic value.

---

## 5. Extensibility — Adding New Strategies Without Modifying the Vault

### Core Design Principle

The vault is a dumb router: it knows which strategy handles which asset, calls a fixed interface, and records results. Protocol-specific knowledge belongs exclusively in the strategy contract. The vault never imports `IPool`, never calls `IPool.supply()` directly, and never reads `IAToken` balances directly.

### Day 1 vs Future

**Day 1 (single strategy per asset):**
```solidity
struct AssetConfig {
    bool whitelisted;
    address strategy;        // exactly one active strategy
    uint256 depositCap;
    uint256 idleBalance;
    uint256 deployedBalance;
}
```

**Future (multiple strategies per asset):**
```solidity
struct StrategyAllocation {
    address strategy;
    uint256 allocationBps;   // basis points out of 10000
    uint256 deployedBalance;
    bool active;
}
```

Adding a new strategy (e.g., Compound V3 for USDC) requires deploying a new `IStrategy` contract and calling `vault.setStrategy(USDC, address(compoundStrategy))` — one admin transaction. No vault code changes, no redeployment.

---

## 6. Non-Standard ERC-20 Handling

### USDT (Missing Return Value)

OpenZeppelin's `SafeERC20.forceApprove` handles USDT's missing return value and zero-before-nonzero requirement. **Rule:** Every token approval must use `SafeERC20.forceApprove`, never bare `IERC20.approve`.

### Fee-on-Transfer Tokens

Measure balance before and after transfer:

```solidity
uint256 balanceBefore = IERC20(asset).balanceOf(address(this));
SafeERC20.safeTransferFrom(IERC20(asset), from, address(this), amount);
uint256 actualReceived = IERC20(asset).balanceOf(address(this)) - balanceBefore;
assetConfigs[asset].idleBalance += actualReceived;
```

### Rebasing Tokens

The vault should not whitelist rebasing tokens as primary assets. aTokens are rebasing — which is why strategies hold aTokens internally and return plain tokens to the vault on withdraw/harvest.

---

## 7. Aave V3 Strategy-Specific Notes

Strategy contract flow for yield calculation (used in `harvest`):
1. Get aToken address from `aavePool.getReserveData(asset).aTokenAddress`
2. Read current aToken balance (includes principal + accrued yield)
3. Yield = `aTokenBalance - deployedPrincipal`
4. Call `aavePool.withdraw(asset, yield, grvtBank)` to extract only yield

The deployed balance the vault records is the **principal** amount. It does not grow. Yield is the difference between current aToken value and recorded principal, materialized only at harvest time.

---

## 8. RBAC Design Sketch

| Role | Actions |
|---|---|
| `DEFAULT_ADMIN_ROLE` | Grant/revoke roles, upgrade contracts |
| `MANAGER_ROLE` | Whitelist assets, set strategies, set deposit caps, pause |
| `OPERATOR_ROLE` | Deposit capital, deploy to strategy, withdraw from strategy, harvest |

OpenZeppelin `AccessControl` is the correct base. It uses `bytes32` role identifiers, supports multiple accounts per role, and emits `RoleGranted`/`RoleRevoked` events.

---

## 9. Summary Recommendations

| Decision | Recommendation |
|---|---|
| ERC-4626 | Do not implement — mismatch for treasury pattern |
| Vault architecture | Single multi-asset vault contract |
| Asset tracking | `mapping(address => AssetConfig)` with explicit idle/deployed balance fields |
| Strategy interface | Custom `IStrategy` interface, not ERC-4626 |
| Strategy cardinality | 1:1 on Day 1; struct designed for future 1:N |
| ETH handling | Auto-wrap to WETH on receipt; use WETH address as asset key |
| Token safety | `SafeERC20.forceApprove` everywhere; before/after balance measurement on deposit |
| Rebasing tokens | Not held in vault directly; aTokens held only in strategy |
| RBAC | OpenZeppelin `AccessControl` with `MANAGER_ROLE` / `OPERATOR_ROLE` split |
| Accounting | Explicit ledger (not derived from `balanceOf`); principal tracked separately from yield |

# Aave V3 Integration Deep Dive

Research for GRVT Yield Vault — Ethereum Mainnet
Sources: `lib/aave-v3-core` v1.19.4 (read directly from installed library), Aave V3 protocol internals.

---

## 1. Aave V3 Pool Interface

### 1.1 `supply()`

```solidity
function supply(
    address asset,       // ERC20 token address (e.g. USDC, WETH)
    uint256 amount,      // Amount in asset's native decimals
    address onBehalfOf,  // Who receives aTokens — use address(this) for a vault
    uint16 referralCode  // Pass 0 for non-partners
) external;
```

**Pre-conditions (all checked inside the Pool, will revert if violated):**
- Caller must have called `approve(pool, amount)` on `asset` before this call
- Reserve must be active, not paused, and not frozen
- Supply cap must not be exceeded

**What happens internally:**
1. The Pool transfers `amount` of `asset` from `msg.sender` to the aToken contract address
2. The aToken mints scaled tokens to `onBehalfOf`: `scaledAmount = amount / liquidityIndex`
3. On first supply by `onBehalfOf`, emits `ReserveUsedAsCollateralEnabled` if applicable

**No return value.** The amount credited equals `amount` exactly.

There is also a deprecated `deposit()` with the same signature — always use `supply()`.

---

### 1.2 `withdraw()`

```solidity
function withdraw(
    address asset,   // ERC20 token to withdraw
    uint256 amount,  // Amount to withdraw; type(uint256).max withdraws entire balance
    address to       // Who receives the underlying asset
) external returns (uint256);  // Returns actual amount withdrawn
```

**`type(uint256).max` behavior** (confirmed in `SupplyLogic.executeWithdraw`):

```solidity
uint256 userBalance = IAToken(aToken).scaledBalanceOf(msg.sender)
    .rayMul(reserveCache.nextLiquidityIndex);

uint256 amountToWithdraw = params.amount;
if (params.amount == type(uint256).max) {
    amountToWithdraw = userBalance;  // collapses to full balance
}
```

**Pre-conditions:**
- Reserve must be active and not paused (frozen reserves still allow withdrawal)
- `amount <= userBalance` — reverts with `NOT_ENOUGH_AVAILABLE_USER_BALANCE` if exceeded
- Pool must hold sufficient liquidity (utilization concern, not a code check)

**Always capture the return value** — it equals `amountToWithdraw` (the actual amount withdrawn). When using `type(uint256).max`, the returned value is the exact amount sent to `to`.

---

### 1.3 `getReserveData()`

```solidity
function getReserveData(address asset)
    external view returns (DataTypes.ReserveData memory);
```

`DataTypes.ReserveData`:

```solidity
struct ReserveData {
    ReserveConfigurationMap configuration;  // Packed bitmap
    uint128 liquidityIndex;                 // Current index, ray (1e27 = 1.0)
    uint128 currentLiquidityRate;           // Supply APY (net, after reserve factor), ray
    uint128 variableBorrowIndex;
    uint128 currentVariableBorrowRate;
    uint128 currentStableBorrowRate;
    uint40  lastUpdateTimestamp;
    uint16  id;
    address aTokenAddress;                  // The aToken for this asset
    address stableDebtTokenAddress;
    address variableDebtTokenAddress;
    address interestRateStrategyAddress;
    uint128 accruedToTreasury;
    uint128 unbacked;
    uint128 isolationModeTotalDebt;
}
```

**Key fields for the vault:**
- `aTokenAddress` — needed to read balances and hold the position
- `liquidityIndex` — multiply scaled balance by this to get actual balance
- `currentLiquidityRate` — net APY, expressed in ray; divide by 1e27 for decimal

---

## 2. aToken Mechanics

### 2.1 Rebasing via Scaled Balances

aTokens store a **scaled balance** in ERC20 state. The visible `balanceOf` is computed on read:

```solidity
// From AToken.sol:
function balanceOf(address user) public view returns (uint256) {
    return super.balanceOf(user)  // scaled balance (constant between interactions)
        .rayMul(POOL.getReserveNormalizedIncome(_underlyingAsset));
        //      ^--- liquidity index, grows monotonically over time
}
```

- `getReserveNormalizedIncome(asset)` returns the **current** liquidity index including time-accrued interest since the last stored update
- This means `balanceOf` automatically reflects yield without any transactions

**On deposit:** `scaledMinted = amount.rayDiv(liquidityIndex)`
**On read:** `actualBalance = scaledBalance.rayMul(liquidityIndex)`

The liquidity index only grows, so `balanceOf` never decreases for a pure supplier.

### 2.2 Two Balance Views

| Function | What it returns | When to use |
|---|---|---|
| `aToken.balanceOf(user)` | Actual redeemable amount (grows over time) | TVL, yield calc, withdraw sizing |
| `aToken.scaledBalanceOf(user)` | Raw scaled amount (static unless deposit/withdraw) | Precise principal tracking |
| `pool.getReserveNormalizedIncome(asset)` | Current liquidity index (real-time) | Computing current value from scaled balance |

### 2.3 Precision

Ray = 1e27. WadRayMath rounds half-up. For USDC (6 decimals):
- Rounding in `rayDiv` / `rayMul` is at most 1 wei per operation
- For positions in the millions of USDC, yield precision is effectively perfect

---

## 3. Yield Accounting

### 3.1 Simple Balance Delta Method

```
yield = aToken.balanceOf(vault) - principal[asset]
```

This is **correct and sufficient** for this vault. Because:
1. `balanceOf` is the full redeemable value including all interest
2. The reserve factor is already deducted before suppliers earn — `currentLiquidityRate` is net of fees
3. There are no deductions applied to a supplier's aToken balance from external events

### 3.2 Reserve Factor Does Not Require Adjustment

The `reserveFactor` (typically 10–20% for stablecoins) is taken from **borrowers' interest payments** before distribution to suppliers. The `liquidityRate` shown is already the net supply APY. No separate accounting needed.

### 3.3 Can a Supplier's Balance Decrease?

Suppliers are **not subject to liquidation**. The only ways a vault's aToken balance decreases:
1. The vault itself calls `withdraw()` — expected
2. Aave governance insolvency backstop (extreme theoretical scenario)
3. Unauthorized transfer of aTokens out of the vault address

**Conclusion:** `principal` tracking is robust. `balanceOf - principal` reliably measures yield.

### 3.4 Harvest Pattern

```solidity
function harvestYield(address asset) internal returns (uint256 harvested) {
    address aToken = IPool(pool).getReserveData(asset).aTokenAddress;
    uint256 current = IERC20(aToken).balanceOf(address(this));
    uint256 yield = current > principal[asset] ? current - principal[asset] : 0;

    if (yield == 0) return 0;

    // Withdraw only the yield portion
    harvested = IPool(pool).withdraw(asset, yield, grvtBank);
    // principal[asset] unchanged — position continues earning
}
```

---

## 4. WETH Gateway

### 4.1 Approach A: Wrap ETH Manually (Recommended)

```solidity
// Supply ETH flow:
IWETH(WETH).deposit{value: ethAmount}();
IERC20(WETH).forceApprove(aavePool, ethAmount);
IPool(aavePool).supply(WETH, ethAmount, address(this), 0);

// Withdraw ETH flow:
uint256 wethReceived = IPool(aavePool).withdraw(WETH, amount, address(this));
IWETH(WETH).withdraw(wethReceived);
```

**Advantages over WETHGateway:**
- No external contract dependency
- The vault holds aWETH directly (full control)
- No approval of an external gateway contract
- Simpler audit surface

### 4.2 Approach B: WETHGateway (Not Recommended)

Address: `0xD322A49006FC828F9B5B37Ab215F99B4E5caB19C`. Requires vault to approve gateway to spend aWETH — adds trust surface. Not needed for contract-to-contract integration.

---

## 5. Mainnet Contract Addresses

### 5.1 Core Protocol (Ethereum Mainnet)

| Contract | Address |
|---|---|
| PoolAddressesProvider | `0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e` |
| Pool (proxy) | `0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2` |
| AaveProtocolDataProvider | `0x7B4EB56E7CD4b454BA8ff71E4518426369a138a3` |
| WETHGateway | `0xD322A49006FC828F9B5B37Ab215F99B4E5caB19C` |

### 5.2 Tokens (Underlying + aToken)

| Asset | Underlying | aToken |
|---|---|---|
| WETH | `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2` | `0x4d5F47FA6A74757f35C14fD3a6Ef8E3C9BC514E8` |
| USDC | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` | `0x98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c` |
| USDT | `0xdAC17F958D2ee523a2206206994597C13D831ec7` | `0x23878914EFE38d27C4D67Ab83ed1b93A74D4086a` |
| DAI | `0x6B175474E89094C44Da98b954EedeAC495271d0F` | `0x018008bfb33d285247A21d44E50697654f754e63` |

### 5.3 Address Notes

- The **Pool is a proxy** — always call the proxy address, never hardcode implementation
- aToken addresses are stable and can be hardcoded or resolved via `getReserveData(asset).aTokenAddress`

---

## 6. Important Considerations and Gotchas

### 6.1 Supply Cap

Aave V3 introduces per-reserve supply caps. If exceeded, `supply()` reverts with `SUPPLY_CAP_EXCEEDED`. For major stablecoins caps are in the billions — not a practical concern for vault sizes under $100M.

### 6.2 Frozen Reserve

A frozen reserve blocks new `supply()` calls but **allows** `withdraw()`. The strategy should check `isFrozen` before attempting supply and always allow withdrawal.

### 6.3 Paused Reserve

A paused reserve blocks **both** `supply()` and `withdraw()`. The vault cannot withdraw from a paused reserve. Must handle gracefully — do not revert the entire vault for a single paused reserve.

### 6.4 Reentrancy

The Aave V3 Pool has its own reentrancy guard. Nevertheless:
- Wrap all vault functions that call into Aave with `nonReentrant`
- The ETH receive path should be state-change-free
- Never implement `IFlashLoanReceiver` in the vault contract

### 6.5 USDT Approval Pattern

USDT reverts if `approve()` is called when the current allowance is non-zero. Always use:

```solidity
IERC20(asset).forceApprove(pool, amount);  // OZ SafeERC20 v5+
```

### 6.6 Supply on Behalf of `address(this)`

Standard and correct pattern for a contract vault:

```solidity
IPool(pool).supply(asset, amount, address(this), 0);
```

### 6.7 Withdraw Return Value

Always use the return value of `withdraw()` for accounting updates, especially when using `type(uint256).max`.

### 6.8 Flash Loans

Flash loans do not affect supplier balances. The liquidity index only grows monotonically.

---

## 7. Recommended Implementation Snippets

### Supply

```solidity
using SafeERC20 for IERC20;

function _supplyToAave(address asset, uint256 amount) internal {
    IERC20(asset).forceApprove(aavePool, amount);
    IPool(aavePool).supply(asset, amount, address(this), 0);
    deployedPrincipal[asset] += amount;
}
```

### Withdraw

```solidity
function _withdrawFromAave(address asset, uint256 amount) internal returns (uint256 withdrawn) {
    withdrawn = IPool(aavePool).withdraw(asset, amount, address(this));

    if (amount == type(uint256).max) {
        deployedPrincipal[asset] = 0;
    } else {
        deployedPrincipal[asset] -= withdrawn;
    }
}
```

### TVL and Yield Reporting

```solidity
function deployedBalance(address asset) public view returns (uint256) {
    address aToken = IPool(aavePool).getReserveData(asset).aTokenAddress;
    return IERC20(aToken).balanceOf(address(this));
}

function pendingYield(address asset) public view returns (uint256) {
    uint256 current = deployedBalance(asset);
    uint256 p = deployedPrincipal[asset];
    return current > p ? current - p : 0;
}
```

---

## 8. Summary of Key Design Choices

| Decision | Choice | Rationale |
|---|---|---|
| ETH handling | Wrap to WETH manually | Avoid WETHGateway dependency; simpler; vault holds aWETH directly |
| Principal tracking | `uint256 principal` per asset | Sufficient for yield delta; simpler than scaled balance tracking |
| Yield calculation | `balanceOf - principal` | Correct and direct; reserve factor already deducted |
| `onBehalfOf` | `address(this)` | Standard vault pattern; vault holds aTokens itself |
| Referral code | `0` | Correct for non-registered integrators |
| Token approvals | `SafeERC20.forceApprove` | Required for USDT; safe for all ERC20s |
| Paused reserve | Graceful, do not revert | Governance can pause; vault must remain operational |
| Pool address | Hardcode proxy as constant | Proxy is stable; implementation is governance-upgradeable |

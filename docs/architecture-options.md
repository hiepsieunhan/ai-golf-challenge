# Architecture Options — GRVT Yield Vault

Based on Phase 1 research in `docs/research/`. Three options presented from simplest to most sophisticated.

---

## Option A: Monolithic Vault (Aave-Aware)

### Contract Structure

| Contract | Purpose |
|---|---|
| `GrvtVault.sol` | Single contract: holds assets, calls Aave directly, tracks balances, reports TVL |

The vault imports `IPool` and calls `supply()`/`withdraw()` directly. No strategy abstraction layer. Aave-specific logic lives inside the vault.

### Strategy Interface

None. Aave calls are inline:

```solidity
// Inside GrvtVault
function deployToAave(address asset, uint256 amount) external onlyRole(OPERATOR_ROLE) {
    IERC20(asset).forceApprove(AAVE_POOL, amount);
    IPool(AAVE_POOL).supply(asset, amount, address(this), 0);
    _deployedBalance[asset] += amount;
}
```

### RBAC

Two roles:

| Role | Actions |
|---|---|
| `DEFAULT_ADMIN_ROLE` | Configuration, whitelist assets, pause/unpause, role management |
| `OPERATOR_ROLE` | Deposit, deploy to Aave, withdraw from Aave, harvest |

Inherits `AccessControl` + `Pausable` + `ReentrancyGuard`.

### ETH Handling

Auto-wrap to WETH on `receive()`. All internal logic uses WETH address.

### Yield Accounting

`aToken.balanceOf(this) - _deployedBalance[asset]` computed inline. Harvest withdraws yield portion directly to `grvtBank`.

### Emergency Controls

`pause()` by ADMIN. `emergencyWithdraw(asset)` by ADMIN calls `IPool.withdraw(asset, type(uint256).max, address(this))`.

### TVL Reporting

```solidity
function getAssetBalance(address asset) external view returns (uint256 idle, uint256 deployed, uint256 total);
function getAllAssetBalances() external view returns (address[] assets, uint256[] idle, uint256[] deployed);
```

`deployed` reads `aToken.balanceOf(this)` directly (real-time, includes yield).

### Tradeoffs

| Dimension | Assessment |
|---|---|
| Simplicity | Highest — one contract, no interfaces, no delegation |
| Gas cost | Lowest — no inter-contract calls |
| Extensibility | **Poor** — adding Compound requires modifying the vault, redeploying |
| Testability | Moderate — all logic in one place but tightly coupled to Aave |
| Security surface | Smallest — no strategy trust assumptions |
| Meets "extensible" requirement | **No** — hardcoded to Aave; violates requirement #4 |

---

## Option B: Vault + Strategy Interface (Recommended)

### Contract Structure

| Contract | Purpose |
|---|---|
| `GrvtVault.sol` | Core vault: holds idle assets, routes to strategies, tracks balances, reports TVL, RBAC |
| `IStrategy.sol` | Interface that all strategies implement |
| `AaveV3Strategy.sol` | Aave V3 implementation of `IStrategy`; holds aTokens, knows Aave-specific logic |

The vault never imports `IPool`. All protocol knowledge lives in strategy contracts. The vault is a dumb router that calls a fixed interface.

### Strategy Interface

```solidity
interface IStrategy {
    /// @notice The underlying asset this strategy operates on
    function asset() external view returns (address);

    /// @notice Deploy amount of asset into the yield protocol
    /// @dev Vault transfers tokens to strategy before calling, or strategy pulls from vault
    function deploy(uint256 amount) external;

    /// @notice Withdraw amount back to the vault
    function withdraw(uint256 amount) external returns (uint256 actual);

    /// @notice Harvest accrued yield, send to recipient
    function harvest(address recipient) external returns (uint256 yieldAmount);

    /// @notice Current total value (principal + yield) in the protocol
    function totalDeployed() external view returns (uint256);

    /// @notice Emergency: pull everything back to recipient
    function emergencyWithdraw(address recipient) external returns (uint256 recovered);
}
```

Strategy is asset-specific (one instance per asset per protocol). The vault transfers tokens to the strategy before calling `deploy()`. The strategy has an `onlyVault` modifier on all external functions.

### RBAC

Four roles via `AccessControlEnumerable`:

| Role | Actions |
|---|---|
| `DEFAULT_ADMIN_ROLE` | Set strategies, whitelist assets, set `grvtBank`, role management, unpause, emergency withdraw |
| `STRATEGIST_ROLE` | Deploy to strategy, withdraw from strategy, harvest |
| `DEPOSITOR_ROLE` | Deposit ERC20 / deposit ETH |
| `GUARDIAN_ROLE` | Pause only |

Uses `AccessControlDefaultAdminRules` with 1-day transfer delay. GUARDIAN is asymmetric: can pause but not unpause (only ADMIN unpauses).

### ETH Handling

Auto-wrap to WETH in a dedicated `depositETH()` function (role-gated to DEPOSITOR). Internal accounting uses WETH address. Strategy receives WETH like any other ERC20.

```solidity
function depositETH() external payable nonReentrant onlyRole(DEPOSITOR_ROLE) whenNotPaused {
    if (msg.value == 0) revert ZeroAmount();
    IWETH(WETH).deposit{value: msg.value}();
    _recordDeposit(WETH, msg.value);
}
```

### Yield Accounting

**In the vault**: tracks `deployedPrincipal[asset]` — the sum of all amounts sent to the strategy via `deploy()`, minus amounts returned via `withdraw()`.

**In the strategy**: tracks its own principal. `totalDeployed()` returns `aToken.balanceOf(this)` (real-time value including yield). `harvest()` computes `aToken.balanceOf(this) - principal`, withdraws that delta from Aave, and transfers to `recipient` (grvtBank).

**Vault's view of deployed balance**: calls `strategy.totalDeployed()` for real-time TVL. Uses `deployedPrincipal[asset]` for internal accounting (what was sent, not what it's worth now).

### Emergency Controls

- `Pausable`: GUARDIAN pauses inbound operations. `withdrawFromStrategy` is NOT pausable (must always be able to pull funds out).
- `emergencyWithdrawFromStrategy(asset)`: ADMIN-only. Calls `strategy.emergencyWithdraw(address(this))`, which passes `type(uint256).max` to Aave's `withdraw()`. Returns all capital to vault idle.
- Strategy's `emergencyWithdraw` is callable only by vault (`onlyVault`).

### TVL Reporting

```solidity
/// @notice Per-asset breakdown for third-party trackers
function getAssetBalance(address asset)
    external view
    returns (uint256 idle, uint256 deployed, uint256 total);

/// @notice All supported assets at once
function getAllAssetBalances()
    external view
    returns (
        address[] memory assets,
        uint256[] memory idle,
        uint256[] memory deployed,
        uint256[] memory total
    );
```

`idle` = vault's internal ledger. `deployed` = `strategy.totalDeployed()` (live aToken balance, includes unrealized yield). `total` = `idle + deployed`.

### Tradeoffs

| Dimension | Assessment |
|---|---|
| Simplicity | Moderate — 3 contracts, clear separation |
| Gas cost | Slightly higher — inter-contract calls for deploy/withdraw/harvest |
| Extensibility | **Good** — new strategy = new contract + one admin tx (`setStrategy`) |
| Testability | High — vault testable with mock strategies; strategy testable independently against fork |
| Security surface | Moderate — strategy is a trust boundary; mitigated by `onlyVault` + admin-only registration |
| Meets "extensible" requirement | **Yes** — core design goal |

---

## Option C: Vault + Strategy Registry + Multi-Strategy Router

### Contract Structure

| Contract | Purpose |
|---|---|
| `GrvtVault.sol` | Core vault: holds idle assets, delegates to router |
| `StrategyRegistry.sol` | Separate contract: manages strategy whitelist, allocation weights per asset |
| `StrategyRouter.sol` | Routes deploy/withdraw/harvest across multiple strategies per asset based on allocation weights |
| `IStrategy.sol` | Same interface as Option B |
| `AaveV3Strategy.sol` | Same as Option B |

The vault calls the router; the router reads the registry to determine which strategies to use and how to split capital.

### Strategy Interface

Same as Option B. The router aggregates calls across multiple `IStrategy` implementations.

### RBAC

Five roles:

| Role | Actions |
|---|---|
| `DEFAULT_ADMIN_ROLE` | Role management, unpause, emergency |
| `REGISTRY_ADMIN_ROLE` | Add/remove strategies in registry, set allocation weights |
| `STRATEGIST_ROLE` | Deploy, withdraw, harvest, rebalance |
| `DEPOSITOR_ROLE` | Deposit |
| `GUARDIAN_ROLE` | Pause |

### ETH Handling

Same as Option B (auto-wrap to WETH).

### Yield Accounting

Per-strategy tracking via the router:

```solidity
struct StrategyAllocation {
    address strategy;
    uint256 allocationBps;    // target allocation in basis points
    uint256 deployedPrincipal;
    bool active;
}
mapping(address asset => StrategyAllocation[]) allocations;
```

Harvest iterates all active strategies for an asset. Rebalance moves capital between strategies to match target weights.

### Emergency Controls

Same as Option B, plus: `emergencyWithdrawAll(asset)` iterates all strategies for that asset and pulls everything to idle.

### TVL Reporting

Same interface as Option B, but `deployed` aggregates across all strategies per asset.

### Tradeoffs

| Dimension | Assessment |
|---|---|
| Simplicity | **Low** — 4+ contracts, allocation logic, rebalancing |
| Gas cost | Highest — router indirection, iteration over strategies |
| Extensibility | **Excellent** — multi-strategy per asset, allocation weights, rebalancing |
| Testability | Complex — many interaction paths, allocation edge cases |
| Security surface | Largest — registry is a new trust boundary, router has delegation logic |
| Meets "extensible" requirement | Over-delivers for Day 1 |

---

## Comparison Matrix

| Dimension | Option A (Monolithic) | Option B (Vault + Strategy) | Option C (Full Registry) |
|---|---|---|---|
| Contracts | 1 | 3 | 5+ |
| Extensibility | None | Good (1:1 asset:strategy) | Excellent (N:M) |
| Day 1 complexity | Low | Moderate | High |
| Meets requirement #4 | No | Yes | Yes (over-delivers) |
| RBAC granularity | 2 roles | 4 roles | 5 roles |
| Strategy trust model | N/A (no strategies) | Vault trusts registered strategies | Vault trusts router trusts strategies |
| Gas overhead | Lowest | Low (+1 external call per operation) | Moderate (+iteration, +router hop) |
| Time to implement | Fastest | Moderate | Longest |
| Future migration path | Must rewrite for new protocols | Add strategy contract, one admin tx | Add strategy, set allocation weights |
| Admin transfer protection | No | Yes (1-day delay) | Yes (1-day delay) |
| Emergency controls | Basic pause + withdraw | Pause + per-strategy emergency withdraw | Pause + per-strategy + withdraw-all-strategies |

---

## Recommendation

**Option B** is the right choice for this challenge.

- Option A fails requirement #4 ("be extensible beyond Aave V3") — it hardcodes Aave into the vault.
- Option C over-engineers for Day 1 — multi-strategy allocation, rebalancing, and a separate registry add complexity without delivering value when there's exactly one strategy per asset. The migration from Option B's `address strategy` field to Option C's `StrategyAllocation[]` is additive and does not require a vault rewrite.
- Option B hits the sweet spot: clean separation via `IStrategy`, extensible without vault changes, four-role RBAC with meaningful isolation, and all security patterns from research (CEI, ReentrancyGuard, SafeERC20, Pausable, onlyVault).

### Option B File Layout

```
src/
├── GrvtVault.sol              # Core vault (AccessControlEnumerable, Pausable, ReentrancyGuardTransient)
├── interfaces/
│   └── IStrategy.sol          # Strategy interface
└── strategies/
    └── AaveV3Strategy.sol     # Aave V3 implementation (onlyVault, SafeERC20)

test/
├── base/
│   └── VaultTestBase.sol      # Fork setup, deploy, fund, helpers
├── unit/
│   └── VaultAccessControl.t.sol
└── integration/
    ├── VaultDeposit.t.sol
    ├── VaultStrategy.t.sol
    ├── VaultHarvest.t.sol
    └── VaultTVL.t.sol
```

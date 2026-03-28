# Architecture — GRVT Yield Vault

**Decision**: Option B — Vault + Strategy Interface
**Date**: 2026-03-28

---

## Contract Structure

```
src/
├── GrvtVault.sol              # Core vault
├── interfaces/
│   └── IStrategy.sol          # Strategy interface
└── strategies/
    └── AaveV3Strategy.sol     # Aave V3 strategy implementation
```

### `GrvtVault.sol`

Core treasury vault. Holds idle assets, routes capital to strategies, tracks per-asset accounting, reports TVL, enforces RBAC.

**Inherits**: `AccessControlEnumerable`, `AccessControlDefaultAdminRules(1 days)`, `ReentrancyGuardTransient`, `Pausable`

**Responsibilities**:
- Accept ERC20 deposits from authorized depositors
- Accept native ETH, auto-wrap to WETH
- Route capital to/from registered strategies
- Track idle and deployed balances per asset
- Harvest yield and forward to `grvtBank`
- Report TVL (idle + deployed) per asset
- Pause/unpause operations
- Emergency withdraw from strategies

**Does NOT**: import `IPool`, call Aave directly, hold aTokens, know any protocol-specific logic.

### `IStrategy.sol`

Interface contract. Defines the boundary between vault and yield protocols.

### `AaveV3Strategy.sol`

Aave V3 implementation of `IStrategy`. Holds aTokens. Knows how to call `IPool.supply()`, `IPool.withdraw()`, compute yield via `aToken.balanceOf()`.

**Inherits**: none (standalone, no OZ base — uses `onlyVault` modifier)

**Responsibilities**:
- Receive tokens from vault, supply to Aave V3
- Withdraw from Aave V3, return tokens to vault
- Compute yield as `aToken.balanceOf(this) - principal`
- Harvest: withdraw yield portion from Aave, transfer to recipient
- Emergency: withdraw everything from Aave, transfer to recipient
- Report `totalDeployed()` via live aToken balance

---

## Interface Definitions

### IStrategy

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

interface IStrategy {
    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    /// @notice The ERC-20 asset this strategy operates on
    /// @return The underlying token address (e.g., USDC, WETH)
    function asset() external view returns (address);

    /// @notice The vault this strategy is bound to
    /// @return The vault contract address
    function vault() external view returns (address);

    /// @notice Total value currently in the protocol (principal + accrued yield)
    /// @return Total value in units of asset()
    function totalDeployed() external view returns (uint256);

    // -------------------------------------------------------------------------
    // Mutative (vault-only)
    // -------------------------------------------------------------------------

    /// @notice Deploy tokens into the yield protocol
    /// @dev Vault must transfer tokens to this contract before calling
    /// @param amount Amount of asset to deploy
    function deploy(uint256 amount) external;

    /// @notice Withdraw tokens from the yield protocol back to the vault
    /// @param amount Amount to withdraw (type(uint256).max = withdraw all)
    /// @return actual Amount actually returned to the vault
    function withdraw(uint256 amount) external returns (uint256 actual);

    /// @notice Harvest accrued yield and send to recipient
    /// @param recipient Address to receive harvested yield (grvtBank)
    /// @return yieldAmount Amount of yield harvested
    function harvest(address recipient) external returns (uint256 yieldAmount);

    /// @notice Emergency: withdraw everything, send to recipient
    /// @param recipient Address to receive all recovered assets
    /// @return recovered Total amount recovered
    function emergencyWithdraw(address recipient) external returns (uint256 recovered);
}
```

### GrvtVault — External Functions

```solidity
// -------------------------------------------------------------------------
// Deposit (DEPOSITOR_ROLE)
// -------------------------------------------------------------------------

/// @notice Deposit ERC20 tokens into the vault
/// @param asset Token address (must be whitelisted)
/// @param amount Amount to deposit
function deposit(address asset, uint256 amount) external;

/// @notice Deposit native ETH — auto-wraps to WETH
function depositETH() external payable;

// -------------------------------------------------------------------------
// Strategy Operations (STRATEGIST_ROLE)
// -------------------------------------------------------------------------

/// @notice Deploy idle assets into the registered strategy
/// @param asset Token to deploy
/// @param amount Amount to deploy from idle balance
function deployToStrategy(address asset, uint256 amount) external;

/// @notice Withdraw assets from the strategy back to idle
/// @param asset Token to withdraw
/// @param amount Amount to withdraw (type(uint256).max = all)
function withdrawFromStrategy(address asset, uint256 amount) external;

/// @notice Harvest yield from strategy, send to grvtBank
/// @param asset Token whose yield to harvest
function harvest(address asset) external;

// -------------------------------------------------------------------------
// Configuration (DEFAULT_ADMIN_ROLE)
// -------------------------------------------------------------------------

/// @notice Whitelist an asset for deposits
/// @param asset Token address
function whitelistAsset(address asset) external;

/// @notice Remove asset from whitelist (does not affect existing balances)
/// @param asset Token address
function removeAsset(address asset) external;

/// @notice Register or replace the strategy for an asset
/// @param asset Token address
/// @param strategy IStrategy implementation address
function setStrategy(address asset, address strategy) external;

/// @notice Remove the strategy for an asset (must have zero deployed)
/// @param asset Token address
function removeStrategy(address asset) external;

/// @notice Set the yield recipient address
/// @param newGrvtBank Address to receive harvested yield
function setGrvtBank(address newGrvtBank) external;

// -------------------------------------------------------------------------
// Emergency (DEFAULT_ADMIN_ROLE / GUARDIAN_ROLE)
// -------------------------------------------------------------------------

/// @notice Pause deposit, deploy, and harvest operations
function pause() external;  // GUARDIAN_ROLE

/// @notice Unpause operations
function unpause() external;  // DEFAULT_ADMIN_ROLE

/// @notice Emergency: pull all assets from a strategy back to idle
/// @param asset Token address
function emergencyWithdrawFromStrategy(address asset) external;  // DEFAULT_ADMIN_ROLE

// -------------------------------------------------------------------------
// TVL Reporting (public view)
// -------------------------------------------------------------------------

/// @notice Per-asset balance breakdown
/// @return idle Tokens sitting in the vault contract
/// @return deployed Current value in strategy (principal + yield)
/// @return total idle + deployed
function getAssetBalance(address asset)
    external view returns (uint256 idle, uint256 deployed, uint256 total);

/// @notice All whitelisted assets and their balances
/// @return assets Array of token addresses
/// @return idle Array of idle balances
/// @return deployed Array of deployed balances (live, includes yield)
/// @return total Array of total balances
function getAllAssetBalances()
    external view
    returns (
        address[] memory assets,
        uint256[] memory idle,
        uint256[] memory deployed,
        uint256[] memory total
    );

/// @notice List all whitelisted asset addresses
function getWhitelistedAssets() external view returns (address[] memory);
```

---

## RBAC

```
DEFAULT_ADMIN_ROLE ─── manages all other roles
├── STRATEGIST_ROLE
├── DEPOSITOR_ROLE
└── GUARDIAN_ROLE
```

All custom roles have `DEFAULT_ADMIN_ROLE` as their role admin (default OZ behavior). No custom `_setRoleAdmin` calls.

| Role | Constant | Holders | Permissions |
|---|---|---|---|
| `DEFAULT_ADMIN_ROLE` | `bytes32(0)` | GRVT multisig | `whitelistAsset`, `removeAsset`, `setStrategy`, `removeStrategy`, `setGrvtBank`, `unpause`, `emergencyWithdrawFromStrategy`, `grantRole`, `revokeRole` |
| `STRATEGIST_ROLE` | `keccak256("STRATEGIST_ROLE")` | Operations wallet / multisig | `deployToStrategy`, `withdrawFromStrategy`, `harvest` |
| `DEPOSITOR_ROLE` | `keccak256("DEPOSITOR_ROLE")` | Funding wallet | `deposit`, `depositETH` |
| `GUARDIAN_ROLE` | `keccak256("GUARDIAN_ROLE")` | Monitoring bot / security multisig | `pause` |

**Key design decisions**:
- DEPOSITOR cannot extract funds — compromised funding wallet can only push capital in
- GUARDIAN can pause but not unpause — compromised guardian causes nuisance halt, not fund loss
- `withdrawFromStrategy` is NOT pausable — must always be able to pull funds out of external protocols
- Admin transfer uses 2-step process with 1-day delay (`AccessControlDefaultAdminRules`)

---

## Data Structures

### GrvtVault State

```solidity
// -------------------------------------------------------------------------
// Constants
// -------------------------------------------------------------------------
bytes32 public constant STRATEGIST_ROLE = keccak256("STRATEGIST_ROLE");
bytes32 public constant DEPOSITOR_ROLE  = keccak256("DEPOSITOR_ROLE");
bytes32 public constant GUARDIAN_ROLE   = keccak256("GUARDIAN_ROLE");

address public immutable WETH;  // Set in constructor (mainnet: 0xC02...Cc2)

// -------------------------------------------------------------------------
// Configuration
// -------------------------------------------------------------------------
address public grvtBank;  // Yield recipient

// -------------------------------------------------------------------------
// Per-asset state
// -------------------------------------------------------------------------
mapping(address asset => bool) public whitelistedAssets;
mapping(address asset => address strategy) public assetStrategy;
mapping(address asset => uint256) public idleBalance;
mapping(address asset => uint256) public deployedPrincipal;

// Enumerable list for TVL iteration
address[] internal _assetList;
```

### AaveV3Strategy State

```solidity
address public immutable vault;       // The GrvtVault address
address public immutable aavePool;    // Aave V3 Pool proxy
address public immutable asset_;      // The ERC-20 this strategy handles

uint256 internal _principal;          // Sum of deployed amounts minus withdrawals
```

**Why separate `idleBalance` and `deployedPrincipal` mappings instead of a struct?**

Flat mappings are simpler to read via auto-generated getters, cheaper for single-field access (no struct unpacking), and avoid the need to read unused fields. The vault only ever accesses one or two fields per function call.

---

## Fund Flow Diagrams

### Deposit Flow

```
Funding Wallet                    GrvtVault
     │                                │
     │  deposit(USDC, 1_000_000)      │
     │ ──────────────────────────────>│
     │                                │── check: DEPOSITOR_ROLE, not paused, whitelisted
     │                                │── safeTransferFrom(funder, vault, amount)
     │                                │── measure actual received (balance delta)
     │                                │── idleBalance[USDC] += received
     │                                │── emit Deposited(funder, USDC, received)
     │                                │
```

### ETH Deposit Flow

```
Funding Wallet                    GrvtVault                     WETH Contract
     │                                │                              │
     │  depositETH{value: 100 ETH}()  │                              │
     │ ──────────────────────────────>│                              │
     │                                │── check: DEPOSITOR_ROLE      │
     │                                │── WETH.deposit{100 ETH}() ──>│
     │                                │<── (100 WETH minted) ────────│
     │                                │── idleBalance[WETH] += 100e18│
     │                                │── emit Deposited(..., WETH)  │
```

### Deploy to Strategy Flow

```
Strategist           GrvtVault                 AaveV3Strategy            Aave V3 Pool
    │                     │                          │                        │
    │ deployToStrategy    │                          │                        │
    │  (USDC, 500_000)   │                          │                        │
    │ ──────────────────>│                          │                        │
    │                     │── check: STRATEGIST_ROLE │                        │
    │                     │── check: idle >= amount  │                        │
    │                     │── idleBalance -= amount  │                        │
    │                     │── deployedPrincipal += amount                     │
    │                     │── safeTransfer(strategy, amount)                  │
    │                     │── strategy.deploy(amount)│                        │
    │                     │                          │── forceApprove(pool)   │
    │                     │                          │── pool.supply() ──────>│
    │                     │                          │<── (aUSDC minted) ─────│
    │                     │                          │── forceApprove(pool, 0)│
    │                     │                          │── _principal += amount │
    │                     │── emit DeployedToStrategy(USDC, strategy, amount)│
```

### Withdraw from Strategy Flow

```
Strategist           GrvtVault                 AaveV3Strategy            Aave V3 Pool
    │                     │                          │                        │
    │ withdrawFromStrategy│                          │                        │
    │  (USDC, 300_000)   │                          │                        │
    │ ──────────────────>│                          │                        │
    │                     │── check: STRATEGIST_ROLE │                        │
    │                     │── check: principal >= amt│                        │
    │                     │── deployedPrincipal -= amount                     │
    │                     │── strategy.withdraw(amt) │                        │
    │                     │                          │── pool.withdraw() ────>│
    │                     │                          │<── (USDC returned) ────│
    │                     │                          │── _principal -= actual │
    │                     │                          │── safeTransfer(vault)  │
    │                     │<── returns actual ────────│                        │
    │                     │── idleBalance += actual  │                        │
    │                     │── emit WithdrawnFromStrategy(USDC, strategy, actual)
```

### Harvest Flow

```
Strategist           GrvtVault                 AaveV3Strategy            Aave V3 Pool     grvtBank
    │                     │                          │                        │               │
    │ harvest(USDC)       │                          │                        │               │
    │ ──────────────────>│                          │                        │               │
    │                     │── check: STRATEGIST_ROLE │                        │               │
    │                     │── strategy.harvest(grvtBank)                      │               │
    │                     │                          │── yield = aToken.balanceOf(this)       │
    │                     │                          │          - _principal  │               │
    │                     │                          │── if yield == 0: return 0              │
    │                     │                          │── pool.withdraw(yield)─>│               │
    │                     │                          │<── (USDC returned) ────│               │
    │                     │                          │── safeTransfer(grvtBank, yield) ─────>│
    │                     │                          │── return yield         │               │
    │                     │<── returns yieldAmount ───│                        │               │
    │                     │── emit Harvested(USDC, strategy, yieldAmount, grvtBank)           │
```

### Emergency Withdraw Flow

```
Admin                GrvtVault                 AaveV3Strategy            Aave V3 Pool
    │                     │                          │                        │
    │ emergencyWithdraw   │                          │                        │
    │  FromStrategy(USDC) │                          │                        │
    │ ──────────────────>│                          │                        │
    │                     │── check: DEFAULT_ADMIN   │                        │
    │                     │── strategy.emergencyWithdraw(vault)               │
    │                     │                          │── pool.withdraw(max) ─>│
    │                     │                          │<── (all USDC) ─────────│
    │                     │                          │── _principal = 0       │
    │                     │                          │── safeTransfer(vault)  │
    │                     │<── returns recovered ─────│                        │
    │                     │── idleBalance += recovered│                        │
    │                     │── deployedPrincipal = 0  │                        │
    │                     │── emit EmergencyWithdrawal(USDC, strategy, recovered)
```

---

## Yield Accounting

### Principle

The vault tracks **principal** (what was sent to the strategy). The strategy tracks **current value** (principal + yield via aToken balance). Yield = current value - principal. Yield is materialized only at harvest time.

### In GrvtVault

```
deployedPrincipal[asset]  — sum of amounts sent via deployToStrategy()
                            minus amounts returned via withdrawFromStrategy()
                            reset to 0 on emergencyWithdraw
```

This number does NOT grow with yield. It represents "what we put in."

### In AaveV3Strategy

```
_principal                — mirrors the vault's view: sum of deploy() calls minus withdraw() calls
totalDeployed()           — aToken.balanceOf(this) — grows in real-time with Aave yield
pendingYield()            — totalDeployed() - _principal (can be 0 due to rounding)
```

### Harvest Mechanics

1. `harvest(recipient)` computes `yield = aToken.balanceOf(this) - _principal`
2. Guard: if `yield == 0`, return 0 (handles rounding where balance <= principal)
3. Call `IPool.withdraw(asset, yield, recipient)` — sends yield directly to `grvtBank`
4. `_principal` is unchanged — the remaining aToken balance still equals the original principal
5. Return `yield` to the vault for event emission

### Why This Works

- aToken `balanceOf` is rebasing — it grows automatically as Aave accrues interest
- Reserve factor is already deducted from `liquidityRate` — no adjustment needed
- Suppliers cannot be liquidated — balance only decreases via explicit `withdraw()` calls
- `balanceOf - principal` is a correct and sufficient yield measure

### Edge Cases

- **Rounding**: Aave rounds by 1 wei on supply/withdraw. Guard `current > principal` before subtraction.
- **Multiple deploys**: `_principal` accumulates correctly across multiple `deploy()` calls.
- **Partial withdraw**: `withdraw(amount)` decreases `_principal` by `actual` (the return value from Aave), keeping the yield delta accurate.
- **Harvest then withdraw**: After harvest, `aToken.balanceOf ≈ _principal`. A subsequent withdraw returns principal correctly.

---

## ETH Handling

### Approach: Auto-wrap to WETH

All native ETH is converted to WETH immediately on entry. Internally, the vault treats WETH as a standard ERC20 asset. The WETH address is used as the asset key in all mappings.

### Entry Point

```solidity
function depositETH() external payable nonReentrant onlyRole(DEPOSITOR_ROLE) whenNotPaused {
    if (msg.value == 0) revert ZeroAmount();
    IWETH(WETH).deposit{value: msg.value}();
    idleBalance[WETH] += msg.value;
    emit Deposited(msg.sender, WETH, msg.value);
}
```

No `receive()` or `fallback()` that accepts arbitrary ETH. The only ETH entry is `depositETH()` with role checks. This prevents accidental ETH sends from corrupting accounting.

Exception: a minimal `receive()` is needed to accept WETH unwrap returns if the vault ever needs to send native ETH out. If not needed Day 1, omit it entirely.

### Why Not WETHGateway

- Adds an external contract dependency and trust surface
- Requires vault to approve the gateway to spend aWETH
- Manual wrapping is one line (`IWETH.deposit{value: amount}()`) and the vault holds aWETH directly
- WETHGateway is designed for EOA users, not contract-to-contract integration

### Strategy Interaction

The AaveV3Strategy receives WETH like any other ERC20. It calls `IPool.supply(WETH, amount, ...)`. Aave returns aWETH. On withdraw, Aave returns WETH. The strategy never handles native ETH.

---

## Modifier / Guard Summary

| Function | `nonReentrant` | `whenNotPaused` | Role | Reason |
|---|---|---|---|---|
| `deposit` | Yes | Yes | DEPOSITOR | Moves tokens in |
| `depositETH` | Yes | Yes | DEPOSITOR | Moves ETH in |
| `deployToStrategy` | Yes | Yes | STRATEGIST | Moves tokens to strategy |
| `withdrawFromStrategy` | Yes | **No** | STRATEGIST | Must work during pause for emergency exit |
| `harvest` | Yes | Yes | STRATEGIST | Moves yield out |
| `emergencyWithdrawFromStrategy` | Yes | **No** | DEFAULT_ADMIN | Must work during pause |
| `pause` | No | No | GUARDIAN | State change only |
| `unpause` | No | No | DEFAULT_ADMIN | State change only |
| `whitelistAsset` | No | No | DEFAULT_ADMIN | Config only |
| `setStrategy` | No | No | DEFAULT_ADMIN | Config only |
| `setGrvtBank` | No | No | DEFAULT_ADMIN | Config only |

---

## Events

```solidity
event Deposited(address indexed depositor, address indexed asset, uint256 amount);
event DeployedToStrategy(address indexed asset, address indexed strategy, uint256 amount);
event WithdrawnFromStrategy(address indexed asset, address indexed strategy, uint256 amount);
event Harvested(address indexed asset, address indexed strategy, uint256 yieldAmount, address recipient);
event EmergencyWithdrawal(address indexed asset, address indexed strategy, uint256 recovered);
event AssetWhitelisted(address indexed asset);
event AssetRemoved(address indexed asset);
event StrategySet(address indexed asset, address indexed strategy);
event StrategyRemoved(address indexed asset, address indexed oldStrategy);
event GrvtBankUpdated(address indexed oldBank, address indexed newBank);
```

---

## Custom Errors

```solidity
error ZeroAmount();
error ZeroAddress();
error AssetNotWhitelisted(address asset);
error AssetAlreadyWhitelisted(address asset);
error StrategyNotSet(address asset);
error StrategyAlreadySet(address asset);
error StrategyStillDeployed(address asset, uint256 remaining);
error StrategyAssetMismatch(address expected, address actual);
error InsufficientIdleBalance(address asset, uint256 available, uint256 requested);
error InsufficientDeployedBalance(address asset, uint256 available, uint256 requested);
error GrvtBankNotSet();
```

```solidity
// AaveV3Strategy
error CallerNotVault(address caller);
error ZeroAmount();
error ZeroAddress();
```

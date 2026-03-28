# Security Patterns Research — GRVT Yield Vault

**Research date**: 2026-03-28
**OpenZeppelin version**: 5.6.1 (verified from `lib/openzeppelin-contracts/CHANGELOG.md`)
**Aave V3**: Core interfaces verified from `lib/aave-v3-core/contracts/interfaces/`
**Solidity target**: 0.8.34

---

## 1. Multi-Tier RBAC Design

### AccessControl vs AccessControlEnumerable

`AccessControl` stores membership as `mapping(bytes32 role => mapping(address => bool))`. Role membership can only be enumerated off-chain by replaying events.

`AccessControlEnumerable` extends it with `EnumerableSet.AddressSet` per role, enabling on-chain queries: `getRoleMember(role, index)`, `getRoleMemberCount(role)`, `getRoleMembers(role)`. Extra cost: ~20,000 gas per `grantRole`/`revokeRole`.

**Recommendation**: Use `AccessControlEnumerable`. On-chain auditability of role holders is worth the marginal cost since fund-moving functions don't call role management.

### DEFAULT_ADMIN_ROLE and AccessControlDefaultAdminRules

`DEFAULT_ADMIN_ROLE = bytes32(0)`. A compromised admin key allows immediate escalation to any role — including STRATEGIST — enabling complete fund drain.

`AccessControlDefaultAdminRules` mitigates this:
- Only one address holds `DEFAULT_ADMIN_ROLE` at any time
- Transfer is 2-step: `beginDefaultAdminTransfer` + `acceptDefaultAdminTransfer`, separated by configurable delay
- During delay, current admin can `cancelDefaultAdminTransfer()`
- Direct `grantRole(DEFAULT_ADMIN_ROLE, ...)` and `revokeRole(DEFAULT_ADMIN_ROLE, ...)` are blocked

**Recommendation**: Use `AccessControlDefaultAdminRules` with `initialDelay` of `1 days`.

### Role Hierarchy — Recommended: Four-Role Separation

```
DEFAULT_ADMIN_ROLE  — configuration, role management, unpause
STRATEGIST_ROLE     — deploy to strategy, withdraw from strategy, harvest
DEPOSITOR_ROLE      — deposit capital into vault (funding wallet only)
GUARDIAN_ROLE       — pause only (emergency stop, no fund access)
```

| Function | Required Role |
|---|---|
| `setStrategy`, `setGrvtBank`, `grantRole`, `revokeRole`, `unpause` | DEFAULT_ADMIN |
| `deposit(asset, amount)`, `depositETH()` | DEPOSITOR |
| `deployToStrategy`, `withdrawFromStrategy`, `harvest` | STRATEGIST |
| `pause()` | GUARDIAN |

**Rationale**: The funding wallet should only push funds in — never call `withdrawFromStrategy` or `harvest`. Compromising the funding wallet allows deposits but not extraction. The GUARDIAN key can be held by automated monitoring — if compromised, worst outcome is a nuisance pause. Unpause requires DEFAULT_ADMIN.

**Constructor pattern**:

```solidity
bytes32 public constant STRATEGIST_ROLE = keccak256("STRATEGIST_ROLE");
bytes32 public constant DEPOSITOR_ROLE  = keccak256("DEPOSITOR_ROLE");
bytes32 public constant GUARDIAN_ROLE   = keccak256("GUARDIAN_ROLE");

constructor(address admin, address strategist, address depositor, address guardian)
    AccessControlDefaultAdminRules(1 days, admin)
{
    _grantRole(STRATEGIST_ROLE, strategist);
    _grantRole(DEPOSITOR_ROLE, depositor);
    _grantRole(GUARDIAN_ROLE, guardian);
}
```

Do NOT call `_setRoleAdmin` to make custom roles admins of each other — alternate admin paths create privilege escalation surfaces.

---

## 2. Reentrancy Protection

### Reentrancy Vectors in This Vault

| Function | External Calls Made | Vector |
|---|---|---|
| `deposit(ERC20)` | `token.safeTransferFrom(...)` | ERC-777 `tokensToSend` hook |
| `deployToStrategy` | `strategy.deploy(...)` | Malicious strategy re-entering vault |
| `withdrawFromStrategy` | `strategy.withdraw(...)` → Aave `withdraw()` | Token arrives before state update |
| `harvest` | strategy call + `token.safeTransfer(grvtBank)` | `grvtBank` re-entering before accounting updated |

### ReentrancyGuard vs ReentrancyGuardTransient

`ReentrancyGuardTransient` (OZ 5.6.1) uses EIP-1153 transient storage (`TSTORE`/`TLOAD`): ~100 gas cheaper, auto-clears at end of transaction. Available on Ethereum mainnet since Cancun (March 2024).

**Recommendation**: Use `ReentrancyGuardTransient` for mainnet.

### Functions Requiring `nonReentrant`

All fund-moving functions: `deposit`, `depositETH`, `deployToStrategy`, `withdrawFromStrategy`, `harvest`.

**Important**: Because `nonReentrant` uses a single global lock, `nonReentrant` functions cannot call each other. Structure all internal logic as `private` helpers.

### Checks-Effects-Interactions Pattern

State must be updated BEFORE external calls:

```solidity
// CHECKS
if (amount == 0) revert ZeroAmount();
uint256 deployed = _deployedBalance[strategy][asset];
if (amount > deployed) revert InsufficientDeployed(deployed, amount);

// EFFECTS — update state before external call
_deployedBalance[strategy][asset] = deployed - amount;
_idleBalance[asset] += amount;

// INTERACTIONS — external call last
IStrategy(strategy).withdraw(asset, amount, address(this));
```

### Aave V3 Reentrancy Analysis

Aave's `supply()` and `withdraw()` do NOT callback into `msg.sender`. For non-ERC777 tokens (USDC, USDT), transfers have no receiver hooks. The primary Aave risk is protocol-level pausing — if a reserve is paused, `supply()`/`withdraw()` will revert. With CEI, a revert rolls back all state changes, preserving accounting.

**Severity if reentrancy guards omitted**: CRITICAL.

---

## 3. Emergency Controls

### Pausable Pattern

```solidity
function pause() external onlyRole(GUARDIAN_ROLE) { _pause(); }
function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) { _unpause(); }
```

GUARDIAN can pause; only DEFAULT_ADMIN can unpause. Compromised GUARDIAN halts operations but cannot prevent recovery.

### Which Functions Are Pausable

Apply `whenNotPaused` to: `deposit`, `depositETH`, `deployToStrategy`, `harvest`.

Do NOT apply `whenNotPaused` to `withdrawFromStrategy`. The emergency withdrawal path must remain open — pulling funds out of external protocols is the primary incident response action.

### Emergency Withdrawal Function

```solidity
function emergencyWithdrawAll(address strategy, address asset)
    external onlyRole(DEFAULT_ADMIN_ROLE)
{
    _deployedBalance[strategy][asset] = 0;
    uint256 received = IStrategy(strategy).emergencyWithdraw(asset, address(this));
    _idleBalance[asset] += received;
    emit EmergencyWithdrawal(strategy, asset, received);
}
```

**Severity if emergency controls omitted**: HIGH.

---

## 4. Token Safety

### SafeERC20

USDT's `transfer` and `approve` don't return a value. Raw `IERC20(token).transfer(...)` reverts at ABI decode for USDT.

```solidity
using SafeERC20 for IERC20;
IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
IERC20(asset).safeTransfer(recipient, amount);
IERC20(asset).forceApprove(spender, amount);
```

### forceApprove for USDT

USDT reverts if `approve` is called when allowance is non-zero and new value is also non-zero. `SafeERC20.forceApprove` handles this (zero-first if needed).

**Rule**: Use `forceApprove` for all approvals. Revoke approval after each Aave supply:

```solidity
IERC20(asset).forceApprove(address(aavePool), amount);
aavePool.supply(asset, amount, address(this), 0);
IERC20(asset).forceApprove(address(aavePool), 0);  // revoke residual
```

### Fee-on-Transfer Token Accounting

Use balance-delta pattern:

```solidity
uint256 balanceBefore = IERC20(asset).balanceOf(address(this));
IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
uint256 received = IERC20(asset).balanceOf(address(this)) - balanceBefore;
_idleBalance[asset] += received;
```

### Token Whitelisting

Maintain `mapping(address => bool) supportedAssets`. Only DEFAULT_ADMIN can modify. Apply `onlySupportedAsset(asset)` modifier to deposit, deploy, and harvest.

---

## 5. Common DeFi Vault Vulnerabilities

### Inflation Attack / First Depositor Attack

**Not applicable.** This vault does not issue shares. Inflation attacks target ERC4626-style vaults with share price mechanisms.

### Sandwich Attack on Harvest

Low practical impact for Aave-based yield. Aave's `aToken.balanceOf` is computed from `scaledBalanceOf * liquidityIndex / RAY` — the index is time-based, not manipulable in a single block without proportional economic cost.

**Mitigation**: Compute yield as `aToken.balanceOf(vault) - recordedPrincipal`. No spot oracle prices in harvest logic.

### Rounding Errors in Yield Calculation

Always guard against rounding causing apparent negative yield:

```solidity
uint256 current = aToken.balanceOf(address(this));
uint256 principal = _deployedBalance[strategy][asset];
if (current <= principal) return;  // no harvestable yield
uint256 yield = current - principal;
```

### Strategy Trust Assumptions

A malicious strategy is a total loss vector. Mitigations:
1. `approvedStrategies` whitelist — only DEFAULT_ADMIN can add
2. Strategies should be immutable (non-proxy) or upgrade authority verified
3. Verify token balance delta after strategy calls
4. `onlyVault` modifier on all strategy external functions

### Missing Validation

All external entry points must validate:
- `address` arguments: revert on `address(0)`
- `uint256` amounts: revert on `0`
- `grvtBank != address(0)` at harvest time
- Strategy in `approvedStrategies` whitelist
- Asset in `supportedAssets` whitelist

### Unchecked Return Values

Aave's `withdraw()` returns `uint256 finalAmount`. Verify it:

```solidity
uint256 received = aavePool.withdraw(asset, amount, address(this));
if (received < amount) revert AaveWithdrawShortfall(amount, received);
```

**Severity**: HIGH for unchecked Aave withdraw return value.

---

## 6. Access Control for Fund Flows

### Fund Flow Matrix

| Flow | From | To | Authorized Role |
|---|---|---|---|
| Capital enters vault | Funding wallet | Vault idle | DEPOSITOR_ROLE |
| Capital to strategy | Vault idle | Strategy / Aave | STRATEGIST_ROLE |
| Capital from strategy | Strategy / Aave | Vault idle | STRATEGIST_ROLE |
| Yield to bank | Strategy / Aave | `grvtBank` | STRATEGIST_ROLE |
| Emergency exit | Strategy / Aave | Vault idle | DEFAULT_ADMIN_ROLE |

### onlyVault on Strategy Contracts

Strategy contracts must restrict all external entry points to the vault address:

```solidity
contract AaveStrategy is IStrategy {
    address public immutable vault;

    error CallerNotVault(address caller);

    modifier onlyVault() {
        if (msg.sender != vault) revert CallerNotVault(msg.sender);
        _;
    }

    function deploy(...) external onlyVault { ... }
    function withdraw(...) external onlyVault { ... }
    function harvest(...) external onlyVault returns (uint256) { ... }
    function emergencyWithdraw(...) external onlyVault returns (uint256) { ... }
}
```

**Severity if `onlyVault` omitted**: CRITICAL. Any account can call strategy functions directly, bypassing all vault-level RBAC.

---

## Summary by Severity

| Finding | Severity | Mitigation |
|---|---|---|
| Strategy lacks `onlyVault` on external functions | CRITICAL | `onlyVault` modifier on all strategy entry points |
| No reentrancy guard on fund-moving functions | CRITICAL | `nonReentrant` on deposit, deploy, withdraw, harvest |
| Broken CEI pattern | HIGH | State updates before every external call |
| Raw `approve()` for USDT | HIGH | `SafeERC20.forceApprove()` throughout |
| No `SafeERC20` wrapping | HIGH | `using SafeERC20 for IERC20` throughout |
| `DEFAULT_ADMIN_ROLE` without transfer delay | HIGH | `AccessControlDefaultAdminRules(1 days, admin)` |
| Unchecked Aave `withdraw()` return value | HIGH | Verify `received >= amount` |
| No pause mechanism | HIGH | `Pausable`; GUARDIAN pauses, DEFAULT_ADMIN unpauses |
| No emergency withdrawal function | HIGH | `emergencyWithdrawAll` callable by DEFAULT_ADMIN |
| No strategy whitelist | HIGH | `approvedStrategies` mapping; only DEFAULT_ADMIN modifies |
| Missing zero-address / zero-amount validation | MEDIUM | Validate all inputs at entry |
| No fee-on-transfer balance-delta accounting | MEDIUM | `balanceBefore`/`balanceAfter` in deposits |
| Rounding underflow in yield delta | MEDIUM | Guard `current > principal` before subtraction |
| No supported-asset whitelist | MEDIUM | `supportedAssets` mapping; only DEFAULT_ADMIN modifies |
| `AccessControl` instead of `AccessControlEnumerable` | LOW | Use Enumerable for on-chain role auditability |
| Residual Aave allowance after supply | LOW | `forceApprove(aavePool, 0)` after each supply |

---

## Key OpenZeppelin Contract References (v5.6.1)

| Contract | Path | Purpose |
|---|---|---|
| `AccessControlEnumerable` | `access/extensions/AccessControlEnumerable.sol` | Role management with on-chain enumeration |
| `AccessControlDefaultAdminRules` | `access/extensions/AccessControlDefaultAdminRules.sol` | Protected admin transfer with delay |
| `ReentrancyGuardTransient` | `utils/ReentrancyGuardTransient.sol` | Reentrancy lock via EIP-1153 (preferred) |
| `ReentrancyGuard` | `utils/ReentrancyGuard.sol` | Reentrancy lock via storage (fallback) |
| `Pausable` | `utils/Pausable.sol` | Emergency stop mechanism |
| `SafeERC20` | `token/ERC20/utils/SafeERC20.sol` | Safe token operations; `forceApprove` for USDT |

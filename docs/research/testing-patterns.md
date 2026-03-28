# Testing Patterns for the GRVT Yield Vault

Research for Foundry testing patterns — treasury vault integrating with Aave V3.
Sources: `lib/forge-std/`, `lib/aave-v3-core/`, `lib/openzeppelin-contracts/`.

---

## 1. Foundry Fork Testing

### How Fork Tests Work

**Mode A — CLI flag (simplest):**
```bash
forge test --fork-url $ETH_RPC_URL -vvv
```

**Mode B — In-test fork creation (preferred):**
```solidity
vm.createSelectFork(vm.envString("ETH_RPC_URL"), FORK_BLOCK);
```
Only tests that explicitly select a fork run against mainnet state. Non-fork unit tests remain fast.

### Block Pinning for Determinism

Always pin to a specific block number:

```solidity
uint256 internal constant FORK_BLOCK = 21_900_000; // Ethereum mainnet
```

Choose a block where Aave V3 USDC/USDT/WETH markets are active and have positive supply APY.

### RPC URL as Environment Variable

Never hardcode RPC URLs:
```solidity
string memory rpcUrl = vm.envString("ETH_RPC_URL");
```

For `foundry.toml`:
```toml
[rpc_endpoints]
mainnet = "${ETH_RPC_URL}"
```

### Fork Test Performance

- **Pin to a fixed block** — Foundry caches fetched state between runs
- **Separate fork tests** — Allows `forge test --no-match-path "test/fork/*"` for fast iteration
- **Avoid `vm.roll()` mid-test** — Rolling invalidates cache

---

## 2. Test Organization

### Recommended File Structure

```
test/
├── base/
│   └── VaultTestBase.sol        # Abstract base: fork setup, deploy, fund wallets
├── unit/
│   ├── VaultAccessControl.t.sol # Role checks — no fork needed
│   └── VaultUnit.t.sol          # Pure logic tests
├── integration/
│   ├── VaultDeposit.t.sol       # Deposit flows against forked mainnet
│   ├── VaultStrategy.t.sol      # Deploy/withdraw against real Aave V3
│   ├── VaultHarvest.t.sol       # Yield accrual and harvest
│   └── VaultTVL.t.sol           # TVL reporting accuracy
└── invariant/
    └── VaultInvariant.t.sol     # total assets >= sum of tracked principals
```

### Naming Convention

```
test_{action}_{condition}_{expectedOutcome}
```

Examples:
- `test_deposit_usdc_increasesIdleBalance`
- `test_deploy_revertsIfCallerLacksOperatorRole`
- `test_harvest_sendYieldToGrvtBank`

---

## 3. Base Test Contract

```solidity
abstract contract VaultTestBase is Test {
    // Mainnet addresses
    address internal constant AAVE_V3_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant AUSDC = 0x98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c;

    uint256 internal constant FORK_BLOCK = 21_900_000;

    // Test actors
    address internal admin;
    address internal operator;
    address internal fundingWallet;
    address internal grvtBank;
    address internal stranger;

    function setUp() public virtual {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"), FORK_BLOCK);

        admin         = makeAddr("admin");
        operator      = makeAddr("operator");
        fundingWallet = makeAddr("fundingWallet");
        grvtBank      = makeAddr("grvtBank");
        stranger      = makeAddr("stranger");

        vm.label(AAVE_V3_POOL, "AaveV3Pool");
        vm.label(USDC, "USDC");
        vm.label(USDT, "USDT");
        vm.label(WETH, "WETH");

        // Deploy contracts, grant roles, fund wallets in subclass
    }

    function _fundWallet(address to, address token, uint256 amount) internal {
        deal(token, to, amount);
    }

    function _skipTime(uint256 seconds_) internal {
        vm.warp(block.timestamp + seconds_);
        vm.roll(block.number + seconds_ / 12);
    }
}
```

### Why `makeAddr()` Instead of Hardcoded Addresses

`makeAddr("label")` derives a deterministic address from the label string and automatically calls `vm.label()`. Avoids collisions with real mainnet contracts.

---

## 4. Token Setup with `deal()`

### Standard Usage

```solidity
deal(USDC, fundingWallet, 1_000_000e6); // 1M USDC (6 decimals)
deal(USDT, fundingWallet, 1_000_000e6); // 1M USDT (6 decimals)
deal(WETH, fundingWallet, 500e18);      // 500 WETH
vm.deal(fundingWallet, 1_000 ether);    // 1000 native ETH
```

### USDC/USDT Proxy Storage Slot Issue

If `deal()` fails for proxy tokens, use whale transfer fallback:

```solidity
function _fundViaWhale(address token, address to, uint256 amount) internal {
    address whale = _getWhale(token);
    vm.prank(whale);
    IERC20(token).transfer(to, amount);
}
```

**Recommendation:** Try `deal()` first. Fall back to whale if storage slot fails.

---

## 5. Time Simulation for Yield

### Aave V3 Interest Model

- Supply-side yield uses **compounded interest** (time-based, not block-based)
- `currentLiquidityRate` is stored in ray (1e27)
- Interest measured in **seconds** relative to `lastUpdateTimestamp`
- `SECONDS_PER_YEAR = 365 days = 31_536_000`

Because Aave depends only on time, **`vm.warp()` alone is sufficient**:

```solidity
vm.warp(block.timestamp + 30 days);
uint256 currentBalance = IERC20(AUSDC).balanceOf(address(strategy));
assertGt(currentBalance, depositedAmount);
```

### How Much Time Produces Measurable Yield

For USDC at typical 2–8% APY:
- **1 day**: ~0.005–0.02% — barely detectable
- **7 days**: ~0.04–0.15% — detectable with 1M+ USDC
- **30 days**: ~0.17–0.65% — clearly detectable (recommended)
- **365 days**: ~2–8% — full annual yield

For 1,000,000 USDC at 5% APY, 30 days ≈ 4,110 USDC yield.

---

## 6. Yield Accounting Test Approaches

### Recommended: Simple Balance Comparison

```solidity
uint256 principal = 1_000_000e6;
strategy.deploy(USDC, principal);
uint256 snapshot = IERC20(AUSDC).balanceOf(address(strategy));

vm.warp(block.timestamp + 30 days);

uint256 currentBalance = IERC20(AUSDC).balanceOf(address(strategy));
uint256 yield = currentBalance - snapshot;
assertGt(yield, 0);
```

### Tolerance for Aave Rounding

aTokens round by 1 wei on supply/withdraw. Never assert exact equality:

```solidity
assertApproxEqAbs(actualYield, expectedYield, 2, "yield mismatch");
```

---

## 7. Test Helpers and Cheatcodes

### `vm.prank(address)` / `vm.startPrank(address)`

```solidity
vm.prank(operator);
vault.deployToStrategy(USDC, 500_000e6);

vm.startPrank(fundingWallet);
IERC20(USDC).approve(address(vault), type(uint256).max);
vault.deposit(USDC, 1_000_000e6);
vm.stopPrank();
```

### `vm.expectRevert()`

For custom errors:
```solidity
vm.expectRevert(GrvtVault.UnauthorizedCaller.selector);
vm.prank(stranger);
vault.deployToStrategy(USDC, 500_000e6);
```

For OZ AccessControl:
```solidity
vm.expectRevert(
    abi.encodeWithSelector(
        IAccessControl.AccessControlUnauthorizedAccount.selector,
        stranger,
        vault.OPERATOR_ROLE()
    )
);
```

### `vm.expectEmit()`

```solidity
vm.expectEmit(address(vault));
emit GrvtVault.Deposited(fundingWallet, USDC, 1_000_000e6);
vm.prank(fundingWallet);
vault.deposit(USDC, 1_000_000e6);
```

### `bound()` for Fuzz Tests

```solidity
function testFuzz_deposit_anyAmount(uint256 amount) public {
    amount = bound(amount, 1e6, 10_000_000e6);
    deal(USDC, fundingWallet, amount);
    vm.prank(fundingWallet);
    vault.deposit(USDC, amount);
    assertEq(vault.idleBalance(USDC), amount);
}
```

### `assertApproxEqAbs` / `assertApproxEqRel`

```solidity
assertApproxEqAbs(actualYield, expectedYield, 10, "off by >10 wei");
assertApproxEqRel(actualYield, expectedYield, 1e16, "off by >1bps");
```

---

## 8. Access Control Tests

### The Requirement

From requirements: "Tests should not only cover the happy path... privileged actions are appropriately restricted."

For every privileged function, test with unauthorized callers and assert revert.

### Role × Function Matrix

| Function | Authorized Role | Must-Fail Callers |
|---|---|---|
| `deposit()` | DEPOSITOR/FUNDING | stranger, operator, admin |
| `deployToStrategy()` | OPERATOR_ROLE | stranger, fundingWallet |
| `withdrawFromStrategy()` | OPERATOR_ROLE | stranger, fundingWallet |
| `harvest()` | OPERATOR_ROLE | stranger, fundingWallet |
| `setStrategy()` | MANAGER/ADMIN | stranger, operator |
| `whitelistAsset()` | MANAGER/ADMIN | stranger, operator |
| `grantRole()` | DEFAULT_ADMIN | stranger, operator |

### Testing Role Grant/Revoke

```solidity
function test_revokeRole_operatorLosesAccess() public {
    vm.prank(admin);
    vault.revokeRole(vault.OPERATOR_ROLE(), operator);

    vm.expectRevert(/* AccessControlUnauthorizedAccount */);
    vm.prank(operator);
    vault.deployToStrategy(USDC, 1e6);
}
```

---

## 9. Key Test Scenarios

### Deposit Tests
- Happy path: USDC, USDT, ETH deposits increase idle balance
- Negative: unsupported asset, zero amount, unauthorized caller
- Fuzz: arbitrary amounts within bounds

### Strategy Deploy Tests
- Deploy moves assets to Aave, idle decreases, deployed increases
- Over-deploy reverts (insufficient idle)
- Double deploy accumulates correctly

### Withdraw Tests
- Partial and full withdrawal from strategy
- `type(uint256).max` for full withdrawal
- TVL consistency after withdraw

### Yield/Harvest Tests (require fork + time warp)
```solidity
function test_harvest_sendYieldToGrvtBank() public {
    _depositUsdc(1_000_000e6);
    vm.prank(operator);
    vault.deployToStrategy(USDC, 1_000_000e6);

    vm.warp(block.timestamp + 30 days);

    uint256 grvtBankBefore = IERC20(USDC).balanceOf(grvtBank);
    vm.prank(operator);
    vault.harvest(USDC);
    uint256 harvested = IERC20(USDC).balanceOf(grvtBank) - grvtBankBefore;

    assertGt(harvested, 0, "no yield harvested");
}

function test_harvest_preservesPrincipal() public {
    _depositAndDeploy(1_000_000e6);
    vm.warp(block.timestamp + 365 days);
    vm.prank(operator);
    vault.harvest(USDC);
    assertGe(vault.deployedBalance(USDC), 1_000_000e6 - 2);
}
```

### TVL Tests
- Idle only before deploy
- `total == idle + deployed` at all states
- TVL grows with yield over time

### Edge Cases
- Deploy more than idle (revert)
- Withdraw more than deployed (revert)
- Harvest with zero yield (no-op)
- Double harvest: second only gets new yield

---

## 10. Event Testing

Every state-changing function must emit an event. Test with `vm.expectEmit()`:

```solidity
function test_deposit_emitsEvent() public {
    deal(USDC, fundingWallet, 1_000_000e6);
    vm.startPrank(fundingWallet);
    IERC20(USDC).approve(address(vault), 1_000_000e6);

    vm.expectEmit(address(vault));
    emit GrvtVault.Deposited(fundingWallet, USDC, 1_000_000e6);
    vault.deposit(USDC, 1_000_000e6);
    vm.stopPrank();
}
```

---

## 11. `foundry.toml` Configuration

```toml
[profile.default]
src = "src"
out = "out"
libs = ["lib"]
solc_version = "0.8.34"
fuzz_runs = 256

[profile.ci]
fuzz_runs = 1000

[rpc_endpoints]
mainnet = "${ETH_RPC_URL}"
```

---

## 12. Known Pitfalls

1. **`deal()` for USDC on fork may fail** — USDC uses non-standard proxy; use whale transfer fallback
2. **aToken balance off-by-one** — Aave rounds 1 wei on supply; always use `assertApproxEqAbs(..., 2)`
3. **`vm.warp()` does not advance `block.number`** — Aave only uses `block.timestamp`, so `vm.warp()` alone suffices
4. **`vm.expectRevert()` placement** — must be immediately before the reverting call
5. **Aave V3 supply caps** — verify cap has headroom at pinned block
6. **USDT `approve()` requires zero-first** — use `SafeERC20.forceApprove()` in vault; in tests use `approve(0)` then `approve(amount)` if manual
7. **Fork caching** — requires consistent RPC; switching providers invalidates cache

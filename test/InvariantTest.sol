// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GrvtVault} from "../src/GrvtVault.sol";
import {AaveV3Strategy} from "../src/strategies/AaveV3Strategy.sol";

/// @title VaultHandler
/// @notice Stateful handler for invariant fuzzing — calls vault operations in random order
contract VaultHandler is Test {
    GrvtVault public vault;
    AaveV3Strategy public strategy;
    address public asset;
    address public depositor;
    address public strategist;
    address public grvtBank;

    uint256 public totalDeposited;
    uint256 public totalWithdrawn;

    // Track ghost variables for invariant checks
    uint256 public depositCount;
    uint256 public deployCount;
    uint256 public withdrawIdleCount;
    uint256 public withdrawStrategyCount;
    uint256 public harvestCount;

    constructor(
        GrvtVault _vault,
        AaveV3Strategy _strategy,
        address _asset,
        address _depositor,
        address _strategist,
        address _grvtBank
    ) {
        vault = _vault;
        strategy = _strategy;
        asset = _asset;
        depositor = _depositor;
        strategist = _strategist;
        grvtBank = _grvtBank;
    }

    function deposit(uint256 amount) external {
        // Minimum 100 USDC to avoid Aave rounding issues with tiny amounts
        amount = bound(amount, 100e6, 10_000_000e6);

        deal(asset, depositor, amount);
        vm.startPrank(depositor);
        IERC20(asset).approve(address(vault), amount);
        vault.deposit(asset, amount);
        vm.stopPrank();

        totalDeposited += amount;
        depositCount++;
    }

    function deployToStrategy(uint256 amount) external {
        uint256 idle = vault.idleBalance(asset);
        if (idle < 1e6) return; // Skip tiny deploys that Aave rounds to 0

        amount = bound(amount, 1e6, idle);

        vm.prank(strategist);
        vault.deployToStrategy(asset, amount);
        deployCount++;
    }

    function withdrawIdle(uint256 amount) external {
        uint256 idle = vault.idleBalance(asset);
        if (idle == 0) return;

        amount = bound(amount, 1, idle);
        address recipient = address(0xBEEF);

        vm.prank(strategist);
        vault.withdraw(asset, amount, recipient);

        totalWithdrawn += amount;
        withdrawIdleCount++;
    }

    function withdrawFromStrategy(uint256 amount) external {
        uint256 principal = vault.deployedPrincipal(asset);
        if (principal == 0) return;

        amount = bound(amount, 1, principal);

        vm.prank(strategist);
        vault.withdrawFromStrategy(asset, amount);
        withdrawStrategyCount++;
    }

    function harvest() external {
        uint256 principal = vault.deployedPrincipal(asset);
        if (principal == 0) return;

        // Warp forward to accrue some yield
        vm.warp(block.timestamp + 7 days);
        vm.roll(block.number + 50_400);

        // Harvest may revert with NoYieldAvailable if yield is tiny — catch it
        vm.prank(strategist);
        try vault.harvest(asset) {
            harvestCount++;
        } catch {}
    }
}

/// @title InvariantTest
/// @notice Stateful fuzz test asserting accounting invariants hold regardless of call ordering.
/// @dev Requires a high-rate-limit RPC (e.g. Alchemy/Infura) via ETH_RPC_URL.
///      Free RPCs will 429 during invariant setup due to Foundry's address exploration.
contract InvariantTest is Test {
    // Mainnet addresses
    address public constant AAVE_V3_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    GrvtVault public vault;
    AaveV3Strategy public strategy;
    VaultHandler public handler;

    address public admin;
    address public strategist;
    address public depositor;
    address public guardian;
    address public grvtBank;

    function setUp() public {
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", string("https://eth.llamarpc.com")));

        admin = makeAddr("admin");
        strategist = makeAddr("strategist");
        depositor = makeAddr("depositor");
        guardian = makeAddr("guardian");
        grvtBank = makeAddr("grvtBank");

        vm.prank(admin);
        vault = new GrvtVault(admin, WETH, grvtBank);

        strategy = new AaveV3Strategy(address(vault), AAVE_V3_POOL, USDC);

        vm.startPrank(admin);
        vault.grantRole(vault.STRATEGIST_ROLE(), strategist);
        vault.grantRole(vault.DEPOSITOR_ROLE(), depositor);
        vault.grantRole(vault.GUARDIAN_ROLE(), guardian);
        vault.whitelistAsset(USDC);
        vault.setStrategy(USDC, address(strategy));
        vm.stopPrank();

        handler = new VaultHandler(vault, strategy, USDC, depositor, strategist, grvtBank);

        // Only target the handler for invariant calls
        targetContract(address(handler));
    }

    /// @notice Vault's actual token balance must be >= tracked idle balance
    function invariant_vaultBalanceCoversIdle() public view {
        uint256 vaultBalance = IERC20(USDC).balanceOf(address(vault));
        uint256 idle = vault.idleBalance(USDC);
        assertGe(vaultBalance, idle, "vault token balance must cover idle balance");
    }

    /// @notice Strategy's totalDeployed must be >= vault's deployedPrincipal (yield can only increase)
    ///         Allow small tolerance for Aave supply/withdraw rounding (up to 2 wei per operation)
    function invariant_strategyCoversDeployedPrincipal() public view {
        uint256 deployed = strategy.totalDeployed();
        uint256 principal = vault.deployedPrincipal(USDC);
        uint256 totalOps = handler.deployCount() + handler.withdrawStrategyCount() + handler.harvestCount();
        uint256 tolerance = totalOps * 2 + 2;
        assertGe(deployed + tolerance, principal, "strategy totalDeployed must cover deployedPrincipal (within rounding)");
    }

    /// @notice Accounting identity: idle + principal <= totalDeposited - totalWithdrawn
    ///         (can be < due to Aave rounding on withdrawals)
    function invariant_accountingIdentity() public view {
        uint256 idle = vault.idleBalance(USDC);
        uint256 principal = vault.deployedPrincipal(USDC);
        uint256 deposited = handler.totalDeposited();
        uint256 withdrawn = handler.totalWithdrawn();

        // Allow small rounding tolerance (2 wei per operation)
        uint256 totalOps = handler.depositCount() + handler.deployCount()
            + handler.withdrawIdleCount() + handler.withdrawStrategyCount()
            + handler.harvestCount();
        uint256 tolerance = totalOps * 2 + 1;

        assertLe(
            idle + principal,
            deposited - withdrawn + tolerance,
            "idle + principal must not exceed net deposits (with rounding tolerance)"
        );
    }
}

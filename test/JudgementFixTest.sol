// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {BaseTest} from "./BaseTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {GrvtVault} from "../src/GrvtVault.sol";
import {AaveV3Strategy} from "../src/strategies/AaveV3Strategy.sol";

/// @title JudgementFixTest
/// @notice Tests for fixes addressing challenge judgement findings (M-01, M-02, L-01, L-03)
///         and fuzz tests for deposit/deploy/withdraw ratios
contract JudgementFixTest is BaseTest {
    // =========================================================================
    // M-01: withdraw() for idle funds
    // =========================================================================

    function test_withdraw_succeeds_when_idleFundsAvailable() public {
        _depositUSDC(1_000_000e6);

        address recipient = makeAddr("treasury");
        vm.prank(strategist);
        vault.withdraw(USDC, 500_000e6, recipient);

        assertEq(vault.idleBalance(USDC), 500_000e6, "idle should decrease by withdrawn amount");
        assertEq(IERC20(USDC).balanceOf(recipient), 500_000e6, "recipient should receive funds");
    }

    function test_withdraw_succeeds_when_withdrawingAll() public {
        _depositUSDC(1_000_000e6);

        address recipient = makeAddr("treasury");
        vm.prank(strategist);
        vault.withdraw(USDC, 1_000_000e6, recipient);

        assertEq(vault.idleBalance(USDC), 0, "idle should be zero");
        assertEq(IERC20(USDC).balanceOf(recipient), 1_000_000e6, "recipient should receive all");
    }

    function test_withdraw_revertsWhen_insufficientIdle() public {
        _depositUSDC(1_000e6);

        vm.prank(strategist);
        vm.expectRevert(
            abi.encodeWithSelector(GrvtVault.InsufficientIdleBalance.selector, USDC, 1_000e6, 2_000e6)
        );
        vault.withdraw(USDC, 2_000e6, makeAddr("recipient"));
    }

    function test_withdraw_revertsWhen_zeroAmount() public {
        vm.prank(strategist);
        vm.expectRevert(GrvtVault.ZeroAmount.selector);
        vault.withdraw(USDC, 0, makeAddr("recipient"));
    }

    function test_withdraw_revertsWhen_zeroRecipient() public {
        _depositUSDC(1_000e6);
        vm.prank(strategist);
        vm.expectRevert(GrvtVault.ZeroAddress.selector);
        vault.withdraw(USDC, 1_000e6, address(0));
    }

    function test_withdraw_revertsWhen_callerLacksStrategistRole() public {
        _depositUSDC(1_000e6);
        bytes32 role = vault.STRATEGIST_ROLE();
        vm.prank(randomUser);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, randomUser, role)
        );
        vault.withdraw(USDC, 1_000e6, makeAddr("recipient"));
    }

    function test_withdraw_revertsWhen_assetNotWhitelisted() public {
        address fakeToken = makeAddr("fakeToken");
        vm.prank(strategist);
        vm.expectRevert(abi.encodeWithSelector(GrvtVault.AssetNotWhitelisted.selector, fakeToken));
        vault.withdraw(fakeToken, 1_000e6, makeAddr("recipient"));
    }

    // =========================================================================
    // M-02: deployedPrincipal syncs after harvest
    // =========================================================================

    function test_harvest_syncsDeployedPrincipal() public {
        _depositUSDC(1_000_000e6);
        vm.prank(strategist);
        vault.deployToStrategy(USDC, 1_000_000e6);

        // Warp 1 year for yield
        vm.warp(block.timestamp + 365 days);
        vm.roll(block.number + 2_600_000);

        uint256 principalBefore = vault.deployedPrincipal(USDC);
        uint256 strategyTotalBefore = usdcStrategy.totalDeployed();

        // Yield should exist
        assertGt(strategyTotalBefore, principalBefore, "yield should have accrued");

        vm.prank(strategist);
        vault.harvest(USDC);

        // After harvest, deployedPrincipal should match strategy's totalDeployed
        uint256 principalAfter = vault.deployedPrincipal(USDC);
        uint256 strategyTotalAfter = usdcStrategy.totalDeployed();

        assertEq(principalAfter, strategyTotalAfter, "vault principal should match strategy totalDeployed");
        // Principal should be approximately the original (yield was removed, principal stays)
        assertApproxEqAbs(principalAfter, 1_000_000e6, 2, "principal should be ~original amount");
    }

    // =========================================================================
    // L-01: removeAsset reverts with non-zero idle balance
    // =========================================================================

    function test_removeAsset_revertsWhen_idleBalanceNotZero() public {
        // Deposit into USDT (no strategy set)
        deal(USDT, depositor, 1_000e6);
        vm.startPrank(depositor);
        (bool success,) = USDT.call(abi.encodeWithSignature("approve(address,uint256)", address(vault), 1_000e6));
        require(success, "approve failed");
        vault.deposit(USDT, 1_000e6);
        vm.stopPrank();

        // USDT has no strategy, so we can try removeAsset — but idle balance > 0
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(GrvtVault.IdleBalanceNotZero.selector, USDT, 1_000e6)
        );
        vault.removeAsset(USDT);
    }

    function test_removeAsset_succeeds_when_idleBalanceIsZero() public {
        // USDT has no strategy and no deposits — idle is 0
        vm.prank(admin);
        vault.removeAsset(USDT);

        assertFalse(vault.whitelistedAssets(USDT), "USDT should no longer be whitelisted");
    }

    // =========================================================================
    // L-03: migrateStrategy
    // =========================================================================

    function test_migrateStrategy_succeeds_withDeployedFunds() public {
        _depositUSDC(1_000_000e6);
        vm.prank(strategist);
        vault.deployToStrategy(USDC, 1_000_000e6);

        // Deploy a new strategy
        AaveV3Strategy newStrategy = new AaveV3Strategy(address(vault), AAVE_V3_POOL, USDC);

        uint256 idleBefore = vault.idleBalance(USDC);

        vm.prank(admin);
        vault.migrateStrategy(USDC, address(newStrategy));

        // Old strategy should be replaced
        assertEq(vault.assetStrategy(USDC), address(newStrategy), "strategy should be new one");
        // Deployed principal should be zero (funds moved to idle)
        assertEq(vault.deployedPrincipal(USDC), 0, "deployed principal should be zero after migration");
        // Idle should have recovered the funds
        assertApproxEqAbs(vault.idleBalance(USDC), idleBefore + 1_000_000e6, 2, "idle should recover funds");
    }

    function test_migrateStrategy_succeeds_withNoDeployedFunds() public {
        // No deposits, just migrate strategy
        AaveV3Strategy newStrategy = new AaveV3Strategy(address(vault), AAVE_V3_POOL, USDC);

        vm.prank(admin);
        vault.migrateStrategy(USDC, address(newStrategy));

        assertEq(vault.assetStrategy(USDC), address(newStrategy), "strategy should be new one");
    }

    function test_migrateStrategy_revertsWhen_noStrategySet() public {
        AaveV3Strategy newStrategy = new AaveV3Strategy(address(vault), AAVE_V3_POOL, USDT);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(GrvtVault.StrategyNotSet.selector, USDT));
        vault.migrateStrategy(USDT, address(newStrategy));
    }

    function test_migrateStrategy_revertsWhen_callerLacksAdminRole() public {
        AaveV3Strategy newStrategy = new AaveV3Strategy(address(vault), AAVE_V3_POOL, USDC);
        bytes32 role = vault.DEFAULT_ADMIN_ROLE();

        vm.prank(randomUser);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, randomUser, role)
        );
        vault.migrateStrategy(USDC, address(newStrategy));
    }

    function test_migrateStrategy_revertsWhen_assetMismatch() public {
        AaveV3Strategy wrongStrategy = new AaveV3Strategy(address(vault), AAVE_V3_POOL, WETH);

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(GrvtVault.StrategyAssetMismatch.selector, USDC, WETH)
        );
        vault.migrateStrategy(USDC, address(wrongStrategy));
    }

    // =========================================================================
    // Fuzz Tests
    // =========================================================================

    function testFuzz_deposit_and_withdraw_idle(uint256 depositAmt, uint256 withdrawAmt) public {
        // Bound to reasonable USDC amounts (1 to 100M USDC)
        depositAmt = bound(depositAmt, 1, 100_000_000e6);
        withdrawAmt = bound(withdrawAmt, 1, depositAmt);

        deal(USDC, depositor, depositAmt);
        vm.startPrank(depositor);
        IERC20(USDC).approve(address(vault), depositAmt);
        vault.deposit(USDC, depositAmt);
        vm.stopPrank();

        assertEq(vault.idleBalance(USDC), depositAmt, "idle should match deposit");

        address recipient = makeAddr("fuzzRecipient");
        vm.prank(strategist);
        vault.withdraw(USDC, withdrawAmt, recipient);

        assertEq(vault.idleBalance(USDC), depositAmt - withdrawAmt, "idle should decrease");
        assertEq(IERC20(USDC).balanceOf(recipient), withdrawAmt, "recipient should receive");
    }

    function testFuzz_deploy_and_withdraw_ratio(uint256 depositAmt, uint256 deployAmt) public {
        // Bound to reasonable USDC amounts
        depositAmt = bound(depositAmt, 1e6, 10_000_000e6);
        deployAmt = bound(deployAmt, 1e6, depositAmt);

        deal(USDC, depositor, depositAmt);
        vm.startPrank(depositor);
        IERC20(USDC).approve(address(vault), depositAmt);
        vault.deposit(USDC, depositAmt);
        vm.stopPrank();

        vm.prank(strategist);
        vault.deployToStrategy(USDC, deployAmt);

        assertEq(vault.idleBalance(USDC), depositAmt - deployAmt, "idle should be remainder");
        assertEq(vault.deployedPrincipal(USDC), deployAmt, "principal should match deployed");

        // Withdraw all from strategy
        vm.prank(strategist);
        vault.withdrawFromStrategy(USDC, type(uint256).max);

        assertEq(vault.deployedPrincipal(USDC), 0, "principal should be zero after full withdraw");
        // Aave rounding may cause ±1 wei difference
        assertApproxEqAbs(vault.idleBalance(USDC), depositAmt, 2, "idle should recover ~full deposit");
    }
}

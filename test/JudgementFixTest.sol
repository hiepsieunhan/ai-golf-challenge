// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {BaseTest} from "./BaseTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {GrvtVault} from "../src/GrvtVault.sol";
import {AaveV3Strategy} from "../src/strategies/AaveV3Strategy.sol";

/// @title JudgementFixTest
/// @notice Tests for fixes addressing challenge judgement findings (M-01, M-02, L-01, L-03),
///         fuzz tests, multi-step integration, repeated harvest, and invariant tests
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

    function test_withdraw_revertsWhen_paused() public {
        _depositUSDC(1_000e6);

        vm.prank(guardian);
        vault.pause();

        vm.prank(strategist);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.withdraw(USDC, 1_000e6, makeAddr("recipient"));
    }

    // =========================================================================
    // emergencyWithdrawIdle (admin-only, works while paused)
    // =========================================================================

    function test_emergencyWithdrawIdle_succeeds_when_paused() public {
        _depositUSDC(1_000_000e6);

        vm.prank(guardian);
        vault.pause();

        address recipient = makeAddr("treasury");
        vm.prank(admin);
        vault.emergencyWithdrawIdle(USDC, recipient);

        assertEq(vault.idleBalance(USDC), 0, "idle should be zero");
        assertEq(IERC20(USDC).balanceOf(recipient), 1_000_000e6, "recipient should receive all");
    }

    function test_emergencyWithdrawIdle_succeeds_when_notPaused() public {
        _depositUSDC(500_000e6);

        address recipient = makeAddr("treasury");
        vm.prank(admin);
        vault.emergencyWithdrawIdle(USDC, recipient);

        assertEq(vault.idleBalance(USDC), 0, "idle should be zero");
        assertEq(IERC20(USDC).balanceOf(recipient), 500_000e6, "recipient should receive all");
    }

    function test_emergencyWithdrawIdle_revertsWhen_callerLacksAdminRole() public {
        _depositUSDC(1_000e6);
        bytes32 role = vault.DEFAULT_ADMIN_ROLE();
        vm.prank(strategist);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, strategist, role)
        );
        vault.emergencyWithdrawIdle(USDC, makeAddr("recipient"));
    }

    function test_emergencyWithdrawIdle_revertsWhen_zeroBalance() public {
        vm.prank(admin);
        vm.expectRevert(GrvtVault.ZeroAmount.selector);
        vault.emergencyWithdrawIdle(USDC, makeAddr("recipient"));
    }

    function test_emergencyWithdrawIdle_revertsWhen_zeroRecipient() public {
        _depositUSDC(1_000e6);
        vm.prank(admin);
        vm.expectRevert(GrvtVault.ZeroAddress.selector);
        vault.emergencyWithdrawIdle(USDC, address(0));
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
    // Repeated harvest cycles (rounding drift check)
    // =========================================================================

    function test_repeatedHarvest_noDrift() public {
        _depositUSDC(1_000_000e6);
        vm.prank(strategist);
        vault.deployToStrategy(USDC, 1_000_000e6);

        uint256 initialPrincipal = vault.deployedPrincipal(USDC);

        // 10 harvest cycles, 30 days apart
        for (uint256 i; i < 10; ++i) {
            vm.warp(block.timestamp + 30 days);
            vm.roll(block.number + 216_000);

            vm.prank(strategist);
            vault.harvest(USDC);

            // deployedPrincipal should stay close to initial — no drift accumulation
            uint256 currentPrincipal = vault.deployedPrincipal(USDC);
            uint256 strategyTotal = usdcStrategy.totalDeployed();

            // Principal must exactly match strategy's reported total after harvest
            assertEq(currentPrincipal, strategyTotal, "principal must match strategy after each harvest");
            // Should not drift more than 10 wei from initial over 10 cycles
            assertApproxEqAbs(currentPrincipal, initialPrincipal, 10, "principal should not drift significantly");
        }

        // Final: grvtBank should have received yield from all 10 harvests
        assertGt(IERC20(USDC).balanceOf(grvtBank), 0, "grvtBank should have accumulated yield");
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

        AaveV3Strategy newStrategy = new AaveV3Strategy(address(vault), AAVE_V3_POOL, USDC);

        uint256 idleBefore = vault.idleBalance(USDC);

        vm.prank(admin);
        vault.migrateStrategy(USDC, address(newStrategy));

        assertEq(vault.assetStrategy(USDC), address(newStrategy), "strategy should be new one");
        assertEq(vault.deployedPrincipal(USDC), 0, "deployed principal should be zero after migration");
        assertApproxEqAbs(vault.idleBalance(USDC), idleBefore + 1_000_000e6, 2, "idle should recover funds");
    }

    function test_migrateStrategy_succeeds_withNoDeployedFunds() public {
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

    function test_migrateStrategy_succeeds_whenPaused() public {
        _depositUSDC(1_000_000e6);
        vm.prank(strategist);
        vault.deployToStrategy(USDC, 1_000_000e6);

        vm.prank(guardian);
        vault.pause();

        AaveV3Strategy newStrategy = new AaveV3Strategy(address(vault), AAVE_V3_POOL, USDC);

        vm.prank(admin);
        vault.migrateStrategy(USDC, address(newStrategy));

        assertEq(vault.assetStrategy(USDC), address(newStrategy), "migration should work while paused");
        assertEq(vault.deployedPrincipal(USDC), 0, "deployed principal should be zero");
        assertApproxEqAbs(vault.idleBalance(USDC), 1_000_000e6, 2, "idle should recover funds");
    }

    // =========================================================================
    // Multi-step integration test
    // =========================================================================

    function test_fullLifecycle_multiStep() public {
        // 1. Deposit 1M USDC
        _depositUSDC(1_000_000e6);
        assertEq(vault.idleBalance(USDC), 1_000_000e6);

        // 2. Deploy 800K to strategy
        vm.prank(strategist);
        vault.deployToStrategy(USDC, 800_000e6);
        assertEq(vault.idleBalance(USDC), 200_000e6);
        assertEq(vault.deployedPrincipal(USDC), 800_000e6);

        // 3. Warp 6 months, harvest yield
        vm.warp(block.timestamp + 180 days);
        vm.roll(block.number + 1_300_000);

        uint256 bankBefore = IERC20(USDC).balanceOf(grvtBank);
        vm.prank(strategist);
        vault.harvest(USDC);

        uint256 yield1 = IERC20(USDC).balanceOf(grvtBank) - bankBefore;
        assertGt(yield1, 0, "first harvest should produce yield");
        // deployedPrincipal should be re-synced
        assertApproxEqAbs(vault.deployedPrincipal(USDC), 800_000e6, 2, "principal ~unchanged after harvest");

        // 4. Warp another 6 months, harvest again
        vm.warp(block.timestamp + 180 days);
        vm.roll(block.number + 1_300_000);

        bankBefore = IERC20(USDC).balanceOf(grvtBank);
        vm.prank(strategist);
        vault.harvest(USDC);

        uint256 yield2 = IERC20(USDC).balanceOf(grvtBank) - bankBefore;
        assertGt(yield2, 0, "second harvest should produce yield");

        // 5. Deposit more, deploy more
        _depositUSDC(500_000e6);
        vm.prank(strategist);
        vault.deployToStrategy(USDC, 500_000e6);
        assertEq(vault.idleBalance(USDC), 200_000e6, "idle should be original remainder");
        assertApproxEqAbs(vault.deployedPrincipal(USDC), 1_300_000e6, 2, "principal should be 800K + 500K");

        // 6. Migrate to new strategy
        AaveV3Strategy newStrategy = new AaveV3Strategy(address(vault), AAVE_V3_POOL, USDC);
        vm.prank(admin);
        vault.migrateStrategy(USDC, address(newStrategy));

        assertEq(vault.deployedPrincipal(USDC), 0, "principal zero after migration");
        // idle should have recovered ~1.3M + the 200K that was already idle
        assertApproxEqAbs(vault.idleBalance(USDC), 1_500_000e6, 10, "idle should recover ~all deposited");

        // 7. Withdraw idle to treasury
        address treasury = makeAddr("treasury");
        uint256 idleNow = vault.idleBalance(USDC);
        vm.prank(strategist);
        vault.withdraw(USDC, idleNow, treasury);

        assertEq(vault.idleBalance(USDC), 0, "idle should be zero after full withdraw");
        assertEq(IERC20(USDC).balanceOf(treasury), idleNow, "treasury should receive all idle");

        // 8. Verify final TVL is zero
        (uint256 idle, uint256 deployed, uint256 total) = vault.getAssetBalance(USDC);
        assertEq(idle, 0, "final idle should be 0");
        assertEq(deployed, 0, "final deployed should be 0");
        assertEq(total, 0, "final total should be 0");

        // 9. Verify grvtBank accumulated yield from both harvests
        assertGt(IERC20(USDC).balanceOf(grvtBank), yield1, "grvtBank should have yield from both harvests");
    }

    // =========================================================================
    // Fuzz Tests
    // =========================================================================

    function testFuzz_deposit_and_withdraw_idle(uint256 depositAmt, uint256 withdrawAmt) public {
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
        assertApproxEqAbs(vault.idleBalance(USDC), depositAmt, 2, "idle should recover ~full deposit");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {BaseTest} from "./BaseTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {GrvtVault} from "../src/GrvtVault.sol";

/// @title HardeningTest
/// @notice RBAC restriction tests, edge case tests, and emergency control tests
contract HardeningTest is BaseTest {
    // =========================================================================
    // RBAC — every privileged function reverts for unauthorized callers
    // =========================================================================

    function test_deposit_revertsWhen_callerLacksDepositorRole() public {
        bytes32 role = vault.DEPOSITOR_ROLE();
        deal(USDC, randomUser, 1_000e6);
        vm.startPrank(randomUser);
        IERC20(USDC).approve(address(vault), 1_000e6);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, randomUser, role)
        );
        vault.deposit(USDC, 1_000e6);
        vm.stopPrank();
    }

    function test_depositETH_revertsWhen_callerLacksDepositorRole() public {
        bytes32 role = vault.DEPOSITOR_ROLE();
        vm.deal(randomUser, 1 ether);
        vm.startPrank(randomUser);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, randomUser, role)
        );
        vault.depositETH{value: 1 ether}();
        vm.stopPrank();
    }

    function test_deployToStrategy_revertsWhen_callerLacksStrategistRole() public {
        bytes32 role = vault.STRATEGIST_ROLE();
        _depositUSDC(1_000e6);

        vm.startPrank(randomUser);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, randomUser, role)
        );
        vault.deployToStrategy(USDC, 1_000e6);
        vm.stopPrank();
    }

    function test_withdrawFromStrategy_revertsWhen_callerLacksStrategistRole() public {
        bytes32 role = vault.STRATEGIST_ROLE();
        vm.startPrank(randomUser);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, randomUser, role)
        );
        vault.withdrawFromStrategy(USDC, 1_000e6);
        vm.stopPrank();
    }

    function test_harvest_revertsWhen_callerLacksStrategistRole() public {
        bytes32 role = vault.STRATEGIST_ROLE();
        vm.startPrank(randomUser);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, randomUser, role)
        );
        vault.harvest(USDC);
        vm.stopPrank();
    }

    function test_pause_revertsWhen_callerLacksGuardianRole() public {
        bytes32 role = vault.GUARDIAN_ROLE();
        vm.startPrank(randomUser);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, randomUser, role)
        );
        vault.pause();
        vm.stopPrank();
    }

    function test_unpause_revertsWhen_callerLacksAdminRole() public {
        bytes32 role = vault.DEFAULT_ADMIN_ROLE();
        vm.prank(guardian);
        vault.pause();

        vm.startPrank(randomUser);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, randomUser, role)
        );
        vault.unpause();
        vm.stopPrank();
    }

    function test_whitelistAsset_revertsWhen_callerLacksAdminRole() public {
        bytes32 role = vault.DEFAULT_ADMIN_ROLE();
        vm.startPrank(randomUser);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, randomUser, role)
        );
        vault.whitelistAsset(address(0xBEEF));
        vm.stopPrank();
    }

    function test_emergencyWithdraw_revertsWhen_callerLacksAdminRole() public {
        bytes32 role = vault.DEFAULT_ADMIN_ROLE();
        vm.startPrank(randomUser);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, randomUser, role)
        );
        vault.emergencyWithdrawFromStrategy(USDC);
        vm.stopPrank();
    }

    // =========================================================================
    // Edge Cases — zero amounts, non-whitelisted assets, excess operations
    // =========================================================================

    function test_deposit_revertsWhen_amountIsZero() public {
        vm.prank(depositor);
        vm.expectRevert(GrvtVault.ZeroAmount.selector);
        vault.deposit(USDC, 0);
    }

    function test_depositETH_revertsWhen_valueIsZero() public {
        vm.prank(depositor);
        vm.expectRevert(GrvtVault.ZeroAmount.selector);
        vault.depositETH{value: 0}();
    }

    function test_deposit_revertsWhen_assetNotWhitelisted() public {
        address fakeToken = makeAddr("fakeToken");
        vm.prank(depositor);
        vm.expectRevert(abi.encodeWithSelector(GrvtVault.AssetNotWhitelisted.selector, fakeToken));
        vault.deposit(fakeToken, 1_000e6);
    }

    function test_deployToStrategy_revertsWhen_insufficientIdle() public {
        _depositUSDC(1_000e6);

        vm.prank(strategist);
        vm.expectRevert(
            abi.encodeWithSelector(GrvtVault.InsufficientIdleBalance.selector, USDC, 1_000e6, 2_000e6)
        );
        vault.deployToStrategy(USDC, 2_000e6);
    }

    function test_deployToStrategy_revertsWhen_amountIsZero() public {
        vm.prank(strategist);
        vm.expectRevert(GrvtVault.ZeroAmount.selector);
        vault.deployToStrategy(USDC, 0);
    }

    function test_withdrawFromStrategy_revertsWhen_amountIsZero() public {
        vm.prank(strategist);
        vm.expectRevert(GrvtVault.ZeroAmount.selector);
        vault.withdrawFromStrategy(USDC, 0);
    }

    function test_deployToStrategy_revertsWhen_noStrategySet() public {
        // USDT is whitelisted but has no strategy — deposit directly via deal + prank
        // Note: USDT has non-standard approve, so we use forceApprove pattern via deal
        deal(USDT, depositor, 1_000e6);
        vm.startPrank(depositor);
        // USDT requires setting approval to 0 first, but SafeERC20.safeTransferFrom handles it
        // Use low-level approve to handle USDT's non-standard return
        (bool success,) = USDT.call(abi.encodeWithSignature("approve(address,uint256)", address(vault), 1_000e6));
        require(success, "approve failed");
        vault.deposit(USDT, 1_000e6);
        vm.stopPrank();

        vm.prank(strategist);
        vm.expectRevert(abi.encodeWithSelector(GrvtVault.StrategyNotSet.selector, USDT));
        vault.deployToStrategy(USDT, 1_000e6);
    }

    function test_whitelistAsset_revertsWhen_alreadyWhitelisted() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(GrvtVault.AssetAlreadyWhitelisted.selector, USDC));
        vault.whitelistAsset(USDC);
    }

    function test_whitelistAsset_revertsWhen_zeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(GrvtVault.ZeroAddress.selector);
        vault.whitelistAsset(address(0));
    }

    function test_setGrvtBank_revertsWhen_zeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(GrvtVault.ZeroAddress.selector);
        vault.setGrvtBank(address(0));
    }

    function test_removeStrategy_revertsWhen_fundsStillDeployed() public {
        _depositUSDC(1_000e6);

        vm.prank(strategist);
        vault.deployToStrategy(USDC, 1_000e6);

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(GrvtVault.StrategyStillDeployed.selector, USDC, 1_000e6)
        );
        vault.removeStrategy(USDC);
    }

    // =========================================================================
    // Emergency / Pause Controls
    // =========================================================================

    function test_deposit_revertsWhen_paused() public {
        vm.prank(guardian);
        vault.pause();

        deal(USDC, depositor, 1_000e6);
        vm.startPrank(depositor);
        IERC20(USDC).approve(address(vault), 1_000e6);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.deposit(USDC, 1_000e6);
        vm.stopPrank();
    }

    function test_deployToStrategy_revertsWhen_paused() public {
        _depositUSDC(1_000e6);

        vm.prank(guardian);
        vault.pause();

        vm.prank(strategist);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.deployToStrategy(USDC, 1_000e6);
    }

    function test_harvest_revertsWhen_paused() public {
        vm.prank(guardian);
        vault.pause();

        vm.prank(strategist);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.harvest(USDC);
    }

    function test_withdrawFromStrategy_succeeds_when_paused() public {
        _depositUSDC(1_000e6);

        vm.prank(strategist);
        vault.deployToStrategy(USDC, 1_000e6);

        vm.prank(guardian);
        vault.pause();

        // withdrawFromStrategy must work during pause (not pausable)
        vm.prank(strategist);
        vault.withdrawFromStrategy(USDC, type(uint256).max);

        assertEq(vault.deployedPrincipal(USDC), 0, "should withdraw all even when paused");
    }

    function test_emergencyWithdraw_succeeds_when_paused() public {
        _depositUSDC(1_000e6);

        vm.prank(strategist);
        vault.deployToStrategy(USDC, 1_000e6);

        vm.prank(guardian);
        vault.pause();

        // emergencyWithdrawFromStrategy must work during pause (not pausable)
        vm.prank(admin);
        vault.emergencyWithdrawFromStrategy(USDC);

        assertEq(vault.deployedPrincipal(USDC), 0, "emergency withdraw should work when paused");
    }

    function test_unpause_succeeds_when_calledByAdmin() public {
        vm.prank(guardian);
        vault.pause();

        vm.prank(admin);
        vault.unpause();

        // Deposit should work again
        _depositUSDC(1_000e6);
        assertEq(vault.idleBalance(USDC), 1_000e6, "should deposit after unpause");
    }

    // =========================================================================
    // Additional RBAC + edge cases requested by team lead
    // =========================================================================

    function test_setStrategy_revertsWhen_callerLacksAdminRole() public {
        bytes32 role = vault.DEFAULT_ADMIN_ROLE();
        vm.startPrank(randomUser);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, randomUser, role)
        );
        vault.setStrategy(USDC, address(usdcStrategy));
        vm.stopPrank();
    }

    function test_withdrawFromStrategy_revertsWhen_excessAmount() public {
        _depositUSDC(1_000e6);

        vm.prank(strategist);
        vault.deployToStrategy(USDC, 1_000e6);

        vm.prank(strategist);
        vm.expectRevert(
            abi.encodeWithSelector(GrvtVault.InsufficientDeployedBalance.selector, USDC, 1_000e6, 2_000e6)
        );
        vault.withdrawFromStrategy(USDC, 2_000e6);
    }

    function test_setStrategy_revertsWhen_assetMismatch() public {
        // Try to set the WETH strategy for USDT (asset mismatch)
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(GrvtVault.StrategyAssetMismatch.selector, USDT, WETH)
        );
        vault.setStrategy(USDT, address(wethStrategy));
    }

    // =========================================================================
    // Removal lifecycle — removeStrategy and removeAsset happy path
    // =========================================================================

    function test_removeStrategy_succeeds_when_noFundsDeployed() public {
        // USDC strategy has no funds deployed (nothing was deposited/deployed in this test)
        vm.prank(admin);
        vault.removeStrategy(USDC);
        assertEq(vault.assetStrategy(USDC), address(0), "strategy should be cleared");
    }

    function test_removeAsset_succeeds_afterStrategyRemoved() public {
        vm.startPrank(admin);
        vault.removeStrategy(USDC);
        vault.removeAsset(USDC);
        vm.stopPrank();

        assertFalse(vault.whitelistedAssets(USDC), "USDC should no longer be whitelisted");

        // Verify it's gone from getWhitelistedAssets
        address[] memory assets = vault.getWhitelistedAssets();
        for (uint256 i; i < assets.length; ++i) {
            assertTrue(assets[i] != USDC, "USDC should not appear in asset list");
        }
    }

    function test_removeAsset_revertsWhen_strategyStillSet() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(GrvtVault.StrategyStillSet.selector, USDC));
        vault.removeAsset(USDC);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {BaseTest} from "./BaseTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title HappyPathTest
/// @notice Fork tests covering the core deposit -> deploy -> yield -> harvest -> withdraw flow
contract HappyPathTest is BaseTest {
    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    /// @notice Deposit and deploy a token in a single call
    function _depositAndDeploy(
        address token,
        uint256 depositAmt,
        uint256 deployAmt
    ) internal {
        // Deposit
        deal(token, depositor, depositAmt);
        vm.startPrank(depositor);
        IERC20(token).approve(address(vault), depositAmt);
        vault.deposit(token, depositAmt);
        vm.stopPrank();

        // Deploy
        vm.prank(strategist);
        vault.deployToStrategy(token, deployAmt);
    }

    // -------------------------------------------------------------------------
    // 1. Deposit USDC
    // -------------------------------------------------------------------------

    function test_deposit_succeeds_when_depositingUSDC() public {
        _depositUSDC(1_000_000e6);

        assertEq(vault.idleBalance(USDC), 1_000_000e6, "idle balance should be 1M USDC");
        assertEq(IERC20(USDC).balanceOf(address(vault)), 1_000_000e6, "vault should hold 1M USDC");
    }

    // -------------------------------------------------------------------------
    // 2. Deposit ETH (auto-wrap to WETH)
    // -------------------------------------------------------------------------

    function test_depositETH_succeeds_when_sendingETH() public {
        vm.deal(depositor, 100 ether);
        vm.prank(depositor);
        vault.depositETH{value: 100 ether}();

        assertEq(vault.idleBalance(WETH), 100 ether, "idle WETH should be 100 ether");
    }

    // -------------------------------------------------------------------------
    // 3. Deploy USDC to strategy
    // -------------------------------------------------------------------------

    function test_deployToStrategy_succeeds_when_deployingUSDC() public {
        _depositUSDC(1_000_000e6);

        vm.prank(strategist);
        vault.deployToStrategy(USDC, 500_000e6);

        assertEq(vault.idleBalance(USDC), 500_000e6, "idle should be 500K USDC");
        assertEq(vault.deployedPrincipal(USDC), 500_000e6, "deployed principal should be 500K");
        // Aave rounds by up to 1 wei on supply
        assertApproxEqAbs(usdcStrategy.totalDeployed(), 500_000e6, 2, "strategy totalDeployed ~= 500K");
    }

    // -------------------------------------------------------------------------
    // 4. Withdraw USDC from strategy
    // -------------------------------------------------------------------------

    function test_withdrawFromStrategy_succeeds_when_withdrawingUSDC() public {
        _depositAndDeploy(USDC, 1_000_000e6, 1_000_000e6);

        uint256 idleBefore = vault.idleBalance(USDC);
        uint256 principalBefore = vault.deployedPrincipal(USDC);

        vm.prank(strategist);
        vault.withdrawFromStrategy(USDC, 500_000e6);

        assertGt(vault.idleBalance(USDC), idleBefore, "idle balance should increase");
        assertLt(vault.deployedPrincipal(USDC), principalBefore, "deployed principal should decrease");
    }

    // -------------------------------------------------------------------------
    // 5. Yield accrual after time warp
    // -------------------------------------------------------------------------

    function test_yieldAccrual_succeeds_when_timeWarped() public {
        _depositAndDeploy(USDC, 1_000_000e6, 1_000_000e6);

        // Warp 1 year
        vm.warp(block.timestamp + 365 days);
        vm.roll(block.number + 2_600_000);

        assertGt(usdcStrategy.totalDeployed(), 1_000_000e6, "totalDeployed should exceed principal after yield");
        assertGt(usdcStrategy.pendingYield(), 0, "pendingYield should be > 0");
    }

    // -------------------------------------------------------------------------
    // 6. Harvest yield
    // -------------------------------------------------------------------------

    function test_harvest_succeeds_when_yieldAvailable() public {
        _depositAndDeploy(USDC, 1_000_000e6, 1_000_000e6);

        // Warp 1 year for yield
        vm.warp(block.timestamp + 365 days);
        vm.roll(block.number + 2_600_000);

        uint256 bankBefore = IERC20(USDC).balanceOf(grvtBank);

        vm.prank(strategist);
        vault.harvest(USDC);

        assertGt(IERC20(USDC).balanceOf(grvtBank), bankBefore, "grvtBank should receive yield");
    }

    // -------------------------------------------------------------------------
    // 7. Emergency withdraw
    // -------------------------------------------------------------------------

    function test_emergencyWithdraw_succeeds_when_calledByAdmin() public {
        _depositAndDeploy(USDC, 1_000_000e6, 1_000_000e6);

        vm.prank(admin);
        vault.emergencyWithdrawFromStrategy(USDC);

        // Aave rounding may cause up to 1 wei less than exact principal
        assertApproxEqAbs(vault.idleBalance(USDC), 1_000_000e6, 2, "idle should recover ~principal");
        assertEq(vault.deployedPrincipal(USDC), 0, "deployed principal should be zero");
    }

    // -------------------------------------------------------------------------
    // 8. Get asset balance
    // -------------------------------------------------------------------------

    function test_getAssetBalance_succeeds_when_fundsDeployed() public {
        _depositUSDC(1_000_000e6);

        vm.prank(strategist);
        vault.deployToStrategy(USDC, 500_000e6);

        (uint256 idle, uint256 deployed, uint256 total) = vault.getAssetBalance(USDC);
        assertEq(idle, 500_000e6, "idle should be 500K");
        // Aave rounds by up to 1 wei on supply
        assertApproxEqAbs(deployed, 500_000e6, 2, "deployed ~= 500K");
        assertApproxEqAbs(total, 1_000_000e6, 2, "total ~= 1M");
    }

    // -------------------------------------------------------------------------
    // 9. Deposit WETH
    // -------------------------------------------------------------------------

    function test_depositWETH_succeeds_when_depositingWETH() public {
        _depositWETH(50 ether);

        assertEq(vault.idleBalance(WETH), 50 ether, "idle WETH should be 50 ether");
    }

    // -------------------------------------------------------------------------
    // 10. Deploy WETH to strategy
    // -------------------------------------------------------------------------

    function test_deployToStrategy_succeeds_when_deployingWETH() public {
        _depositWETH(50 ether);

        vm.prank(strategist);
        vault.deployToStrategy(WETH, 25 ether);

        assertEq(vault.idleBalance(WETH), 25 ether, "idle should be 25 WETH");
        assertEq(vault.deployedPrincipal(WETH), 25 ether, "principal should be 25 WETH");
        // Aave rounds by up to 1 wei on supply
        assertApproxEqAbs(wethStrategy.totalDeployed(), 25 ether, 2, "strategy totalDeployed ~= 25 WETH");
    }
}

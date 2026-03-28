// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GrvtVault} from "../src/GrvtVault.sol";
import {AaveV3Strategy} from "../src/strategies/AaveV3Strategy.sol";
import {IStrategy} from "../src/interfaces/IStrategy.sol";

contract BaseTest is Test {
    // -------------------------------------------------------------------------
    // Mainnet addresses
    // -------------------------------------------------------------------------
    address public constant AAVE_V3_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address public constant A_USDC = 0x98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c;
    address public constant A_WETH = 0x4d5F47FA6A74757f35C14fD3a6Ef8E3C9BC514E8;

    // -------------------------------------------------------------------------
    // Contracts
    // -------------------------------------------------------------------------
    GrvtVault public vault;
    AaveV3Strategy public usdcStrategy;
    AaveV3Strategy public wethStrategy;

    // -------------------------------------------------------------------------
    // Test accounts
    // -------------------------------------------------------------------------
    address public admin;
    address public strategist;
    address public depositor;
    address public guardian;
    address public grvtBank;
    address public randomUser;

    function setUp() public virtual {
        // Fork mainnet
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", string("https://eth.llamarpc.com")));

        // Label mainnet addresses
        vm.label(AAVE_V3_POOL, "AaveV3Pool");
        vm.label(WETH, "WETH");
        vm.label(USDC, "USDC");
        vm.label(USDT, "USDT");
        vm.label(A_USDC, "aEthUSDC");
        vm.label(A_WETH, "aEthWETH");

        // Create test accounts
        admin = makeAddr("admin");
        strategist = makeAddr("strategist");
        depositor = makeAddr("depositor");
        guardian = makeAddr("guardian");
        grvtBank = makeAddr("grvtBank");
        randomUser = makeAddr("randomUser");

        // Deploy vault as admin
        vm.prank(admin);
        vault = new GrvtVault(admin, WETH, grvtBank);
        vm.label(address(vault), "GrvtVault");

        // Deploy strategies
        usdcStrategy = new AaveV3Strategy(address(vault), AAVE_V3_POOL, USDC);
        wethStrategy = new AaveV3Strategy(address(vault), AAVE_V3_POOL, WETH);
        vm.label(address(usdcStrategy), "UsdcStrategy");
        vm.label(address(wethStrategy), "WethStrategy");

        // Grant roles and configure vault as admin
        vm.startPrank(admin);

        vault.grantRole(vault.STRATEGIST_ROLE(), strategist);
        vault.grantRole(vault.DEPOSITOR_ROLE(), depositor);
        vault.grantRole(vault.GUARDIAN_ROLE(), guardian);

        // Whitelist assets
        vault.whitelistAsset(USDC);
        vault.whitelistAsset(WETH);
        vault.whitelistAsset(USDT);

        // Set strategies
        vault.setStrategy(USDC, address(usdcStrategy));
        vault.setStrategy(WETH, address(wethStrategy));

        vm.stopPrank();
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    /// @notice Deal ERC20 tokens to an address
    function _dealERC20(address token, address to, uint256 amount) internal {
        deal(token, to, amount);
    }

    /// @notice Deal USDC to depositor and deposit into vault
    function _depositUSDC(uint256 amount) internal {
        deal(USDC, depositor, amount);
        vm.startPrank(depositor);
        IERC20(USDC).approve(address(vault), amount);
        vault.deposit(USDC, amount);
        vm.stopPrank();
    }

    /// @notice Deal WETH to depositor and deposit into vault
    function _depositWETH(uint256 amount) internal {
        deal(WETH, depositor, amount);
        vm.startPrank(depositor);
        IERC20(WETH).approve(address(vault), amount);
        vault.deposit(WETH, amount);
        vm.stopPrank();
    }
}

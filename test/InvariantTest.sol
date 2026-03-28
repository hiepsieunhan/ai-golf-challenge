// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GrvtVault} from "../src/GrvtVault.sol";
import {AaveV3Strategy} from "../src/strategies/AaveV3Strategy.sol";

/// @title MultiAssetVaultHandler
/// @notice Stateful handler for invariant fuzzing — calls vault operations across multiple assets
contract MultiAssetVaultHandler is Test {
    GrvtVault public vault;
    address public depositor;
    address public strategist;

    address[] public assets;
    mapping(address => AaveV3Strategy) public strategies;

    // Per-asset ghost variables
    mapping(address => uint256) public totalDeposited;
    mapping(address => uint256) public totalWithdrawn;
    mapping(address => uint256) public opCount;

    constructor(
        GrvtVault _vault,
        address _depositor,
        address _strategist,
        address[] memory _assets,
        AaveV3Strategy[] memory _strategies
    ) {
        vault = _vault;
        depositor = _depositor;
        strategist = _strategist;

        for (uint256 i; i < _assets.length; ++i) {
            assets.push(_assets[i]);
            strategies[_assets[i]] = _strategies[i];
        }
    }

    /// @dev Select an asset based on fuzz seed
    function _selectAsset(uint256 seed) internal view returns (address) {
        return assets[seed % assets.length];
    }

    function deposit(uint256 seed, uint256 amount) external {
        address asset = _selectAsset(seed);
        // Use asset-appropriate minimums (USDC=6 decimals, WETH=18 decimals)
        uint256 decimals = asset == assets[0] ? 6 : 18; // USDC first, WETH second
        uint256 minAmt = 100 * (10 ** decimals);
        uint256 maxAmt = 10_000 * (10 ** decimals);
        amount = bound(amount, minAmt, maxAmt);

        deal(asset, depositor, amount);
        vm.startPrank(depositor);
        IERC20(asset).approve(address(vault), amount);
        vault.deposit(asset, amount);
        vm.stopPrank();

        totalDeposited[asset] += amount;
        opCount[asset]++;
    }

    function deployToStrategy(uint256 seed, uint256 amount) external {
        address asset = _selectAsset(seed);
        uint256 idle = vault.idleBalance(asset);
        uint256 decimals = asset == assets[0] ? 6 : 18;
        uint256 minDeploy = 10 ** decimals; // 1 USDC or 1 WETH as minimum
        if (idle < minDeploy) return;

        amount = bound(amount, minDeploy, idle);

        vm.prank(strategist);
        vault.deployToStrategy(asset, amount);
        opCount[asset]++;
    }

    function withdrawIdle(uint256 seed, uint256 amount) external {
        address asset = _selectAsset(seed);
        uint256 idle = vault.idleBalance(asset);
        if (idle == 0) return;

        amount = bound(amount, 1, idle);
        address recipient = address(0xBEEF);

        vm.prank(strategist);
        vault.withdraw(asset, amount, recipient);

        totalWithdrawn[asset] += amount;
        opCount[asset]++;
    }

    function withdrawFromStrategy(uint256 seed, uint256 amount) external {
        address asset = _selectAsset(seed);
        uint256 principal = vault.deployedPrincipal(asset);
        if (principal == 0) return;

        amount = bound(amount, 1, principal);

        vm.prank(strategist);
        vault.withdrawFromStrategy(asset, amount);
        opCount[asset]++;
    }

    function harvest(uint256 seed) external {
        address asset = _selectAsset(seed);
        uint256 principal = vault.deployedPrincipal(asset);
        if (principal == 0) return;

        // Warp forward to accrue some yield
        vm.warp(block.timestamp + 7 days);
        vm.roll(block.number + 50_400);

        vm.prank(strategist);
        try vault.harvest(asset) {
            opCount[asset]++;
        } catch {}
    }

    function assetCount() external view returns (uint256) {
        return assets.length;
    }
}

/// @title InvariantTest
/// @notice Multi-asset stateful fuzz test asserting accounting invariants hold regardless of call ordering.
/// @dev Requires a high-rate-limit RPC (e.g. Alchemy/Infura) via ETH_RPC_URL.
///      Free RPCs will 429 during invariant setup due to Foundry's address exploration.
contract InvariantTest is Test {
    // Mainnet addresses
    address public constant AAVE_V3_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    GrvtVault public vault;
    AaveV3Strategy public usdcStrategy;
    AaveV3Strategy public wethStrategy;
    MultiAssetVaultHandler public handler;

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

        usdcStrategy = new AaveV3Strategy(address(vault), AAVE_V3_POOL, USDC);
        wethStrategy = new AaveV3Strategy(address(vault), AAVE_V3_POOL, WETH);

        vm.startPrank(admin);
        vault.grantRole(vault.STRATEGIST_ROLE(), strategist);
        vault.grantRole(vault.DEPOSITOR_ROLE(), depositor);
        vault.grantRole(vault.GUARDIAN_ROLE(), guardian);
        vault.whitelistAsset(USDC);
        vault.whitelistAsset(WETH);
        vault.setStrategy(USDC, address(usdcStrategy));
        vault.setStrategy(WETH, address(wethStrategy));
        vm.stopPrank();

        // Build asset/strategy arrays
        address[] memory assets = new address[](2);
        AaveV3Strategy[] memory strats = new AaveV3Strategy[](2);
        assets[0] = USDC;
        assets[1] = WETH;
        strats[0] = usdcStrategy;
        strats[1] = wethStrategy;

        handler = new MultiAssetVaultHandler(vault, depositor, strategist, assets, strats);

        // Only target the handler for invariant calls
        targetContract(address(handler));
    }

    /// @notice Vault's actual token balance must be >= tracked idle balance (per asset)
    function invariant_vaultBalanceCoversIdle() public view {
        _checkAsset(USDC);
        _checkAsset(WETH);
    }

    function _checkAsset(address asset) internal view {
        uint256 vaultBalance = IERC20(asset).balanceOf(address(vault));
        uint256 idle = vault.idleBalance(asset);
        assertGe(vaultBalance, idle, "vault token balance must cover idle balance");
    }

    /// @notice Strategy's totalDeployed must be >= vault's deployedPrincipal per asset
    ///         (within Aave rounding tolerance)
    function invariant_strategyCoversDeployedPrincipal() public view {
        _checkStrategyCovers(USDC, usdcStrategy);
        _checkStrategyCovers(WETH, wethStrategy);
    }

    function _checkStrategyCovers(address asset, AaveV3Strategy strategy) internal view {
        uint256 deployed = strategy.totalDeployed();
        uint256 principal = vault.deployedPrincipal(asset);
        uint256 ops = handler.opCount(asset);
        uint256 tolerance = ops * 2 + 2;
        assertGe(deployed + tolerance, principal, "strategy totalDeployed must cover deployedPrincipal (within rounding)");
    }

    /// @notice Accounting identity per asset: idle + principal <= totalDeposited - totalWithdrawn
    function invariant_accountingIdentity() public view {
        _checkAccounting(USDC);
        _checkAccounting(WETH);
    }

    function _checkAccounting(address asset) internal view {
        uint256 idle = vault.idleBalance(asset);
        uint256 principal = vault.deployedPrincipal(asset);
        uint256 deposited = handler.totalDeposited(asset);
        uint256 withdrawn = handler.totalWithdrawn(asset);

        // No deposits yet — skip (avoid underflow)
        if (deposited == 0) return;

        uint256 ops = handler.opCount(asset);
        uint256 tolerance = ops * 2 + 1;

        assertLe(
            idle + principal,
            deposited - withdrawn + tolerance,
            "idle + principal must not exceed net deposits (with rounding tolerance)"
        );
    }
}

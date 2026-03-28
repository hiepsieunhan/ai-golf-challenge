// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {AccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";
import {AccessControlDefaultAdminRules} from "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IStrategy} from "./interfaces/IStrategy.sol";

/// @notice Minimal WETH interface for deposit (wrap) and withdraw (unwrap)
interface IWETH {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

/// @title GrvtVault
/// @notice Core treasury vault for GRVT. Accepts capital from funding wallets,
///         holds it safely, deploys it into yield strategies, reports TVL,
///         and supports harvesting yield to grvtBank.
/// @dev Uses ReentrancyGuardTransient (EIP-1153 TSTORE/TLOAD). Deploy only to
///      networks with the Cancun hard fork activated (Ethereum mainnet post-March 2024).
contract GrvtVault is
    AccessControlEnumerable,
    AccessControlDefaultAdminRules,
    ReentrancyGuardTransient,
    Pausable
{
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    bytes32 public constant STRATEGIST_ROLE = keccak256("STRATEGIST_ROLE");
    bytes32 public constant DEPOSITOR_ROLE = keccak256("DEPOSITOR_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    address public immutable WETH;

    // -------------------------------------------------------------------------
    // Configuration
    // -------------------------------------------------------------------------

    address public grvtBank;

    // -------------------------------------------------------------------------
    // Per-asset state
    // -------------------------------------------------------------------------

    mapping(address asset => bool) public whitelistedAssets;
    mapping(address asset => address strategy) public assetStrategy;
    mapping(address asset => uint256) public idleBalance;
    mapping(address asset => uint256) public deployedPrincipal;

    /// @dev Enumerable list for TVL iteration
    address[] internal _assetList;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

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

    // -------------------------------------------------------------------------
    // Custom Errors
    // -------------------------------------------------------------------------

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
    error NoYieldAvailable(address asset);
    error StrategyVaultMismatch(address expected, address actual);
    error StrategyStillSet(address asset);

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    /// @notice Initializes the vault with admin, WETH address, and yield recipient
    /// @param initialAdmin Address to receive DEFAULT_ADMIN_ROLE (2-step transfer with 1-day delay)
    /// @param weth WETH contract address for auto-wrapping ETH deposits
    /// @param _grvtBank Address to receive harvested yield
    constructor(
        address initialAdmin,
        address weth,
        address _grvtBank
    ) AccessControlDefaultAdminRules(1 days, initialAdmin) {
        if (weth == address(0)) revert ZeroAddress();
        if (_grvtBank == address(0)) revert ZeroAddress();

        WETH = weth;
        grvtBank = _grvtBank;
    }

    // -------------------------------------------------------------------------
    // Deposit (DEPOSITOR_ROLE)
    // -------------------------------------------------------------------------

    /// @notice Deposit ERC20 tokens into the vault
    /// @param asset Token address (must be whitelisted)
    /// @param amount Amount to deposit
    function deposit(address asset, uint256 amount) external nonReentrant whenNotPaused onlyRole(DEPOSITOR_ROLE) {
        if (amount == 0) revert ZeroAmount();
        if (!whitelistedAssets[asset]) revert AssetNotWhitelisted(asset);

        uint256 balanceBefore = IERC20(asset).balanceOf(address(this));
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(asset).balanceOf(address(this)) - balanceBefore;

        idleBalance[asset] += received;
        emit Deposited(msg.sender, asset, received);
    }

    /// @notice Deposit native ETH — auto-wraps to WETH
    function depositETH() external payable nonReentrant whenNotPaused onlyRole(DEPOSITOR_ROLE) {
        if (msg.value == 0) revert ZeroAmount();
        if (!whitelistedAssets[WETH]) revert AssetNotWhitelisted(WETH);

        IWETH(WETH).deposit{value: msg.value}();
        idleBalance[WETH] += msg.value;
        emit Deposited(msg.sender, WETH, msg.value);
    }

    // -------------------------------------------------------------------------
    // Strategy Operations (STRATEGIST_ROLE)
    // -------------------------------------------------------------------------

    /// @notice Deploy idle assets into the registered strategy
    /// @param asset Token to deploy
    /// @param amount Amount to deploy from idle balance
    function deployToStrategy(address asset, uint256 amount) external nonReentrant whenNotPaused onlyRole(STRATEGIST_ROLE) {
        if (amount == 0) revert ZeroAmount();
        address strategy = assetStrategy[asset];
        if (strategy == address(0)) revert StrategyNotSet(asset);

        uint256 idle = idleBalance[asset];
        if (idle < amount) revert InsufficientIdleBalance(asset, idle, amount);

        idleBalance[asset] -= amount;
        deployedPrincipal[asset] += amount;

        IERC20(asset).safeTransfer(strategy, amount);
        IStrategy(strategy).deploy(amount);

        emit DeployedToStrategy(asset, strategy, amount);
    }

    /// @notice Withdraw assets from the strategy back to idle
    /// @param asset Token to withdraw
    /// @param amount Amount to withdraw (type(uint256).max = all)
    function withdrawFromStrategy(address asset, uint256 amount) external nonReentrant onlyRole(STRATEGIST_ROLE) {
        if (amount == 0) revert ZeroAmount();
        address strategy = assetStrategy[asset];
        if (strategy == address(0)) revert StrategyNotSet(asset);

        uint256 principal = deployedPrincipal[asset];
        if (amount != type(uint256).max && principal < amount) {
            revert InsufficientDeployedBalance(asset, principal, amount);
        }

        uint256 actual = IStrategy(strategy).withdraw(amount);

        if (amount == type(uint256).max || actual >= principal) {
            deployedPrincipal[asset] = 0;
        } else {
            deployedPrincipal[asset] -= actual;
        }
        idleBalance[asset] += actual;

        emit WithdrawnFromStrategy(asset, strategy, actual);
    }

    /// @notice Harvest yield from strategy, send to grvtBank
    /// @param asset Token whose yield to harvest
    function harvest(address asset) external nonReentrant whenNotPaused onlyRole(STRATEGIST_ROLE) {
        address strategy = assetStrategy[asset];
        if (strategy == address(0)) revert StrategyNotSet(asset);
        if (grvtBank == address(0)) revert GrvtBankNotSet();

        uint256 yieldAmount = IStrategy(strategy).harvest(grvtBank);
        if (yieldAmount == 0) revert NoYieldAvailable(asset);

        emit Harvested(asset, strategy, yieldAmount, grvtBank);
    }

    // -------------------------------------------------------------------------
    // Configuration (DEFAULT_ADMIN_ROLE)
    // -------------------------------------------------------------------------

    /// @notice Whitelist an asset for deposits
    /// @param asset Token address
    function whitelistAsset(address asset) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (asset == address(0)) revert ZeroAddress();
        if (whitelistedAssets[asset]) revert AssetAlreadyWhitelisted(asset);

        whitelistedAssets[asset] = true;
        _assetList.push(asset);
        emit AssetWhitelisted(asset);
    }

    /// @notice Remove asset from whitelist (does not affect existing balances)
    /// @param asset Token address
    function removeAsset(address asset) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!whitelistedAssets[asset]) revert AssetNotWhitelisted(asset);
        if (assetStrategy[asset] != address(0)) revert StrategyStillSet(asset);

        whitelistedAssets[asset] = false;

        // Remove from _assetList by swap-and-pop
        uint256 len = _assetList.length;
        for (uint256 i; i < len; ++i) {
            if (_assetList[i] == asset) {
                _assetList[i] = _assetList[len - 1];
                _assetList.pop();
                break;
            }
        }

        emit AssetRemoved(asset);
    }

    /// @notice Register or replace the strategy for an asset
    /// @param asset Token address
    /// @param strategy IStrategy implementation address
    function setStrategy(address asset, address strategy) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (asset == address(0)) revert ZeroAddress();
        if (strategy == address(0)) revert ZeroAddress();
        if (!whitelistedAssets[asset]) revert AssetNotWhitelisted(asset);
        if (assetStrategy[asset] != address(0)) revert StrategyAlreadySet(asset);
        address strategyAsset = IStrategy(strategy).asset();
        if (strategyAsset != asset) revert StrategyAssetMismatch(asset, strategyAsset);
        address strategyVault = IStrategy(strategy).vault();
        if (strategyVault != address(this)) revert StrategyVaultMismatch(address(this), strategyVault);

        assetStrategy[asset] = strategy;
        emit StrategySet(asset, strategy);
    }

    /// @notice Remove the strategy for an asset (must have zero deployed)
    /// @param asset Token address
    function removeStrategy(address asset) external onlyRole(DEFAULT_ADMIN_ROLE) {
        address oldStrategy = assetStrategy[asset];
        if (oldStrategy == address(0)) revert StrategyNotSet(asset);

        uint256 remaining = deployedPrincipal[asset];
        if (remaining > 0) revert StrategyStillDeployed(asset, remaining);

        assetStrategy[asset] = address(0);
        emit StrategyRemoved(asset, oldStrategy);
    }

    /// @notice Set the yield recipient address
    /// @param newGrvtBank Address to receive harvested yield
    function setGrvtBank(address newGrvtBank) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newGrvtBank == address(0)) revert ZeroAddress();

        address oldBank = grvtBank;
        grvtBank = newGrvtBank;
        emit GrvtBankUpdated(oldBank, newGrvtBank);
    }

    // -------------------------------------------------------------------------
    // Emergency (DEFAULT_ADMIN_ROLE / GUARDIAN_ROLE)
    // -------------------------------------------------------------------------

    /// @notice Pause deposit, deploy, and harvest operations
    function pause() external onlyRole(GUARDIAN_ROLE) {
        _pause();
    }

    /// @notice Unpause operations
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /// @notice Emergency: pull all assets from a strategy back to idle
    /// @param asset Token address
    function emergencyWithdrawFromStrategy(address asset) external nonReentrant onlyRole(DEFAULT_ADMIN_ROLE) {
        address strategy = assetStrategy[asset];
        if (strategy == address(0)) revert StrategyNotSet(asset);

        uint256 recovered = IStrategy(strategy).emergencyWithdraw(address(this));

        idleBalance[asset] += recovered;
        deployedPrincipal[asset] = 0;

        emit EmergencyWithdrawal(asset, strategy, recovered);
    }

    // -------------------------------------------------------------------------
    // TVL Reporting (public view)
    // -------------------------------------------------------------------------

    /// @notice Per-asset balance breakdown
    /// @param asset Token address
    /// @return idle Tokens sitting in the vault contract
    /// @return deployed Current value in strategy (principal + yield)
    /// @return total idle + deployed
    function getAssetBalance(address asset)
        public
        view
        returns (uint256 idle, uint256 deployed, uint256 total)
    {
        idle = idleBalance[asset];
        address strategy = assetStrategy[asset];
        deployed = strategy != address(0) ? IStrategy(strategy).totalDeployed() : deployedPrincipal[asset];
        total = idle + deployed;
    }

    /// @notice All whitelisted assets and their balances
    /// @return assets Array of token addresses
    /// @return idle Array of idle balances
    /// @return deployed Array of deployed balances (live, includes yield)
    /// @return total Array of total balances
    function getAllAssetBalances()
        external
        view
        returns (
            address[] memory assets,
            uint256[] memory idle,
            uint256[] memory deployed,
            uint256[] memory total
        )
    {
        uint256 len = _assetList.length;
        assets = _assetList;
        idle = new uint256[](len);
        deployed = new uint256[](len);
        total = new uint256[](len);

        for (uint256 i; i < len; ++i) {
            (idle[i], deployed[i], total[i]) = getAssetBalance(assets[i]);
        }
    }

    /// @notice List all whitelisted asset addresses
    /// @return Array of whitelisted asset addresses
    function getWhitelistedAssets() external view returns (address[] memory) {
        return _assetList;
    }

    // -------------------------------------------------------------------------
    // Override resolution for dual AccessControl inheritance
    // -------------------------------------------------------------------------

    /// @inheritdoc AccessControlEnumerable
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(AccessControlEnumerable, AccessControlDefaultAdminRules)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    /// @inheritdoc AccessControlDefaultAdminRules
    function grantRole(bytes32 role, address account)
        public
        override(AccessControl, AccessControlDefaultAdminRules, IAccessControl)
    {
        super.grantRole(role, account);
    }

    /// @inheritdoc AccessControlDefaultAdminRules
    function revokeRole(bytes32 role, address account)
        public
        override(AccessControl, AccessControlDefaultAdminRules, IAccessControl)
    {
        super.revokeRole(role, account);
    }

    /// @inheritdoc AccessControlDefaultAdminRules
    function renounceRole(bytes32 role, address account)
        public
        override(AccessControl, AccessControlDefaultAdminRules, IAccessControl)
    {
        super.renounceRole(role, account);
    }

    /// @dev Resolves _setRoleAdmin between AccessControl and AccessControlDefaultAdminRules
    function _setRoleAdmin(bytes32 role, bytes32 adminRole)
        internal
        override(AccessControl, AccessControlDefaultAdminRules)
    {
        super._setRoleAdmin(role, adminRole);
    }

    /// @dev Resolves _grantRole between AccessControlEnumerable and AccessControlDefaultAdminRules
    function _grantRole(bytes32 role, address account)
        internal
        override(AccessControlEnumerable, AccessControlDefaultAdminRules)
        returns (bool)
    {
        return super._grantRole(role, account);
    }

    /// @dev Resolves _revokeRole between AccessControlEnumerable and AccessControlDefaultAdminRules
    function _revokeRole(bytes32 role, address account)
        internal
        override(AccessControlEnumerable, AccessControlDefaultAdminRules)
        returns (bool)
    {
        return super._revokeRole(role, account);
    }
}

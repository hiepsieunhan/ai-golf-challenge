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
        // Wave 2
    }

    /// @notice Deposit native ETH — auto-wraps to WETH
    function depositETH() external payable nonReentrant whenNotPaused onlyRole(DEPOSITOR_ROLE) {
        // Wave 2
    }

    // -------------------------------------------------------------------------
    // Strategy Operations (STRATEGIST_ROLE)
    // -------------------------------------------------------------------------

    /// @notice Deploy idle assets into the registered strategy
    /// @param asset Token to deploy
    /// @param amount Amount to deploy from idle balance
    function deployToStrategy(address asset, uint256 amount) external nonReentrant whenNotPaused onlyRole(STRATEGIST_ROLE) {
        // Wave 2
    }

    /// @notice Withdraw assets from the strategy back to idle
    /// @param asset Token to withdraw
    /// @param amount Amount to withdraw (type(uint256).max = all)
    function withdrawFromStrategy(address asset, uint256 amount) external nonReentrant onlyRole(STRATEGIST_ROLE) {
        // Wave 2
    }

    /// @notice Harvest yield from strategy, send to grvtBank
    /// @param asset Token whose yield to harvest
    function harvest(address asset) external nonReentrant whenNotPaused onlyRole(STRATEGIST_ROLE) {
        // Wave 2
    }

    // -------------------------------------------------------------------------
    // Configuration (DEFAULT_ADMIN_ROLE)
    // -------------------------------------------------------------------------

    /// @notice Whitelist an asset for deposits
    /// @param asset Token address
    function whitelistAsset(address asset) external onlyRole(DEFAULT_ADMIN_ROLE) {
        // Wave 2
    }

    /// @notice Remove asset from whitelist (does not affect existing balances)
    /// @param asset Token address
    function removeAsset(address asset) external onlyRole(DEFAULT_ADMIN_ROLE) {
        // Wave 2
    }

    /// @notice Register or replace the strategy for an asset
    /// @param asset Token address
    /// @param strategy IStrategy implementation address
    function setStrategy(address asset, address strategy) external onlyRole(DEFAULT_ADMIN_ROLE) {
        // Wave 2
    }

    /// @notice Remove the strategy for an asset (must have zero deployed)
    /// @param asset Token address
    function removeStrategy(address asset) external onlyRole(DEFAULT_ADMIN_ROLE) {
        // Wave 2
    }

    /// @notice Set the yield recipient address
    /// @param newGrvtBank Address to receive harvested yield
    function setGrvtBank(address newGrvtBank) external onlyRole(DEFAULT_ADMIN_ROLE) {
        // Wave 2
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
        // Wave 2
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
        external
        view
        returns (uint256 idle, uint256 deployed, uint256 total)
    {
        // Wave 2
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
        // Wave 2
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

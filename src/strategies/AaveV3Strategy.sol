// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";
import {IPool} from "@aave/v3-core/contracts/interfaces/IPool.sol";

/// @title AaveV3Strategy
/// @notice Aave V3 implementation of IStrategy. Holds aTokens, supplies/withdraws
///         from the Aave V3 Pool, and computes yield via aToken rebasing balance.
contract AaveV3Strategy is IStrategy, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error CallerNotVault(address caller);
    error ZeroAmount();
    error ZeroAddress();

    // -------------------------------------------------------------------------
    // Immutables
    // -------------------------------------------------------------------------

    /// @notice The GrvtVault address that controls this strategy
    address public immutable override vault;

    /// @notice Aave V3 Pool proxy address
    address public immutable aavePool;

    /// @notice The ERC-20 asset this strategy handles
    address private immutable _asset;

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    /// @dev Sum of deployed amounts minus withdrawn amounts
    uint256 internal _principal;

    // -------------------------------------------------------------------------
    // Modifiers
    // -------------------------------------------------------------------------

    /// @dev Restricts calls to the bound vault contract
    modifier onlyVault() {
        if (msg.sender != vault) revert CallerNotVault(msg.sender);
        _;
    }

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    /// @notice Deploy a new AaveV3Strategy
    /// @param _vault The GrvtVault address
    /// @param _aavePool The Aave V3 Pool proxy address
    /// @param asset__ The ERC-20 asset this strategy manages
    constructor(address _vault, address _aavePool, address asset__) {
        if (_vault == address(0)) revert ZeroAddress();
        if (_aavePool == address(0)) revert ZeroAddress();
        if (asset__ == address(0)) revert ZeroAddress();

        vault = _vault;
        aavePool = _aavePool;
        _asset = asset__;
    }

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    /// @inheritdoc IStrategy
    function asset() external view override returns (address) {
        return _asset;
    }

    /// @inheritdoc IStrategy
    function totalDeployed() external view override returns (uint256) {
        // Wave 2
        return 0;
    }

    /// @notice Pending yield available for harvest
    /// @return yield The difference between current aToken balance and principal
    function pendingYield() external view returns (uint256) {
        // Wave 2
        return 0;
    }

    // -------------------------------------------------------------------------
    // Mutative (vault-only)
    // -------------------------------------------------------------------------

    /// @inheritdoc IStrategy
    function deploy(uint256 amount) external override onlyVault nonReentrant {
        // Wave 2
    }

    /// @inheritdoc IStrategy
    function withdraw(uint256 amount) external override onlyVault nonReentrant returns (uint256 actual) {
        // Wave 2
        return 0;
    }

    /// @inheritdoc IStrategy
    function harvest(address recipient) external override onlyVault nonReentrant returns (uint256 yieldAmount) {
        // Wave 2
        return 0;
    }

    /// @inheritdoc IStrategy
    function emergencyWithdraw(address recipient) external override onlyVault nonReentrant returns (uint256 recovered) {
        // Wave 2
        return 0;
    }
}

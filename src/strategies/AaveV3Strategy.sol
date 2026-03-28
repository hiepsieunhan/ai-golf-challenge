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
    // Events
    // -------------------------------------------------------------------------

    event Deployed(uint256 amount);
    event Withdrawn(uint256 amount);
    event YieldHarvested(uint256 yieldAmount, address indexed recipient);
    event EmergencyWithdrawn(uint256 recovered, address indexed recipient);

    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    /// @dev Aave referral code (unused, set to 0)
    uint16 private constant REFERRAL_CODE = 0;

    // -------------------------------------------------------------------------
    // Immutables
    // -------------------------------------------------------------------------

    /// @notice The GrvtVault address that controls this strategy
    address public immutable override vault;

    /// @notice Aave V3 Pool proxy address
    address public immutable aavePool;

    /// @notice The aToken corresponding to the underlying asset
    address public immutable aToken;

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

        // Resolve the aToken address from Aave's reserve data
        address resolvedAToken = IPool(_aavePool).getReserveData(asset__).aTokenAddress;
        if (resolvedAToken == address(0)) revert ZeroAddress();
        aToken = resolvedAToken;
    }

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    /// @inheritdoc IStrategy
    function asset() external view override returns (address) {
        return _asset;
    }

    /// @inheritdoc IStrategy
    function totalDeployed() public view override returns (uint256) {
        return IERC20(aToken).balanceOf(address(this));
    }

    /// @notice Pending yield available for harvest
    /// @return The difference between current aToken balance and principal
    function pendingYield() external view returns (uint256) {
        uint256 current = totalDeployed();
        if (current <= _principal) return 0;
        return current - _principal;
    }

    // -------------------------------------------------------------------------
    // Mutative (vault-only)
    // -------------------------------------------------------------------------

    /// @inheritdoc IStrategy
    function deploy(uint256 amount) external override onlyVault nonReentrant {
        if (amount == 0) revert ZeroAmount();

        IERC20 token = IERC20(_asset);

        // Approve Aave Pool to pull tokens, then supply
        token.forceApprove(aavePool, amount);
        IPool(aavePool).supply(_asset, amount, address(this), REFERRAL_CODE);
        token.forceApprove(aavePool, 0);

        _principal += amount;

        emit Deployed(amount);
    }

    /// @inheritdoc IStrategy
    function withdraw(uint256 amount) external override onlyVault nonReentrant returns (uint256 actual) {
        if (amount == 0) revert ZeroAmount();

        // Aave natively handles type(uint256).max as "withdraw all"
        actual = IPool(aavePool).withdraw(_asset, amount, vault);

        // Adjust principal: floor at zero for safety (handles rounding)
        if (amount == type(uint256).max || actual >= _principal) {
            _principal = 0;
        } else {
            _principal -= actual;
        }

        emit Withdrawn(actual);
    }

    /// @inheritdoc IStrategy
    function harvest(address recipient) external override onlyVault nonReentrant returns (uint256 yieldAmount) {
        if (recipient == address(0)) revert ZeroAddress();

        uint256 current = totalDeployed();
        if (current <= _principal) return 0;

        yieldAmount = current - _principal;

        // Withdraw only the yield portion, send directly to recipient
        IPool(aavePool).withdraw(_asset, yieldAmount, recipient);

        // _principal unchanged — remaining aToken balance still equals principal

        emit YieldHarvested(yieldAmount, recipient);
    }

    /// @inheritdoc IStrategy
    function emergencyWithdraw(address recipient) external override onlyVault nonReentrant returns (uint256 recovered) {
        if (recipient == address(0)) revert ZeroAddress();

        uint256 balance = IERC20(aToken).balanceOf(address(this));
        if (balance == 0) return 0;

        // Withdraw everything from Aave
        recovered = IPool(aavePool).withdraw(_asset, type(uint256).max, recipient);

        _principal = 0;

        emit EmergencyWithdrawn(recovered, recipient);
    }
}

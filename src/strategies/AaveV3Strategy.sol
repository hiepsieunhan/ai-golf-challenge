// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";
import {IPool} from "@aave/v3-core/contracts/interfaces/IPool.sol";

/// @title AaveV3Strategy
/// @notice Aave V3 implementation of IStrategy. Holds aTokens, supplies/withdraws
///         from the Aave V3 Pool, and computes yield via aToken rebasing balance.
/// @dev Uses ReentrancyGuardTransient (EIP-1153 TSTORE/TLOAD). Deploy only to
///      networks with the Cancun hard fork activated (Ethereum mainnet post-March 2024).
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
    address private immutable _VAULT;

    /// @notice Aave V3 Pool proxy address
    address private immutable _AAVE_POOL;

    /// @notice The aToken corresponding to the underlying asset
    address private immutable _A_TOKEN;

    /// @notice The ERC-20 asset this strategy handles
    address private immutable _ASSET;

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
        if (msg.sender != _VAULT) revert CallerNotVault(msg.sender);
        _;
    }

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    /// @notice Deploy a new AaveV3Strategy
    /// @param vault_ The GrvtVault address
    /// @param aavePool_ The Aave V3 Pool proxy address
    /// @param asset_ The ERC-20 asset this strategy manages
    constructor(address vault_, address aavePool_, address asset_) {
        if (vault_ == address(0)) revert ZeroAddress();
        if (aavePool_ == address(0)) revert ZeroAddress();
        if (asset_ == address(0)) revert ZeroAddress();

        _VAULT = vault_;
        _AAVE_POOL = aavePool_;
        _ASSET = asset_;

        // Resolve the aToken address from Aave's reserve data
        address resolvedAToken = IPool(aavePool_).getReserveData(asset_).aTokenAddress;
        if (resolvedAToken == address(0)) revert ZeroAddress();
        _A_TOKEN = resolvedAToken;
    }

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    /// @inheritdoc IStrategy
    function asset() external view override returns (address) {
        return _ASSET;
    }

    /// @inheritdoc IStrategy
    function vault() external view override returns (address) {
        return _VAULT;
    }

    /// @inheritdoc IStrategy
    function totalDeployed() public view override returns (uint256) {
        return IERC20(_A_TOKEN).balanceOf(address(this));
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

        // Effects before interactions (CEI pattern)
        _principal += amount;

        // Interactions: approve, supply to Aave, reset approval
        IERC20 token = IERC20(_ASSET);
        token.forceApprove(_AAVE_POOL, amount);
        IPool(_AAVE_POOL).supply(_ASSET, amount, address(this), REFERRAL_CODE);
        token.forceApprove(_AAVE_POOL, 0);

        emit Deployed(amount);
    }

    /// @inheritdoc IStrategy
    function withdraw(uint256 amount) external override onlyVault nonReentrant returns (uint256 actual) {
        if (amount == 0) revert ZeroAmount();

        // Aave natively handles type(uint256).max as "withdraw all"
        actual = IPool(_AAVE_POOL).withdraw(_ASSET, amount, _VAULT);

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
        uint256 actualYield = IPool(_AAVE_POOL).withdraw(_ASSET, yieldAmount, recipient);

        // Re-sync principal to actual remaining aToken balance (handles Aave rounding)
        _principal = IERC20(_A_TOKEN).balanceOf(address(this));

        emit YieldHarvested(actualYield, recipient);
        return actualYield;
    }

    /// @inheritdoc IStrategy
    function emergencyWithdraw(address recipient) external override onlyVault nonReentrant returns (uint256 recovered) {
        if (recipient == address(0)) revert ZeroAddress();

        uint256 balance = IERC20(_A_TOKEN).balanceOf(address(this));
        if (balance == 0) return 0;

        // Withdraw everything from Aave
        recovered = IPool(_AAVE_POOL).withdraw(_ASSET, type(uint256).max, recipient);

        _principal = 0;

        emit EmergencyWithdrawn(recovered, recipient);
    }
}

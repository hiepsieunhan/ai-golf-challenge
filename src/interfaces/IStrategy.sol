// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

interface IStrategy {
    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    /// @notice The ERC-20 asset this strategy operates on
    /// @return The underlying token address (e.g., USDC, WETH)
    function asset() external view returns (address);

    /// @notice The vault this strategy is bound to
    /// @return The vault contract address
    function vault() external view returns (address);

    /// @notice Total value currently in the protocol (principal + accrued yield)
    /// @return Total value in units of asset()
    function totalDeployed() external view returns (uint256);

    // -------------------------------------------------------------------------
    // Mutative (vault-only)
    // -------------------------------------------------------------------------

    /// @notice Deploy tokens into the yield protocol
    /// @dev Vault must transfer tokens to this contract before calling
    /// @param amount Amount of asset to deploy
    function deploy(uint256 amount) external;

    /// @notice Withdraw tokens from the yield protocol back to the vault
    /// @param amount Amount to withdraw (type(uint256).max = withdraw all)
    /// @return actual Amount actually returned to the vault
    function withdraw(uint256 amount) external returns (uint256 actual);

    /// @notice Harvest accrued yield and send to recipient
    /// @param recipient Address to receive harvested yield (grvtBank)
    /// @return yieldAmount Amount of yield harvested
    function harvest(address recipient) external returns (uint256 yieldAmount);

    /// @notice Emergency: withdraw everything, send to recipient
    /// @param recipient Address to receive all recovered assets
    /// @return recovered Total amount recovered
    function emergencyWithdraw(address recipient) external returns (uint256 recovered);
}

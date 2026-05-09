// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Minimal DeployersWhitelist ABI shared by factories and frontend integrations.
interface IDeployersWhitelist {
    event AdminUpdated(address indexed admin, bool enabled);
    event DeployerWhitelistUpdated(address indexed deployer, bool enabled);

    error OnlyAdmin();
    error OwnableUnauthorizedAccount(address account);

    /// @notice Returns whether `deployer` may configure extended tax durations.
    function isWhitelisted(address deployer) external view returns (bool enabled);

    /// @notice Adds or removes a deployer from the extended-tax whitelist. Callable only by admins.
    function setWhitelisted(address deployer, bool enabled) external;
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable, Ownable2Step} from "lib/openzeppelin-contracts/contracts/access/Ownable2Step.sol";

/// @notice Admin-managed whitelist for deployers allowed to use extended tax durations.
contract DeployersWhitelist is Ownable2Step {
    /// @notice Accounts allowed to update deployer whitelist entries.
    mapping(address admin => bool enabled) public admins;

    /// @notice Deployers allowed to use extended tax durations in factories.
    mapping(address deployer => bool enabled) public isWhitelisted;

    event AdminUpdated(address indexed admin, bool enabled);
    event DeployerWhitelistUpdated(address indexed deployer, bool enabled);

    error OnlyAdmin();

    modifier onlyAdmin() {
        require(admins[msg.sender], OnlyAdmin());
        _;
    }

    constructor() Ownable(msg.sender) {}

    /// @notice Adds or removes an admin. Callable only by the owner.
    function setAdmin(address admin, bool enabled) external onlyOwner {
        admins[admin] = enabled;
        emit AdminUpdated(admin, enabled);
    }

    /// @notice Adds or removes a deployer from the extended-tax whitelist. Callable only by admins.
    function setWhitelisted(address deployer, bool enabled) external onlyAdmin {
        isWhitelisted[deployer] = enabled;
        emit DeployerWhitelistUpdated(deployer, enabled);
    }
}

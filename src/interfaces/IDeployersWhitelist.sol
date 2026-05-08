// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IDeployersWhitelist {
    function isWhitelisted(address deployer) external view returns (bool);
}

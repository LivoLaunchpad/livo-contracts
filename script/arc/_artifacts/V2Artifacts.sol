// SPDX-License-Identifier: MIT
pragma solidity =0.5.16;

// Compile-anchor for the Uniswap V2 factory (0.5.16). Importing the factory also pulls in
// UniswapV2Pair (it reads `type(UniswapV2Pair).creationCode`), so the pair artifact — needed for the
// init-code-hash in DeployUniswapArc — is built too. Router02 (0.6.6) is anchored separately.
import "lib/v2-core/contracts/UniswapV2Factory.sol";

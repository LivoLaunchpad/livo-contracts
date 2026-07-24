// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Compile-anchor for UniversalRouter (see V4Artifacts.sol). This file is pinned to via_ir in
// foundry.toml so it compiles in the same IR unit as UniversalRouter (which needs it — V3SwapRouter
// overflows the stack otherwise).
import "lib/universal-router/contracts/UniversalRouter.sol";

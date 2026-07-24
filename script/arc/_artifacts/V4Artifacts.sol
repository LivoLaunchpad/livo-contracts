// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Compile-anchors: nothing in Livo imports these concrete Uniswap V4 contracts (only their
// interfaces), so Foundry would not build them and `DeployUniswapArc`'s `deployCode` lookups would
// fail with "no matching artifact found". Named imports force the artifacts to exist without
// re-exporting colliding transitive symbols.
import {PoolManager} from "lib/v4-core/src/PoolManager.sol";
import {PositionManager} from "lib/v4-periphery/src/PositionManager.sol";
import {PositionDescriptor} from "lib/v4-periphery/src/PositionDescriptor.sol";
import {StateView} from "lib/v4-periphery/src/lens/StateView.sol";
import {V4Quoter} from "lib/v4-periphery/src/lens/V4Quoter.sol";

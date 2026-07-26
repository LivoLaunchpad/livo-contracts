// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "lib/forge-std/src/Script.sol";
import {console} from "lib/forge-std/src/console.sol";
import {MinimalWETH9} from "./MinimalWETH9.sol";
import {DeploymentAddressesArcTestnet as Arc} from "src/config/DeploymentAddresses.sol";

/// @title DeployUniswapV2RouterArc
/// @notice Redeploys ONLY the Uniswap V2 Router02 on ARC testnet, from the vendored
///         `LivoUniswapV2Router02` whose `LivoUniswapV2Library` bakes THIS repo's real pair
///         init-code-hash (0xb5a7f108…). The originally-deployed stock Router02 (`Arc.UNIV2_ROUTER`)
///         baked the stock mainnet hash (0x96e8ac42…), which does NOT match this repo's factory, so
///         its `pairFor` targets a non-contract and every `addLiquidity`/`swap` reverts. The factory
///         and existing pairs are untouched — only the router is replaced.
///
///         After running: paste the new address into `DeploymentAddressesArcTestnet.UNIV2_ROUTER`,
///         then `just export-deployments`.
///
/// Dry run: forge script DeployUniswapV2RouterArc --rpc-url arc-testnet
/// Deploy:  forge script DeployUniswapV2RouterArc --rpc-url arc-testnet --account livo.dev --broadcast \
///            --slow --gas-estimate-multiplier 300
contract DeployUniswapV2RouterArc is Script {
    uint256 constant ARC_TESTNET = 5042002;

    function run() external {
        require(block.chainid == ARC_TESTNET, "DeployUniswapV2RouterArc: ARC testnet (5042002) only");

        // Drift guard: the vendored library hardcodes 0xb5a7…; it MUST equal the freshly-compiled
        // UniswapV2Pair hash (= what the factory actually deploys), else the new router is wrong too.
        bytes32 pairHash = keccak256(vm.getCode("out/UniswapV2Pair.sol/UniswapV2Pair.json"));
        require(
            pairHash == Arc.UNIV2_PAIR_INIT_CODE_HASH,
            "pair init-code-hash drift: update LivoUniswapV2Library + Arc.UNIV2_PAIR_INIT_CODE_HASH, rebuild"
        );

        vm.startBroadcast();
        // Inert WETH stub only satisfies the ctor; Livo's ARC paths never call router.WETH().
        address weth9 = address(new MinimalWETH9());
        address router = deployCode(
            "out/LivoUniswapV2Router02.sol/LivoUniswapV2Router02.json", abi.encode(Arc.UNIV2_FACTORY, weth9)
        );
        vm.stopBroadcast();

        console.log("=== ARC testnet Uniswap V2 Router REDEPLOY (chainId %s) ===", block.chainid);
        console.log("Factory (unchanged):       %s", Arc.UNIV2_FACTORY);
        console.log("Old (broken) Router02:     %s", Arc.UNIV2_ROUTER);
        console.log("New LivoUniswapV2Router02: %s", router);
        console.log("-> paste into DeploymentAddressesArcTestnet.UNIV2_ROUTER, then `just export-deployments`");
    }
}

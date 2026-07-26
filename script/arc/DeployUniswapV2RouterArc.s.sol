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

        // NB: no local `keccak256(UniswapV2Pair)` drift check here — this redeploys the router ONLY,
        // against the EXISTING factory (Arc.UNIV2_FACTORY), whose deployed pairs hash to
        // Arc.UNIV2_PAIR_INIT_CODE_HASH (0xb5a7…). The vendored router bakes exactly that constant, and
        // `test/arc/UniswapV2RouterArcFix.t.sol` proves it works against the real factory. A local
        // pair-hash would instead reflect THIS environment's compile (solc metadata varies by
        // compilation unit) — relevant only when also redeploying the factory (see DeployUniswapArc).

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

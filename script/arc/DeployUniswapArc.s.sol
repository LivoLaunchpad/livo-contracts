// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "lib/forge-std/src/Script.sol";
import {console} from "lib/forge-std/src/console.sol";
import {RouterParameters} from "lib/universal-router/contracts/types/RouterParameters.sol";
import {MinimalWETH9} from "./MinimalWETH9.sol";

/// @title DeployUniswapArc
/// @notice Deploys a self-owned Uniswap V2 + V4 stack on ARC testnet (Circle L1, native = USDC), since
///         no official/canonical Uniswap exists there. Everything is deployed via `deployCode` so this
///         0.8.28 script can bring up the mixed-compiler sources (V2 factory 0.5.16, router 0.6.6, V4
///         core/periphery 0.8.26, UniversalRouter 0.8.26+viaIR) without importing them.
///
///         Notes for ARC (no WETH, USDC is native):
///           - Permit2 is already live at the canonical address; reused, not deployed.
///           - V4 pairs use native `address(0)`; V2 pairs use the 6-dec USDC ERC-20 (`0x3600..`) as the
///             quote token. Neither needs a wrapped-native, so `MinimalWETH9` is an inert stub that only
///             satisfies the PositionManager/UniversalRouter constructors.
///           - The V2 pair init-code-hash is computed + logged; paste it into
///             `DeploymentAddressesArcTestnet.UNIV2_PAIR_INIT_CODE_HASH`.
///
/// Dry run: forge script DeployUniswapArc --rpc-url arc-testnet
/// Deploy:  forge script DeployUniswapArc --rpc-url arc-testnet --account livo.dev --broadcast --slow \
///            --gas-estimate-multiplier 300
contract DeployUniswapArc is Script {
    /// @notice Canonical Permit2, already deployed on ARC testnet.
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    /// @notice Native USDC 6-dec ERC-20 alias — the V2 quote token on ARC.
    address constant USDC = 0x3600000000000000000000000000000000000000;
    /// @notice PositionManager subscriber-unsubscribe gas cap. Not used by Livo (NFTs are locked, never
    ///         subscribed); a standard value that only bounds third-party subscriber callbacks.
    uint256 constant UNSUBSCRIBE_GAS_LIMIT = 100_000;
    uint256 constant ARC_TESTNET = 5042002;

    function run() external {
        require(block.chainid == ARC_TESTNET, "DeployUniswapArc: ARC testnet (5042002) only");
        // PoolManager owner + V2 feeToSetter. The broadcaster for now; hand to the Livo multisig later.
        address owner = msg.sender;

        vm.startBroadcast();

        // --- inert WETH9 stub (only to satisfy Uniswap constructors; ARC has no wrapped-native) ---
        address weth9 = address(new MinimalWETH9());

        // --- Uniswap V4 core + periphery ---
        address poolManager = deployCode("out/PoolManager.sol/PoolManager.json", abi.encode(owner));
        address descriptor = deployCode(
            "out/PositionDescriptor.sol/PositionDescriptor.json", abi.encode(poolManager, weth9, bytes32("USDC"))
        );
        address positionManager = deployCode(
            "out/PositionManager.sol/PositionManager.json",
            abi.encode(poolManager, PERMIT2, UNSUBSCRIBE_GAS_LIMIT, descriptor, weth9)
        );
        address stateView = deployCode("out/StateView.sol/StateView.json", abi.encode(poolManager));
        address v4Quoter = deployCode("out/V4Quoter.sol/V4Quoter.json", abi.encode(poolManager));

        // --- Uniswap V2 (token + USDC-ERC20 pairs) ---
        address v2Factory = deployCode("out/UniswapV2Factory.sol/UniswapV2Factory.json", abi.encode(owner));
        // Use the VENDORED router whose UniswapV2Library bakes THIS repo's pair init-code-hash. The
        // stock out/UniswapV2Router02 bakes the mainnet hash 0x96e8ac42… and is broken against our
        // factory (pairFor → non-contract). See script/arc/vendored/ + DeployUniswapV2RouterArc.
        address v2Router =
            deployCode("out/LivoUniswapV2Router02.sol/LivoUniswapV2Router02.json", abi.encode(v2Factory, weth9));
        bytes32 v2PairInitCodeHash = keccak256(vm.getCode("out/UniswapV2Pair.sol/UniswapV2Pair.json"));
        // The vendored library's hardcoded hash must match the freshly-compiled pair, else the router
        // is misdeployed exactly like the stock one. Catch drift at deploy time.
        require(
            v2PairInitCodeHash == 0xb5a7f1081ecaa7c30957adf56bd79febe0588ca66ec38a0fb1ee92e7d324b3f9,
            "pair hash drift: update LivoUniswapV2Library hardcoded hash + rebuild"
        );

        // --- UniversalRouter (V4 swap routing; V3 params zeroed — unused on ARC) ---
        RouterParameters memory rp = RouterParameters({
            permit2: PERMIT2,
            weth9: weth9,
            v2Factory: v2Factory,
            v3Factory: address(0),
            pairInitCodeHash: v2PairInitCodeHash,
            poolInitCodeHash: bytes32(0),
            v4PoolManager: poolManager,
            permissionsAdapterFactory: address(0),
            v3NFTPositionManager: address(0),
            v4PositionManager: positionManager,
            spokePool: address(0)
        });
        address universalRouter = deployCode("out/UniversalRouter.sol/UniversalRouter.json", abi.encode(rp));

        vm.stopBroadcast();

        console.log("=== ARC testnet Uniswap deployment (chainId %s) ===", block.chainid);
        console.log("MinimalWETH9 (stub):     %s", weth9);
        console.log("Permit2 (canonical):     %s", PERMIT2);
        console.log("USDC (V2 quote, 6-dec):  %s", USDC);
        console.log("-- Uniswap V4 --");
        console.log("PoolManager:             %s", poolManager);
        console.log("PositionDescriptor:      %s", descriptor);
        console.log("PositionManager:         %s", positionManager);
        console.log("StateView:               %s", stateView);
        console.log("V4Quoter:                %s", v4Quoter);
        console.log("UniversalRouter:         %s", universalRouter);
        console.log("-- Uniswap V2 --");
        console.log("UniswapV2Factory:        %s", v2Factory);
        console.log("UniswapV2Router02:       %s", v2Router);
        console.log("UNIV2_PAIR_INIT_CODE_HASH (paste into DeploymentAddressesArcTestnet):");
        console.logBytes32(v2PairInitCodeHash);
    }
}

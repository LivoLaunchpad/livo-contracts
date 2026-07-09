// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {LivoGraduatorUniswapV4} from "src/graduators/LivoGraduatorUniswapV4.sol";
import {UniswapV4PoolConstants} from "src/libraries/UniswapV4PoolConstants.sol";
import {
    DeploymentAddressesEthereumMainnet,
    DeploymentAddressesEthereumSepolia
} from "src/config/DeploymentAddresses.sol";
import {DeploymentsEthereumMainnet} from "src/config/manifest.ethereum.mainnet.sol";
import {DeploymentsEthereumSepolia} from "src/config/manifest.ethereum.sepolia.sol";

/// @title Redeploy all six `LivoGraduatorUniswapV4` instances (bytecode-only change)
/// @notice Redeploys the six V4 graduators (DEFAULT/THIN/THICK x 100/50-bps hook) with unchanged
///         constructor args, so the only difference is the updated `PoolIdRegistered` event (now
///         carrying `swapHookAddress`). Curves, the V2 graduator, and token impls are untouched.
///
///         After running, paste the six printed addresses into their manifest slots
///         (`GRADUATOR_UNIV4`, `GRADUATOR_UNIV4_0P5`, `GRADUATOR_UNIV4_THIN(_0P5)`,
///         `GRADUATOR_UNIV4_THICK(_0P5)`) in `src/config/manifest.<chain>.sol`, run
///         `just export-deployments`, and only THEN flip the V4 factory to point at them
///         (`RedeployUnifiedFactoriesOnly`).
///
/// @dev    Run with:
///         forge script RedeployUniV4Graduators --rpc-url <mainnet|sepolia> \
///             --verify --account livo.dev --slow --broadcast
contract RedeployUniV4Graduators is Script {
    /// @dev Graduation prices per tier, from `simulations/script/uniswapV4Settings.py`. Mirrors the
    ///      values already hardcoded in `DeployTierLiquiditySystem` / `DeployUniV4Graduator0p5`.
    uint160 internal constant DEFAULT_GRAD_SQRT_PRICE_X96 = 715832709642994126662528799866880; // 12.25 ETH mcap
    uint160 internal constant THIN_GRAD_SQRT_PRICE_X96 = 1012340326367404053977557838594048; // 6.125 ETH mcap
    uint160 internal constant THICK_GRAD_SQRT_PRICE_X96 = 506170163183702026988778919297024; // 24.5 ETH mcap

    struct Deps {
        address launchpad;
        address poolManager;
        address positionManager;
        address permit2;
        address hook100; // 100-bps LivoSwapHook
        address hook50; // 50-bps LivoSwapHook
    }

    function run() external {
        Deps memory d = _resolveDeps();

        console.log("=== Redeploy the six LivoGraduatorUniswapV4 instances ===");
        console.log("Chain ID:", block.chainid);
        console.log("Deployer:", msg.sender);
        console.log("");

        int24 tickDefault = UniswapV4PoolConstants.TICK_UPPER;
        int24 tickThin = UniswapV4PoolConstants.TICK_UPPER_THIN;

        vm.startBroadcast();
        address gradDefault = _deployGraduator(d, d.hook100, DEFAULT_GRAD_SQRT_PRICE_X96, tickDefault);
        address gradDefault0p5 = _deployGraduator(d, d.hook50, DEFAULT_GRAD_SQRT_PRICE_X96, tickDefault);
        address gradThin = _deployGraduator(d, d.hook100, THIN_GRAD_SQRT_PRICE_X96, tickThin);
        address gradThin0p5 = _deployGraduator(d, d.hook50, THIN_GRAD_SQRT_PRICE_X96, tickThin);
        address gradThick = _deployGraduator(d, d.hook100, THICK_GRAD_SQRT_PRICE_X96, tickDefault);
        address gradThick0p5 = _deployGraduator(d, d.hook50, THICK_GRAD_SQRT_PRICE_X96, tickDefault);
        vm.stopBroadcast();

        console.log("=== Deployed. Paste into src/config/manifest.<chain>.sol ===");
        console.log("GRADUATOR_UNIV4          ", gradDefault);
        console.log("GRADUATOR_UNIV4_0P5      ", gradDefault0p5);
        console.log("GRADUATOR_UNIV4_THIN     ", gradThin);
        console.log("GRADUATOR_UNIV4_THIN_0P5 ", gradThin0p5);
        console.log("GRADUATOR_UNIV4_THICK    ", gradThick);
        console.log("GRADUATOR_UNIV4_THICK_0P5", gradThick0p5);
        console.log("");
        console.log("Next: update the manifest, `just export-deployments`, then RedeployUnifiedFactoriesOnly.");
    }

    function _deployGraduator(Deps memory d, address hook, uint160 sqrtPriceGraduation, int24 tickUpper)
        internal
        returns (address)
    {
        LivoGraduatorUniswapV4 graduator = new LivoGraduatorUniswapV4(
            d.launchpad, d.poolManager, d.positionManager, d.permit2, hook, sqrtPriceGraduation, tickUpper
        );
        require(graduator.HOOK_ADDRESS() == hook, "graduator hook mismatch");
        return address(graduator);
    }

    function _resolveDeps() internal view returns (Deps memory d) {
        if (block.chainid == DeploymentAddressesEthereumMainnet.BLOCKCHAIN_ID) {
            d = Deps({
                launchpad: DeploymentsEthereumMainnet.LAUNCHPAD,
                poolManager: DeploymentAddressesEthereumMainnet.UNIV4_POOL_MANAGER,
                positionManager: DeploymentAddressesEthereumMainnet.UNIV4_POSITION_MANAGER,
                permit2: DeploymentAddressesEthereumMainnet.PERMIT2,
                hook100: DeploymentsEthereumMainnet.SWAP_HOOK,
                hook50: DeploymentsEthereumMainnet.SWAP_HOOK_0P5
            });
        } else if (block.chainid == DeploymentAddressesEthereumSepolia.BLOCKCHAIN_ID) {
            d = Deps({
                launchpad: DeploymentsEthereumSepolia.LAUNCHPAD,
                poolManager: DeploymentAddressesEthereumSepolia.UNIV4_POOL_MANAGER,
                positionManager: DeploymentAddressesEthereumSepolia.UNIV4_POSITION_MANAGER,
                permit2: DeploymentAddressesEthereumSepolia.PERMIT2,
                hook100: DeploymentsEthereumSepolia.SWAP_HOOK,
                hook50: DeploymentsEthereumSepolia.SWAP_HOOK_0P5
            });
        } else {
            revert("Unsupported chain ID");
        }

        require(d.launchpad != address(0), "manifest: LAUNCHPAD missing");
        require(d.hook100 != address(0), "manifest: SWAP_HOOK missing");
        require(d.hook50 != address(0), "manifest: SWAP_HOOK_0P5 missing");
    }
}

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

/// @title Redeploy all three `LivoGraduatorUniswapV4` instances (bytecode-only change)
/// @notice Redeploys the three V4 graduators (one per liquidity tier: DEFAULT/THIN/THICK) with
///         unchanged constructor args, so the only difference is the updated `PoolIdRegistered` event
///         (now carrying `swapHookAddress`). All three pair with the single fee-agnostic `SWAP_HOOK`,
///         which reads the LP fee from the token. Curves, the V2 graduator, and token impls are
///         untouched.
///
///         After running, paste the three printed addresses into their manifest slots
///         (`GRADUATOR_UNIV4`, `GRADUATOR_UNIV4_THIN`, `GRADUATOR_UNIV4_THICK`) in
///         `src/config/manifest.<chain>.sol`, run `just export-deployments`, and only THEN flip the V4
///         factory to point at them (`RedeployUnifiedFactoriesOnly`).
///
/// @dev    Run with:
///         forge script RedeployUniV4Graduators --rpc-url <mainnet|sepolia> \
///             --verify --account livo.dev --slow --broadcast
contract RedeployUniV4Graduators is Script {
    /// @dev Graduation prices per tier, from `simulations/script/uniswapV4Settings.py`. Mirrors the
    ///      values already hardcoded in `DeployTierLiquiditySystem`.
    uint160 internal constant DEFAULT_GRAD_SQRT_PRICE_X96 = 715832709642994126662528799866880; // 12.25 ETH mcap
    uint160 internal constant THIN_GRAD_SQRT_PRICE_X96 = 1012340326367404053977557838594048; // 6.125 ETH mcap
    uint160 internal constant THICK_GRAD_SQRT_PRICE_X96 = 506170163183702026988778919297024; // 24.5 ETH mcap

    struct Deps {
        address launchpad;
        address poolManager;
        address positionManager;
        address permit2;
        address hook; // fee-agnostic LivoSwapHook (reads the LP fee from the token)
    }

    function run() external {
        Deps memory d = _resolveDeps();

        console.log("=== Redeploy the three LivoGraduatorUniswapV4 instances ===");
        console.log("Chain ID:", block.chainid);
        console.log("Deployer:", msg.sender);
        console.log("");

        int24 tickDefault = UniswapV4PoolConstants.TICK_UPPER;
        int24 tickThin = UniswapV4PoolConstants.TICK_UPPER_THIN;

        vm.startBroadcast();
        address gradDefault = _deployGraduator(d, d.hook, DEFAULT_GRAD_SQRT_PRICE_X96, tickDefault);
        address gradThin = _deployGraduator(d, d.hook, THIN_GRAD_SQRT_PRICE_X96, tickThin);
        address gradThick = _deployGraduator(d, d.hook, THICK_GRAD_SQRT_PRICE_X96, tickDefault);
        vm.stopBroadcast();

        console.log("=== Deployed. Paste into src/config/manifest.<chain>.sol ===");
        console.log("GRADUATOR_UNIV4      ", gradDefault);
        console.log("GRADUATOR_UNIV4_THIN ", gradThin);
        console.log("GRADUATOR_UNIV4_THICK", gradThick);
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
                hook: DeploymentsEthereumMainnet.SWAP_HOOK
            });
        } else if (block.chainid == DeploymentAddressesEthereumSepolia.BLOCKCHAIN_ID) {
            d = Deps({
                launchpad: DeploymentsEthereumSepolia.LAUNCHPAD,
                poolManager: DeploymentAddressesEthereumSepolia.UNIV4_POOL_MANAGER,
                positionManager: DeploymentAddressesEthereumSepolia.UNIV4_POSITION_MANAGER,
                permit2: DeploymentAddressesEthereumSepolia.PERMIT2,
                hook: DeploymentsEthereumSepolia.SWAP_HOOK
            });
        } else {
            revert("Unsupported chain ID");
        }

        require(d.launchpad != address(0), "manifest: LAUNCHPAD missing");
        require(d.hook != address(0), "manifest: SWAP_HOOK missing");
    }
}

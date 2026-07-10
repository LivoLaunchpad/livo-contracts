// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "lib/forge-std/src/Script.sol";
import {console} from "lib/forge-std/src/console.sol";
import {LivoGraduatorUniswapV4} from "src/graduators/LivoGraduatorUniswapV4.sol";
import {UniswapV4PoolConstants} from "src/libraries/UniswapV4PoolConstants.sol";
import {
    DeploymentAddressesEthereumMainnet,
    DeploymentAddressesEthereumSepolia
} from "src/config/DeploymentAddresses.sol";
import {DeploymentsEthereumMainnet} from "src/config/manifest.ethereum.mainnet.sol";
import {DeploymentsEthereumSepolia} from "src/config/manifest.ethereum.sepolia.sol";

/// @notice Deploys a `LivoGraduatorUniswapV4` instance wired to `SWAP_HOOK_0P5` (50-bps LP fee).
/// @dev    The existing `GRADUATOR_UNIV4` (paired with the 100-bps hook) is untouched — only the
///         0.5% counterpart is new. After broadcasting, paste the printed address into
///         `GRADUATOR_UNIV4_0P5` in the per-chain manifest and run `just export-deployments`. From
///         there the existing factory deploy/upgrade scripts will pick the new graduator up
///         automatically.
///
/// Usage (dry run):  forge script DeployUniV4Graduator0p5 --rpc-url <mainnet|sepolia> --account livo.dev
/// Usage (deploy):   forge script DeployUniV4Graduator0p5 --rpc-url <mainnet|sepolia> --account livo.dev --slow --broadcast --verify
contract DeployUniV4Graduator0p5 is Script {
    struct Deps {
        address launchpad;
        address poolManager;
        address positionManager;
        address permit2;
        address hook;
    }

    function run() external {
        Deps memory d = _resolveDeps();

        console.log("=== Deploy LivoGraduatorUniswapV4 (0.5%) ===");
        console.log("Chain ID:        %d", block.chainid);
        console.log("Launchpad:       %s", d.launchpad);
        console.log("PoolManager:     %s", d.poolManager);
        console.log("PositionManager: %s", d.positionManager);
        console.log("Permit2:         %s", d.permit2);
        console.log("Hook (50 bps):   %s", d.hook);

        vm.startBroadcast();
        // DEFAULT-tier graduation price (12.25 ETH mcap), from uniswapV4Settings.py 12250000000.
        LivoGraduatorUniswapV4 graduator = new LivoGraduatorUniswapV4(
            d.launchpad,
            d.poolManager,
            d.positionManager,
            d.permit2,
            d.hook,
            715832709642994126662528799866880,
            UniswapV4PoolConstants.TICK_UPPER
        );
        vm.stopBroadcast();

        require(graduator.HOOK_ADDRESS() == d.hook, "graduator hook mismatch");

        console.log("=== Deployed ===");
        console.log("LivoGraduatorUniswapV4 (0.5%%): %s", address(graduator));
        console.log("");
        console.log(
            "Next: paste this address into GRADUATOR_UNIV4_0P5 in src/config/manifest.%s.sol",
            block.chainid == 1 ? "mainnet" : "sepolia"
        );
        console.log("Then: `just export-deployments` and re-run UpgradeUnifiedFactories.");
    }

    function _resolveDeps() internal view returns (Deps memory d) {
        if (block.chainid == DeploymentAddressesEthereumMainnet.BLOCKCHAIN_ID) {
            d = Deps({
                launchpad: DeploymentsEthereumMainnet.LAUNCHPAD,
                poolManager: DeploymentAddressesEthereumMainnet.UNIV4_POOL_MANAGER,
                positionManager: DeploymentAddressesEthereumMainnet.UNIV4_POSITION_MANAGER,
                permit2: DeploymentAddressesEthereumMainnet.PERMIT2,
                hook: DeploymentsEthereumMainnet.SWAP_HOOK_0P5
            });
        } else if (block.chainid == DeploymentAddressesEthereumSepolia.BLOCKCHAIN_ID) {
            d = Deps({
                launchpad: DeploymentsEthereumSepolia.LAUNCHPAD,
                poolManager: DeploymentAddressesEthereumSepolia.UNIV4_POOL_MANAGER,
                positionManager: DeploymentAddressesEthereumSepolia.UNIV4_POSITION_MANAGER,
                permit2: DeploymentAddressesEthereumSepolia.PERMIT2,
                hook: DeploymentsEthereumSepolia.SWAP_HOOK_0P5
            });
        } else {
            revert("Unsupported chain ID");
        }

        require(d.launchpad != address(0), "manifest: LAUNCHPAD missing");
        require(d.hook != address(0), "manifest: SWAP_HOOK_0P5 missing");
    }
}

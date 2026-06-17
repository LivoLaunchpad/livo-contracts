// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "lib/forge-std/src/Script.sol";
import {console} from "lib/forge-std/src/console.sol";
import {LivoGraduatorUniswapV4} from "src/graduators/LivoGraduatorUniswapV4.sol";
import {DeploymentAddressesMainnet, DeploymentAddressesSepolia} from "src/config/DeploymentAddresses.sol";
import {DeploymentsMainnet} from "src/config/manifest.mainnet.sol";
import {DeploymentsSepolia} from "src/config/manifest.sepolia.sol";

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
        LivoGraduatorUniswapV4 graduator =
            new LivoGraduatorUniswapV4(d.launchpad, d.poolManager, d.positionManager, d.permit2, d.hook);
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
        if (block.chainid == DeploymentAddressesMainnet.BLOCKCHAIN_ID) {
            d = Deps({
                launchpad: DeploymentsMainnet.LAUNCHPAD,
                poolManager: DeploymentAddressesMainnet.UNIV4_POOL_MANAGER,
                positionManager: DeploymentAddressesMainnet.UNIV4_POSITION_MANAGER,
                permit2: DeploymentAddressesMainnet.PERMIT2,
                hook: DeploymentsMainnet.SWAP_HOOK_0P5
            });
        } else if (block.chainid == DeploymentAddressesSepolia.BLOCKCHAIN_ID) {
            d = Deps({
                launchpad: DeploymentsSepolia.LAUNCHPAD,
                poolManager: DeploymentAddressesSepolia.UNIV4_POOL_MANAGER,
                positionManager: DeploymentAddressesSepolia.UNIV4_POSITION_MANAGER,
                permit2: DeploymentAddressesSepolia.PERMIT2,
                hook: DeploymentsSepolia.SWAP_HOOK_0P5
            });
        } else {
            revert("Unsupported chain ID");
        }

        require(d.launchpad != address(0), "manifest: LAUNCHPAD missing");
        require(d.hook != address(0), "manifest: SWAP_HOOK_0P5 missing");
    }
}

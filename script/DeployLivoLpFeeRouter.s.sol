// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "lib/forge-std/src/Script.sol";
import {console} from "lib/forge-std/src/console.sol";
import {ERC1967Proxy} from "lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {LivoLpFeeRouter} from "src/feeRouters/LivoLpFeeRouter.sol";
import {DeploymentAddressesMainnet, DeploymentAddressesSepolia} from "src/config/DeploymentAddresses.sol";

/// @notice Deploys the `LivoLpFeeRouter` implementation + UUPS proxy with the initial tier policy.
/// @dev Tier thresholds are denominated in ETH wei and were chosen assuming ETH ≈ $3000 to mirror
///      the USD marketcap brackets that drive the split (100K / 500K / 1M / 2M / 3M / 5M USD).
///      To update the policy later (or rotate the treasury), deploy a new implementation with
///      different constructor args and call `upgradeTo` on the proxy — the implementation is
///      otherwise stateless.
///
/// Usage (dry run):  forge script DeployLivoLpFeeRouter --rpc-url sepolia --account livo.dev
/// Usage (deploy):   forge script DeployLivoLpFeeRouter --rpc-url sepolia --account livo.dev --slow --broadcast --verify
contract DeployLivoLpFeeRouter is Script {
    function run() external {
        address treasury = _resolveTreasury();

        console.log("=== Deploy LivoLpFeeRouter ===");
        console.log("Chain ID: %d", block.chainid);
        console.log("Treasury: %s", treasury);

        LivoLpFeeRouter.Config memory cfg = _defaultConfig();

        vm.startBroadcast();
        address impl = address(new LivoLpFeeRouter(treasury, cfg));
        address proxy = address(new ERC1967Proxy(impl, abi.encodeCall(LivoLpFeeRouter.initialize, ())));
        vm.stopBroadcast();

        console.log("=== Deployed ===");
        console.log("LivoLpFeeRouter (impl):  %s", impl);
        console.log("LivoLpFeeRouter (proxy): %s", proxy);
        console.log("");
        console.log(
            "Next: paste these into LP_FEE_ROUTER + LP_FEE_ROUTER_IMPL in src/config/deployments.%s.sol",
            block.chainid == 1 ? "mainnet" : "sepolia"
        );
        console.log("Then: just export-deployments");
    }

    /// @dev Production tier policy:
    ///        Tier 0 (post-graduation):  40% treasury / 60% creator
    ///        Tier 1 (>≈100K USD mc):   35% / 65%
    ///        Tier 2 (>≈500K USD mc):   30% / 70%
    ///        Tier 3 (>≈  1M USD mc):   25% / 75%
    ///        Tier 4 (>≈  2M USD mc):   20% / 80%
    ///        Tier 5 (>≈  3M USD mc):   15% / 85%
    ///        Tier 6 (>≈  5M USD mc):   10% / 90%
    function _defaultConfig() internal pure returns (LivoLpFeeRouter.Config memory cfg) {
        cfg.thresholds = [
            uint256(30 ether),
            uint256(150 ether),
            uint256(300 ether),
            uint256(600 ether),
            uint256(900 ether),
            uint256(1500 ether)
        ];
        cfg.treasuryBps = [uint16(4000), 3500, 3000, 2500, 2000, 1500, 1000];
    }

    function _resolveTreasury() internal view returns (address treasury) {
        if (block.chainid == DeploymentAddressesMainnet.BLOCKCHAIN_ID) {
            treasury = DeploymentAddressesMainnet.LIVO_TREASURY;
        } else if (block.chainid == DeploymentAddressesSepolia.BLOCKCHAIN_ID) {
            treasury = DeploymentAddressesSepolia.LIVO_TREASURY;
        } else {
            revert("Unsupported chain ID");
        }
    }
}

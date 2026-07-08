// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ForkIntegrationCaseLib} from "test/integration/fork/base/ForkIntegrationCaseLib.t.sol";
import {DeploymentAddressesSepolia} from "src/config/DeploymentAddresses.sol";
import {DeploymentsSepolia} from "src/config/manifest.sepolia.sol";

/// @notice Chain-specific address config for chain-neutral fork integration suites.
/// @dev Sepolia deployed unified factory / master handler addresses can be supplied by env while
///      the manifest catches up:
///      LIVO_FACTORY_V2_UNIFIED, LIVO_FACTORY_V4_UNIFIED, LIVO_MASTER_FEE_HANDLER.
abstract contract ForkIntegrationConfig is Test {
    using ForkIntegrationCaseLib for *;

    function _sepoliaConfig() internal view returns (ForkIntegrationCaseLib.ForkChainConfig memory cfg) {
        cfg = ForkIntegrationCaseLib.ForkChainConfig({
            rpcUrlEnv: "SEPOLIA_RPC_URL",
            chainId: DeploymentsSepolia.BLOCKCHAIN_ID,
            forkBlock: vm.envOr("SEPOLIA_FORK_BLOCK", uint256(0)),
            launchpad: vm.envOr("LIVO_LAUNCHPAD", DeploymentsSepolia.LAUNCHPAD),
            quoter: vm.envOr("LIVO_QUOTER", DeploymentsSepolia.QUOTER),
            bondingCurve: vm.envOr("LIVO_BONDING_CURVE", DeploymentsSepolia.BONDING_CURVE),
            graduatorV2: vm.envOr("LIVO_GRADUATOR_UNIV2", DeploymentsSepolia.GRADUATOR_UNIV2),
            graduatorV4: vm.envOr("LIVO_GRADUATOR_UNIV4", DeploymentsSepolia.GRADUATOR_UNIV4),
            masterFeeHandler: vm.envOr("LIVO_MASTER_FEE_HANDLER", DeploymentsSepolia.MASTER_FEE_HANDLER),
            factoryV2Unified: vm.envOr("LIVO_FACTORY_V2_UNIFIED", DeploymentsSepolia.FACTORY_UNIV2_UNIFIED),
            factoryV4Unified: vm.envOr("LIVO_FACTORY_V4_UNIFIED", DeploymentsSepolia.FACTORY_UNIV4_UNIFIED),
            tokenImpl: vm.envOr("LIVO_TOKEN_IMPL", DeploymentsSepolia.TOKEN_IMPL),
            taxTokenImpl: vm.envOr("LIVO_TAX_TOKEN_IMPL", DeploymentsSepolia.TAXABLE_TOKEN_V4_IMPL),
            weth: vm.envOr("LIVO_WETH", DeploymentAddressesSepolia.WETH),
            uniV2Router: vm.envOr("LIVO_UNIV2_ROUTER", DeploymentAddressesSepolia.UNIV2_ROUTER),
            uniV2Factory: vm.envOr("LIVO_UNIV2_FACTORY", DeploymentAddressesSepolia.UNIV2_FACTORY),
            uniV2PairInitCodeHash: vm.envOr(
                "LIVO_UNIV2_PAIR_INIT_CODE_HASH", DeploymentAddressesSepolia.UNIV2_PAIR_INIT_CODE_HASH
            ),
            uniV4PoolManager: vm.envOr("LIVO_UNIV4_POOL_MANAGER", DeploymentAddressesSepolia.UNIV4_POOL_MANAGER),
            uniV4PositionManager: vm.envOr(
                "LIVO_UNIV4_POSITION_MANAGER", DeploymentAddressesSepolia.UNIV4_POSITION_MANAGER
            ),
            uniV4UniversalRouter: vm.envOr(
                "LIVO_UNIV4_UNIVERSAL_ROUTER", DeploymentAddressesSepolia.UNIV4_UNIVERSAL_ROUTER
            ),
            permit2: vm.envOr("LIVO_PERMIT2", DeploymentAddressesSepolia.PERMIT2),
            uniV4Hook: vm.envOr("LIVO_UNIV4_HOOK", DeploymentsSepolia.SWAP_HOOK)
        });
    }
}

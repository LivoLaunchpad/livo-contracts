// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {LivoFactoryUniV4Unified} from "src/factories/LivoFactoryUniV4Unified.sol";
import {CreatorVaultDeployHelper} from "src/config/CreatorVaultDeployHelper.sol";
import {UUPSUpgradeable} from "lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

import {DeploymentAddresses as AddressesFromLivoTaxableToken} from "src/tokens/LivoTaxableTokenUniV4.sol";

import {DeploymentAddressesMainnet, DeploymentAddressesSepolia} from "src/config/DeploymentAddresses.sol";
import {DeploymentsMainnet} from "src/config/deployments.mainnet.sol";
import {DeploymentsSepolia} from "src/config/deployments.sepolia.sol";

/// @title Upgrade the LivoFactoryUniV4Unified proxy to the dual-graduator implementation
/// @notice Rolls out the 0.5% LP-fee variant: the new `LivoFactoryUniV4Unified` constructor now
///         takes both `graduator` (100 bps) and `graduator0p5` (50 bps) and routes `createToken`
///         calls between them based on `UniV4Configs.lpFeeBps`. Only the V4 unified factory proxy
///         is touched — the V2 unified factory is untouched, and the launchpad's
///         `whitelistedFactories` mapping is unchanged because the proxy address doesn't move.
///
///         Single broadcast:
///         1. deploys a fresh `LivoFactoryUniV4Unified` implementation wired to the addresses in
///            the per-chain manifest (`src/config/deployments.{mainnet,sepolia}.sol`), including
///            the new `GRADUATOR_UNIV4_0P5`.
///         2. calls `upgradeToAndCall(newImpl, "")` on the existing V4 factory proxy.
///
///         No init data is passed — no new storage slots are added by this implementation
///         (`GRADUATOR_0P5` is an immutable, baked into the bytecode).
///
///         The broadcaster MUST be the proxy owner. If not, `_authorizeUpgrade` reverts with
///         `OwnableUnauthorizedAccount(broadcaster)` and no state changes.
///
///         Pre-flight: `GRADUATOR_UNIV4_0P5` must already be deployed and recorded in the manifest.
///         Use `script/DeployUniV4Graduator0p5.s.sol` first if it's still `address(0)`.
///
///         Post-broadcast: update `FACTORY_UNIV4_UNIFIED_IMPL` in `src/config/deployments.<chain>.sol`,
///         then run `just export-deployments`.
///
/// @dev    Run with:
///         forge script UpgradeUniV4UnifiedFactory --rpc-url <mainnet|sepolia> \
///             --verify --account livo.dev --slow --broadcast
contract UpgradeUniV4UnifiedFactory is Script {
    /// @dev Per-chain addresses pulled from the manifest. `factoryV4Proxy` is the existing UUPS
    ///      proxy whose impl we're swapping. Everything else is wired into the new implementation
    ///      as immutables.
    struct Deps {
        address factoryV4Proxy;
        address launchpad;
        address bondingCurve;
        address graduatorV4;
        address graduatorV4_0p5;
        address masterFeeHandler;
        address tokenImpl;
        address tokenSniperImpl;
        address taxTokenImpl;
        address taxTokenSniperImpl;
    }

    function _getDeps() internal view returns (Deps memory d) {
        if (block.chainid == DeploymentsMainnet.BLOCKCHAIN_ID) {
            d = Deps({
                factoryV4Proxy: DeploymentsMainnet.FACTORY_UNIV4_UNIFIED,
                launchpad: DeploymentsMainnet.LAUNCHPAD,
                bondingCurve: DeploymentsMainnet.BONDING_CURVE,
                graduatorV4: DeploymentsMainnet.GRADUATOR_UNIV4,
                graduatorV4_0p5: DeploymentsMainnet.GRADUATOR_UNIV4_0P5,
                masterFeeHandler: DeploymentsMainnet.MASTER_FEE_HANDLER,
                tokenImpl: DeploymentsMainnet.TOKEN_IMPL,
                tokenSniperImpl: DeploymentsMainnet.TOKEN_SNIPER_PROTECTED_IMPL,
                taxTokenImpl: DeploymentsMainnet.TAXABLE_TOKEN_IMPL,
                taxTokenSniperImpl: DeploymentsMainnet.TAXABLE_TOKEN_SNIPER_PROTECTED_IMPL
            });
            require(
                AddressesFromLivoTaxableToken.UNIV4_POOL_MANAGER == DeploymentAddressesMainnet.UNIV4_POOL_MANAGER,
                "LivoTaxableTokenUniV4 import is not Mainnet"
            );
        } else if (block.chainid == DeploymentsSepolia.BLOCKCHAIN_ID) {
            d = Deps({
                factoryV4Proxy: DeploymentsSepolia.FACTORY_UNIV4_UNIFIED,
                launchpad: DeploymentsSepolia.LAUNCHPAD,
                bondingCurve: DeploymentsSepolia.BONDING_CURVE,
                graduatorV4: DeploymentsSepolia.GRADUATOR_UNIV4,
                graduatorV4_0p5: DeploymentsSepolia.GRADUATOR_UNIV4_0P5,
                masterFeeHandler: DeploymentsSepolia.MASTER_FEE_HANDLER,
                tokenImpl: DeploymentsSepolia.TOKEN_IMPL,
                tokenSniperImpl: DeploymentsSepolia.TOKEN_SNIPER_PROTECTED_IMPL,
                taxTokenImpl: DeploymentsSepolia.TAXABLE_TOKEN_IMPL,
                taxTokenSniperImpl: DeploymentsSepolia.TAXABLE_TOKEN_SNIPER_PROTECTED_IMPL
            });
            require(
                AddressesFromLivoTaxableToken.UNIV4_POOL_MANAGER == DeploymentAddressesSepolia.UNIV4_POOL_MANAGER,
                "LivoTaxableTokenUniV4 import is not Sepolia (run `just taxtokenaddresses`)"
            );
        } else {
            revert("Unsupported chain");
        }

        require(d.factoryV4Proxy != address(0), "manifest: FACTORY_UNIV4_UNIFIED missing");
        require(d.launchpad != address(0), "manifest: LAUNCHPAD missing");
        require(d.bondingCurve != address(0), "manifest: BONDING_CURVE missing");
        require(d.graduatorV4 != address(0), "manifest: GRADUATOR_UNIV4 missing");
        require(d.graduatorV4_0p5 != address(0), "manifest: GRADUATOR_UNIV4_0P5 missing (deploy it first)");
        require(d.masterFeeHandler != address(0), "manifest: MASTER_FEE_HANDLER missing");
        require(d.tokenImpl != address(0), "manifest: TOKEN_IMPL missing");
        require(d.tokenSniperImpl != address(0), "manifest: TOKEN_SNIPER_PROTECTED_IMPL missing");
        require(d.taxTokenImpl != address(0), "manifest: TAXABLE_TOKEN_IMPL missing");
        require(d.taxTokenSniperImpl != address(0), "manifest: TAXABLE_TOKEN_SNIPER_PROTECTED_IMPL missing");
    }

    function run() public {
        Deps memory d = _getDeps();

        // Sanity: confirm the proxy is responsive and initialized. Catches a wrong manifest
        // address pointing at a non-Livo contract before we waste a deploy.
        address proxyOwner = LivoFactoryUniV4Unified(d.factoryV4Proxy).owner();
        require(proxyOwner != address(0), "V4 proxy not initialized");

        console.log("=== Livo UniV4 Unified Factory Upgrade (dual-graduator routing) ===");
        console.log("Chain ID:                ", block.chainid);
        console.log("Broadcaster:             ", msg.sender);
        console.log("Required proxy owner:    ", proxyOwner);
        console.log("V4 factory proxy:        ", d.factoryV4Proxy);
        console.log("Graduator (100 bps):     ", d.graduatorV4);
        console.log("Graduator (50 bps):      ", d.graduatorV4_0p5);
        console.log("");

        vm.startBroadcast();

        console.log("| Contract Name                          | Address |");
        console.log("| -------------------------------------- | --- |");

        address factoryV4Impl = address(
            new LivoFactoryUniV4Unified(
                d.launchpad,
                d.tokenImpl,
                d.tokenSniperImpl,
                d.taxTokenImpl,
                d.taxTokenSniperImpl,
                d.bondingCurve,
                d.graduatorV4,
                d.graduatorV4_0p5,
                d.masterFeeHandler,
                CreatorVaultDeployHelper.factoryFor(),
                CreatorVaultDeployHelper.curvesFor()
            )
        );
        console.log("| LivoFactoryUniV4Unified (new impl)    |", factoryV4Impl);

        UUPSUpgradeable(d.factoryV4Proxy).upgradeToAndCall(factoryV4Impl, "");
        console.log("| V4 proxy upgraded to                  |", factoryV4Impl);

        vm.stopBroadcast();

        console.log("");
        console.log("=== Upgrade Complete ===");
        console.log("Proxy address is UNCHANGED - no launchpad whitelisting or integrator action needed.");
        console.log("Update the per-chain manifest, then run `just export-deployments`:");
        console.log("  FACTORY_UNIV4_UNIFIED_IMPL :", factoryV4Impl);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {DeployFullStackBase} from "./DeployFullStack.s.sol";
import {LivoLaunchpad} from "src/LivoLaunchpad.sol";
import {LivoGraduatorUniswapV2} from "src/graduators/LivoGraduatorUniswapV2.sol";
import {LivoFactoryAbstract} from "src/factories/LivoFactoryAbstract.sol";
import {LivoFactoryUniV2Unified} from "src/factories/LivoFactoryUniV2Unified.sol";
import {LivoFactoryUniV4Unified} from "src/factories/LivoFactoryUniV4Unified.sol";
import {ILivoFactory} from "src/interfaces/ILivoFactory.sol";

import {DeploymentsEthereumMainnet} from "src/config/manifest.ethereum.mainnet.sol";
import {DeploymentsEthereumSepolia} from "src/config/manifest.ethereum.sepolia.sol";
import {DeploymentsRobinhoodMainnet} from "src/config/manifest.robinhood.mainnet.sol";
import {DeploymentsRobinhoodTestnet} from "src/config/manifest.robinhood.testnet.sol";

/// @title DeployFullStackPart2 — Part 2 of the launchpad-v2 rollout (build with LP_FEE_BPS=50)
/// @notice Deploys the 0.5% swap hook + its three tier graduators, the Uniswap V2 graduator (where V2
///         exists), and the V4/V2 unified factories wired to ALL SIX V4 graduators — then whitelists
///         them on the launchpad. Reads Part 1's addresses from `src/config/manifest.<chain>.sol`, so
///         run `DeployFullStack` (Part 1) first, paste its output into the manifest, and
///         `just export-deployments` before running this.
/// @dev MUST be built with `LP_FEE_BPS = 50` in `LivoSwapHook` so the deployed hook bytecode matches
///      mainnet's `SWAP_HOOK_0P5`. Run: forge script DeployFullStackPart2 --rpc-url <chain> --account livo.dev --slow --broadcast
contract DeployFullStackPart2 is DeployFullStackBase {
    /// @dev Part 1's on-chain addresses, read from the manifest (or injected directly in a fork test).
    struct Part1Addrs {
        address launchpad;
        address feeHandler;
        address vaultFactory;
        Curves curves;
        Impls impls;
        address gradV4; // 1% DEFAULT graduator
        address gradV4Thin; // 1% THIN graduator
        address gradV4Thick; // 1% THICK graduator
    }

    struct Out {
        address hook50;
        address gradV4_0p5;
        address gradV4Thin0p5;
        address gradV4Thick0p5;
        address gradV2;
        address factoryV4Impl;
        address factoryV4;
        address factoryV2Impl;
        address factoryV2;
    }

    function run() public {
        Deps memory d = deps();
        _assertTaxTokenImports();
        Part1Addrs memory p = _readManifest();
        require(p.launchpad != address(0), "manifest: LAUNCHPAD missing (run Part 1 + export-deployments first)");
        require(p.gradV4 != address(0), "manifest: GRADUATOR_UNIV4 missing");

        console.log("=== Deploy Livo launchpad-v2 - PART 2 (0.5%% hook + factories) ===");
        console.log("Chain ID:  ", block.chainid);
        console.log("Deployer:  ", msg.sender);
        console.log("Launchpad: ", p.launchpad);
        console.log("");

        vm.startBroadcast();
        Out memory o = deployPart2(d, p);
        vm.stopBroadcast();

        _log(o, d);
    }

    /// @notice Split out of `run()` so a fork test can inject Part 1's addresses directly. Whitelisting
    ///         is done by `address(this)`, which MUST be the launchpad owner (the broadcaster in
    ///         production, or the calling contract in a fork test).
    function deployPart2(Deps memory d, Part1Addrs memory p) public returns (Out memory o) {
        // 0.5% hook (this build bakes LP_FEE_BPS=50) + its three tier graduators.
        o.hook50 = _deployHook(p.launchpad, d.poolManager);
        (o.gradV4_0p5, o.gradV4Thin0p5, o.gradV4Thick0p5) = _deployTierGraduators(p.launchpad, d, o.hook50);

        if (d.hasV2) {
            o.gradV2 = address(new LivoGraduatorUniswapV2(d.univ2Router, p.launchpad, d.univ2PairInitCodeHash));
        }

        _deployV4Factory(p, o);
        if (d.hasV2) {
            _deployV2Factory(p, o);
        }
    }

    function _deployV4Factory(Part1Addrs memory p, Out memory o) internal {
        LivoFactoryUniV4Unified.V4TierConfig memory v4Tier = LivoFactoryUniV4Unified.V4TierConfig({
            curves: _tierCurves(p.curves),
            graduators: LivoFactoryUniV4Unified.TierGraduators({
                thin: p.gradV4Thin, thin0p5: o.gradV4Thin0p5, thick: p.gradV4Thick, thick0p5: o.gradV4Thick0p5
            })
        });
        o.factoryV4Impl = address(
            new LivoFactoryUniV4Unified(
                p.launchpad,
                ILivoFactory.TokenImpls({
                    base: p.impls.token,
                    antiSniper: p.impls.tokenSniper,
                    tax: p.impls.taxV4,
                    taxAntiSniper: p.impls.taxV4Sniper
                }),
                p.curves.bondingCurve,
                p.gradV4, // 1% DEFAULT graduator (from Part 1)
                o.gradV4_0p5, // 0.5% DEFAULT graduator (just deployed)
                p.feeHandler,
                p.vaultFactory,
                p.curves.vaultCurves,
                v4Tier
            )
        );
        o.factoryV4 = address(new ERC1967Proxy(o.factoryV4Impl, abi.encodeCall(LivoFactoryAbstract.initialize, ())));
        LivoLaunchpad(p.launchpad).whitelistFactory(o.factoryV4);
    }

    function _deployV2Factory(Part1Addrs memory p, Out memory o) internal {
        o.factoryV2Impl = address(
            new LivoFactoryUniV2Unified(
                p.launchpad,
                ILivoFactory.TokenImpls({
                    base: p.impls.token,
                    antiSniper: p.impls.tokenSniper,
                    tax: p.impls.taxV2,
                    taxAntiSniper: p.impls.taxV2Sniper
                }),
                p.curves.bondingCurve,
                o.gradV2,
                p.feeHandler,
                p.vaultFactory,
                p.curves.vaultCurves,
                _tierCurves(p.curves)
            )
        );
        o.factoryV2 = address(new ERC1967Proxy(o.factoryV2Impl, abi.encodeCall(LivoFactoryAbstract.initialize, ())));
        LivoLaunchpad(p.launchpad).whitelistFactory(o.factoryV2);
    }

    function _tierCurves(Curves memory c) internal pure returns (ILivoFactory.LiquidityTierConfig memory t) {
        t.thin = ILivoFactory.TierCurves({base: c.thinBase, vaults: c.thinVaults});
        t.thick = ILivoFactory.TierCurves({base: c.thickBase, vaults: c.thickVaults});
    }

    // -------------------------------------------------------------- manifest reader

    function _readManifest() internal view returns (Part1Addrs memory p) {
        if (block.chainid == DeploymentsEthereumMainnet.BLOCKCHAIN_ID) {
            p.launchpad = DeploymentsEthereumMainnet.LAUNCHPAD;
            p.feeHandler = DeploymentsEthereumMainnet.MASTER_FEE_HANDLER;
            p.vaultFactory = DeploymentsEthereumMainnet.CREATOR_VAULT_FACTORY;
            p.curves.bondingCurve = DeploymentsEthereumMainnet.BONDING_CURVE;
            p.curves.vaultCurves = DeploymentsEthereumMainnet.vaultBondingCurves();
            p.curves.thinBase = DeploymentsEthereumMainnet.THIN_CURVE_BASE;
            p.curves.thinVaults = DeploymentsEthereumMainnet.thinVaultCurves();
            p.curves.thickBase = DeploymentsEthereumMainnet.THICK_CURVE_BASE;
            p.curves.thickVaults = DeploymentsEthereumMainnet.thickVaultCurves();
            p.impls.token = DeploymentsEthereumMainnet.TOKEN_IMPL;
            p.impls.tokenSniper = DeploymentsEthereumMainnet.TOKEN_SNIPER_PROTECTED_IMPL;
            p.impls.taxV4 = DeploymentsEthereumMainnet.TAXABLE_TOKEN_IMPL;
            p.impls.taxV4Sniper = DeploymentsEthereumMainnet.TAXABLE_TOKEN_SNIPER_PROTECTED_IMPL;
            p.impls.taxV2 = DeploymentsEthereumMainnet.TAXABLE_TOKEN_V2_IMPL;
            p.impls.taxV2Sniper = DeploymentsEthereumMainnet.TAXABLE_TOKEN_V2_SNIPER_PROTECTED_IMPL;
            p.gradV4 = DeploymentsEthereumMainnet.GRADUATOR_UNIV4;
            p.gradV4Thin = DeploymentsEthereumMainnet.GRADUATOR_UNIV4_THIN;
            p.gradV4Thick = DeploymentsEthereumMainnet.GRADUATOR_UNIV4_THICK;
        } else if (block.chainid == DeploymentsEthereumSepolia.BLOCKCHAIN_ID) {
            p.launchpad = DeploymentsEthereumSepolia.LAUNCHPAD;
            p.feeHandler = DeploymentsEthereumSepolia.MASTER_FEE_HANDLER;
            p.vaultFactory = DeploymentsEthereumSepolia.CREATOR_VAULT_FACTORY;
            p.curves.bondingCurve = DeploymentsEthereumSepolia.BONDING_CURVE;
            p.curves.vaultCurves = DeploymentsEthereumSepolia.vaultBondingCurves();
            p.curves.thinBase = DeploymentsEthereumSepolia.THIN_CURVE_BASE;
            p.curves.thinVaults = DeploymentsEthereumSepolia.thinVaultCurves();
            p.curves.thickBase = DeploymentsEthereumSepolia.THICK_CURVE_BASE;
            p.curves.thickVaults = DeploymentsEthereumSepolia.thickVaultCurves();
            p.impls.token = DeploymentsEthereumSepolia.TOKEN_IMPL;
            p.impls.tokenSniper = DeploymentsEthereumSepolia.TOKEN_SNIPER_PROTECTED_IMPL;
            p.impls.taxV4 = DeploymentsEthereumSepolia.TAXABLE_TOKEN_IMPL;
            p.impls.taxV4Sniper = DeploymentsEthereumSepolia.TAXABLE_TOKEN_SNIPER_PROTECTED_IMPL;
            p.impls.taxV2 = DeploymentsEthereumSepolia.TAXABLE_TOKEN_V2_IMPL;
            p.impls.taxV2Sniper = DeploymentsEthereumSepolia.TAXABLE_TOKEN_V2_SNIPER_PROTECTED_IMPL;
            p.gradV4 = DeploymentsEthereumSepolia.GRADUATOR_UNIV4;
            p.gradV4Thin = DeploymentsEthereumSepolia.GRADUATOR_UNIV4_THIN;
            p.gradV4Thick = DeploymentsEthereumSepolia.GRADUATOR_UNIV4_THICK;
        } else if (block.chainid == DeploymentsRobinhoodMainnet.BLOCKCHAIN_ID) {
            p.launchpad = DeploymentsRobinhoodMainnet.LAUNCHPAD;
            p.feeHandler = DeploymentsRobinhoodMainnet.MASTER_FEE_HANDLER;
            p.vaultFactory = DeploymentsRobinhoodMainnet.CREATOR_VAULT_FACTORY;
            p.curves.bondingCurve = DeploymentsRobinhoodMainnet.BONDING_CURVE;
            p.curves.vaultCurves = DeploymentsRobinhoodMainnet.vaultBondingCurves();
            p.curves.thinBase = DeploymentsRobinhoodMainnet.THIN_CURVE_BASE;
            p.curves.thinVaults = DeploymentsRobinhoodMainnet.thinVaultCurves();
            p.curves.thickBase = DeploymentsRobinhoodMainnet.THICK_CURVE_BASE;
            p.curves.thickVaults = DeploymentsRobinhoodMainnet.thickVaultCurves();
            p.impls.token = DeploymentsRobinhoodMainnet.TOKEN_IMPL;
            p.impls.tokenSniper = DeploymentsRobinhoodMainnet.TOKEN_SNIPER_PROTECTED_IMPL;
            p.impls.taxV4 = DeploymentsRobinhoodMainnet.TAXABLE_TOKEN_IMPL;
            p.impls.taxV4Sniper = DeploymentsRobinhoodMainnet.TAXABLE_TOKEN_SNIPER_PROTECTED_IMPL;
            p.impls.taxV2 = DeploymentsRobinhoodMainnet.TAXABLE_TOKEN_V2_IMPL;
            p.impls.taxV2Sniper = DeploymentsRobinhoodMainnet.TAXABLE_TOKEN_V2_SNIPER_PROTECTED_IMPL;
            p.gradV4 = DeploymentsRobinhoodMainnet.GRADUATOR_UNIV4;
            p.gradV4Thin = DeploymentsRobinhoodMainnet.GRADUATOR_UNIV4_THIN;
            p.gradV4Thick = DeploymentsRobinhoodMainnet.GRADUATOR_UNIV4_THICK;
        } else if (block.chainid == DeploymentsRobinhoodTestnet.BLOCKCHAIN_ID) {
            p.launchpad = DeploymentsRobinhoodTestnet.LAUNCHPAD;
            p.feeHandler = DeploymentsRobinhoodTestnet.MASTER_FEE_HANDLER;
            p.vaultFactory = DeploymentsRobinhoodTestnet.CREATOR_VAULT_FACTORY;
            p.curves.bondingCurve = DeploymentsRobinhoodTestnet.BONDING_CURVE;
            p.curves.vaultCurves = DeploymentsRobinhoodTestnet.vaultBondingCurves();
            p.curves.thinBase = DeploymentsRobinhoodTestnet.THIN_CURVE_BASE;
            p.curves.thinVaults = DeploymentsRobinhoodTestnet.thinVaultCurves();
            p.curves.thickBase = DeploymentsRobinhoodTestnet.THICK_CURVE_BASE;
            p.curves.thickVaults = DeploymentsRobinhoodTestnet.thickVaultCurves();
            p.impls.token = DeploymentsRobinhoodTestnet.TOKEN_IMPL;
            p.impls.tokenSniper = DeploymentsRobinhoodTestnet.TOKEN_SNIPER_PROTECTED_IMPL;
            p.impls.taxV4 = DeploymentsRobinhoodTestnet.TAXABLE_TOKEN_IMPL;
            p.impls.taxV4Sniper = DeploymentsRobinhoodTestnet.TAXABLE_TOKEN_SNIPER_PROTECTED_IMPL;
            p.impls.taxV2 = DeploymentsRobinhoodTestnet.TAXABLE_TOKEN_V2_IMPL;
            p.impls.taxV2Sniper = DeploymentsRobinhoodTestnet.TAXABLE_TOKEN_V2_SNIPER_PROTECTED_IMPL;
            p.gradV4 = DeploymentsRobinhoodTestnet.GRADUATOR_UNIV4;
            p.gradV4Thin = DeploymentsRobinhoodTestnet.GRADUATOR_UNIV4_THIN;
            p.gradV4Thick = DeploymentsRobinhoodTestnet.GRADUATOR_UNIV4_THICK;
        } else {
            revert("DeployFullStackPart2: unsupported chain");
        }
    }

    function _log(Out memory o, Deps memory d) internal pure {
        console.log("=== PART 2 deployed. Paste into src/config/manifest.<chain>.sol, then export-deployments ===");
        _logAddr("SWAP_HOOK_0P5 (0.5%)                 ", o.hook50);
        _logAddr("GRADUATOR_UNIV4_0P5                  ", o.gradV4_0p5);
        _logAddr("GRADUATOR_UNIV4_THIN_0P5             ", o.gradV4Thin0p5);
        _logAddr("GRADUATOR_UNIV4_THICK_0P5            ", o.gradV4Thick0p5);
        _logAddr("GRADUATOR_UNIV2                      ", o.gradV2);
        _logAddr("FACTORY_UNIV4_UNIFIED (proxy)        ", o.factoryV4);
        _logAddr("FACTORY_UNIV4_UNIFIED_IMPL           ", o.factoryV4Impl);
        _logAddr("FACTORY_UNIV2_UNIFIED (proxy)        ", o.factoryV2);
        _logAddr("FACTORY_UNIV2_UNIFIED_IMPL           ", o.factoryV2Impl);
        if (!d.hasV2) {
            console.log("");
            console.log("NOTE: Uniswap V2 not on this chain -> V2 graduator/factory skipped.");
        }
    }
}

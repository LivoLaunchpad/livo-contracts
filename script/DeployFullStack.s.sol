// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {HookMiner} from "lib/v4-periphery/src/utils/HookMiner.sol";

import {LivoLaunchpad} from "src/LivoLaunchpad.sol";
import {LivoQuoter} from "src/LivoQuoter.sol";
import {LivoMasterFeeHandler} from "src/feeHandlers/LivoMasterFeeHandler.sol";
import {LivoCreatorVault} from "src/vaults/LivoCreatorVault.sol";
import {LivoCreatorVaultFactory} from "src/vaults/LivoCreatorVaultFactory.sol";
import {ConstantProductBondingCurve} from "src/bondingCurves/ConstantProductBondingCurve.sol";
import {ConstantProductBondingCurveConfigurable} from "src/bondingCurves/ConstantProductBondingCurveConfigurable.sol";
import {CreatorVaultCurveConstants} from "src/config/CreatorVaultCurveConstants.sol";
import {LivoGraduatorUniswapV4} from "src/graduators/LivoGraduatorUniswapV4.sol";
import {LivoSwapHook} from "src/hooks/LivoSwapHook.sol";
import {LivoToken} from "src/tokens/LivoToken.sol";
import {LivoTokenSniperProtected} from "src/tokens/LivoTokenSniperProtected.sol";
import {LivoTaxableTokenUniV2} from "src/tokens/LivoTaxableTokenUniV2.sol";
import {LivoTaxableTokenUniV2SniperProtected} from "src/tokens/LivoTaxableTokenUniV2SniperProtected.sol";
import {LivoTaxableTokenUniV4} from "src/tokens/LivoTaxableTokenUniV4.sol";
import {LivoTaxableTokenUniV4SniperProtected} from "src/tokens/LivoTaxableTokenUniV4SniperProtected.sol";
import {LiquidityTier} from "src/types/LiquidityTier.sol";
import {UniswapV4PoolConstants} from "src/libraries/UniswapV4PoolConstants.sol";

import {
    DeploymentAddressesEthereumMainnet,
    DeploymentAddressesEthereumSepolia,
    DeploymentAddressesRobinhoodMainnet,
    DeploymentAddressesRobinhoodTestnet
} from "src/config/DeploymentAddresses.sol";
// Reflects whatever chain the two taxable-token impls were compiled against (set by `just taxtoken-<chain>`),
// so a run can assert the compile-time import matches the target chain before wasting a deploy.
import {DeploymentAddresses as AddressesFromTaxTokenV2} from "src/tokens/LivoTaxableTokenUniV2.sol";
import {DeploymentAddresses as AddressesFromTaxTokenV4} from "src/tokens/LivoTaxableTokenUniV4.sol";

/// @title DeployFullStackBase — shared config + deploy helpers for the two-part launchpad-v2 rollout
/// @notice `LivoSwapHook` bakes its LP fee as a `constant`, so the 1% and 0.5% hooks have DIFFERENT
///         bytecode and must be built separately (each identical to its mainnet counterpart, which is
///         what lets Uniswap verify the deployed hook against the audited source). A single `forge
///         build` therefore yields only ONE hook fee, so the from-scratch deploy is split in two:
///
///           Part 1 (`DeployFullStack`, build with LP_FEE_BPS=100): launchpad, fee handler, quoter,
///             creator-vault system, all 21 bonding curves, the 6 token impls, the 1% hook + its three
///             tier graduators.
///           Part 2 (`DeployFullStackPart2`, rebuild with LP_FEE_BPS=50): the 0.5% hook + its three
///             tier graduators, the V2 graduator, and the V4/V2 unified factories (wired to all six V4
///             graduators) — then whitelists them. Reads Part 1's addresses from `manifest.<chain>.sol`.
///
/// @dev Chain-generic: external addresses resolve from `DeploymentAddresses<Chain>` by `block.chainid`
///      (Ethereum mainnet/sepolia + Robinhood mainnet/testnet). Run the matching `just taxtoken-<chain>`
///      BEFORE building so the two taxable-token impls bake the right chain constants (asserted below).
///      Chains without Uniswap V2 (e.g. Robinhood testnet) skip the V2 graduator/factory/tax-impls
///      automatically (`hasV2 = UNIV2_ROUTER != address(0)`).
abstract contract DeployFullStackBase is Script {
    /// @dev Foundry's deterministic CREATE2 proxy, used for hook mining + deployment.
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    /// @dev Per-tier graduation prices (sqrtPriceX96). Mirror the values in the existing tier scripts.
    uint160 internal constant DEFAULT_GRAD_SQRT_PRICE_X96 = 715832709642994126662528799866880; // 12.25 ETH mcap
    uint160 internal constant THIN_GRAD_SQRT_PRICE_X96 = 1012340326367404053977557838594048; // 6.125 ETH mcap
    uint160 internal constant THICK_GRAD_SQRT_PRICE_X96 = 506170163183702026988778919297024; // 24.5 ETH mcap

    struct Deps {
        address poolManager;
        address positionManager;
        address permit2;
        address univ2Router;
        bytes32 univ2PairInitCodeHash;
        address treasury;
        bool hasV2;
    }

    struct Curves {
        address bondingCurve; // DEFAULT base (hardcoded curve)
        address[6] vaultCurves; // DEFAULT vault curves 5..30
        address thinBase;
        address[6] thinVaults;
        address thickBase;
        address[6] thickVaults;
    }

    struct Impls {
        address token;
        address tokenSniper;
        address taxV4;
        address taxV4Sniper;
        address taxV2; // zero on chains without V2
        address taxV2Sniper; // zero on chains without V2
    }

    // -------------------------------------------------------------- deploy helpers

    function _deployVaultSystem() internal returns (address vaultImpl, address vaultFactoryImpl, address vaultFactory) {
        vaultImpl = address(new LivoCreatorVault());
        vaultFactoryImpl = address(new LivoCreatorVaultFactory(vaultImpl));
        vaultFactory =
            address(new ERC1967Proxy(vaultFactoryImpl, abi.encodeCall(LivoCreatorVaultFactory.initialize, ())));
    }

    function _deployCurves() internal returns (Curves memory c) {
        uint256[6] memory bps = [uint256(500), 1000, 1500, 2000, 2500, 3000];

        (uint256 thr, uint256 maxExcess) = CreatorVaultCurveConstants.tierGraduation(LiquidityTier.DEFAULT);
        c.bondingCurve = address(new ConstantProductBondingCurve());
        for (uint256 i = 0; i < 6; ++i) {
            c.vaultCurves[i] = _configurable(LiquidityTier.DEFAULT, bps[i], thr, maxExcess);
        }

        (thr, maxExcess) = CreatorVaultCurveConstants.tierGraduation(LiquidityTier.THIN);
        c.thinBase = _configurable(LiquidityTier.THIN, 0, thr, maxExcess);
        for (uint256 i = 0; i < 6; ++i) {
            c.thinVaults[i] = _configurable(LiquidityTier.THIN, bps[i], thr, maxExcess);
        }

        (thr, maxExcess) = CreatorVaultCurveConstants.tierGraduation(LiquidityTier.THICK);
        c.thickBase = _configurable(LiquidityTier.THICK, 0, thr, maxExcess);
        for (uint256 i = 0; i < 6; ++i) {
            c.thickVaults[i] = _configurable(LiquidityTier.THICK, bps[i], thr, maxExcess);
        }
    }

    function _configurable(LiquidityTier tier, uint256 totalBps, uint256 threshold, uint256 maxExcess)
        internal
        returns (address)
    {
        (uint256 k, uint256 t0, uint256 e0) = CreatorVaultCurveConstants.paramsFor(tier, totalBps);
        return address(new ConstantProductBondingCurveConfigurable(k, t0, e0, threshold, maxExcess));
    }

    function _deployImpls(bool hasV2) internal returns (Impls memory impls) {
        impls.token = address(new LivoToken());
        impls.tokenSniper = address(new LivoTokenSniperProtected());
        impls.taxV4 = address(new LivoTaxableTokenUniV4());
        impls.taxV4Sniper = address(new LivoTaxableTokenUniV4SniperProtected());
        if (hasV2) {
            impls.taxV2 = address(new LivoTaxableTokenUniV2());
            impls.taxV2Sniper = address(new LivoTaxableTokenUniV2SniperProtected());
        }
    }

    /// @dev Mines a CREATE2 salt encoding the four required V4 permission flags into the hook address,
    ///      then deploys the hook by calling the `0x4e59` CREATE2 deployer directly (rather than
    ///      `new{salt}`) so the address is identical under `forge script --broadcast`, `forge test`, and
    ///      on-chain. The LP fee is a `constant` baked at compile time — this deploys whichever variant
    ///      the current build carries (100 or 50 bps).
    function _deployHook(address launchpad, address poolManager) internal returns (address) {
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        bytes memory creationCode = type(LivoSwapHook).creationCode;
        bytes memory args = abi.encode(IPoolManager(poolManager), launchpad);
        (address mined, bytes32 salt) = HookMiner.find(CREATE2_DEPLOYER, flags, creationCode, args);

        // The `0x4e59` deployer takes `salt ++ initcode` and returns the 20-byte deployed address.
        (bool ok, bytes memory ret) = CREATE2_DEPLOYER.call(abi.encodePacked(salt, creationCode, args));
        require(ok, "hook CREATE2 deploy failed");
        address hookAddr = address(bytes20(ret));
        require(hookAddr == mined, "hook address mismatch");
        return hookAddr;
    }

    /// @dev Deploys the three V4 tier graduators (DEFAULT/THIN/THICK) for a single hook fee variant.
    function _deployTierGraduators(address launchpad, Deps memory d, address hook)
        internal
        returns (address gradDefault, address gradThin, address gradThick)
    {
        gradDefault = _v4grad(launchpad, d, hook, DEFAULT_GRAD_SQRT_PRICE_X96, UniswapV4PoolConstants.TICK_UPPER);
        gradThin = _v4grad(launchpad, d, hook, THIN_GRAD_SQRT_PRICE_X96, UniswapV4PoolConstants.TICK_UPPER_THIN);
        gradThick = _v4grad(launchpad, d, hook, THICK_GRAD_SQRT_PRICE_X96, UniswapV4PoolConstants.TICK_UPPER);
    }

    function _v4grad(address launchpad, Deps memory d, address hook, uint160 sqrtPrice, int24 tickUpper)
        internal
        returns (address)
    {
        return address(
            new LivoGraduatorUniswapV4(
                launchpad, d.poolManager, d.positionManager, d.permit2, hook, sqrtPrice, tickUpper
            )
        );
    }

    // -------------------------------------------------------------- config / guards

    function deps() public view returns (Deps memory d) {
        if (block.chainid == DeploymentAddressesEthereumMainnet.BLOCKCHAIN_ID) {
            d.poolManager = DeploymentAddressesEthereumMainnet.UNIV4_POOL_MANAGER;
            d.positionManager = DeploymentAddressesEthereumMainnet.UNIV4_POSITION_MANAGER;
            d.permit2 = DeploymentAddressesEthereumMainnet.PERMIT2;
            d.univ2Router = DeploymentAddressesEthereumMainnet.UNIV2_ROUTER;
            d.univ2PairInitCodeHash = DeploymentAddressesEthereumMainnet.UNIV2_PAIR_INIT_CODE_HASH;
            d.treasury = DeploymentAddressesEthereumMainnet.LIVO_TREASURY;
        } else if (block.chainid == DeploymentAddressesEthereumSepolia.BLOCKCHAIN_ID) {
            d.poolManager = DeploymentAddressesEthereumSepolia.UNIV4_POOL_MANAGER;
            d.positionManager = DeploymentAddressesEthereumSepolia.UNIV4_POSITION_MANAGER;
            d.permit2 = DeploymentAddressesEthereumSepolia.PERMIT2;
            d.univ2Router = DeploymentAddressesEthereumSepolia.UNIV2_ROUTER;
            d.univ2PairInitCodeHash = DeploymentAddressesEthereumSepolia.UNIV2_PAIR_INIT_CODE_HASH;
            d.treasury = DeploymentAddressesEthereumSepolia.LIVO_TREASURY;
        } else if (block.chainid == DeploymentAddressesRobinhoodMainnet.BLOCKCHAIN_ID) {
            d.poolManager = DeploymentAddressesRobinhoodMainnet.UNIV4_POOL_MANAGER;
            d.positionManager = DeploymentAddressesRobinhoodMainnet.UNIV4_POSITION_MANAGER;
            d.permit2 = DeploymentAddressesRobinhoodMainnet.PERMIT2;
            d.univ2Router = DeploymentAddressesRobinhoodMainnet.UNIV2_ROUTER;
            d.univ2PairInitCodeHash = DeploymentAddressesRobinhoodMainnet.UNIV2_PAIR_INIT_CODE_HASH;
            d.treasury = DeploymentAddressesRobinhoodMainnet.LIVO_TREASURY;
        } else if (block.chainid == DeploymentAddressesRobinhoodTestnet.BLOCKCHAIN_ID) {
            d.poolManager = DeploymentAddressesRobinhoodTestnet.UNIV4_POOL_MANAGER;
            d.positionManager = DeploymentAddressesRobinhoodTestnet.UNIV4_POSITION_MANAGER;
            d.permit2 = DeploymentAddressesRobinhoodTestnet.PERMIT2;
            d.univ2Router = DeploymentAddressesRobinhoodTestnet.UNIV2_ROUTER;
            d.univ2PairInitCodeHash = DeploymentAddressesRobinhoodTestnet.UNIV2_PAIR_INIT_CODE_HASH;
            d.treasury = DeploymentAddressesRobinhoodTestnet.LIVO_TREASURY;
        } else {
            revert("DeployFullStack: unsupported chain");
        }
        require(d.poolManager != address(0), "missing UNIV4_POOL_MANAGER");
        require(d.treasury != address(0), "missing LIVO_TREASURY");
        d.hasV2 = d.univ2Router != address(0);
    }

    /// @dev The two taxable-token impls bake chain constants at compile time and gate on `block.chainid`.
    ///      Fail loudly (before any deploy) if the wrong `just taxtoken-<chain>` was run for this chain.
    function _assertTaxTokenImports() internal view {
        require(
            AddressesFromTaxTokenV4.BLOCKCHAIN_ID == block.chainid,
            "LivoTaxableTokenUniV4 compiled for wrong chain: run the matching `just taxtoken-<chain>` then rebuild"
        );
        require(
            AddressesFromTaxTokenV2.BLOCKCHAIN_ID == block.chainid,
            "LivoTaxableTokenUniV2 compiled for wrong chain: run the matching `just taxtoken-<chain>` then rebuild"
        );
    }

    function _logAddr(string memory name, address a) internal pure {
        console.log(name, a);
    }
}

/// @title DeployFullStack — Part 1 of the launchpad-v2 rollout (build with LP_FEE_BPS=100)
/// @notice Deploys the launchpad, fee handler, quoter, creator-vault system, all 21 bonding curves, the
///         six token implementations, the 1% swap hook, and its three tier graduators. Prints every
///         address to paste into `src/config/manifest.<chain>.sol`; then run `just export-deployments`
///         and proceed to Part 2 (`DeployFullStackPart2`) after rebuilding with LP_FEE_BPS=50.
/// @dev Run (broadcast): forge script DeployFullStack --rpc-url <chain> --account livo.dev --slow --broadcast
contract DeployFullStack is DeployFullStackBase {
    struct Out {
        address feeHandler;
        address launchpad;
        address quoter;
        address vaultImpl;
        address vaultFactoryImpl;
        address vaultFactory;
        Curves curves;
        Impls impls;
        address hook; // 1% hook
        address gradV4;
        address gradV4Thin;
        address gradV4Thick;
    }

    function run() public {
        Deps memory d = deps();
        _assertTaxTokenImports();

        console.log("=== Deploy Livo launchpad-v2 - PART 1 (1%% hook) ===");
        console.log("Chain ID:  ", block.chainid);
        console.log("Deployer:  ", msg.sender);
        console.log("Treasury:  ", d.treasury);
        console.log("");

        vm.startBroadcast();
        Out memory o = deployPart1(d, msg.sender);
        vm.stopBroadcast();

        _log(o, d);
    }

    /// @notice Split out of `run()` (no broadcast cheatcodes) so a fork test can drive it directly.
    ///         `owner` becomes the launchpad owner (Part 2 whitelists the factories as this owner).
    function deployPart1(Deps memory d, address owner) public returns (Out memory o) {
        o.feeHandler = address(new LivoMasterFeeHandler());
        o.launchpad = address(new LivoLaunchpad(d.treasury, owner));
        o.quoter = address(new LivoQuoter(o.launchpad));
        (o.vaultImpl, o.vaultFactoryImpl, o.vaultFactory) = _deployVaultSystem();
        o.curves = _deployCurves();
        o.impls = _deployImpls(d.hasV2);
        o.hook = _deployHook(o.launchpad, d.poolManager);
        (o.gradV4, o.gradV4Thin, o.gradV4Thick) = _deployTierGraduators(o.launchpad, d, o.hook);
    }

    function _log(Out memory o, Deps memory d) internal pure {
        console.log("=== PART 1 deployed. Paste into src/config/manifest.<chain>.sol, then export-deployments ===");
        _logAddr("LAUNCHPAD                            ", o.launchpad);
        _logAddr("QUOTER                               ", o.quoter);
        _logAddr("MASTER_FEE_HANDLER                   ", o.feeHandler);
        _logAddr("BONDING_CURVE                        ", o.curves.bondingCurve);
        _logAddr("SWAP_HOOK (1%)                       ", o.hook);
        _logAddr("GRADUATOR_UNIV4                      ", o.gradV4);
        _logAddr("GRADUATOR_UNIV4_THIN                 ", o.gradV4Thin);
        _logAddr("GRADUATOR_UNIV4_THICK                ", o.gradV4Thick);
        _logAddr("TOKEN_IMPL                           ", o.impls.token);
        _logAddr("TOKEN_SNIPER_PROTECTED_IMPL          ", o.impls.tokenSniper);
        _logAddr("TAXABLE_TOKEN_IMPL (V4)              ", o.impls.taxV4);
        _logAddr("TAXABLE_TOKEN_SNIPER_PROTECTED_IMPL  ", o.impls.taxV4Sniper);
        _logAddr("TAXABLE_TOKEN_V2_IMPL                ", o.impls.taxV2);
        _logAddr("TAXABLE_TOKEN_V2_SNIPER_PROTECTED_IMPL", o.impls.taxV2Sniper);
        _logAddr("CREATOR_VAULT_IMPL                   ", o.vaultImpl);
        _logAddr("CREATOR_VAULT_FACTORY (proxy)        ", o.vaultFactory);
        _logAddr("CREATOR_VAULT_FACTORY_IMPL           ", o.vaultFactoryImpl);
        console.log("VAULT_CURVE_5/10/15/20/25/30:");
        for (uint256 i = 0; i < 6; ++i) {
            _logAddr("  ", o.curves.vaultCurves[i]);
        }
        _logAddr("THIN_CURVE_BASE                      ", o.curves.thinBase);
        console.log("THIN_VAULT_CURVE_5..30:");
        for (uint256 i = 0; i < 6; ++i) {
            _logAddr("  ", o.curves.thinVaults[i]);
        }
        _logAddr("THICK_CURVE_BASE                     ", o.curves.thickBase);
        console.log("THICK_VAULT_CURVE_5..30:");
        for (uint256 i = 0; i < 6; ++i) {
            _logAddr("  ", o.curves.thickVaults[i]);
        }
        console.log("");
        console.log("NEXT: rebuild with LP_FEE_BPS=50 and run DeployFullStackPart2.");
        if (!d.hasV2) {
            console.log("NOTE: Uniswap V2 not on this chain -> V2 graduator/factory/tax-impls skipped in Part 2.");
        }
    }
}

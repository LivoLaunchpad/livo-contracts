// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {LivoLaunchpad} from "src/LivoLaunchpad.sol";
import {LivoQuoter} from "src/LivoQuoter.sol";
import {LivoGraduatorUniswapV2} from "src/graduators/LivoGraduatorUniswapV2.sol";
import {LivoGraduatorUniswapV4} from "src/graduators/LivoGraduatorUniswapV4.sol";
import {LivoToken} from "src/tokens/LivoToken.sol";
import {LivoTokenSniperProtected} from "src/tokens/LivoTokenSniperProtected.sol";
import {LivoTaxableTokenUniV2} from "src/tokens/LivoTaxableTokenUniV2.sol";
import {LivoTaxableTokenUniV2SniperProtected} from "src/tokens/LivoTaxableTokenUniV2SniperProtected.sol";
import {LivoTaxableTokenUniV4} from "src/tokens/LivoTaxableTokenUniV4.sol";
import {LivoTaxableTokenUniV4SniperProtected} from "src/tokens/LivoTaxableTokenUniV4SniperProtected.sol";
import {LivoFactoryUniV2Unified} from "src/factories/LivoFactoryUniV2Unified.sol";
import {LivoFactoryUniV4Unified} from "src/factories/LivoFactoryUniV4Unified.sol";

import {DeploymentAddresses as AddressesFromLivoTaxableTokenV2} from "src/tokens/LivoTaxableTokenUniV2.sol";
import {DeploymentAddresses as AddressesFromLivoTaxableTokenV4} from "src/tokens/LivoTaxableTokenUniV4.sol";

import {DeploymentAddressesMainnet, DeploymentAddressesSepolia} from "src/config/DeploymentAddresses.sol";
import {DeploymentsMainnet} from "src/config/deployments.mainnet.sol";
import {DeploymentsSepolia} from "src/config/deployments.sepolia.sol";

/// @title Launchpad-v2 rollout, phase 1: deploy everything that bakes the launchpad address in
/// @notice First of a TWO-PHASE rollout for the launchpad-v2 release (per-token, creator-splittable
///         pre-graduation fees). Eleven deployments + two whitelistings — the factory proxies are
///         NOT upgraded here (phase 2, see below), so token creation keeps flowing to the OLD
///         launchpad until phase 2 lands:
///
///         1.  `LivoLaunchpad` (v2) — via CREATE2 with a mined vanity salt so the address ends in
///             `0x1110` AND is identical on mainnet and sepolia (see "Cross-chain address parity").
///         2.  `LivoQuoter` — immutable `launchpad`, must follow the launchpad.
///         3.  `LivoGraduatorUniswapV2` — immutable `LIVO_LAUNCHPAD`.
///         4.  `LivoGraduatorUniswapV4` (1% hook) — immutable `LIVO_LAUNCHPAD`; reuses the existing
///             `SWAP_HOOK` (the hook only reads `treasury()` from its old-launchpad immutable, so it
///             keeps working as long as the old launchpad stays deployed with a current treasury —
///             enforced below: both launchpads must report the same treasury).
///         5.  `LivoGraduatorUniswapV4` (0.5% hook) — same, reusing `SWAP_HOOK_0P5`.
///         6.  The six token implementations (interface changed: `getLaunchpadFees`, lp-fee init
///             params, creation-anchored tax window):
///             `LivoToken`, `LivoTokenSniperProtected`, `LivoTaxableTokenUniV2`,
///             `LivoTaxableTokenUniV2SniperProtected`, `LivoTaxableTokenUniV4`,
///             `LivoTaxableTokenUniV4SniperProtected`.
///         7.  `whitelistFactory` for both (unchanged) factory proxies on the NEW launchpad.
///             Harmless ahead of time: the proxies don't talk to the new launchpad until phase 2.
///
///         ## Phase 2 — factory upgrade (separate run, after updating the manifest)
///         Update `src/config/deployments.<chain>.sol` with the addresses printed by this script,
///         then run the existing `UpgradeUnifiedFactories` script as-is: it deploys both factory
///         implementations wired entirely from the manifest (new launchpad, new graduators, new
///         token impls) and `upgradeToAndCall`s the proxies. That run is the atomic switch of token
///         creation to the v2 stack.
///
///         NOT redeployed: bonding curves (stateless, no launchpad reference), master fee handler,
///         swap hooks (reused, see above), the factory proxies, and the whole creator-vault stack.
///
///         The OLD launchpad is left untouched: tokens already registered there keep trading and
///         graduating against it through the old graduators. Optionally blacklist the factory
///         proxies on the old launchpad after phase 2 (cosmetic — the upgraded proxies register
///         new tokens on the new launchpad only).
///
///         ## Cross-chain address parity
///         The launchpad is deployed through Foundry's deterministic CREATE2 deployer, so its
///         address depends only on (salt, initcode). To get the SAME address on both chains:
///         - the constructor args are compile-time constants identical on every chain: the MAINNET
///           treasury and the deployer EOA as owner. On sepolia, `setTreasuryAddress` is called
///           right after deployment (same broadcast) to point the treasury at the sepolia one.
///         - the salt is mined deterministically from the initcode hash, starting at
///           `VANITY_SALT_OFFSET` — both chains find the same salt as long as the launchpad
///           bytecode is identical. DEPLOY BOTH CHAINS FROM THE SAME COMMIT. (The
///           `just taxtokenaddresses` import swap touches only token sources, not the launchpad,
///           so running it between the sepolia and mainnet broadcasts is fine.)
///
///         The broadcaster MUST be `LAUNCHPAD_OWNER` (it whitelists factories and, on sepolia,
///         retargets the treasury). No factory-proxy ownership is needed in this phase.
///
///         Treasury invariant: `oldLaunchpad.treasury() == newLaunchpad.treasury()` — the reused
///         swap hooks read the treasury from the OLD launchpad, so the two must agree. Checked
///         pre-broadcast against the manifest launchpad; any future treasury change must be applied
///         on BOTH launchpads.
///
///         Post-broadcast: update these constants in `src/config/deployments.<chain>.sol`, then run
///         `just export-deployments` (and mirror the new addresses in the envio-indexer configs):
///         - `LAUNCHPAD`, `QUOTER`
///         - `GRADUATOR_UNIV2`, `GRADUATOR_UNIV4`, `GRADUATOR_UNIV4_0P5`
///         - `TOKEN_IMPL`, `TOKEN_SNIPER_PROTECTED_IMPL`
///         - `TAXABLE_TOKEN_IMPL`, `TAXABLE_TOKEN_SNIPER_PROTECTED_IMPL`
///         - `TAXABLE_TOKEN_V2_IMPL`, `TAXABLE_TOKEN_V2_SNIPER_PROTECTED_IMPL`
///         (`FACTORY_UNIV2_UNIFIED_IMPL` / `FACTORY_UNIV4_UNIFIED_IMPL` are updated after phase 2.)
///
/// @dev    Run with:
///         forge script DeployLaunchpadV2Stack --rpc-url <mainnet|sepolia> --verify --account livo.dev --slow --broadcast
contract DeployLaunchpadV2Stack is Script {
    // ========================= CREATE2 / vanity configuration =========================

    /// @dev Constructor args of the launchpad. Part of the CREATE2 initcode, so they MUST be
    ///      identical on every chain (see "Cross-chain address parity" above). Sepolia's treasury
    ///      is corrected post-deploy via `setTreasuryAddress`.
    address internal constant LAUNCHPAD_TREASURY = DeploymentAddressesMainnet.LIVO_TREASURY;
    address internal constant LAUNCHPAD_OWNER = 0xBa489180Ea6EEB25cA65f123a46F3115F388f181; // livo.dev

    /// @dev Foundry's deterministic deployment proxy (CREATE2 deployer used by `new X{salt: ...}`)
    address internal constant FOUNDRY_CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    /// @dev Vanity suffix for the launchpad address: 0x1110 (same as v1).
    ///      4 hex chars = 16 bits -> mask 0xFFFF, ~65k attempts on average.
    uint160 internal constant VANITY_MASK = 0xFFFF;
    uint160 internal constant VANITY_TARGET = 0x1110;

    /// @dev Starting point for the salt search. The v2 initcode differs from v1's, so there is no
    ///      collision risk with the old launchpad's salt — any offset works, but it must be the
    ///      SAME on every chain so both runs mine the same salt.
    uint256 internal constant VANITY_SALT_OFFSET = 0x11123422;

    // ========================= Per-chain dependencies =========================

    /// @dev Everything reused (not redeployed) by this rollout, resolved per chain. Livo contracts
    ///      come from `src/config/deployments.<chain>.sol`, external infra from
    ///      `src/config/DeploymentAddresses.sol`.
    struct Deps {
        // reused Livo contracts
        address oldLaunchpad;
        address factoryV2Proxy;
        address factoryV4Proxy;
        address swapHook;
        address swapHook0p5;
        // external infrastructure
        address univ2Router;
        bytes32 univ2PairInitCodeHash;
        address univ4PoolManager;
        address univ4PositionManager;
        address permit2;
        // treasury the launchpad should end up with on THIS chain (differs from the constructor
        // arg only on sepolia)
        address chainTreasury;
    }

    /// @dev Addresses emitted by this script (for logging + manifest updates).
    struct FreshDeployments {
        address launchpad;
        address quoter;
        address graduatorV2;
        address graduatorV4;
        address graduatorV4_0p5;
        address tokenImpl;
        address tokenSniperImpl;
        address taxTokenV2Impl;
        address taxTokenV2SniperImpl;
        address taxTokenV4Impl;
        address taxTokenV4SniperImpl;
    }

    function _getDeps() internal view returns (Deps memory d) {
        if (block.chainid == DeploymentsMainnet.BLOCKCHAIN_ID) {
            d = Deps({
                oldLaunchpad: DeploymentsMainnet.LAUNCHPAD,
                factoryV2Proxy: DeploymentsMainnet.FACTORY_UNIV2_UNIFIED,
                factoryV4Proxy: DeploymentsMainnet.FACTORY_UNIV4_UNIFIED,
                swapHook: DeploymentsMainnet.SWAP_HOOK,
                swapHook0p5: DeploymentsMainnet.SWAP_HOOK_0P5,
                univ2Router: DeploymentAddressesMainnet.UNIV2_ROUTER,
                univ2PairInitCodeHash: DeploymentAddressesMainnet.UNIV2_PAIR_INIT_CODE_HASH,
                univ4PoolManager: DeploymentAddressesMainnet.UNIV4_POOL_MANAGER,
                univ4PositionManager: DeploymentAddressesMainnet.UNIV4_POSITION_MANAGER,
                permit2: DeploymentAddressesMainnet.PERMIT2,
                chainTreasury: DeploymentAddressesMainnet.LIVO_TREASURY
            });
            require(
                AddressesFromLivoTaxableTokenV2.BLOCKCHAIN_ID == DeploymentAddressesMainnet.BLOCKCHAIN_ID,
                "LivoTaxableTokenUniV2 import is not Mainnet (run `just taxtokenaddresses` only for sepolia)"
            );
            require(
                AddressesFromLivoTaxableTokenV4.UNIV4_POOL_MANAGER == DeploymentAddressesMainnet.UNIV4_POOL_MANAGER,
                "LivoTaxableTokenUniV4 import is not Mainnet"
            );
        } else if (block.chainid == DeploymentsSepolia.BLOCKCHAIN_ID) {
            d = Deps({
                oldLaunchpad: DeploymentsSepolia.LAUNCHPAD,
                factoryV2Proxy: DeploymentsSepolia.FACTORY_UNIV2_UNIFIED,
                factoryV4Proxy: DeploymentsSepolia.FACTORY_UNIV4_UNIFIED,
                swapHook: DeploymentsSepolia.SWAP_HOOK,
                swapHook0p5: DeploymentsSepolia.SWAP_HOOK_0P5,
                univ2Router: DeploymentAddressesSepolia.UNIV2_ROUTER,
                univ2PairInitCodeHash: DeploymentAddressesSepolia.UNIV2_PAIR_INIT_CODE_HASH,
                univ4PoolManager: DeploymentAddressesSepolia.UNIV4_POOL_MANAGER,
                univ4PositionManager: DeploymentAddressesSepolia.UNIV4_POSITION_MANAGER,
                permit2: DeploymentAddressesSepolia.PERMIT2,
                chainTreasury: DeploymentAddressesSepolia.LIVO_TREASURY
            });
            require(
                AddressesFromLivoTaxableTokenV2.BLOCKCHAIN_ID == DeploymentAddressesSepolia.BLOCKCHAIN_ID,
                "LivoTaxableTokenUniV2 import is not Sepolia (run `just taxtokenaddresses`)"
            );
            require(
                AddressesFromLivoTaxableTokenV4.UNIV4_POOL_MANAGER == DeploymentAddressesSepolia.UNIV4_POOL_MANAGER,
                "LivoTaxableTokenUniV4 import is not Sepolia (run `just taxtokenaddresses`)"
            );
        } else {
            revert("Unsupported chain");
        }

        // Belt-and-braces: catch a stale or zero address in the manifest before we waste a deploy.
        require(d.oldLaunchpad != address(0), "manifest: LAUNCHPAD missing");
        require(d.factoryV2Proxy != address(0), "manifest: FACTORY_UNIV2_UNIFIED missing");
        require(d.factoryV4Proxy != address(0), "manifest: FACTORY_UNIV4_UNIFIED missing");
        require(d.swapHook != address(0), "manifest: SWAP_HOOK missing");
        require(d.swapHook0p5 != address(0), "manifest: SWAP_HOOK_0P5 missing");
    }

    // ========================= Vanity Address Mining =========================

    /// @notice Mines a CREATE2 salt that produces a launchpad address with the 0x1110 suffix
    /// @dev Precomputes initCodeHash and uses a single abi.encodePacked per iteration with
    ///      fixed-size args to minimize memory growth. Deterministic given the launchpad bytecode,
    ///      so every chain mines the same (salt, address) pair from the same commit.
    function _mineVanitySalt(address treasury, address owner)
        internal
        pure
        returns (bytes32 salt, address vanityAddress)
    {
        bytes32 initCodeHash =
            keccak256(abi.encodePacked(type(LivoLaunchpad).creationCode, abi.encode(treasury, owner)));

        for (uint256 i = VANITY_SALT_OFFSET; i < VANITY_SALT_OFFSET + 500_000; i++) {
            vanityAddress = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xFF), FOUNDRY_CREATE2_DEPLOYER, i, initCodeHash))))
            );
            if (uint160(vanityAddress) & VANITY_MASK == VANITY_TARGET) {
                return (bytes32(i), vanityAddress);
            }
        }
        revert("VanityMiner: could not find salt");
    }

    // ========================= Deployment =========================

    function run() public {
        Deps memory d = _getDeps();
        FreshDeployments memory fresh;

        // Catch wrong manifest addresses pointing at non-Livo contracts before we waste deploys
        // (the proxies are only whitelisted here, not upgraded — phase 2 does the upgrades).
        require(LivoFactoryUniV2Unified(d.factoryV2Proxy).owner() != address(0), "V2 proxy not initialized");
        require(LivoFactoryUniV4Unified(d.factoryV4Proxy).owner() != address(0), "V4 proxy not initialized");

        // Treasury invariant: the reused swap hooks read `treasury()` from the OLD launchpad, so
        // the new launchpad must end up with the exact same treasury on this chain.
        require(
            LivoLaunchpad(d.oldLaunchpad).treasury() == d.chainTreasury,
            "old launchpad treasury != chain treasury; reconcile before deploying"
        );

        // Mine the vanity salt before broadcast (pure computation, no on-chain cost)
        (bytes32 launchpadSalt, address expectedLaunchpad) = _mineVanitySalt(LAUNCHPAD_TREASURY, LAUNCHPAD_OWNER);

        console.log("=== Livo Launchpad-v2 Stack Rollout (phase 1: no factory upgrade) ===");
        console.log("Chain ID:                ", block.chainid);
        console.log("Broadcaster:             ", msg.sender);
        console.log("Old launchpad:           ", d.oldLaunchpad);
        console.log("Launchpad owner:         ", LAUNCHPAD_OWNER);
        console.log("Launchpad ctor treasury: ", LAUNCHPAD_TREASURY);
        console.log("Final chain treasury:    ", d.chainTreasury);
        console.log("Mined launchpad salt:    ", uint256(launchpadSalt));
        console.log("Expected launchpad:      ", expectedLaunchpad);
        console.log("(cross-check salt+address against the other chain's run before broadcasting)");
        console.log("");

        vm.startBroadcast();

        console.log("| Contract Name                                  | Address |");
        console.log("| ---------------------------------------------- | --- |");

        // --- Launchpad v2 (CREATE2 vanity address, identical across chains) ---
        fresh.launchpad = address(new LivoLaunchpad{salt: launchpadSalt}(LAUNCHPAD_TREASURY, LAUNCHPAD_OWNER));
        require(fresh.launchpad == expectedLaunchpad, "Launchpad vanity address mismatch");
        console.log("| LivoLaunchpad (v2)                            |", fresh.launchpad);

        // The constructor treasury is the mainnet one on every chain (CREATE2 initcode parity);
        // retarget it where this chain's treasury differs (sepolia).
        if (d.chainTreasury != LAUNCHPAD_TREASURY) {
            LivoLaunchpad(fresh.launchpad).setTreasuryAddress(d.chainTreasury);
            console.log("| ^ treasury retargeted to                      |", d.chainTreasury);
        }

        // --- Quoter ---
        fresh.quoter = address(new LivoQuoter(fresh.launchpad));
        console.log("| LivoQuoter                                    |", fresh.quoter);

        // --- Graduators (hooks are reused from the manifest) ---
        fresh.graduatorV2 = address(new LivoGraduatorUniswapV2(d.univ2Router, fresh.launchpad, d.univ2PairInitCodeHash));
        console.log("| LivoGraduatorUniswapV2                        |", fresh.graduatorV2);

        fresh.graduatorV4 = address(
            new LivoGraduatorUniswapV4(
                fresh.launchpad, d.univ4PoolManager, d.univ4PositionManager, d.permit2, d.swapHook
            )
        );
        console.log("| LivoGraduatorUniswapV4                        |", fresh.graduatorV4);

        fresh.graduatorV4_0p5 = address(
            new LivoGraduatorUniswapV4(
                fresh.launchpad, d.univ4PoolManager, d.univ4PositionManager, d.permit2, d.swapHook0p5
            )
        );
        console.log("| LivoGraduatorUniswapV4 (0p5 hook)             |", fresh.graduatorV4_0p5);

        // --- Token implementations (6) ---
        fresh.tokenImpl = address(new LivoToken());
        console.log("| LivoToken (new impl)                          |", fresh.tokenImpl);

        fresh.tokenSniperImpl = address(new LivoTokenSniperProtected());
        console.log("| LivoTokenSniperProtected (new impl)           |", fresh.tokenSniperImpl);

        fresh.taxTokenV2Impl = address(new LivoTaxableTokenUniV2());
        console.log("| LivoTaxableTokenUniV2 (new impl)              |", fresh.taxTokenV2Impl);

        fresh.taxTokenV2SniperImpl = address(new LivoTaxableTokenUniV2SniperProtected());
        console.log("| LivoTaxableTokenUniV2SniperProtected (new)    |", fresh.taxTokenV2SniperImpl);

        fresh.taxTokenV4Impl = address(new LivoTaxableTokenUniV4());
        console.log("| LivoTaxableTokenUniV4 (new impl)              |", fresh.taxTokenV4Impl);

        fresh.taxTokenV4SniperImpl = address(new LivoTaxableTokenUniV4SniperProtected());
        console.log("| LivoTaxableTokenUniV4SniperProtected (new)    |", fresh.taxTokenV4SniperImpl);

        // --- Whitelist the (unchanged, not-yet-upgraded) factory proxies on the NEW launchpad ---
        // Harmless ahead of phase 2: the proxies keep registering tokens on the old launchpad
        // until UpgradeUnifiedFactories swaps their implementations.
        LivoLaunchpad(fresh.launchpad).whitelistFactory(d.factoryV2Proxy);
        LivoLaunchpad(fresh.launchpad).whitelistFactory(d.factoryV4Proxy);
        console.log("| ^ both factory proxies whitelisted on         |", fresh.launchpad);

        vm.stopBroadcast();

        _sanityChecks(d, fresh);

        console.log("");
        console.log("=== Phase 1 Complete (factories NOT upgraded) ===");
        console.log("The OLD launchpad keeps serving all tokens until phase 2.");
        console.log("Update the per-chain manifest with these addresses, run `just export-deployments`,");
        console.log("then run `UpgradeUnifiedFactories` as-is for phase 2 (factory impls + proxy upgrades).");
        console.log("Also mirror launchpad/quoter/graduators in the envio-indexer configs:");
        console.log("  LAUNCHPAD                               :", fresh.launchpad);
        console.log("  QUOTER                                  :", fresh.quoter);
        console.log("  GRADUATOR_UNIV2                         :", fresh.graduatorV2);
        console.log("  GRADUATOR_UNIV4                         :", fresh.graduatorV4);
        console.log("  GRADUATOR_UNIV4_0P5                     :", fresh.graduatorV4_0p5);
        console.log("  TOKEN_IMPL                              :", fresh.tokenImpl);
        console.log("  TOKEN_SNIPER_PROTECTED_IMPL             :", fresh.tokenSniperImpl);
        console.log("  TAXABLE_TOKEN_IMPL                      :", fresh.taxTokenV4Impl);
        console.log("  TAXABLE_TOKEN_SNIPER_PROTECTED_IMPL    :", fresh.taxTokenV4SniperImpl);
        console.log("  TAXABLE_TOKEN_V2_IMPL                   :", fresh.taxTokenV2Impl);
        console.log("  TAXABLE_TOKEN_V2_SNIPER_PROTECTED_IMPL :", fresh.taxTokenV2SniperImpl);
    }

    /// @dev Post-broadcast wiring assertions, run against the simulated end state. Any mismatch
    ///      aborts the simulation before anything is broadcast.
    function _sanityChecks(Deps memory d, FreshDeployments memory fresh) internal view {
        // vanity suffix
        require(uint160(fresh.launchpad) & VANITY_MASK == VANITY_TARGET, "launchpad: vanity suffix mismatch");

        // launchpad config
        LivoLaunchpad launchpad = LivoLaunchpad(fresh.launchpad);
        require(launchpad.owner() == LAUNCHPAD_OWNER, "launchpad: wrong owner");
        require(launchpad.treasury() == d.chainTreasury, "launchpad: wrong treasury");
        // the reused swap hooks read treasury() from the old launchpad — both must agree
        require(
            launchpad.treasury() == LivoLaunchpad(d.oldLaunchpad).treasury(), "launchpad: treasury diverges from old"
        );
        require(launchpad.whitelistedFactories(d.factoryV2Proxy), "launchpad: V2 proxy not whitelisted");
        require(launchpad.whitelistedFactories(d.factoryV4Proxy), "launchpad: V4 proxy not whitelisted");

        // quoter + graduators point at the new launchpad
        require(address(LivoQuoter(fresh.quoter).launchpad()) == fresh.launchpad, "quoter: wrong launchpad");
        require(
            LivoGraduatorUniswapV2(payable(fresh.graduatorV2)).LIVO_LAUNCHPAD() == fresh.launchpad,
            "graduatorV2: wrong launchpad"
        );
        require(
            LivoGraduatorUniswapV4(payable(fresh.graduatorV4)).LIVO_LAUNCHPAD() == fresh.launchpad,
            "graduatorV4: wrong launchpad"
        );
        require(
            LivoGraduatorUniswapV4(payable(fresh.graduatorV4_0p5)).LIVO_LAUNCHPAD() == fresh.launchpad,
            "graduatorV4_0p5: wrong launchpad"
        );

        // graduators keep the existing hooks
        require(
            LivoGraduatorUniswapV4(payable(fresh.graduatorV4)).HOOK_ADDRESS() == d.swapHook, "graduatorV4: wrong hook"
        );
        require(
            LivoGraduatorUniswapV4(payable(fresh.graduatorV4_0p5)).HOOK_ADDRESS() == d.swapHook0p5,
            "graduatorV4_0p5: wrong hook"
        );

        // factory proxies are intentionally untouched in this phase: still on the old impls,
        // still pointing at the OLD launchpad until UpgradeUnifiedFactories runs (phase 2).
        require(
            address(LivoFactoryUniV2Unified(d.factoryV2Proxy).LAUNCHPAD()) == d.oldLaunchpad,
            "factoryV2: unexpectedly already migrated"
        );
        require(
            address(LivoFactoryUniV4Unified(d.factoryV4Proxy).LAUNCHPAD()) == d.oldLaunchpad,
            "factoryV4: unexpectedly already migrated"
        );
    }
}

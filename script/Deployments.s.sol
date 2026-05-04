// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {LivoToken} from "src/tokens/LivoToken.sol";
import {LivoTokenSniperProtected} from "src/tokens/LivoTokenSniperProtected.sol";
import {ConstantProductBondingCurve} from "src/bondingCurves/ConstantProductBondingCurve.sol";
import {LivoLaunchpad} from "src/LivoLaunchpad.sol";
import {LivoGraduatorUniswapV2} from "src/graduators/LivoGraduatorUniswapV2.sol";
import {LivoGraduatorUniswapV4} from "src/graduators/LivoGraduatorUniswapV4.sol";
import {LivoTaxableTokenUniV4} from "src/tokens/LivoTaxableTokenUniV4.sol";
import {LivoTaxableTokenUniV4SniperProtected} from "src/tokens/LivoTaxableTokenUniV4SniperProtected.sol";
import {LivoFactoryUniV2Unified} from "src/factories/LivoFactoryUniV2Unified.sol";
import {LivoFactoryUniV4Unified} from "src/factories/LivoFactoryUniV4Unified.sol";
import {LivoFeeHandler} from "src/feeHandlers/LivoFeeHandler.sol";
import {DeploymentAddressesMainnet, DeploymentAddressesSepolia} from "src/config/DeploymentAddresses.sol";

import {DeploymentAddresses as AddressesFromLivoTaxableToken} from "src/tokens/LivoTaxableTokenUniV4.sol";
import {LivoFeeSplitter} from "src/feeSplitters/LivoFeeSplitter.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {HookMiner} from "lib/v4-periphery/src/utils/HookMiner.sol";
import {LivoSwapHook} from "src/hooks/LivoSwapHook.sol";

/// @title Livo Protocol Deployment Script
/// @notice Deploys all core Livo contracts and configures whitelisted component sets
/// @dev Run with: forge script script/Deployments.s.sol --rpc-url <mainnet|sepolia> --broadcast --verify
contract Deployments is Script {
    // ========================= Configuration =========================

    // set to livodev in sepolia
    address constant TREASURY = DeploymentAddressesMainnet.LIVO_TREASURY;

    // Deployer EOA (owner of deployed contracts)
    address constant DEPLOYER = 0xBa489180Ea6EEB25cA65f123a46F3115F388f181;

    // Foundry's deterministic deployment proxy (Create2 deployer)
    address constant FOUNDRY_CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    // Vanity suffix for LivoLaunchpad address: 0x1110
    // 4 hex chars = 16 bits → mask 0xFFFF, ~65k attempts on average
    uint160 constant VANITY_MASK = 0xFFFF;
    uint160 constant VANITY_TARGET = 0x1110;

    // Bump this after each deployment to skip already-used CREATE2 salts
    uint256 constant VANITY_SALT_OFFSET = 0x11123421;

    // ========================= Network Config =========================

    function _getNetworkAddresses()
        internal
        view
        returns (
            address univ2Router,
            address univ4PoolManager,
            address univ4PositionManager,
            address permit2,
            bytes32 univ2PairInitCodeHash
        )
    {
        if (block.chainid == 1) {
            // Mainnet
            univ2Router = DeploymentAddressesMainnet.UNIV2_ROUTER;
            univ4PoolManager = DeploymentAddressesMainnet.UNIV4_POOL_MANAGER;
            univ4PositionManager = DeploymentAddressesMainnet.UNIV4_POSITION_MANAGER;
            permit2 = DeploymentAddressesMainnet.PERMIT2;
            univ2PairInitCodeHash = DeploymentAddressesMainnet.UNIV2_PAIR_INIT_CODE_HASH;
        } else if (block.chainid == 11155111) {
            // Sepolia
            univ2Router = DeploymentAddressesSepolia.UNIV2_ROUTER;
            univ4PoolManager = DeploymentAddressesSepolia.UNIV4_POOL_MANAGER;
            univ4PositionManager = DeploymentAddressesSepolia.UNIV4_POSITION_MANAGER;
            permit2 = DeploymentAddressesSepolia.PERMIT2;
            univ2PairInitCodeHash = DeploymentAddressesSepolia.UNIV2_PAIR_INIT_CODE_HASH;
        } else {
            revert("Unsupported chain");
        }

        // NOTE: LivoTaxableTokenUniV4 has hardcoded addresses corresponding to the imported configs
        // this makes sure we have the right imports in both places
        // if the pool manager is in the right network, all other addresses are
        require(
            address(AddressesFromLivoTaxableToken.UNIV4_POOL_MANAGER) == univ4PoolManager,
            "Invalid UNIV4_POOL_MANAGER address. Wrong chain id"
        );
    }

    // ========================= Hook Deployment =========================

    function _deployHook(address poolManager, address launchpad) internal returns (address hookAddress) {
        uint160 flags = uint160(
            Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
        bytes memory constructorArgs = abi.encode(IPoolManager(poolManager), launchpad);
        bytes memory creationCode = type(LivoSwapHook).creationCode;

        bytes32 salt;
        (hookAddress, salt) = HookMiner.find(FOUNDRY_CREATE2_DEPLOYER, flags, creationCode, constructorArgs);

        LivoSwapHook livoSwapHook = new LivoSwapHook{salt: salt}(IPoolManager(poolManager), launchpad);
        require(address(livoSwapHook) == hookAddress, "Hook address mismatch");
    }

    // ========================= Vanity Address Mining =========================

    /// @notice Mines a CREATE2 salt that produces an address with a vanity suffix
    /// @dev Precomputes initCodeHash and uses a single abi.encodePacked per iteration with fixed-size args
    ///      to minimize memory growth (same approach as HookMiner but with precomputed hash)
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

    /// @dev Bundle of deployed addresses returned from `_deployCore` to keep `run()` under the
    ///      stack limit when also computing the V4 hook + factory wiring.
    struct CoreDeployment {
        address launchpad;
        address bondingCurve;
        address feeHandler;
        address feeSplitterImpl;
        address graduatorV2;
        address graduatorV4;
        address tokenImpl;
        address tokenSniperImpl;
        address taxTokenImpl;
        address taxTokenSniperImpl;
    }

    function _deployCore(
        address univ2Router,
        bytes32 univ2PairInitCodeHash,
        address univ4PoolManager,
        address univ4PositionManager,
        address permit2,
        bytes32 launchpadSalt,
        address expectedLaunchpad
    ) internal returns (CoreDeployment memory c) {
        // 1. Deploy token implementations (cloned by factories)
        c.tokenImpl = address(new LivoToken());
        console.log("| LivoToken | ", c.tokenImpl);

        c.tokenSniperImpl = address(new LivoTokenSniperProtected());
        console.log("| LivoTokenSniperProtected | ", c.tokenSniperImpl);

        c.taxTokenImpl = address(new LivoTaxableTokenUniV4());
        console.log("| LivoTaxableTokenUniV4 | ", c.taxTokenImpl);

        c.taxTokenSniperImpl = address(new LivoTaxableTokenUniV4SniperProtected());
        console.log("| LivoTaxableTokenUniV4SniperProtected | ", c.taxTokenSniperImpl);

        // 2. Bonding curve
        c.bondingCurve = address(new ConstantProductBondingCurve());
        console.log("| ConstantProductBondingCurve | ", c.bondingCurve);

        // 3. LivoLaunchpad with vanity address via CREATE2
        c.launchpad = address(new LivoLaunchpad{salt: launchpadSalt}(TREASURY, DEPLOYER));
        require(c.launchpad == expectedLaunchpad, "Launchpad vanity address mismatch");
        console.log("| LivoLaunchpad | ", c.launchpad);

        // 4. Fee handler
        c.feeHandler = address(new LivoFeeHandler());
        console.log("| LivoFeeHandler | ", c.feeHandler);

        // 5. Hook (via CREATE2 with mined salt)
        address hookAddress = _deployHook(univ4PoolManager, c.launchpad);
        console.log("| LivoSwapHook | ", hookAddress);

        // 6. Graduators
        c.graduatorV2 = address(new LivoGraduatorUniswapV2(univ2Router, c.launchpad, univ2PairInitCodeHash));
        console.log("| LivoGraduatorUniswapV2 | ", c.graduatorV2);

        c.graduatorV4 = address(
            new LivoGraduatorUniswapV4(c.launchpad, univ4PoolManager, univ4PositionManager, permit2, hookAddress)
        );
        console.log("| LivoGraduatorUniswapV4 | ", c.graduatorV4);

        // 7. Fee splitter implementation
        c.feeSplitterImpl = address(new LivoFeeSplitter());
        console.log("| LivoFeeSplitter (impl) | ", c.feeSplitterImpl);
    }

    function run() public {
        require(TREASURY != address(0), "TREASURY address not set");

        (
            address univ2Router,
            address univ4PoolManager,
            address univ4PositionManager,
            address permit2,
            bytes32 univ2PairInitCodeHash
        ) = _getNetworkAddresses();

        console.log("=== Livo Protocol Deployment ===");
        console.log("Chain ID:", block.chainid);
        console.log("Deployer:", msg.sender);
        console.log("Treasury:", TREASURY);
        console.log("");

        // Mine vanity salt before broadcast (pure computation, no on-chain cost)
        (bytes32 launchpadSalt, address expectedLaunchpad) = _mineVanitySalt(TREASURY, DEPLOYER);
        console.log("Launchpad vanity salt mined, expected address:", expectedLaunchpad);

        console.log("");
        console.log("Deploying contracts...");
        console.log("");

        vm.startBroadcast();

        console.log("| Contract Name | Address |");
        console.log("| ---- | --- | ");

        CoreDeployment memory c = _deployCore(
            univ2Router,
            univ2PairInitCodeHash,
            univ4PoolManager,
            univ4PositionManager,
            permit2,
            launchpadSalt,
            expectedLaunchpad
        );

        // Unified factories — V2 family (2 impls) + V4 family (4 impls).
        LivoFactoryUniV2Unified factoryV2 = new LivoFactoryUniV2Unified(
            c.launchpad, c.tokenImpl, c.tokenSniperImpl, c.bondingCurve, c.graduatorV2, c.feeHandler, c.feeSplitterImpl
        );
        console.log("| LivoFactoryUniV2Unified | ", address(factoryV2));

        LivoFactoryUniV4Unified factoryV4 = new LivoFactoryUniV4Unified(
            c.launchpad,
            c.tokenImpl,
            c.tokenSniperImpl,
            c.taxTokenImpl,
            c.taxTokenSniperImpl,
            c.bondingCurve,
            c.graduatorV4,
            c.feeHandler,
            c.feeSplitterImpl
        );
        console.log("| LivoFactoryUniV4Unified | ", address(factoryV4));

        console.log("");
        console.log("Whitelisting factories...");

        LivoLaunchpad launchpad = LivoLaunchpad(c.launchpad);
        launchpad.whitelistFactory(address(factoryV2));
        console.log("whitelisting LivoFactoryUniV2Unified in LivoLaunchpad");
        launchpad.whitelistFactory(address(factoryV4));
        console.log("whitelisting LivoFactoryUniV4Unified in LivoLaunchpad");

        vm.stopBroadcast();

        console.log("");
        console.log("=== Deployment Complete ===");
        console.log("");
        console.log("Next steps:");
        console.log("1. Update deployed addresses in justfile");
        console.log("2. Update launchpad address in envio");
        console.log("3. (Optional) Transfer ownership if needed");
    }
}

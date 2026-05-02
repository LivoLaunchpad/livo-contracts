// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {LivoToken} from "src/tokens/LivoToken.sol";
import {ConstantProductBondingCurve} from "src/bondingCurves/ConstantProductBondingCurve.sol";
import {LivoLaunchpad} from "src/LivoLaunchpad.sol";
import {LivoGraduatorUniswapV2} from "src/graduators/LivoGraduatorUniswapV2.sol";
import {LivoGraduatorUniswapV4} from "src/graduators/LivoGraduatorUniswapV4.sol";
import {LivoTaxableTokenUniV4} from "src/tokens/LivoTaxableTokenUniV4.sol";
import {LivoFactoryUniV4} from "src/factories/LivoFactoryUniV4.sol";
import {LivoFactoryUniV2} from "src/factories/LivoFactoryUniV2.sol";
import {LivoFactoryTaxToken} from "src/factories/LivoFactoryTaxToken.sol";
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

        // 1. Deploy LivoToken (implementation for clones)
        LivoToken livoToken = new LivoToken();
        console.log("| LivoToken | ", address(livoToken));

        // 7. Deploy LivoTaxableTokenUniV4 (implementation for clones)
        // note: the right chainid config is checked when reading configs
        LivoTaxableTokenUniV4 livoTaxableToken = new LivoTaxableTokenUniV4();
        console.log("| LivoTaxableTokenUniV4 | ", address(livoTaxableToken));

        // 2. Deploy ConstantProductBondingCurve
        ConstantProductBondingCurve bondingCurve = new ConstantProductBondingCurve();
        console.log("| ConstantProductBondingCurve | ", address(bondingCurve));

        // 3. Deploy LivoLaunchpad with vanity address via CREATE2
        LivoLaunchpad launchpad = new LivoLaunchpad{salt: launchpadSalt}(TREASURY, DEPLOYER);
        require(address(launchpad) == expectedLaunchpad, "Launchpad vanity address mismatch");
        console.log("| LivoLaunchpad | ", address(launchpad));

        // 5. Deploy fee handler used by all factories
        LivoFeeHandler feeHandler = new LivoFeeHandler();
        console.log("| LivoFeeHandler | ", address(feeHandler));

        // 6. Mine and deploy LivoSwapHook via CREATE2
        address hookAddress = _deployHook(univ4PoolManager, address(launchpad));
        console.log("| LivoSwapHook | ", hookAddress);

        // 8. Deploy LivoGraduatorUniswapV2
        LivoGraduatorUniswapV2 graduatorV2 =
            new LivoGraduatorUniswapV2(univ2Router, address(launchpad), univ2PairInitCodeHash);
        console.log("| LivoGraduatorUniswapV2 | ", address(graduatorV2));

        // 7. Deploy LivoGraduatorUniswapV4
        LivoGraduatorUniswapV4 graduatorV4 = new LivoGraduatorUniswapV4(
            address(launchpad), univ4PoolManager, univ4PositionManager, permit2, hookAddress
        );
        console.log("| LivoGraduatorUniswapV4 | ", address(graduatorV4));

        // 9. Deploy fee splitter implementation
        LivoFeeSplitter feeSplitterImpl = new LivoFeeSplitter();
        console.log("| LivoFeeSplitter (impl) | ", address(feeSplitterImpl));

        // 10. Deploy factories
        LivoFactoryUniV2 factoryV2 = new LivoFactoryUniV2(
            address(launchpad),
            address(livoToken),
            address(bondingCurve),
            address(graduatorV2),
            address(feeHandler),
            address(feeSplitterImpl)
        );
        console.log("| LivoFactoryUniV2 (V2) | ", address(factoryV2));
        LivoFactoryUniV4 factoryV4 = new LivoFactoryUniV4(
            address(launchpad),
            address(livoToken),
            address(bondingCurve),
            address(graduatorV4),
            address(feeHandler),
            address(feeSplitterImpl)
        );
        console.log("| LivoFactory (V4) | ", address(factoryV4));

        LivoFactoryTaxToken factoryTax = new LivoFactoryTaxToken(
            address(launchpad),
            address(livoTaxableToken),
            address(bondingCurve),
            address(graduatorV4),
            address(feeHandler),
            address(feeSplitterImpl)
        );
        console.log("| LivoFactoryTaxToken (V4) | ", address(factoryTax));

        console.log("");
        console.log("Whitelisting factories...");

        launchpad.whitelistFactory(address(factoryV2));
        console.log("whitelisting LivoFactoryUniV2 in LivoLaunchpad");
        launchpad.whitelistFactory(address(factoryV4));
        console.log("whitelisting factoryV4 (V4) in launchpad");
        launchpad.whitelistFactory(address(factoryTax));
        console.log("whitelisting factoryTax in launchpad");

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

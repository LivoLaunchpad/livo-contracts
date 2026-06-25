// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {ConstantProductBondingCurveConfigurable} from "src/bondingCurves/ConstantProductBondingCurveConfigurable.sol";
import {CreatorVaultCurveConstants} from "src/config/CreatorVaultCurveConstants.sol";
import {LivoGraduatorUniswapV4} from "src/graduators/LivoGraduatorUniswapV4.sol";
import {LiquidityTier} from "src/types/LiquidityTier.sol";
import {DeploymentAddressesMainnet, DeploymentAddressesSepolia} from "src/config/DeploymentAddresses.sol";
import {DeploymentsMainnet} from "src/config/manifest.mainnet.sol";
import {DeploymentsSepolia} from "src/config/manifest.sepolia.sol";

/// @title Deploy the THIN + THICK liquidity-tier system
/// @notice Deploys the net-new on-chain pieces the deployer-selectable liquidity tiers need:
///         1. The THIN and THICK tier bonding curves — each a no-vault base curve plus six vault
///            curves (5%..30%), 14 `ConstantProductBondingCurveConfigurable` instances total. The
///            DEFAULT tier reuses the already-deployed base curve + six vault curves.
///         2. The four THIN/THICK Uniswap V4 graduators (one per tier x hook fee: 100 / 50 bps).
///            The DEFAULT graduators (`GRADUATOR_UNIV4`, `GRADUATOR_UNIV4_0P5`) are reused as-is.
///
///         Curves are venue-agnostic: the same 14 addresses feed both the V2 and V4 factory tier
///         configs (V2 needs no tier graduators — its depth is set entirely by the curve).
///
///         After running, paste the printed addresses into `src/config/manifest.{mainnet,sepolia}.sol`
///         (the `GRADUATOR_UNIV4_{THIN,THICK}*` and `{THIN,THICK}_*_CURVE_*` slots), run
///         `just export-deployments`, and only THEN upgrade the unified factories so they pick the
///         tier config up (`RedeployUnifiedFactoriesOnly`, or a `Redeploy*Tokens*` variant).
///
/// @dev    Run with:
///         forge script DeployTierLiquiditySystem --rpc-url <mainnet|sepolia> --verify --account livo.dev --slow --broadcast
contract DeployTierLiquiditySystem is Script {
    /// @dev THIN-tier graduation price (6.125 ETH mcap). Mirrors the value in `LivoGraduatorUniswapV4`.
    uint160 internal constant THIN_GRAD_SQRT_PRICE_X96 = 1012340326367404053977557838594048;
    /// @dev THICK-tier graduation price (24.5 ETH mcap).
    uint160 internal constant THICK_GRAD_SQRT_PRICE_X96 = 506170163183702026988778919297024;

    struct Deps {
        address launchpad;
        address poolManager;
        address positionManager;
        address permit2;
        address hook100; // 100-bps LivoSwapHook
        address hook50; // 50-bps LivoSwapHook
    }

    function run() public {
        Deps memory d = _resolveDeps();

        console.log("=== Deploy Livo liquidity-tier system (THIN + THICK) ===");
        console.log("Chain ID:", block.chainid);
        console.log("Deployer:", msg.sender);
        console.log("");

        // bpsList[0] == 0 is the no-vault base curve; bpsList[1..6] are the 5%..30% vault curves.
        uint256[7] memory bpsList = [uint256(0), 500, 1000, 1500, 2000, 2500, 3000];

        vm.startBroadcast();

        address[7] memory thin = _deployTierCurves(LiquidityTier.THIN, bpsList);
        address[7] memory thick = _deployTierCurves(LiquidityTier.THICK, bpsList);

        address gradSmall = _deployGraduator(d, d.hook100, THIN_GRAD_SQRT_PRICE_X96);
        address gradSmall0p5 = _deployGraduator(d, d.hook50, THIN_GRAD_SQRT_PRICE_X96);
        address gradLarge = _deployGraduator(d, d.hook100, THICK_GRAD_SQRT_PRICE_X96);
        address gradLarge0p5 = _deployGraduator(d, d.hook50, THICK_GRAD_SQRT_PRICE_X96);

        vm.stopBroadcast();

        console.log("=== Deployed. Paste into src/config/manifest.<chain>.sol ===");
        console.log("");
        _printTierCurves("THIN", thin);
        _printTierCurves("THICK", thick);
        console.log("GRADUATOR_UNIV4_THIN    ", gradSmall);
        console.log("GRADUATOR_UNIV4_THIN_0P5", gradSmall0p5);
        console.log("GRADUATOR_UNIV4_THICK    ", gradLarge);
        console.log("GRADUATOR_UNIV4_THICK_0P5", gradLarge0p5);
        console.log("");
        console.log("Next: update the manifest, `just export-deployments`, then RedeployUnifiedFactoriesOnly.");
    }

    /// @dev Deploys a tier's seven curves: index 0 is the no-vault base, 1..6 are the 5%..30% vaults.
    function _deployTierCurves(LiquidityTier tier, uint256[7] memory bpsList)
        internal
        returns (address[7] memory curves)
    {
        (uint256 threshold, uint256 maxExcess) = CreatorVaultCurveConstants.tierGraduation(tier);
        for (uint256 i = 0; i < 7; ++i) {
            (uint256 k, uint256 t0, uint256 e0) = CreatorVaultCurveConstants.paramsFor(tier, bpsList[i]);
            curves[i] = address(new ConstantProductBondingCurveConfigurable(k, t0, e0, threshold, maxExcess));
        }
    }

    function _deployGraduator(Deps memory d, address hook, uint160 sqrtPriceGraduation) internal returns (address) {
        LivoGraduatorUniswapV4 graduator = new LivoGraduatorUniswapV4(
            d.launchpad, d.poolManager, d.positionManager, d.permit2, hook, sqrtPriceGraduation
        );
        require(graduator.HOOK_ADDRESS() == hook, "graduator hook mismatch");
        return address(graduator);
    }

    function _printTierCurves(string memory tier, address[7] memory c) internal pure {
        string[7] memory suffix;
        suffix[0] = "_CURVE_BASE   ";
        suffix[1] = "_VAULT_CURVE_5 ";
        suffix[2] = "_VAULT_CURVE_10";
        suffix[3] = "_VAULT_CURVE_15";
        suffix[4] = "_VAULT_CURVE_20";
        suffix[5] = "_VAULT_CURVE_25";
        suffix[6] = "_VAULT_CURVE_30";
        for (uint256 i = 0; i < 7; ++i) {
            console.log(string.concat(tier, suffix[i]), c[i]);
        }
    }

    function _resolveDeps() internal view returns (Deps memory d) {
        if (block.chainid == DeploymentAddressesMainnet.BLOCKCHAIN_ID) {
            d = Deps({
                launchpad: DeploymentsMainnet.LAUNCHPAD,
                poolManager: DeploymentAddressesMainnet.UNIV4_POOL_MANAGER,
                positionManager: DeploymentAddressesMainnet.UNIV4_POSITION_MANAGER,
                permit2: DeploymentAddressesMainnet.PERMIT2,
                hook100: DeploymentsMainnet.SWAP_HOOK,
                hook50: DeploymentsMainnet.SWAP_HOOK_0P5
            });
        } else if (block.chainid == DeploymentAddressesSepolia.BLOCKCHAIN_ID) {
            d = Deps({
                launchpad: DeploymentsSepolia.LAUNCHPAD,
                poolManager: DeploymentAddressesSepolia.UNIV4_POOL_MANAGER,
                positionManager: DeploymentAddressesSepolia.UNIV4_POSITION_MANAGER,
                permit2: DeploymentAddressesSepolia.PERMIT2,
                hook100: DeploymentsSepolia.SWAP_HOOK,
                hook50: DeploymentsSepolia.SWAP_HOOK_0P5
            });
        } else {
            revert("Unsupported chain ID");
        }

        require(d.launchpad != address(0), "manifest: LAUNCHPAD missing");
        require(d.hook100 != address(0), "manifest: SWAP_HOOK missing");
        require(d.hook50 != address(0), "manifest: SWAP_HOOK_0P5 missing");
    }
}

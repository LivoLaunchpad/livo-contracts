// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseUniswapV4GraduationTests} from "test/graduators/graduationUniv4.base.t.sol";
import {ILivoFactory} from "src/interfaces/ILivoFactory.sol";
import {ILivoBondingCurve} from "src/interfaces/ILivoBondingCurve.sol";
import {LivoFactoryUniV4Unified} from "src/factories/LivoFactoryUniV4Unified.sol";
import {LiquidityTier} from "src/types/LiquidityTier.sol";
import {IUniswapV2Router02} from "src/interfaces/IUniswapV2Router02.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/// @notice Graduation price-continuity matrix across BOTH venues (Uniswap V2 + V4), all three liquidity
///         tiers {SMALL, DEFAULT, LARGE} and all seven creator-vault levels {no-vault + 5%..30%}.
///
///         The single invariant under test, for every (venue x tier x vault) cell:
///           the LAST trade price on the bonding curve (right before graduation) must roughly match the
///           FIRST swap price in the freshly-created Uniswap pool (right after graduation), within 5%.
///         A gap larger than that would let the first post-graduation swapper arbitrage the graduation
///         price set-point against the curve — the whole point of matching the curve's marginal price to
///         the pool's initial price.
///
///         Price is measured as "tokens received per ETH spent" so it is direction/decimals-agnostic:
///           - before: the curve's fee-free marginal price at the graduation threshold (a pure view);
///           - after : the realized price of a real, tiny first swap in the live pool (fee-inclusive).
///         The pre-grad number is fee-free and the post-grad number carries the pool fee (V2 0.3% /
///         V4 1%) plus negligible slippage, so the realized "after" sits a hair below "before" — well
///         inside the 5% band, which is what makes the band the right tolerance.
///
/// @dev    This complements the suites that already exist: `TierLiquidityCurvesTest` proves the pure-curve
///         marginal price matches `ethIntoLiquidity / T_GRAD` for all 21 curves, and
///         `TierLiquidityMatrixTest` proves V4 tier-routing + ETH conservation. Neither closed the loop
///         end-to-end against the REAL pool price, and V2 tier graduation was untested entirely.
contract TierGraduationPriceContinuityTest is BaseUniswapV4GraduationTests {
    /// @dev The seven supported creator-vault levels: no-vault plus 5%..30% in 5% steps.
    uint256[7] VAULTS = [uint256(0), 500, 1000, 1500, 2000, 2500, 3000];

    /// @dev Tiny amounts for the marginal-price probes, so slippage is negligible even on the SMALL pool.
    uint256 constant PRICE_PROBE_ETH = 0.001 ether;
    uint256 constant FIRST_SWAP_ETH = 0.001 ether;

    // ───────────────────────── per-(venue, tier) public sweeps ─────────────────────────

    function test_priceContinuity_v2_small() public {
        _sweep(false, LiquidityTier.SMALL);
    }

    function test_priceContinuity_v2_default() public {
        _sweep(false, LiquidityTier.DEFAULT);
    }

    function test_priceContinuity_v2_large() public {
        _sweep(false, LiquidityTier.LARGE);
    }

    function test_priceContinuity_v4_small() public {
        _sweep(true, LiquidityTier.SMALL);
    }

    function test_priceContinuity_v4_default() public {
        _sweep(true, LiquidityTier.DEFAULT);
    }

    function test_priceContinuity_v4_large() public {
        _sweep(true, LiquidityTier.LARGE);
    }

    // ───────────────────────── core scenario ─────────────────────────

    function _sweep(bool isV4, LiquidityTier tier) internal {
        for (uint256 i; i < 7; ++i) {
            _runScenario(isV4, tier, VAULTS[i]);
        }
    }

    function _runScenario(bool isV4, LiquidityTier tier, uint256 vaultBps) internal {
        string memory ctx = _ctx(isV4, tier, vaultBps);
        address token = _create(isV4, tier, vaultBps);

        // Last trade price BEFORE graduation: the curve's fee-free marginal price at the threshold.
        ILivoBondingCurve curve = launchpad.getTokenConfig(token).bondingCurve;
        uint256 tokensPerEthBefore = _curveTokensPerEthAtGraduation(curve);

        _buyToGraduation(token);
        assertTrue(launchpad.getTokenState(token).graduated, string.concat(ctx, "token did not graduate"));

        // First swap price AFTER graduation: a real, tiny swap in the live pool.
        uint256 tokensPerEthAfter = isV4 ? _v4FirstSwapTokensPerEth(token) : _v2FirstSwapTokensPerEth(token);

        assertApproxEqRel(
            tokensPerEthAfter,
            tokensPerEthBefore,
            0.05e18,
            string.concat(ctx, "post-grad swap price drifted >5% from pre-grad curve price")
        );
    }

    // ───────────────────────── price probes ─────────────────────────

    /// @dev Tokens-per-ETH the curve gives for the final sliver of ETH reaching the graduation threshold.
    ///      Pure view on the curve, so it carries no launchpad fee — the clean "last trade" price.
    function _curveTokensPerEthAtGraduation(ILivoBondingCurve curve) internal view returns (uint256) {
        uint256 threshold = curve.ethGraduationThreshold();
        (uint256 tokensOut,) = curve.buyTokensWithExactEth(threshold - PRICE_PROBE_ETH, PRICE_PROBE_ETH);
        return tokensOut * 1e18 / PRICE_PROBE_ETH;
    }

    /// @dev Realized tokens-per-ETH of the first V4 pool swap (a tiny ETH->token buy via the universal router).
    function _v4FirstSwapTokensPerEth(address token) internal returns (uint256) {
        vm.deal(buyer, FIRST_SWAP_ETH + 1 ether);
        uint256 balBefore = IERC20(token).balanceOf(buyer);
        _swap(buyer, token, FIRST_SWAP_ETH, 0, true, true);
        uint256 tokensOut = IERC20(token).balanceOf(buyer) - balBefore;
        assertGt(tokensOut, 0, "v4 first swap returned no tokens");
        return tokensOut * 1e18 / FIRST_SWAP_ETH;
    }

    /// @dev Realized tokens-per-ETH of the first V2 pool swap (a tiny WETH->token buy via the V2 router).
    function _v2FirstSwapTokensPerEth(address token) internal returns (uint256) {
        vm.deal(buyer, FIRST_SWAP_ETH + 1 ether);
        uint256 balBefore = IERC20(token).balanceOf(buyer);

        vm.startPrank(buyer);
        WETH.deposit{value: FIRST_SWAP_ETH}();
        WETH.approve(UNISWAP_V2_ROUTER, FIRST_SWAP_ETH);
        address[] memory path = new address[](2);
        path[0] = address(WETH);
        path[1] = token;
        IUniswapV2Router02(UNISWAP_V2_ROUTER)
            .swapExactTokensForTokens(FIRST_SWAP_ETH, 0, path, buyer, block.timestamp + 1 hours);
        vm.stopPrank();

        uint256 tokensOut = IERC20(token).balanceOf(buyer) - balBefore;
        assertGt(tokensOut, 0, "v2 first swap returned no tokens");
        return tokensOut * 1e18 / FIRST_SWAP_ETH;
    }

    // ───────────────────────── helpers ─────────────────────────

    /// @dev Creates a plain (no-tax, no-sniper) token on the chosen venue + tier with a single creator
    ///      vault holding `vaultBps` of supply (no vault when `vaultBps == 0`).
    function _create(bool isV4, LiquidityTier tier, uint256 vaultBps) internal returns (address token) {
        ILivoFactory.CreatorVault[] memory vaults;
        if (vaultBps == 0) {
            vaults = new ILivoFactory.CreatorVault[](0);
        } else {
            vaults = new ILivoFactory.CreatorVault[](1);
            vaults[0] =
                ILivoFactory.CreatorVault({owner: creator, supplyBps: vaultBps, cliffSeconds: 0, vestingSeconds: 1});
        }
        address factory = isV4 ? address(factoryV4Unified) : address(factoryV2Unified);
        ILivoFactory.TokenSetup memory setup = ILivoFactory.TokenSetup({
            name: "Tier",
            symbol: "TIER",
            salt: _nextValidSalt(factory, address(livoToken)),
            feeShares: _fs(creator),
            liquidityTier: tier
        });
        vm.prank(creator);
        if (isV4) {
            token = factoryV4Unified.createToken(setup, _emptyTaxCfg(), _cfg(), _noSs(), _emptyAntiSniperCfg(), vaults);
        } else {
            token = factoryV2Unified.createToken(setup, _emptyTaxCfg(), _noSs(), _emptyAntiSniperCfg(), vaults);
        }
    }

    /// @dev Buys from the launchpad exactly enough to reach the token's tier-specific graduation threshold.
    function _buyToGraduation(address token) internal {
        ILivoBondingCurve curve = launchpad.getTokenConfig(token).bondingCurve;
        uint256 threshold = curve.ethGraduationThreshold();
        uint256 ethReserves = launchpad.getTokenState(token).ethCollected;
        uint256 buyFeeBps = _currentBuyFeeBps(token);
        uint256 missing = ((threshold - ethReserves) * 10_000) / (10_000 - buyFeeBps);
        vm.deal(buyer, missing);
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: missing}(token, 0, DEADLINE);
    }

    function _cfg() internal pure returns (LivoFactoryUniV4Unified.UniV4Configs memory) {
        return LivoFactoryUniV4Unified.UniV4Configs({renounceOwnership: false, lpFeeBps: 100});
    }

    function _tierName(LiquidityTier tier) internal pure returns (string memory) {
        if (tier == LiquidityTier.SMALL) return "SMALL";
        if (tier == LiquidityTier.DEFAULT) return "DEFAULT";
        return "LARGE";
    }

    /// @dev "[V4 SMALL 1500bps] " prefix so a looped assertion names the exact failing cell.
    function _ctx(bool isV4, LiquidityTier tier, uint256 bps) internal pure returns (string memory) {
        return string.concat("[", isV4 ? "V4 " : "V2 ", _tierName(tier), " ", vm.toString(bps), "bps] ");
    }
}

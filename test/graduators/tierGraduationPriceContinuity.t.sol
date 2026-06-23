// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseUniswapV4GraduationTests} from "test/graduators/graduationUniv4.base.t.sol";
import {ILivoFactory} from "src/interfaces/ILivoFactory.sol";
import {ILivoBondingCurve} from "src/interfaces/ILivoBondingCurve.sol";
import {LivoFactoryUniV4Unified} from "src/factories/LivoFactoryUniV4Unified.sol";
import {LiquidityTier} from "src/types/LiquidityTier.sol";
import {TaxConfigInit} from "src/interfaces/ILivoTaxableToken.sol";
import {AntiSniperConfigs} from "src/tokens/SniperProtection.sol";
import {LivoToken} from "src/tokens/LivoToken.sol";
import {IUniswapV2Pair} from "src/interfaces/IUniswapV2Pair.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

/// @notice Graduation price-continuity matrix across BOTH venues (Uniswap V2 + V4), all three liquidity
///         tiers {SMALL, DEFAULT, LARGE}, all seven creator-vault levels {no-vault + 5%..30%}, AND all
///         four token flavors {plain, tax, sniper-protected, tax+sniper}.
///
///         The single invariant under test, for every cell:
///           the LAST trade price on the bonding curve (right before graduation) must roughly match the
///           FIRST swap price in the freshly-created Uniswap pool (right after graduation), within 5%.
///         A larger gap would let the first post-graduation swapper arbitrage the pool's opening price
///         against the curve — the whole reason the curve's marginal price is matched to the pool's
///         initial price.
///
///         Price is measured fee/tax-FREE on both sides, as ETH-per-token:
///           - before: the curve's marginal price at the graduation threshold (a pure view);
///           - after : the actual deployed pool's opening spot price (V2 reserves ratio / V4 slot0).
///         This is deliberate: taxes and LP fees are charged on top of the price and differ between the
///         curve phase and the pool phase (and between flavors), so folding them in would spend the 5%
///         band on fees rather than on genuine price discontinuity. The pool's opening spot price IS the
///         price the first (infinitesimal) swap transacts at, before its own fee. Because a tax/sniper
///         token graduates with the exact same reserves as a plain one (graduation transfers bypass tax,
///         and the curve is chosen by tier+vault, not flavor), the invariant must hold identically across
///         every flavor — this suite proves it does, end-to-end through the real factory + launchpad +
///         graduator for each.
///
/// @dev    Complements `TierLiquidityCurvesTest` (pure-curve marginal price vs `ethIntoLiquidity/T_GRAD`)
///         and `TierLiquidityMatrixTest` (V4 tier-routing + ETH conservation). Neither closed the loop
///         against the REAL pool price, and V2 tier graduation was untested entirely.
contract TierGraduationPriceContinuityTest is BaseUniswapV4GraduationTests {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    enum Flavor {
        BASE, // no tax, no sniper protection
        TAX, // taxable token
        SNIPER, // sniper-protected token
        TAX_SNIPER // taxable + sniper-protected
    }

    /// @dev The seven supported creator-vault levels: no-vault plus 5%..30% in 5% steps.
    uint256[7] VAULTS = [uint256(0), 500, 1000, 1500, 2000, 2500, 3000];

    /// @dev Non-plain flavors, swept at no-vault (BASE is already covered by the vault sweep at 0 bps).
    Flavor[3] FLAVORS = [Flavor.TAX, Flavor.SNIPER, Flavor.TAX_SNIPER];

    /// @dev Tiny ETH slice for the fee-free curve marginal-price probe at the threshold.
    uint256 constant PRICE_PROBE_ETH = 0.001 ether;

    // ───────────────────── vault sweep (plain token, all 7 vault levels) ─────────────────────

    function test_priceContinuity_v2_small() public {
        _sweepVaults(false, LiquidityTier.SMALL);
    }

    function test_priceContinuity_v2_default() public {
        _sweepVaults(false, LiquidityTier.DEFAULT);
    }

    function test_priceContinuity_v2_large() public {
        _sweepVaults(false, LiquidityTier.LARGE);
    }

    function test_priceContinuity_v4_small() public {
        _sweepVaults(true, LiquidityTier.SMALL);
    }

    function test_priceContinuity_v4_default() public {
        _sweepVaults(true, LiquidityTier.DEFAULT);
    }

    function test_priceContinuity_v4_large() public {
        _sweepVaults(true, LiquidityTier.LARGE);
    }

    // ─────────────── flavor sweep (tax / sniper / tax+sniper, no-vault) ───────────────

    function test_priceContinuity_flavors_v2_small() public {
        _sweepFlavors(false, LiquidityTier.SMALL);
    }

    function test_priceContinuity_flavors_v2_default() public {
        _sweepFlavors(false, LiquidityTier.DEFAULT);
    }

    function test_priceContinuity_flavors_v2_large() public {
        _sweepFlavors(false, LiquidityTier.LARGE);
    }

    function test_priceContinuity_flavors_v4_small() public {
        _sweepFlavors(true, LiquidityTier.SMALL);
    }

    function test_priceContinuity_flavors_v4_default() public {
        _sweepFlavors(true, LiquidityTier.DEFAULT);
    }

    function test_priceContinuity_flavors_v4_large() public {
        _sweepFlavors(true, LiquidityTier.LARGE);
    }

    // ───────────────────────── sweeps ─────────────────────────

    function _sweepVaults(bool isV4, LiquidityTier tier) internal {
        for (uint256 i; i < 7; ++i) {
            _runScenario(isV4, tier, VAULTS[i], Flavor.BASE);
        }
    }

    function _sweepFlavors(bool isV4, LiquidityTier tier) internal {
        for (uint256 i; i < 3; ++i) {
            _runScenario(isV4, tier, 0, FLAVORS[i]);
        }
    }

    // ───────────────────────── core scenario ─────────────────────────

    function _runScenario(bool isV4, LiquidityTier tier, uint256 vaultBps, Flavor flavor) internal {
        string memory ctx = _ctx(isV4, tier, vaultBps, flavor);
        address token = _create(isV4, tier, vaultBps, flavor);

        // Last trade price BEFORE graduation: the curve's fee-free marginal price at the threshold.
        ILivoBondingCurve curve = launchpad.getTokenConfig(token).bondingCurve;
        uint256 ethPerTokenBefore = _curveEthPerTokenAtGraduation(curve);

        _buyToGraduation(token);
        assertTrue(launchpad.getTokenState(token).graduated, string.concat(ctx, "token did not graduate"));

        // First swap price AFTER graduation: the live pool's opening spot price.
        uint256 ethPerTokenAfter = isV4 ? _v4PoolEthPerToken(token) : _v2PoolEthPerToken(token);

        assertApproxEqRel(
            ethPerTokenAfter,
            ethPerTokenBefore,
            0.05e18,
            string.concat(ctx, "post-grad pool price drifted >5% from pre-grad curve price")
        );
    }

    // ───────────────────────── price probes (all ETH-per-token, 1e18-scaled) ─────────────────────────

    /// @dev ETH-per-token the curve charges for the final sliver of ETH reaching the graduation
    ///      threshold. Pure view, so it carries no launchpad fee/tax — the clean "last trade" price.
    function _curveEthPerTokenAtGraduation(ILivoBondingCurve curve) internal view returns (uint256) {
        uint256 threshold = curve.ethGraduationThreshold();
        (uint256 tokensOut,) = curve.buyTokensWithExactEth(threshold - PRICE_PROBE_ETH, PRICE_PROBE_ETH);
        return PRICE_PROBE_ETH * 1e18 / tokensOut;
    }

    /// @dev The V4 pool's opening spot price (ETH per token), read straight from slot0.
    function _v4PoolEthPerToken(address token) internal view returns (uint256) {
        PoolKey memory key = _getPoolKey(token);
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        return _convertSqrtX96ToTokenPrice(sqrtPriceX96);
    }

    /// @dev The V2 pool's opening spot price (ETH per token), from the pair reserves ratio.
    function _v2PoolEthPerToken(address token) internal view returns (uint256) {
        IUniswapV2Pair pair = IUniswapV2Pair(LivoToken(token).pair());
        (uint256 reserve0, uint256 reserve1,) = pair.getReserves();
        (uint256 wethReserve, uint256 tokenReserve) =
            pair.token0() == address(WETH) ? (reserve0, reserve1) : (reserve1, reserve0);
        return wethReserve * 1e18 / tokenReserve;
    }

    // ───────────────────────── helpers ─────────────────────────

    /// @dev Creates a token on the chosen venue + tier + flavor with a single creator vault holding
    ///      `vaultBps` of supply (no vault when `vaultBps == 0`). Sniper flavors whitelist `buyer` so the
    ///      graduation buys bypass the per-tx / per-wallet caps during the protection window.
    function _create(bool isV4, LiquidityTier tier, uint256 vaultBps, Flavor flavor) internal returns (address token) {
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
            salt: _nextValidSalt(factory, _implFor(isV4, flavor)),
            feeShares: _fs(creator),
            liquidityTier: tier
        });
        TaxConfigInit memory taxCfg = _taxCfgFor(flavor);
        AntiSniperConfigs memory sniperCfg = _sniperCfgFor(flavor);
        vm.prank(creator);
        if (isV4) {
            token = factoryV4Unified.createToken(setup, taxCfg, _cfg(), _noSs(), sniperCfg, vaults);
        } else {
            token = factoryV2Unified.createToken(setup, taxCfg, _noSs(), sniperCfg, vaults);
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

    function _isTax(Flavor f) internal pure returns (bool) {
        return f == Flavor.TAX || f == Flavor.TAX_SNIPER;
    }

    function _isSniper(Flavor f) internal pure returns (bool) {
        return f == Flavor.SNIPER || f == Flavor.TAX_SNIPER;
    }

    /// @dev A moderate static, creation-anchored 2%/2% tax for tax flavors; empty otherwise.
    function _taxCfgFor(Flavor f) internal pure returns (TaxConfigInit memory) {
        return _isTax(f) ? _taxCfg(200, 200, uint32(14 days)) : _emptyTaxCfg();
    }

    /// @dev 3%/3% caps over a 3h window for sniper flavors, whitelisting `buyer`; empty otherwise.
    function _sniperCfgFor(Flavor f) internal view returns (AntiSniperConfigs memory) {
        if (!_isSniper(f)) return _emptyAntiSniperCfg();
        address[] memory wl = new address[](1);
        wl[0] = buyer;
        return _antiSniperCfg(300, 300, uint40(3 hours), wl);
    }

    /// @dev The token implementation `createToken` will clone for this venue + flavor (needed to mine the salt).
    function _implFor(bool isV4, Flavor f) internal view returns (address) {
        bool tax = _isTax(f);
        bool sniper = _isSniper(f);
        if (tax && sniper) return isV4 ? address(livoTaxTokenSniper) : address(livoTaxTokenV2Sniper);
        if (tax) return isV4 ? address(livoTaxToken) : address(livoTaxTokenV2);
        if (sniper) return address(livoTokenSniper);
        return address(livoToken);
    }

    function _cfg() internal pure returns (LivoFactoryUniV4Unified.UniV4Configs memory) {
        return LivoFactoryUniV4Unified.UniV4Configs({renounceOwnership: false, lpFeeBps: 100});
    }

    function _tierName(LiquidityTier tier) internal pure returns (string memory) {
        if (tier == LiquidityTier.SMALL) return "SMALL";
        if (tier == LiquidityTier.DEFAULT) return "DEFAULT";
        return "LARGE";
    }

    function _flavorName(Flavor f) internal pure returns (string memory) {
        if (f == Flavor.BASE) return "plain";
        if (f == Flavor.TAX) return "tax";
        if (f == Flavor.SNIPER) return "sniper";
        return "tax+sniper";
    }

    /// @dev "[V4 SMALL 1500bps tax] " prefix so a looped assertion names the exact failing cell.
    function _ctx(bool isV4, LiquidityTier tier, uint256 bps, Flavor f) internal pure returns (string memory) {
        return
            string.concat(
                "[", isV4 ? "V4 " : "V2 ", _tierName(tier), " ", vm.toString(bps), "bps ", _flavorName(f), "] "
            );
    }
}

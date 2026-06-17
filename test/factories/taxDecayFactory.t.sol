// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LaunchpadBaseTestsWithUniv2Graduator} from "test/launchpad/base.t.sol";
import {LivoTaxableTokenUniV2} from "src/tokens/LivoTaxableTokenUniV2.sol";
import {ILivoToken} from "src/interfaces/ILivoToken.sol";
import {TaxConfigInit} from "src/interfaces/ILivoTaxableToken.sol";
import {ILivoFactory} from "src/interfaces/ILivoFactory.sol";

/// @notice Factory-layer tests for the linear tax-decay add-on: validation (caps + sentinel
///         consistency) and dispatch (a decay-only token — no long-term static tax — still routes to
///         the taxable impl, since post-graduation collection lives there).
contract TaxDecayFactoryTests is LaunchpadBaseTestsWithUniv2Graduator {
    uint16 internal constant MAX_DECAY_TOTAL_BPS = 2_000; // 20% combined (buy + sell)
    uint32 internal constant MAX_DECAY_DURATION = 20 minutes; // 1200s

    function _tax(address token, bool isBuy) internal view returns (uint16) {
        return ILivoToken(token)
        .getLaunchpadFees(ILivoToken.LaunchpadTrade({isBuy: isBuy, ethReserves: 0, releasedSupply: 0}))
        .taxBps;
    }

    // ───────────── Dispatch: decay-only routes to the taxable impl ─────────────

    function test_dispatch_decayOnly_returnsTaxImpl() public view {
        // static tax all zero, only decay configured
        address impl = factoryV2Unified.previewTokenImplementation(
            _fs(creator), _noSs(), _decayCfg(1000, 1000, MAX_DECAY_DURATION, true), _emptyAntiSniperCfg()
        );
        assertEq(impl, address(livoTaxTokenV2), "decay-only must route to the taxable impl");
    }

    function test_createToken_decayOnly_isTaxableCloneWithDecay() public {
        TaxConfigInit memory cfg = _decayCfg(1000, 800, MAX_DECAY_DURATION, true);
        bytes32 salt = _nextValidSalt(address(factoryV2Unified), address(livoTaxTokenV2));

        vm.prank(creator);
        address token = factoryV2Unified.createToken("D", "D", salt, _fs(creator), _noSs(), cfg, _emptyAntiSniperCfg());

        LivoTaxableTokenUniV2 t = LivoTaxableTokenUniV2(payable(token));
        // no long-term static tax
        assertEq(uint256(t.buyTaxBps()), 0, "static buy 0");
        assertEq(uint256(t.sellTaxBps()), 0, "static sell 0");
        assertEq(uint256(t.taxDurationSeconds()), 0, "static duration 0");
        // decay stored
        assertEq(uint256(t.buyTaxDecayStartBps()), 1000, "buy decay start");
        assertEq(uint256(t.sellTaxDecayStartBps()), 800, "sell decay start");
        assertEq(uint256(t.taxDecayDuration()), MAX_DECAY_DURATION, "decay duration");
        // effective rate at launch is the decay start
        assertEq(_tax(token, true), 1000, "buy decay live at launch");
        assertEq(_tax(token, false), 800, "sell decay live at launch");
    }

    // ───────────── Decay sentinel validation ─────────────

    function test_preview_revertsOnDecayDurationWithZeroBps() public {
        TaxConfigInit memory cfg = _decayCfg(0, 0, MAX_DECAY_DURATION, true);
        vm.expectRevert(ILivoFactory.InvalidTaxConfig.selector);
        factoryV2Unified.previewTokenImplementation(_fs(creator), _noSs(), cfg, _emptyAntiSniperCfg());
    }

    function test_preview_revertsOnDecayBpsWithZeroDuration() public {
        // decay bps set but duration 0 — inconsistent
        TaxConfigInit memory cfg = _taxCfg(0, 0, 0, true, 1000, 0, 0);
        vm.expectRevert(ILivoFactory.InvalidTaxConfig.selector);
        factoryV2Unified.previewTokenImplementation(_fs(creator), _noSs(), cfg, _emptyAntiSniperCfg());
    }

    // ───────────── Decay caps (combined buy + sell) ─────────────

    function test_preview_acceptsBalancedDecayBpsAtMax() public view {
        // 10% / 10% — sums to exactly the combined cap
        TaxConfigInit memory cfg = _decayCfg(MAX_DECAY_TOTAL_BPS / 2, MAX_DECAY_TOTAL_BPS / 2, MAX_DECAY_DURATION, true);
        factoryV2Unified.previewTokenImplementation(_fs(creator), _noSs(), cfg, _emptyAntiSniperCfg());
    }

    function test_preview_acceptsAsymmetricSplitAtMax() public view {
        // 5% / 15% — rejected under the old per-direction 10% cap, allowed now (sum == 20%)
        TaxConfigInit memory cfg = _decayCfg(500, 1500, MAX_DECAY_DURATION, true);
        factoryV2Unified.previewTokenImplementation(_fs(creator), _noSs(), cfg, _emptyAntiSniperCfg());
    }

    function test_preview_acceptsSingleDirectionAtMax() public view {
        // 20% / 0% — whole combined budget on one direction
        TaxConfigInit memory cfg = _decayCfg(MAX_DECAY_TOTAL_BPS, 0, MAX_DECAY_DURATION, true);
        factoryV2Unified.previewTokenImplementation(_fs(creator), _noSs(), cfg, _emptyAntiSniperCfg());
    }

    function test_preview_revertsOnCombinedDecayBpsOverMax() public {
        // 10% + 10.01% = 20.01% combined, one bp over the cap
        TaxConfigInit memory cfg = _decayCfg(1000, MAX_DECAY_TOTAL_BPS / 2 + 1, MAX_DECAY_DURATION, true);
        vm.expectRevert(ILivoFactory.InvalidTaxBps.selector);
        factoryV2Unified.previewTokenImplementation(_fs(creator), _noSs(), cfg, _emptyAntiSniperCfg());
    }

    function test_preview_acceptsDecayDurationAtMax() public view {
        TaxConfigInit memory cfg = _decayCfg(1000, 1000, MAX_DECAY_DURATION, true);
        factoryV2Unified.previewTokenImplementation(_fs(creator), _noSs(), cfg, _emptyAntiSniperCfg());
    }

    function test_preview_revertsOnDecayDurationOverMax() public {
        TaxConfigInit memory cfg = _decayCfg(1000, 1000, MAX_DECAY_DURATION + 1, true);
        vm.expectRevert(ILivoFactory.InvalidTaxDuration.selector);
        factoryV2Unified.previewTokenImplementation(_fs(creator), _noSs(), cfg, _emptyAntiSniperCfg());
    }

    // ───────────── Decay composes with a long-term static tax ─────────────

    function test_createToken_decayPlusStatic() public {
        // static 500 over 7 days + decay 1000 over 20min
        TaxConfigInit memory cfg = _taxCfg(500, 500, uint32(7 days), true, 1000, 1000, MAX_DECAY_DURATION);
        bytes32 salt = _nextValidSalt(address(factoryV2Unified), address(livoTaxTokenV2));

        vm.prank(creator);
        address token =
            factoryV2Unified.createToken("DS", "DS", salt, _fs(creator), _noSs(), cfg, _emptyAntiSniperCfg());

        assertEq(_tax(token, true), 1000, "at launch, decay 10% dominates static 5%");
    }
}

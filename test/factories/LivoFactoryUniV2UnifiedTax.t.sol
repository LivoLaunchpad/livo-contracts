// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LaunchpadBaseTestsWithUniv2Graduator} from "test/launchpad/base.t.sol";
import {LivoFactoryUniV2Unified} from "src/factories/LivoFactoryUniV2Unified.sol";
import {LivoTaxableTokenUniV2} from "src/tokens/LivoTaxableTokenUniV2.sol";
import {AntiSniperConfigs} from "src/tokens/SniperProtection.sol";
import {TaxConfigInit} from "src/interfaces/ILivoTaxableToken.sol";
import {ILivoFactory} from "src/interfaces/ILivoFactory.sol";

/// @notice Tax dispatch + tax-config validation tests for `LivoFactoryUniV2Unified`. Mirrors the
///         V4 unified tax tests. Locks in: (1) the four-cell dispatch matrix (tax × anti-sniper)
///         resolves to the correct implementation; (2) `previewTokenImplementation` returns the
///         same address `createToken` clones; (3) tax-config validation matches the V4 factory
///         (max bps, max duration up to the 120-year overflow cap, no fee-receiver/ownership
///         gating); (4) tax fields propagate to the deployed token; (5) ownership rule (all V2
///         tokens are ownerless at creation).
contract LivoFactoryUniV2UnifiedTaxTests is LaunchpadBaseTestsWithUniv2Graduator {
    // ───────────── Dispatch — preview returns correct impl per combo ─────────────

    function test_dispatch_tax_returnsTaxImpl() public view {
        address impl = factoryV2Unified.previewTokenImplementation(
            _fs(creator), _noSs(), _toCfgs(_taxCfg(0, 400, uint32(7 days))), _emptyAntiSniperCfg()
        );
        assertEq(impl, address(livoTaxTokenV2));
    }

    function test_dispatch_taxAntiSniper_returnsTaxAntiSniperImpl() public view {
        address impl = factoryV2Unified.previewTokenImplementation(
            _fs(creator), _noSs(), _toCfgs(_taxCfg(0, 400, uint32(7 days))), _defaultAntiSniperCfg()
        );
        assertEq(impl, address(livoTaxTokenV2Sniper));
    }

    // ───────────── Dispatch — preview matches deployed for each tax combo ─────────────

    function test_createToken_dispatchMatchesPreview_tax() public {
        TaxConfigInit memory cfg = _taxCfg(100, 200, uint32(7 days));
        address impl =
            factoryV2Unified.previewTokenImplementation(_fs(creator), _noSs(), _toCfgs(cfg), _emptyAntiSniperCfg());
        bytes32 salt = _nextValidSalt(address(factoryV2Unified), impl);
        address expected = _predictToken(address(factoryV2Unified), impl, creator, salt);

        vm.prank(creator);
        address token = factoryV2Unified.createToken("T", "T", salt, _fs(creator), _noSs(), cfg, _emptyAntiSniperCfg());

        assertEq(token, expected);
    }

    function test_createToken_dispatchMatchesPreview_taxAntiSniper() public {
        TaxConfigInit memory cfg = _taxCfg(100, 200, uint32(7 days));
        address impl =
            factoryV2Unified.previewTokenImplementation(_fs(creator), _noSs(), _toCfgs(cfg), _defaultAntiSniperCfg());
        bytes32 salt = _nextValidSalt(address(factoryV2Unified), impl);
        address expected = _predictToken(address(factoryV2Unified), impl, creator, salt);

        vm.prank(creator);
        address token =
            factoryV2Unified.createToken("T", "T", salt, _fs(creator), _noSs(), cfg, _defaultAntiSniperCfg());

        assertEq(token, expected);
    }

    // ───────────── Tax config readback ─────────────

    function test_createToken_tax_configFieldsStoredOnToken() public {
        TaxConfigInit memory cfg = _taxCfg(150, 250, uint32(7 days));
        address impl =
            factoryV2Unified.previewTokenImplementation(_fs(creator), _noSs(), _toCfgs(cfg), _emptyAntiSniperCfg());
        bytes32 salt = _nextValidSalt(address(factoryV2Unified), impl);

        vm.prank(creator);
        address token = factoryV2Unified.createToken("T", "T", salt, _fs(creator), _noSs(), cfg, _emptyAntiSniperCfg());

        LivoTaxableTokenUniV2 t = LivoTaxableTokenUniV2(payable(token));
        assertEq(t.buyTaxBps(), 150);
        assertEq(t.sellTaxBps(), 250);
        assertEq(uint256(t.taxDurationSeconds()), 7 days);
        assertEq(uint256(t.graduationTimestamp()), 0); // not graduated yet
    }

    // ───────────── Tax sentinel validation ─────────────

    function test_preview_revertsOnDisabledTaxWithNonZeroBps() public {
        TaxConfigInit memory cfg = _taxCfg(100, 0, 0);
        vm.expectRevert(ILivoFactory.InvalidTaxConfig.selector);
        factoryV2Unified.previewTokenImplementation(_fs(creator), _noSs(), _toCfgs(cfg), _emptyAntiSniperCfg());
    }

    function test_preview_revertsOnEnabledTaxWithZeroBps() public {
        TaxConfigInit memory cfg = _taxCfg(0, 0, uint32(7 days));
        vm.expectRevert(ILivoFactory.InvalidTaxConfig.selector);
        factoryV2Unified.previewTokenImplementation(_fs(creator), _noSs(), _toCfgs(cfg), _emptyAntiSniperCfg());
    }

    function test_preview_acceptsBpsAtMax() public view {
        // 500 bps is the V2 tax cap: V2 has no post-graduation LP fee, so the tax can use the full
        // MAX_TOTAL_FEE_BPS. The pre-graduation launchpad LP fee does not count against it. Boundary
        // value must be accepted.
        TaxConfigInit memory cfg = _taxCfg(500, 500, uint32(7 days));
        factoryV2Unified.previewTokenImplementation(_fs(creator), _noSs(), _toCfgs(cfg), _emptyAntiSniperCfg());
    }

    function test_preview_revertsOnTaxBpsOverMax() public {
        TaxConfigInit memory cfg = _taxCfg(501, 0, uint32(7 days));
        vm.expectRevert(ILivoFactory.InvalidTaxBps.selector);
        factoryV2Unified.previewTokenImplementation(_fs(creator), _noSs(), _toCfgs(cfg), _emptyAntiSniperCfg());
    }

    function test_preview_revertsOnSellTaxBpsOverMax() public {
        TaxConfigInit memory cfg = _taxCfg(0, 501, uint32(7 days));
        vm.expectRevert(ILivoFactory.InvalidTaxBps.selector);
        factoryV2Unified.previewTokenImplementation(_fs(creator), _noSs(), _toCfgs(cfg), _emptyAntiSniperCfg());
    }

    function test_preview_revertsOnDurationOverCap() public {
        TaxConfigInit memory cfg = _taxCfg(100, 0, uint32(120 * 365 days + 1));
        vm.expectRevert(ILivoFactory.InvalidTaxDuration.selector);
        factoryV2Unified.previewTokenImplementation(_fs(alice), _noSs(), _toCfgs(cfg), _emptyAntiSniperCfg());
    }

    // ───────────── Extended durations — no restrictions beyond the 120-year cap ─────────────

    function test_createToken_succeedsForExtendedDurationWithDeployerAsFeeReceiver() public {
        TaxConfigInit memory cfg = _taxCfg(100, 0, uint32(5 * 365 days));
        bytes32 salt = _nextValidSalt(address(factoryV2Unified), address(livoTaxTokenV2));

        vm.prank(creator);
        address token = factoryV2Unified.createToken("T", "T", salt, _fs(creator), _noSs(), cfg, _emptyAntiSniperCfg());

        LivoTaxableTokenUniV2 t = LivoTaxableTokenUniV2(payable(token));
        assertEq(uint256(t.taxDurationSeconds()), 5 * 365 days);
        assertEq(t.owner(), address(0));
    }

    function test_createToken_succeedsForExtendedDurationWithMultipleReceivers() public {
        TaxConfigInit memory cfg = _taxCfg(100, 0, uint32(365 days + 1));
        bytes32 salt = _nextValidSalt(address(factoryV2Unified), address(livoTaxTokenV2));

        ILivoFactory.FeeShare[] memory two = new ILivoFactory.FeeShare[](2);
        two[0] = ILivoFactory.FeeShare({account: alice, shares: 5_000, directFeesEnabled: false});
        two[1] = ILivoFactory.FeeShare({account: bob, shares: 5_000, directFeesEnabled: false});

        vm.prank(creator);
        address token = factoryV2Unified.createToken("T", "T", salt, two, _noSs(), cfg, _emptyAntiSniperCfg());

        assertEq(uint256(LivoTaxableTokenUniV2(payable(token)).taxDurationSeconds()), 365 days + 1);
    }

    function test_createToken_succeedsForMaxDuration() public {
        TaxConfigInit memory cfg = _taxCfg(100, 0, uint32(120 * 365 days));
        bytes32 salt = _nextValidSalt(address(factoryV2Unified), address(livoTaxTokenV2));

        vm.prank(creator);
        address token = factoryV2Unified.createToken("T", "T", salt, _fs(alice), _noSs(), cfg, _emptyAntiSniperCfg());

        LivoTaxableTokenUniV2 t = LivoTaxableTokenUniV2(payable(token));
        assertEq(uint256(t.taxDurationSeconds()), 120 * 365 days);
    }

    // ───────────── Ownership semantics ─────────────

    function test_createToken_taxVariant_alwaysSetsOwnerToZero() public {
        TaxConfigInit memory cfg = _taxCfg(100, 100, uint32(7 days));
        bytes32 salt = _nextValidSalt(address(factoryV2Unified), address(livoTaxTokenV2));

        vm.prank(creator);
        address token = factoryV2Unified.createToken("T", "T", salt, _fs(creator), _noSs(), cfg, _emptyAntiSniperCfg());

        assertEq(LivoTaxableTokenUniV2(payable(token)).owner(), address(0));
    }

    function test_createToken_taxAntiSniperVariant_alwaysSetsOwnerToZero() public {
        TaxConfigInit memory cfg = _taxCfg(100, 100, uint32(7 days));
        bytes32 salt = _nextValidSalt(address(factoryV2Unified), address(livoTaxTokenV2Sniper));

        vm.prank(creator);
        address token =
            factoryV2Unified.createToken("T", "T", salt, _fs(creator), _noSs(), cfg, _defaultAntiSniperCfg());

        assertEq(LivoTaxableTokenUniV2(payable(token)).owner(), address(0));
    }

    function test_createToken_nonTaxVariant_alwaysSetsOwnerToZero() public {
        bytes32 salt = _nextValidSalt(address(factoryV2Unified), address(livoToken));

        vm.prank(creator);
        address token =
            factoryV2Unified.createToken("T", "T", salt, _fs(creator), _noSs(), _emptyTaxCfg(), _emptyAntiSniperCfg());

        assertEq(LivoTaxableTokenUniV2(payable(token)).owner(), address(0));
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LaunchpadBaseTestsWithUniv2Graduator} from "test/launchpad/base.t.sol";
import {LivoFactoryUniV2Unified} from "src/factories/LivoFactoryUniV2Unified.sol";
import {LivoToken} from "src/tokens/LivoToken.sol";
import {LivoTokenSniperProtected} from "src/tokens/LivoTokenSniperProtected.sol";
import {AntiSniperConfigs} from "src/tokens/SniperProtection.sol";
import {ILivoFactory} from "src/interfaces/ILivoFactory.sol";
import {Clones} from "lib/openzeppelin-contracts/contracts/proxy/Clones.sol";

/// @notice Dispatch + field-readback tests for `LivoFactoryUniV2Unified`. These non-tax tests lock
///         in dispatch between the base and anti-sniper implementations based on
///         `antiSniperCfg.protectionWindowSeconds != 0`:
///         (1) `previewTokenImplementation(...)` returns the same address that `createToken`
///         actually clones from — load-bearing for frontend salt mining; and (2) the configs
///         are correctly propagated from the factory to the cloned token's storage.
contract LivoFactoryUniV2UnifiedTests is LaunchpadBaseTestsWithUniv2Graduator {
    // ───────────── Dispatch — preview ─────────────

    function test_dispatch_noAntiSniper_returnsBaseImpl() public view {
        address impl = factoryV2Unified.previewTokenImplementation(
            _fs(creator), _noSs(), _toCfgs(_emptyTaxCfg()), _emptyAntiSniperCfg()
        );
        assertEq(impl, address(livoToken));
    }

    function test_dispatch_withAntiSniper_returnsAntiSniperImpl() public view {
        address impl = factoryV2Unified.previewTokenImplementation(
            _fs(creator), _noSs(), _toCfgs(_emptyTaxCfg()), _defaultAntiSniperCfg()
        );
        assertEq(impl, address(livoTokenSniper));
    }

    // ───────────── Dispatch — preview matches deployed ─────────────

    function test_createToken_dispatchMatchesPreview_base() public {
        address impl = factoryV2Unified.previewTokenImplementation(
            _fs(creator), _noSs(), _toCfgs(_emptyTaxCfg()), _emptyAntiSniperCfg()
        );
        bytes32 salt = _nextValidSalt(address(factoryV2Unified), impl);
        address expected = Clones.predictDeterministicAddress(impl, salt, address(factoryV2Unified));

        vm.prank(creator);
        address token =
            factoryV2Unified.createToken("T", "T", salt, _fs(creator), _noSs(), _emptyTaxCfg(), _emptyAntiSniperCfg());

        assertEq(token, expected);
    }

    /// @dev A no-vault token resolves to the base `BONDING_CURVE`; BondingCurveAssigned carries it.
    function test_createToken_emitsBondingCurveAssigned() public {
        address impl = factoryV2Unified.previewTokenImplementation(
            _fs(creator), _noSs(), _toCfgs(_emptyTaxCfg()), _emptyAntiSniperCfg()
        );
        bytes32 salt = _nextValidSalt(address(factoryV2Unified), impl);
        address expected = Clones.predictDeterministicAddress(impl, salt, address(factoryV2Unified));

        vm.expectEmit(true, true, false, false);
        emit ILivoFactory.BondingCurveAssigned(expected, address(factoryV2Unified.BONDING_CURVE()));
        vm.prank(creator);
        factoryV2Unified.createToken("T", "T", salt, _fs(creator), _noSs(), _emptyTaxCfg(), _emptyAntiSniperCfg());
    }

    function test_createToken_dispatchMatchesPreview_antiSniper() public {
        address impl = factoryV2Unified.previewTokenImplementation(
            _fs(creator), _noSs(), _toCfgs(_emptyTaxCfg()), _defaultAntiSniperCfg()
        );
        bytes32 salt = _nextValidSalt(address(factoryV2Unified), impl);
        address expected = Clones.predictDeterministicAddress(impl, salt, address(factoryV2Unified));

        vm.prank(creator);
        address token = factoryV2Unified.createToken(
            "T", "T", salt, _fs(creator), _noSs(), _emptyTaxCfg(), _defaultAntiSniperCfg()
        );

        assertEq(token, expected);
    }

    // ───────────── Anti-sniper config propagation ─────────────

    function test_createToken_antiSniper_configFieldsStoredOnToken() public {
        address[] memory wl = new address[](2);
        wl[0] = alice;
        wl[1] = bob;
        AntiSniperConfigs memory cfg = _antiSniperCfg(50, 150, 45 minutes, wl);

        address impl = factoryV2Unified.previewTokenImplementation(_fs(creator), _noSs(), _toCfgs(_emptyTaxCfg()), cfg);
        bytes32 salt = _nextValidSalt(address(factoryV2Unified), impl);

        vm.prank(creator);
        address token = factoryV2Unified.createToken("T", "T", salt, _fs(creator), _noSs(), _emptyTaxCfg(), cfg);

        LivoTokenSniperProtected t = LivoTokenSniperProtected(token);
        assertEq(t.maxBuyPerTxBps(), 50);
        assertEq(t.maxWalletBps(), 150);
        assertEq(uint256(t.protectionWindowSeconds()), 45 minutes);
        assertTrue(t.sniperBypass(alice));
        assertTrue(t.sniperBypass(bob));
        assertFalse(t.sniperBypass(creator));
    }

    // ───────────── Anti-sniper sentinel validation ─────────────

    function test_preview_revertsOnDisabledAntiSniperWithNonZeroFields() public {
        AntiSniperConfigs memory cfg = _antiSniperCfg(50, 0, 0, new address[](0));

        vm.expectRevert(ILivoFactory.InvalidAntiSniperConfig.selector);
        factoryV2Unified.previewTokenImplementation(_fs(creator), _noSs(), _toCfgs(_emptyTaxCfg()), cfg);
    }

    function test_createToken_revertsOnDisabledAntiSniperWithWhitelist() public {
        address[] memory wl = new address[](1);
        wl[0] = alice;
        AntiSniperConfigs memory cfg = _antiSniperCfg(0, 0, 0, wl);

        vm.prank(creator);
        vm.expectRevert(ILivoFactory.InvalidAntiSniperConfig.selector);
        factoryV2Unified.createToken("T", "T", "0x12", _fs(creator), _noSs(), _emptyTaxCfg(), cfg);
    }

    // ───────────── Ownership: V2 is always ownerless ─────────────

    function test_createToken_alwaysSetsOwnerToZero_base() public {
        address impl = address(livoToken);
        bytes32 salt = _nextValidSalt(address(factoryV2Unified), impl);

        vm.prank(creator);
        address token =
            factoryV2Unified.createToken("T", "T", salt, _fs(creator), _noSs(), _emptyTaxCfg(), _emptyAntiSniperCfg());

        assertEq(LivoToken(token).owner(), address(0));
    }

    function test_createToken_alwaysSetsOwnerToZero_antiSniper() public {
        address impl = address(livoTokenSniper);
        bytes32 salt = _nextValidSalt(address(factoryV2Unified), impl);

        vm.prank(creator);
        address token = factoryV2Unified.createToken(
            "T", "T", salt, _fs(creator), _noSs(), _emptyTaxCfg(), _defaultAntiSniperCfg()
        );

        assertEq(LivoTokenSniperProtected(token).owner(), address(0));
    }

    // ───────────── Empty fee receivers (V2 specific) ─────────────

    function test_createToken_revertsOnEmptyFeeReceivers() public {
        bytes32 salt = _nextValidSalt(address(factoryV2Unified), address(livoToken));

        vm.prank(creator);
        vm.expectRevert(ILivoFactory.InvalidFeeReceiver.selector);
        factoryV2Unified.createToken("T", "T", salt, _noFs(), _noSs(), _emptyTaxCfg(), _emptyAntiSniperCfg());
    }
}

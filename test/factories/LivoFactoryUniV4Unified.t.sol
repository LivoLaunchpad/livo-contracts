// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LaunchpadBaseTestsWithUniv4Graduator} from "test/launchpad/base.t.sol";
import {LivoFactoryUniV4Unified} from "src/factories/LivoFactoryUniV4Unified.sol";
import {LivoToken} from "src/tokens/LivoToken.sol";
import {LivoTokenSniperProtected} from "src/tokens/LivoTokenSniperProtected.sol";
import {LivoTaxableTokenUniV4} from "src/tokens/LivoTaxableTokenUniV4.sol";
import {LivoTaxableTokenUniV4SniperProtected} from "src/tokens/LivoTaxableTokenUniV4SniperProtected.sol";
import {AntiSniperConfigs} from "src/tokens/SniperProtection.sol";
import {TaxConfigInit} from "src/interfaces/ILivoTaxableToken.sol";
import {ILivoFactory} from "src/interfaces/ILivoFactory.sol";
import {Clones} from "lib/openzeppelin-contracts/contracts/proxy/Clones.sol";

/// @notice Dispatch + field-readback tests for `LivoFactoryUniV4Unified`. The unified factory
///         dispatches between four token implementations based on whether `taxCfg` and
///         `antiSniperCfg` are configured. These tests lock in:
///         (1) `previewTokenImplementation(...)` returns the same address that `createToken`
///         actually clones from for each of the 4 dispatch combos — load-bearing for frontend
///         salt mining; and (2) the configs are correctly propagated from the factory to the
///         cloned token's storage.
contract LivoFactoryUniV4UnifiedTests is LaunchpadBaseTestsWithUniv4Graduator {
    // ───────────── Dispatch — preview returns correct impl per combo ─────────────

    function test_dispatch_base_returnsBaseImpl() public view {
        address impl =
            factoryV4Unified.previewTokenImplementation(_fs(creator), _noSs(), _emptyTaxCfg(), _emptyAntiSniperCfg());
        assertEq(impl, address(livoToken));
    }

    function test_dispatch_antiSniper_returnsAntiSniperImpl() public view {
        address impl =
            factoryV4Unified.previewTokenImplementation(_fs(creator), _noSs(), _emptyTaxCfg(), _defaultAntiSniperCfg());
        assertEq(impl, address(livoTokenSniper));
    }

    function test_dispatch_tax_returnsTaxImpl() public view {
        address impl = factoryV4Unified.previewTokenImplementation(
            _fs(creator), _noSs(), _taxCfg(0, 400, uint32(7 days)), _emptyAntiSniperCfg()
        );
        assertEq(impl, address(livoTaxToken));
    }

    function test_dispatch_taxAntiSniper_returnsTaxAntiSniperImpl() public view {
        address impl = factoryV4Unified.previewTokenImplementation(
            _fs(creator), _noSs(), _taxCfg(0, 400, uint32(7 days)), _defaultAntiSniperCfg()
        );
        assertEq(impl, address(livoTaxTokenSniper));
    }

    // ───────────── Dispatch — preview matches deployed for each combo ─────────────

    function test_createToken_dispatchMatchesPreview_base() public {
        address impl =
            factoryV4Unified.previewTokenImplementation(_fs(creator), _noSs(), _emptyTaxCfg(), _emptyAntiSniperCfg());
        bytes32 salt = _nextValidSalt(address(factoryV4Unified), impl);
        address expected = Clones.predictDeterministicAddress(impl, salt, address(factoryV4Unified));

        vm.prank(creator);
        address token = factoryV4Unified.createToken(
            "T", "T", salt, _fs(creator), _noSs(), false, _emptyTaxCfg(), _emptyAntiSniperCfg()
        );

        assertEq(token, expected);
    }

    function test_createToken_dispatchMatchesPreview_antiSniper() public {
        address impl =
            factoryV4Unified.previewTokenImplementation(_fs(creator), _noSs(), _emptyTaxCfg(), _defaultAntiSniperCfg());
        bytes32 salt = _nextValidSalt(address(factoryV4Unified), impl);
        address expected = Clones.predictDeterministicAddress(impl, salt, address(factoryV4Unified));

        vm.prank(creator);
        address token = factoryV4Unified.createToken(
            "T", "T", salt, _fs(creator), _noSs(), false, _emptyTaxCfg(), _defaultAntiSniperCfg()
        );

        assertEq(token, expected);
    }

    function test_createToken_dispatchMatchesPreview_tax() public {
        TaxConfigInit memory cfg = _taxCfg(100, 200, uint32(7 days));
        address impl = factoryV4Unified.previewTokenImplementation(_fs(creator), _noSs(), cfg, _emptyAntiSniperCfg());
        bytes32 salt = _nextValidSalt(address(factoryV4Unified), impl);
        address expected = Clones.predictDeterministicAddress(impl, salt, address(factoryV4Unified));

        vm.prank(creator);
        address token =
            factoryV4Unified.createToken("T", "T", salt, _fs(creator), _noSs(), false, cfg, _emptyAntiSniperCfg());

        assertEq(token, expected);
    }

    function test_createToken_dispatchMatchesPreview_taxAntiSniper() public {
        TaxConfigInit memory cfg = _taxCfg(100, 200, uint32(7 days));
        address impl = factoryV4Unified.previewTokenImplementation(_fs(creator), _noSs(), cfg, _defaultAntiSniperCfg());
        bytes32 salt = _nextValidSalt(address(factoryV4Unified), impl);
        address expected = Clones.predictDeterministicAddress(impl, salt, address(factoryV4Unified));

        vm.prank(creator);
        address token =
            factoryV4Unified.createToken("T", "T", salt, _fs(creator), _noSs(), false, cfg, _defaultAntiSniperCfg());

        assertEq(token, expected);
    }

    // ───────────── Config field readback ─────────────

    function test_createToken_antiSniper_configFieldsStoredOnToken() public {
        address[] memory wl = new address[](2);
        wl[0] = alice;
        wl[1] = bob;
        AntiSniperConfigs memory snipCfg = _antiSniperCfg(50, 100, 30 minutes, wl);

        address impl = factoryV4Unified.previewTokenImplementation(_fs(creator), _noSs(), _emptyTaxCfg(), snipCfg);
        bytes32 salt = _nextValidSalt(address(factoryV4Unified), impl);

        vm.prank(creator);
        address token =
            factoryV4Unified.createToken("T", "T", salt, _fs(creator), _noSs(), false, _emptyTaxCfg(), snipCfg);

        LivoTokenSniperProtected t = LivoTokenSniperProtected(token);
        assertEq(t.maxBuyPerTxBps(), 50);
        assertEq(t.maxWalletBps(), 100);
        assertEq(uint256(t.protectionWindowSeconds()), 30 minutes);
        assertTrue(t.sniperBypass(alice));
        assertTrue(t.sniperBypass(bob));
        assertFalse(t.sniperBypass(creator));
    }

    function test_createToken_tax_configFieldsStoredOnToken() public {
        TaxConfigInit memory cfg = _taxCfg(150, 250, uint32(3 days));
        address impl = factoryV4Unified.previewTokenImplementation(_fs(creator), _noSs(), cfg, _emptyAntiSniperCfg());
        bytes32 salt = _nextValidSalt(address(factoryV4Unified), impl);

        vm.prank(creator);
        address token =
            factoryV4Unified.createToken("T", "T", salt, _fs(creator), _noSs(), false, cfg, _emptyAntiSniperCfg());

        LivoTaxableTokenUniV4 t = LivoTaxableTokenUniV4(payable(token));
        assertEq(t.buyTaxBps(), 150);
        assertEq(t.sellTaxBps(), 250);
        assertEq(uint256(t.taxDurationSeconds()), 3 days);
    }

    function test_createToken_taxAntiSniper_bothFieldsStored() public {
        address[] memory wl = new address[](1);
        wl[0] = alice;
        TaxConfigInit memory taxCfg = _taxCfg(100, 200, uint32(1 days));
        AntiSniperConfigs memory snipCfg = _antiSniperCfg(25, 100, 2 hours, wl);

        address impl = factoryV4Unified.previewTokenImplementation(_fs(creator), _noSs(), taxCfg, snipCfg);
        bytes32 salt = _nextValidSalt(address(factoryV4Unified), impl);

        vm.prank(creator);
        address token = factoryV4Unified.createToken("T", "T", salt, _fs(creator), _noSs(), false, taxCfg, snipCfg);

        LivoTaxableTokenUniV4SniperProtected t = LivoTaxableTokenUniV4SniperProtected(payable(token));
        assertEq(t.buyTaxBps(), 100);
        assertEq(t.sellTaxBps(), 200);
        assertEq(uint256(t.taxDurationSeconds()), 1 days);
        assertEq(t.maxBuyPerTxBps(), 25);
        assertEq(t.maxWalletBps(), 100);
        assertEq(uint256(t.protectionWindowSeconds()), 2 hours);
        assertTrue(t.sniperBypass(alice));
    }

    // ───────────── Renounce ownership ─────────────

    function test_createToken_renounceOwnership_setsOwnerToZero_taxVariant() public {
        TaxConfigInit memory cfg = _taxCfg(0, 400, uint32(14 days));
        address impl = factoryV4Unified.previewTokenImplementation(_fs(creator), _noSs(), cfg, _emptyAntiSniperCfg());
        bytes32 salt = _nextValidSalt(address(factoryV4Unified), impl);

        vm.prank(creator);
        address token =
            factoryV4Unified.createToken("T", "T", salt, _fs(creator), _noSs(), true, cfg, _emptyAntiSniperCfg());

        assertEq(LivoTaxableTokenUniV4(payable(token)).owner(), address(0));
    }

    function test_createToken_keepOwnership_setsOwnerToCaller_taxVariant() public {
        TaxConfigInit memory cfg = _taxCfg(0, 400, uint32(14 days));
        address impl = factoryV4Unified.previewTokenImplementation(_fs(creator), _noSs(), cfg, _emptyAntiSniperCfg());
        bytes32 salt = _nextValidSalt(address(factoryV4Unified), impl);

        vm.prank(creator);
        address token =
            factoryV4Unified.createToken("T", "T", salt, _fs(creator), _noSs(), false, cfg, _emptyAntiSniperCfg());

        assertEq(LivoTaxableTokenUniV4(payable(token)).owner(), creator);
    }

    // ───────────── Tax / anti-sniper sentinel validation ─────────────

    function test_preview_revertsOnDisabledTaxWithNonZeroBps() public {
        vm.expectRevert(ILivoFactory.InvalidTaxConfig.selector);
        factoryV4Unified.previewTokenImplementation(_fs(creator), _noSs(), _taxCfg(100, 0, 0), _emptyAntiSniperCfg());
    }

    function test_createToken_revertsOnDisabledTaxWithNonZeroBps() public {
        vm.prank(creator);
        vm.expectRevert(ILivoFactory.InvalidTaxConfig.selector);
        factoryV4Unified.createToken(
            "T", "T", "0x12", _fs(creator), _noSs(), false, _taxCfg(100, 0, 0), _emptyAntiSniperCfg()
        );
    }

    function test_createToken_revertsOnTaxDurationWithoutBps() public {
        vm.prank(creator);
        vm.expectRevert(ILivoFactory.InvalidTaxConfig.selector);
        factoryV4Unified.createToken(
            "T", "T", "0x12", _fs(creator), _noSs(), false, _taxCfg(0, 0, uint32(1 days)), _emptyAntiSniperCfg()
        );
    }

    function test_createToken_revertsOnDisabledAntiSniperWithNonZeroFields() public {
        AntiSniperConfigs memory cfg = _antiSniperCfg(50, 0, 0, new address[](0));

        vm.prank(creator);
        vm.expectRevert(ILivoFactory.InvalidAntiSniperConfig.selector);
        factoryV4Unified.createToken("T", "T", "0x12", _fs(creator), _noSs(), false, _emptyTaxCfg(), cfg);
    }

    function test_createToken_revertsOnInvalidTaxBps() public {
        vm.prank(creator);
        vm.expectRevert(ILivoFactory.InvalidTaxBps.selector);
        factoryV4Unified.createToken(
            "T", "T", "0x12", _fs(creator), _noSs(), false, _taxCfg(0, 401, uint32(14 days)), _emptyAntiSniperCfg()
        );
    }

    function test_createToken_revertsOnInvalidTaxDuration() public {
        vm.prank(creator);
        vm.expectRevert(ILivoFactory.InvalidTaxDuration.selector);
        factoryV4Unified.createToken(
            "T", "T", "0x12", _fs(creator), _noSs(), false, _taxCfg(0, 400, uint32(730 days + 1)), _emptyAntiSniperCfg()
        );
    }

    function test_createToken_revertsOnInvalidTaxDurationEvenWhenWhitelisted() public {
        vm.prank(admin);
        deployersWhitelist.setWhitelisted(creator, true);

        vm.prank(creator);
        vm.expectRevert(ILivoFactory.InvalidTaxDuration.selector);
        factoryV4Unified.createToken(
            "T", "T", "0x12", _fs(creator), _noSs(), false, _taxCfg(0, 400, uint32(730 days + 1)), _emptyAntiSniperCfg()
        );
    }

    function test_createToken_revertsOnExtendedTaxWhenDeployerNotWhitelisted() public {
        vm.prank(creator);
        vm.expectRevert(ILivoFactory.DeployerNotWhitelisted.selector);
        factoryV4Unified.createToken(
            "T", "T", "0x12", _fs(creator), _noSs(), false, _taxCfg(0, 400, uint32(14 days + 1)), _emptyAntiSniperCfg()
        );
    }

    function test_createToken_allowsExtendedTaxForWhitelistedDeployer() public {
        vm.prank(admin);
        deployersWhitelist.setWhitelisted(creator, true);

        bytes32 salt = _nextValidSalt(address(factoryV4Unified), address(livoTaxToken));

        vm.prank(creator);
        address token = factoryV4Unified.createToken(
            "T", "T", salt, _fs(creator), _noSs(), false, _taxCfg(0, 400, uint32(15 days)), _emptyAntiSniperCfg()
        );

        assertEq(uint256(LivoTaxableTokenUniV4(payable(token)).taxDurationSeconds()), 15 days);
    }

    function test_createToken_allowsMaxExtendedTaxForWhitelistedDeployer() public {
        vm.prank(admin);
        deployersWhitelist.setWhitelisted(creator, true);

        bytes32 salt = _nextValidSalt(address(factoryV4Unified), address(livoTaxToken));

        vm.prank(creator);
        address token = factoryV4Unified.createToken(
            "T", "T", salt, _fs(creator), _noSs(), false, _taxCfg(0, 400, uint32(730 days)), _emptyAntiSniperCfg()
        );

        assertEq(uint256(LivoTaxableTokenUniV4(payable(token)).taxDurationSeconds()), 730 days);
    }

    function test_preview_revertsOnExtendedTaxWhenDeployerNotWhitelisted() public {
        vm.prank(creator);
        vm.expectRevert(ILivoFactory.DeployerNotWhitelisted.selector);
        factoryV4Unified.previewTokenImplementation(
            _fs(creator), _noSs(), _taxCfg(0, 400, uint32(15 days)), _emptyAntiSniperCfg()
        );
    }

    function test_preview_returnsTaxImplForWhitelistedExtendedTax() public {
        vm.prank(admin);
        deployersWhitelist.setWhitelisted(creator, true);

        vm.prank(creator);
        address impl = factoryV4Unified.previewTokenImplementation(
            _fs(creator), _noSs(), _taxCfg(0, 400, uint32(15 days)), _emptyAntiSniperCfg()
        );

        assertEq(impl, address(livoTaxToken));
    }

    // ───────────── InvalidTokenAddress on tax dispatch path ─────────────

    function test_createToken_revertsOnInvalidTokenAddress_taxVariant() public {
        // Find a salt that does NOT yield a 0x1110-suffixed address for the tax impl.
        bytes32 badSalt;
        for (uint256 i = 0;; i++) {
            bytes32 s = bytes32(i);
            address predicted = Clones.predictDeterministicAddress(address(livoTaxToken), s, address(factoryV4Unified));
            if (uint16(uint160(predicted)) != 0x1110) {
                badSalt = s;
                break;
            }
        }

        vm.prank(creator);
        vm.expectRevert(ILivoFactory.InvalidTokenAddress.selector);
        factoryV4Unified.createToken(
            "T", "T", badSalt, _fs(creator), _noSs(), false, _taxCfg(0, 400, uint32(14 days)), _emptyAntiSniperCfg()
        );
    }
}

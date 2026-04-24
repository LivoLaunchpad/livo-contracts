// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LaunchpadBaseTestsWithUniv4GraduatorTaxableToken} from "test/launchpad/base.t.sol";
import {LivoTaxableTokenUniV4} from "src/tokens/LivoTaxableTokenUniV4.sol";
import {LivoFactoryExtendedTax} from "src/factories/LivoFactoryExtendedTax.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";

contract LivoFactoryExtendedTaxTest is LaunchpadBaseTestsWithUniv4GraduatorTaxableToken {
    LivoFactoryExtendedTax public factoryExtended;

    function setUp() public virtual override {
        super.setUp();

        vm.startPrank(admin);
        factoryExtended = new LivoFactoryExtendedTax(
            address(launchpad),
            address(livoTaxToken),
            address(bondingCurve),
            address(graduatorV4),
            address(feeHandler),
            address(FEE_SPLITTER_IMPLEMENTATION())
        );
        launchpad.whitelistFactory(address(factoryExtended));
        vm.stopPrank();
    }

    function FEE_SPLITTER_IMPLEMENTATION() internal view returns (address) {
        return address(factoryTax.FEE_SPLITTER_IMPLEMENTATION());
    }

    // ============ Access Control ============

    /// @dev when a non-owner calls createToken, it reverts with OwnableUnauthorizedAccount
    function test_createToken_revertsWhenCallerIsNotOwner() public {
        bytes32 salt = _nextValidSalt(address(factoryExtended), address(livoTaxToken));

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, creator));
        factoryExtended.createToken("TestToken", "TEST", salt, _fs(creator), _noSs(), _taxCfgExt(100, 100, uint32(30 days)));
    }

    /// @dev when the owner calls createToken with valid params, it succeeds
    function test_createToken_succeedsWhenCallerIsOwner() public {
        bytes32 salt = _nextValidSalt(address(factoryExtended), address(livoTaxToken));

        vm.prank(admin);
        (address token,) =
            factoryExtended.createToken("TestToken", "TEST", salt, _fs(admin), _noSs(), _taxCfgExt(1000, 1000, uint32(365 days)));

        assertTrue(token != address(0));
    }

    // ============ Tax Cap ============

    /// @dev when sellTaxBps exceeds MAX_TAX_BPS (1000 = 10%), createToken reverts with InvalidTaxBps
    function test_createToken_revertsOnTaxAboveTenPercent() public {
        bytes32 salt = _nextValidSalt(address(factoryExtended), address(livoTaxToken));

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(LivoFactoryExtendedTax.InvalidTaxBps.selector));
        factoryExtended.createToken("TestToken", "TEST", salt, _fs(admin), _noSs(), _taxCfgExt(0, 1001, uint32(14 days)));
    }

    /// @dev when sellTaxBps equals MAX_TAX_BPS (1000 = 10%), createToken succeeds
    function test_createToken_acceptsTaxAtExactlyTenPercent() public {
        bytes32 salt = _nextValidSalt(address(factoryExtended), address(livoTaxToken));

        vm.prank(admin);
        (address token,) =
            factoryExtended.createToken("TestToken", "TEST", salt, _fs(admin), _noSs(), _taxCfgExt(1000, 1000, uint32(14 days)));

        assertTrue(token != address(0));
        assertEq(LivoTaxableTokenUniV4(payable(token)).buyTaxBps(), 1000);
        assertEq(LivoTaxableTokenUniV4(payable(token)).sellTaxBps(), 1000);
    }

    // ============ Duration (no cap) ============

    /// @dev when taxDurationSeconds far exceeds the old 14-day ceiling, createToken succeeds
    ///      and the token stores the full duration (effectively "permanent" tax)
    function test_createToken_acceptsDurationBeyondFourteenDays() public {
        bytes32 salt = _nextValidSalt(address(factoryExtended), address(livoTaxToken));
        uint32 longDuration = type(uint32).max;

        vm.prank(admin);
        (address token,) =
            factoryExtended.createToken("TestToken", "TEST", salt, _fs(admin), _noSs(), _taxCfgExt(100, 100, longDuration));

        assertTrue(token != address(0));
        assertEq(LivoTaxableTokenUniV4(payable(token)).taxDurationSeconds(), uint40(longDuration));
    }
}

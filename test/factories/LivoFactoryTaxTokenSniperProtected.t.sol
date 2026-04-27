// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LaunchpadBaseTestsWithUniv4GraduatorTaxableToken} from "test/launchpad/base.t.sol";
import {LivoTaxableTokenUniV4SniperProtected} from "src/tokens/LivoTaxableTokenUniV4SniperProtected.sol";
import {LivoFactoryTaxTokenSniperProtected} from "src/factories/LivoFactoryTaxTokenSniperProtected.sol";
import {SniperProtection} from "src/tokens/SniperProtection.sol";
import {ILivoFactory} from "src/interfaces/ILivoFactory.sol";

contract LivoFactoryTaxTokenSniperProtectedTest is LaunchpadBaseTestsWithUniv4GraduatorTaxableToken {
    function _newSalt() internal returns (bytes32) {
        return _nextValidSalt(address(factoryTaxSniper), address(livoTaxTokenSniper));
    }

    function test_createToken_happyPath() public {
        vm.prank(creator);
        (address token,) = factoryTaxSniper.createToken(
            "TestToken",
            "TEST",
            _newSalt(),
            _fs(creator),
            _noSs(),
            false,
            _taxCfgSniper(100, 200, uint32(1 days)),
            _defaultAntiSniperCfg()
        );

        LivoTaxableTokenUniV4SniperProtected t = LivoTaxableTokenUniV4SniperProtected(payable(token));
        assertEq(t.name(), "TestToken");
        assertEq(t.symbol(), "TEST");
        assertEq(t.owner(), creator);
        assertEq(t.buyTaxBps(), 100);
        assertEq(t.sellTaxBps(), 200);
        assertEq(uint256(t.taxDurationSeconds()), 1 days);
        assertEq(t.maxBuyPerTxBps(), 300);
        assertEq(t.maxWalletBps(), 300);
        assertEq(uint256(t.protectionWindowSeconds()), 3 hours);
    }

    function test_createToken_customConfigsPropagated() public {
        address[] memory wl = new address[](1);
        wl[0] = alice;

        vm.prank(creator);
        (address token,) = factoryTaxSniper.createToken(
            "TestToken",
            "TEST",
            _newSalt(),
            _fs(creator),
            _noSs(),
            false,
            _taxCfgSniper(0, 400, uint32(14 days)),
            _antiSniperCfg(25, 100, 2 hours, wl)
        );

        LivoTaxableTokenUniV4SniperProtected t = LivoTaxableTokenUniV4SniperProtected(payable(token));
        assertEq(t.sellTaxBps(), 400);
        assertEq(t.maxBuyPerTxBps(), 25);
        assertEq(t.maxWalletBps(), 100);
        assertEq(uint256(t.protectionWindowSeconds()), 2 hours);
        assertTrue(t.sniperBypass(alice));
    }

    function test_createToken_revertsOnSellTaxAboveMax() public {
        vm.prank(creator);
        vm.expectRevert(LivoFactoryTaxTokenSniperProtected.InvalidTaxBps.selector);
        factoryTaxSniper.createToken(
            "TestToken",
            "TEST",
            _newSalt(),
            _fs(creator),
            _noSs(),
            false,
            _taxCfgSniper(0, 401, uint32(14 days)),
            _defaultAntiSniperCfg()
        );
    }

    function test_createToken_revertsOnTaxDurationAboveMax() public {
        vm.prank(creator);
        vm.expectRevert(LivoFactoryTaxTokenSniperProtected.InvalidTaxDuration.selector);
        factoryTaxSniper.createToken(
            "TestToken",
            "TEST",
            _newSalt(),
            _fs(creator),
            _noSs(),
            false,
            _taxCfgSniper(0, 400, uint32(14 days + 1)),
            _defaultAntiSniperCfg()
        );
    }

    function test_createToken_revertsOnAntiSniperBpsTooHigh() public {
        vm.prank(creator);
        vm.expectRevert(SniperProtection.MaxBuyPerTxBpsTooHigh.selector);
        factoryTaxSniper.createToken(
            "TestToken",
            "TEST",
            _newSalt(),
            _fs(creator),
            _noSs(),
            false,
            _taxCfgSniper(0, 400, uint32(1 days)),
            _antiSniperCfg(301, 300, 1 hours, new address[](0))
        );
    }

    function test_createToken_revertsOnEmptyName() public {
        vm.prank(creator);
        vm.expectRevert(ILivoFactory.InvalidNameOrSymbol.selector);
        factoryTaxSniper.createToken(
            "",
            "TEST",
            "0x12",
            _fs(creator),
            _noSs(),
            false,
            _taxCfgSniper(0, 400, uint32(1 days)),
            _defaultAntiSniperCfg()
        );
    }

    function test_createToken_withDeployerBuy_distributesCorrectly() public {
        uint256 ethIn = 0.05 ether;
        vm.prank(creator);
        (address token,) = factoryTaxSniper.createToken{value: ethIn}(
            "TestToken",
            "TEST",
            _newSalt(),
            _fs(creator),
            _ss(creator),
            false,
            _taxCfgSniper(100, 100, uint32(1 days)),
            _defaultAntiSniperCfg()
        );

        LivoTaxableTokenUniV4SniperProtected t = LivoTaxableTokenUniV4SniperProtected(payable(token));
        assertGt(t.balanceOf(creator), 0);
    }
}

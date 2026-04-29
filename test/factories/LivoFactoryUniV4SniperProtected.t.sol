// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LaunchpadBaseTestsWithUniv4Graduator} from "test/launchpad/base.t.sol";
import {LivoTokenSniperProtected} from "src/tokens/LivoTokenSniperProtected.sol";
import {SniperProtection, AntiSniperConfigs} from "src/tokens/SniperProtection.sol";
import {ILivoFactory} from "src/interfaces/ILivoFactory.sol";

contract LivoFactoryUniV4SniperProtectedTest is LaunchpadBaseTestsWithUniv4Graduator {
    function _newSalt() internal returns (bytes32) {
        return _nextValidSalt(address(factorySniper), address(livoTokenSniper));
    }

    function test_createToken_happyPath() public {
        vm.prank(creator);
        (address token,) = factorySniper.createToken(
            "TestToken", "TEST", _newSalt(), _fs(creator), _noSs(), false, _defaultAntiSniperCfg()
        );

        LivoTokenSniperProtected t = LivoTokenSniperProtected(token);
        assertEq(t.name(), "TestToken");
        assertEq(t.symbol(), "TEST");
        assertEq(t.owner(), creator);
        assertEq(t.launchTimestamp(), uint40(block.timestamp));
        assertEq(t.maxBuyPerTxBps(), 300);
        assertEq(t.maxWalletBps(), 300);
        assertEq(uint256(t.protectionWindowSeconds()), 3 hours);
    }

    function test_createToken_customConfigsPropagated() public {
        address[] memory wl = new address[](2);
        wl[0] = alice;
        wl[1] = bob;

        vm.prank(creator);
        (address token,) = factorySniper.createToken(
            "TestToken", "TEST", _newSalt(), _fs(creator), _noSs(), false, _antiSniperCfg(50, 100, 30 minutes, wl)
        );

        LivoTokenSniperProtected t = LivoTokenSniperProtected(token);
        assertEq(t.maxBuyPerTxBps(), 50);
        assertEq(t.maxWalletBps(), 100);
        assertEq(uint256(t.protectionWindowSeconds()), 30 minutes);
        assertTrue(t.sniperBypass(alice));
        assertTrue(t.sniperBypass(bob));
        assertFalse(t.sniperBypass(creator));
    }

    function test_createToken_revertsOnMaxBuyBpsTooLow() public {
        vm.prank(creator);
        vm.expectRevert(SniperProtection.MaxBuyPerTxBpsTooLow.selector);
        factorySniper.createToken(
            "TestToken",
            "TEST",
            _newSalt(),
            _fs(creator),
            _noSs(),
            false,
            _antiSniperCfg(9, 300, 1 hours, new address[](0))
        );
    }

    function test_createToken_revertsOnMaxBuyBpsTooHigh() public {
        vm.prank(creator);
        vm.expectRevert(SniperProtection.MaxBuyPerTxBpsTooHigh.selector);
        factorySniper.createToken(
            "TestToken",
            "TEST",
            _newSalt(),
            _fs(creator),
            _noSs(),
            false,
            _antiSniperCfg(301, 300, 1 hours, new address[](0))
        );
    }

    function test_createToken_revertsOnMaxWalletBpsTooLow() public {
        vm.prank(creator);
        vm.expectRevert(SniperProtection.MaxWalletBpsTooLow.selector);
        factorySniper.createToken(
            "TestToken",
            "TEST",
            _newSalt(),
            _fs(creator),
            _noSs(),
            false,
            _antiSniperCfg(300, 9, 1 hours, new address[](0))
        );
    }

    function test_createToken_revertsOnMaxWalletBpsTooHigh() public {
        vm.prank(creator);
        vm.expectRevert(SniperProtection.MaxWalletBpsTooHigh.selector);
        factorySniper.createToken(
            "TestToken",
            "TEST",
            _newSalt(),
            _fs(creator),
            _noSs(),
            false,
            _antiSniperCfg(300, 301, 1 hours, new address[](0))
        );
    }

    function test_createToken_revertsOnProtectionWindowTooShort() public {
        vm.prank(creator);
        vm.expectRevert(SniperProtection.ProtectionWindowTooShort.selector);
        factorySniper.createToken(
            "TestToken",
            "TEST",
            _newSalt(),
            _fs(creator),
            _noSs(),
            false,
            _antiSniperCfg(300, 300, 59 seconds, new address[](0))
        );
    }

    function test_createToken_revertsOnProtectionWindowTooLong() public {
        vm.prank(creator);
        vm.expectRevert(SniperProtection.ProtectionWindowTooLong.selector);
        factorySniper.createToken(
            "TestToken",
            "TEST",
            _newSalt(),
            _fs(creator),
            _noSs(),
            false,
            _antiSniperCfg(300, 300, 1 days + 1, new address[](0))
        );
    }

    function test_createToken_revertsOnEmptyName() public {
        vm.prank(creator);
        vm.expectRevert(ILivoFactory.InvalidNameOrSymbol.selector);
        factorySniper.createToken("", "TEST", "0x12", _fs(creator), _noSs(), false, _defaultAntiSniperCfg());
    }

    function test_createToken_withDeployerBuy_distributesCorrectly() public {
        uint256 ethIn = 0.05 ether;
        vm.prank(creator);
        (address token,) = factorySniper.createToken{value: ethIn}(
            "TestToken", "TEST", _newSalt(), _fs(creator), _ss(creator), false, _defaultAntiSniperCfg()
        );

        LivoTokenSniperProtected t = LivoTokenSniperProtected(token);
        // Creator received all bought tokens (single SupplyShare entry at 10_000 bps).
        assertGt(t.balanceOf(creator), 0);
    }
}

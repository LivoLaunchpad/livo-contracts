// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LaunchpadBaseTestsWithUniv2Graduator} from "test/launchpad/base.t.sol";
import {LivoTokenSniperProtected} from "src/tokens/LivoTokenSniperProtected.sol";
import {SniperProtection} from "src/tokens/SniperProtection.sol";
import {ILivoFactory} from "src/interfaces/ILivoFactory.sol";

contract LivoFactoryUniV2SniperProtectedTest is LaunchpadBaseTestsWithUniv2Graduator {
    function _newSalt() internal returns (bytes32) {
        return _nextValidSalt(address(factoryV2Sniper), address(livoTokenSniper));
    }

    function test_createToken_happyPath_ownerIsZero() public {
        vm.prank(creator);
        (address token,) =
            factoryV2Sniper.createToken("TestToken", "TEST", _newSalt(), _fs(creator), _noSs(), _defaultAntiSniperCfg());

        LivoTokenSniperProtected t = LivoTokenSniperProtected(token);
        assertEq(t.name(), "TestToken");
        assertEq(t.symbol(), "TEST");
        assertEq(t.owner(), address(0));
        assertEq(t.feeReceiver(), creator);
        assertEq(t.maxBuyPerTxBps(), 300);
    }

    function test_createToken_customConfigsPropagated() public {
        address[] memory wl = new address[](1);
        wl[0] = alice;

        vm.prank(creator);
        (address token,) = factoryV2Sniper.createToken(
            "TestToken", "TEST", _newSalt(), _fs(creator), _noSs(), _antiSniperCfg(50, 150, 45 minutes, wl)
        );

        LivoTokenSniperProtected t = LivoTokenSniperProtected(token);
        assertEq(t.maxBuyPerTxBps(), 50);
        assertEq(t.maxWalletBps(), 150);
        assertEq(uint256(t.protectionWindowSeconds()), 45 minutes);
        assertTrue(t.sniperBypass(alice));
    }

    function test_createToken_revertsOnAntiSniperBpsTooLow() public {
        vm.prank(creator);
        vm.expectRevert(SniperProtection.MaxBuyPerTxBpsTooLow.selector);
        factoryV2Sniper.createToken(
            "TestToken", "TEST", _newSalt(), _fs(creator), _noSs(), _antiSniperCfg(9, 300, 1 hours, new address[](0))
        );
    }

    function test_createToken_revertsOnEmptyFeeReceivers() public {
        vm.prank(creator);
        vm.expectRevert(ILivoFactory.InvalidFeeReceiver.selector);
        factoryV2Sniper.createToken("TestToken", "TEST", _newSalt(), _noFs(), _noSs(), _defaultAntiSniperCfg());
    }
}

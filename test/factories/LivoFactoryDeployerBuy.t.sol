// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {
    LaunchpadBaseTestsWithUniv2Graduator,
    LaunchpadBaseTestsWithUniv4GraduatorTaxableToken
} from "test/launchpad/base.t.sol";
import {LivoToken} from "src/tokens/LivoToken.sol";
import {LivoTaxableTokenUniV4} from "src/tokens/LivoTaxableTokenUniV4.sol";
import {TokenState} from "src/types/tokenData.sol";
import {ILivoFactory} from "src/interfaces/ILivoFactory.sol";
import {ILivoToken} from "src/interfaces/ILivoToken.sol";
import {LivoLaunchpad} from "src/LivoLaunchpad.sol";
import {LivoFactoryTaxToken} from "src/factories/LivoFactoryTaxToken.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";

contract LivoFactoryBaseDeployerBuyTest is LaunchpadBaseTestsWithUniv2Graduator {
    // ============ Happy Path ============

    /// @dev deployer buy with a single supply recipient defaults the bought supply to that recipient
    function test_createToken_deployerBuy() public {
        uint256 ethToSpend = 0.1 ether;
        bytes32 salt = _nextValidSalt(address(factoryV2), address(livoToken));

        vm.prank(creator);
        (address token,) =
            factoryV2.createToken{value: ethToSpend}("TestToken", "TEST", salt, _fs(creator), _ss(creator));

        uint256 creatorBalance = LivoToken(token).balanceOf(creator);
        assertGt(creatorBalance, 0);
        assertLe(creatorBalance, TOTAL_SUPPLY * 1_000 / 10_000); // <= 10%

        assertEq(LivoToken(token).balanceOf(address(factoryV2)), 0);

        TokenState memory state = launchpad.getTokenState(token);
        assertGt(state.ethCollected, 0);
        assertEq(state.releasedSupply, creatorBalance);
    }

    /// @dev createToken with msg.value=0 still works (supplyShares must be empty)
    function test_createToken_noEth_backwardCompatible() public {
        bytes32 salt = _nextValidSalt(address(factoryV2), address(livoToken));

        vm.prank(creator);
        (address token,) = factoryV2.createToken("TestToken", "TEST", salt, _fs(creator), _noSs());

        assertEq(LivoToken(token).balanceOf(creator), 0);
        assertEq(LivoToken(token).balanceOf(address(launchpad)), TOTAL_SUPPLY);
    }

    /// @dev splitting bought supply across two recipients distributes proportionally and leaves no dust in the factory
    function test_createToken_supplySplit_twoRecipients_balancesMatchShares() public {
        uint256 ethToSpend = 0.05 ether;
        bytes32 salt = _nextValidSalt(address(factoryV2), address(livoToken));

        ILivoFactory.SupplyShare[] memory ss = new ILivoFactory.SupplyShare[](2);
        ss[0] = ILivoFactory.SupplyShare({account: alice, shares: 3_000}); // 30%
        ss[1] = ILivoFactory.SupplyShare({account: bob, shares: 7_000}); // 70%

        vm.prank(creator);
        (address token,) = factoryV2.createToken{value: ethToSpend}("TestToken", "TEST", salt, _fs(creator), ss);

        uint256 aliceBal = LivoToken(token).balanceOf(alice);
        uint256 bobBal = LivoToken(token).balanceOf(bob);
        uint256 total = aliceBal + bobBal;

        // total equals the launchpad-released supply
        TokenState memory state = launchpad.getTokenState(token);
        assertEq(state.releasedSupply, total);
        // factory holds nothing
        assertEq(LivoToken(token).balanceOf(address(factoryV2)), 0);
        // ratio roughly matches 30/70 (last recipient absorbs dust)
        assertApproxEqRel(aliceBal, total * 3 / 10, 1e15); // within 0.1%
    }

    /// @dev rounding dust from integer division goes to the last recipient
    function test_createToken_supplySplit_dustGoesToLastRecipient() public {
        uint256 ethToSpend = 0.05 ether;
        bytes32 salt = _nextValidSalt(address(factoryV2), address(livoToken));

        ILivoFactory.SupplyShare[] memory ss = new ILivoFactory.SupplyShare[](3);
        ss[0] = ILivoFactory.SupplyShare({account: alice, shares: 3_333});
        ss[1] = ILivoFactory.SupplyShare({account: bob, shares: 3_333});
        ss[2] = ILivoFactory.SupplyShare({account: seller, shares: 3_334});

        vm.prank(creator);
        (address token,) = factoryV2.createToken{value: ethToSpend}("TestToken", "TEST", salt, _fs(creator), ss);

        uint256 aliceBal = LivoToken(token).balanceOf(alice);
        uint256 bobBal = LivoToken(token).balanceOf(bob);
        uint256 sellerBal = LivoToken(token).balanceOf(seller);

        // alice and bob get identical amounts (same shares), seller absorbs any remainder
        assertEq(aliceBal, bobBal);
        // seller's balance must equal the released supply minus the other two
        TokenState memory state = launchpad.getTokenState(token);
        assertEq(sellerBal, state.releasedSupply - aliceBal - bobBal);
        // factory holds no dust
        assertEq(LivoToken(token).balanceOf(address(factoryV2)), 0);
    }

    /// @dev cap applies to aggregate — a single recipient holding 100% shares can receive up to the full cap
    function test_createToken_capAppliesToAggregate_singleRecipientCanHitFullCap() public {
        uint256 maxTokens = TOTAL_SUPPLY * factoryV2.maxBuyOnDeployBps() / 10_000;
        uint256 totalEthNeeded = factoryV2.quoteBuyOnDeploy(maxTokens);
        bytes32 salt = _nextValidSalt(address(factoryV2), address(livoToken));

        vm.prank(creator);
        (address token,) =
            factoryV2.createToken{value: totalEthNeeded}("TestToken", "TEST", salt, _fs(creator), _ss(creator));

        assertGe(LivoToken(token).balanceOf(creator), maxTokens);
    }

    // ============ Supply-share validation ============

    /// @dev shares not summing to 10 000 revert with InvalidShares
    function test_createToken_supplySplit_revertsOnSharesNotSummingTo10000() public {
        bytes32 salt = _nextValidSalt(address(factoryV2), address(livoToken));
        ILivoFactory.SupplyShare[] memory ss = new ILivoFactory.SupplyShare[](2);
        ss[0] = ILivoFactory.SupplyShare({account: alice, shares: 3_000});
        ss[1] = ILivoFactory.SupplyShare({account: bob, shares: 6_000}); // sum = 9_000

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(ILivoFactory.InvalidShares.selector));
        factoryV2.createToken{value: 0.01 ether}("TestToken", "TEST", salt, _fs(creator), ss);
    }

    /// @dev a zero-share entry reverts with InvalidShares
    function test_createToken_supplySplit_revertsOnZeroShare() public {
        bytes32 salt = _nextValidSalt(address(factoryV2), address(livoToken));
        ILivoFactory.SupplyShare[] memory ss = new ILivoFactory.SupplyShare[](2);
        ss[0] = ILivoFactory.SupplyShare({account: alice, shares: 10_000});
        ss[1] = ILivoFactory.SupplyShare({account: bob, shares: 0});

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(ILivoFactory.InvalidShares.selector));
        factoryV2.createToken{value: 0.01 ether}("TestToken", "TEST", salt, _fs(creator), ss);
    }

    /// @dev a zero-address entry reverts with InvalidSupplyShares
    function test_createToken_supplySplit_revertsOnZeroAccount() public {
        bytes32 salt = _nextValidSalt(address(factoryV2), address(livoToken));
        ILivoFactory.SupplyShare[] memory ss = new ILivoFactory.SupplyShare[](1);
        ss[0] = ILivoFactory.SupplyShare({account: address(0), shares: 10_000});

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(ILivoFactory.InvalidSupplyShares.selector));
        factoryV2.createToken{value: 0.01 ether}("TestToken", "TEST", salt, _fs(creator), ss);
    }

    /// @dev duplicate recipients revert with InvalidSupplyShares
    function test_createToken_supplySplit_revertsOnDuplicateAccount() public {
        bytes32 salt = _nextValidSalt(address(factoryV2), address(livoToken));
        ILivoFactory.SupplyShare[] memory ss = new ILivoFactory.SupplyShare[](2);
        ss[0] = ILivoFactory.SupplyShare({account: alice, shares: 5_000});
        ss[1] = ILivoFactory.SupplyShare({account: alice, shares: 5_000});

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(ILivoFactory.InvalidSupplyShares.selector));
        factoryV2.createToken{value: 0.01 ether}("TestToken", "TEST", salt, _fs(creator), ss);
    }

    /// @dev passing supplyShares with msg.value == 0 is rejected
    function test_createToken_revertsOnSupplySharesProvidedWithoutMsgValue() public {
        bytes32 salt = _nextValidSalt(address(factoryV2), address(livoToken));

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(ILivoFactory.InvalidSupplyShares.selector));
        factoryV2.createToken("TestToken", "TEST", salt, _fs(creator), _ss(creator));
    }

    /// @dev sending msg.value without supplyShares is rejected
    function test_createToken_revertsOnMsgValueWithoutSupplyShares() public {
        bytes32 salt = _nextValidSalt(address(factoryV2), address(livoToken));

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(ILivoFactory.InvalidSupplyShares.selector));
        factoryV2.createToken{value: 0.01 ether}("TestToken", "TEST", salt, _fs(creator), _noSs());
    }

    // ============ Cap Enforcement ============

    /// @dev reverts when ETH would buy more than the aggregate cap (10%)
    function test_createToken_revertsWhenExceedingMaxBuy() public {
        // 1 ether should buy way more than 10% at the start of the curve
        bytes32 salt = _nextValidSalt(address(factoryV2), address(livoToken));

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(ILivoFactory.InvalidBuyOnDeploy.selector));
        factoryV2.createToken{value: 1 ether}("TestToken", "TEST", salt, _fs(creator), _ss(creator));
    }

    /// @dev cap is on aggregate — splitting doesn't bypass the cap
    function test_createToken_revertsWhenAggregateExceedsCap_evenWithSplit() public {
        bytes32 salt = _nextValidSalt(address(factoryV2), address(livoToken));
        ILivoFactory.SupplyShare[] memory ss = new ILivoFactory.SupplyShare[](2);
        ss[0] = ILivoFactory.SupplyShare({account: alice, shares: 5_000});
        ss[1] = ILivoFactory.SupplyShare({account: bob, shares: 5_000});

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(ILivoFactory.InvalidBuyOnDeploy.selector));
        factoryV2.createToken{value: 1 ether}("TestToken", "TEST", salt, _fs(creator), ss);
    }

    // ============ Events ============

    /// @dev BuyOnDeploy event is emitted with correct buyer
    function test_createToken_emitsBuyOnDeployEvent() public {
        uint256 ethToSpend = 0.05 ether;
        bytes32 salt = _nextValidSalt(address(factoryV2), address(livoToken));

        vm.prank(creator);
        vm.expectEmit(false, true, false, false);
        emit ILivoFactory.BuyOnDeploy(address(0), creator, 0, 0, new address[](0), new uint256[](0));
        factoryV2.createToken{value: ethToSpend}("TestToken", "TEST", salt, _fs(creator), _ss(creator));
    }

    // ============ Admin: setMaxBuyOnDeployBps ============

    /// @dev owner can update maxBuyOnDeployBps
    function test_setMaxBuyOnDeployBps() public {
        vm.prank(admin);
        factoryV2.setMaxBuyOnDeployBps(500); // 5%
        assertEq(factoryV2.maxBuyOnDeployBps(), 500);
    }

    /// @dev non-owner cannot update maxBuyOnDeployBps
    function test_setMaxBuyOnDeployBps_revertsForNonOwner() public {
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, creator));
        factoryV2.setMaxBuyOnDeployBps(500);
    }

    /// @dev setting maxBuyOnDeployBps to 0 disables buy-on-deploy
    function test_createToken_revertsWhenMaxBuyIsZero() public {
        vm.prank(admin);
        factoryV2.setMaxBuyOnDeployBps(0);

        bytes32 salt = _nextValidSalt(address(factoryV2), address(livoToken));

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(ILivoFactory.InvalidBuyOnDeploy.selector));
        factoryV2.createToken{value: 0.01 ether}("TestToken", "TEST", salt, _fs(creator), _ss(creator));
    }

    /// @dev MaxBuyOnDeployBpsUpdated event is emitted
    function test_setMaxBuyOnDeployBps_emitsEvent() public {
        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit ILivoFactory.MaxBuyOnDeployBpsUpdated(500);
        factoryV2.setMaxBuyOnDeployBps(500);
    }

    // ============ quoteBuyOnDeploy ============

    /// @dev quoteBuyOnDeploy returns correct ETH that yields exactly tokenAmount
    function test_quoteBuyOnDeploy_roundTrip() public {
        uint256 tokenAmount = 50_000_000e18; // 5% of supply
        uint256 totalEthNeeded = factoryV2.quoteBuyOnDeploy(tokenAmount);

        bytes32 salt = _nextValidSalt(address(factoryV2), address(livoToken));

        vm.prank(creator);
        (address token,) =
            factoryV2.createToken{value: totalEthNeeded}("TestToken", "TEST", salt, _fs(creator), _ss(creator));

        assertGe(LivoToken(token).balanceOf(creator), tokenAmount);
    }

    /// @dev quoteBuyOnDeploy at max allowed tokens does not revert on createToken
    function test_quoteBuyOnDeploy_maxAllowedTokens_doesNotRevert() public {
        uint256 maxTokens = TOTAL_SUPPLY * factoryV2.maxBuyOnDeployBps() / 10_000;
        uint256 totalEthNeeded = factoryV2.quoteBuyOnDeploy(maxTokens);

        bytes32 salt = _nextValidSalt(address(factoryV2), address(livoToken));

        vm.prank(creator);
        (address token,) =
            factoryV2.createToken{value: totalEthNeeded}("TestToken", "TEST", salt, _fs(creator), _ss(creator));

        assertGe(LivoToken(token).balanceOf(creator), maxTokens);
    }
}

contract LivoFactoryTaxTokenDeployerBuyTest is LaunchpadBaseTestsWithUniv4GraduatorTaxableToken {
    // ============ Happy Path ============

    /// @dev deployer can buy tokens with ETH during createToken
    function test_createToken_deployerBuy() public {
        uint256 ethToSpend = 0.1 ether;
        bytes32 salt = _nextValidSalt(address(factoryTax), address(livoTaxToken));

        vm.prank(creator);
        (address token,) = factoryTax.createToken{value: ethToSpend}(
            "TestToken", "TEST", salt, _fs(creator), _ss(creator), false, _taxCfg(0, 400, uint32(14 days))
        );

        uint256 creatorBalance = LivoTaxableTokenUniV4(payable(token)).balanceOf(creator);
        assertGt(creatorBalance, 0);
        assertLe(creatorBalance, TOTAL_SUPPLY * 1_000 / 10_000);
        assertEq(LivoTaxableTokenUniV4(payable(token)).balanceOf(address(factoryTax)), 0);
    }

    /// @dev createToken with msg.value=0 still works (supplyShares must be empty)
    function test_createToken_noEth_backwardCompatible() public {
        bytes32 salt = _nextValidSalt(address(factoryTax), address(livoTaxToken));

        vm.prank(creator);
        (address token,) = factoryTax.createToken(
            "TestToken", "TEST", salt, _fs(creator), _noSs(), false, _taxCfg(0, 400, uint32(14 days))
        );

        assertEq(LivoTaxableTokenUniV4(payable(token)).balanceOf(creator), 0);
    }

    // ============ Cap Enforcement ============

    /// @dev reverts when ETH would buy more than 10% of supply
    function test_createToken_revertsWhenExceedingMaxBuy() public {
        bytes32 salt = _nextValidSalt(address(factoryTax), address(livoTaxToken));

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(ILivoFactory.InvalidBuyOnDeploy.selector));
        factoryTax.createToken{value: 1 ether}(
            "TestToken", "TEST", salt, _fs(creator), _ss(creator), false, _taxCfg(0, 400, uint32(14 days))
        );
    }

    // ============ Admin: setMaxBuyOnDeployBps ============

    /// @dev owner can update maxBuyOnDeployBps
    function test_setMaxBuyOnDeployBps() public {
        vm.prank(admin);
        factoryTax.setMaxBuyOnDeployBps(500);
        assertEq(factoryTax.maxBuyOnDeployBps(), 500);
    }

    /// @dev non-owner cannot update maxBuyOnDeployBps
    function test_setMaxBuyOnDeployBps_revertsForNonOwner() public {
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, creator));
        factoryTax.setMaxBuyOnDeployBps(500);
    }

    // ============ quoteBuyOnDeploy ============

    /// @dev quoteBuyOnDeploy returns correct ETH that yields exactly tokenAmount
    function test_quoteBuyOnDeploy_roundTrip() public {
        uint256 tokenAmount = 50_000_000e18; // 5% of supply
        uint256 totalEthNeeded = factoryTax.quoteBuyOnDeploy(tokenAmount);

        bytes32 salt = _nextValidSalt(address(factoryTax), address(livoTaxToken));

        vm.prank(creator);
        (address token,) = factoryTax.createToken{value: totalEthNeeded}(
            "TestToken", "TEST", salt, _fs(creator), _ss(creator), false, _taxCfg(0, 400, uint32(14 days))
        );

        assertGe(LivoTaxableTokenUniV4(payable(token)).balanceOf(creator), tokenAmount);
    }

    /// @dev quoteBuyOnDeploy at max allowed tokens does not revert on createToken
    function test_quoteBuyOnDeploy_maxAllowedTokens_doesNotRevert() public {
        uint256 maxTokens = TOTAL_SUPPLY * factoryTax.maxBuyOnDeployBps() / 10_000;
        uint256 totalEthNeeded = factoryTax.quoteBuyOnDeploy(maxTokens);

        bytes32 salt = _nextValidSalt(address(factoryTax), address(livoTaxToken));

        vm.prank(creator);
        (address token,) = factoryTax.createToken{value: totalEthNeeded}(
            "TestToken", "TEST", salt, _fs(creator), _ss(creator), false, _taxCfg(0, 400, uint32(14 days))
        );

        assertGe(LivoTaxableTokenUniV4(payable(token)).balanceOf(creator), maxTokens);
    }

    // ============ Single-recipient fee (no splitter) ============

    /// @dev single fee receiver does NOT deploy a FeeSplitter
    function test_createToken_singleFeeReceiver_noSplitterDeployed() public {
        bytes32 salt = _nextValidSalt(address(factoryTax), address(livoTaxToken));

        vm.prank(creator);
        (, address feeSplitter) = factoryTax.createToken(
            "TestToken", "TEST", salt, _fs(creator), _noSs(), false, _taxCfg(0, 400, uint32(14 days))
        );

        assertEq(feeSplitter, address(0));
    }

    /// @dev multi-recipient fee deploys a FeeSplitter
    function test_createToken_twoFeeReceivers_deploysSplitter() public {
        bytes32 salt = _nextValidSalt(address(factoryTax), address(livoTaxToken));

        ILivoFactory.FeeShare[] memory fs = new ILivoFactory.FeeShare[](2);
        fs[0] = ILivoFactory.FeeShare({account: alice, shares: 4_000});
        fs[1] = ILivoFactory.FeeShare({account: bob, shares: 6_000});

        vm.prank(creator);
        (, address feeSplitter) =
            factoryTax.createToken("TestToken", "TEST", salt, fs, _noSs(), false, _taxCfg(0, 400, uint32(14 days)));

        assertTrue(feeSplitter != address(0));
    }
}

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
import {LivoFactoryUniV4Unified} from "src/factories/LivoFactoryUniV4Unified.sol";

contract LivoFactoryUniV4DeployerBuyTest is LaunchpadBaseTestsWithUniv2Graduator {
    // ============ Happy Path ============

    /// @dev deployer buy with a single supply recipient defaults the bought supply to that recipient
    function test_createToken_deployerBuy() public {
        uint256 ethToSpend = 0.1 ether;
        bytes32 salt = _nextValidSalt(address(factoryV2), address(livoToken));

        vm.prank(creator);
        address token = factoryV2.createToken{value: ethToSpend}(
            "TestToken", "TEST", salt, _fs(creator), _ss(creator), _emptyTaxCfg(), _emptyAntiSniperCfg()
        );

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
        address token = factoryV2.createToken(
            "TestToken", "TEST", salt, _fs(creator), _noSs(), _emptyTaxCfg(), _emptyAntiSniperCfg()
        );

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
        address token = factoryV2.createToken{value: ethToSpend}(
            "TestToken", "TEST", salt, _fs(creator), ss, _emptyTaxCfg(), _emptyAntiSniperCfg()
        );

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
        address token = factoryV2.createToken{value: ethToSpend}(
            "TestToken", "TEST", salt, _fs(creator), ss, _emptyTaxCfg(), _emptyAntiSniperCfg()
        );

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
        uint256 totalEthNeeded = factoryV2.quoteBuyOnDeploy(maxTokens, 0, _emptyTaxCfg());
        bytes32 salt = _nextValidSalt(address(factoryV2), address(livoToken));

        vm.prank(creator);
        address token = factoryV2.createToken{value: totalEthNeeded}(
            "TestToken", "TEST", salt, _fs(creator), _ss(creator), _emptyTaxCfg(), _emptyAntiSniperCfg()
        );

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
        factoryV2.createToken{value: 0.01 ether}(
            "TestToken", "TEST", salt, _fs(creator), ss, _emptyTaxCfg(), _emptyAntiSniperCfg()
        );
    }

    /// @dev a zero-share entry reverts with InvalidShares
    function test_createToken_supplySplit_revertsOnZeroShare() public {
        bytes32 salt = _nextValidSalt(address(factoryV2), address(livoToken));
        ILivoFactory.SupplyShare[] memory ss = new ILivoFactory.SupplyShare[](2);
        ss[0] = ILivoFactory.SupplyShare({account: alice, shares: 10_000});
        ss[1] = ILivoFactory.SupplyShare({account: bob, shares: 0});

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(ILivoFactory.InvalidShares.selector));
        factoryV2.createToken{value: 0.01 ether}(
            "TestToken", "TEST", salt, _fs(creator), ss, _emptyTaxCfg(), _emptyAntiSniperCfg()
        );
    }

    /// @dev a zero-address entry reverts with InvalidSupplyShares
    function test_createToken_supplySplit_revertsOnZeroAccount() public {
        bytes32 salt = _nextValidSalt(address(factoryV2), address(livoToken));
        ILivoFactory.SupplyShare[] memory ss = new ILivoFactory.SupplyShare[](1);
        ss[0] = ILivoFactory.SupplyShare({account: address(0), shares: 10_000});

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(ILivoFactory.InvalidSupplyShares.selector));
        factoryV2.createToken{value: 0.01 ether}(
            "TestToken", "TEST", salt, _fs(creator), ss, _emptyTaxCfg(), _emptyAntiSniperCfg()
        );
    }

    /// @dev duplicate recipients revert with InvalidSupplyShares
    function test_createToken_supplySplit_revertsOnDuplicateAccount() public {
        bytes32 salt = _nextValidSalt(address(factoryV2), address(livoToken));
        ILivoFactory.SupplyShare[] memory ss = new ILivoFactory.SupplyShare[](2);
        ss[0] = ILivoFactory.SupplyShare({account: alice, shares: 5_000});
        ss[1] = ILivoFactory.SupplyShare({account: alice, shares: 5_000});

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(ILivoFactory.InvalidSupplyShares.selector));
        factoryV2.createToken{value: 0.01 ether}(
            "TestToken", "TEST", salt, _fs(creator), ss, _emptyTaxCfg(), _emptyAntiSniperCfg()
        );
    }

    /// @dev passing supplyShares with msg.value == 0 is rejected
    function test_createToken_revertsOnSupplySharesProvidedWithoutMsgValue() public {
        bytes32 salt = _nextValidSalt(address(factoryV2), address(livoToken));

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(ILivoFactory.InvalidSupplyShares.selector));
        factoryV2.createToken(
            "TestToken", "TEST", salt, _fs(creator), _ss(creator), _emptyTaxCfg(), _emptyAntiSniperCfg()
        );
    }

    /// @dev sending msg.value without supplyShares is rejected
    function test_createToken_revertsOnMsgValueWithoutSupplyShares() public {
        bytes32 salt = _nextValidSalt(address(factoryV2), address(livoToken));

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(ILivoFactory.InvalidSupplyShares.selector));
        factoryV2.createToken{value: 0.01 ether}(
            "TestToken", "TEST", salt, _fs(creator), _noSs(), _emptyTaxCfg(), _emptyAntiSniperCfg()
        );
    }

    // ============ Cap Enforcement ============

    /// @dev reverts when ETH would buy more than the aggregate cap (10%)
    function test_createToken_revertsWhenExceedingMaxBuy() public {
        // 1 ether should buy way more than 10% at the start of the curve
        bytes32 salt = _nextValidSalt(address(factoryV2), address(livoToken));

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(ILivoFactory.InvalidBuyOnDeploy.selector));
        factoryV2.createToken{value: 1 ether}(
            "TestToken", "TEST", salt, _fs(creator), _ss(creator), _emptyTaxCfg(), _emptyAntiSniperCfg()
        );
    }

    /// @dev cap is on aggregate — splitting doesn't bypass the cap
    function test_createToken_revertsWhenAggregateExceedsCap_evenWithSplit() public {
        bytes32 salt = _nextValidSalt(address(factoryV2), address(livoToken));
        ILivoFactory.SupplyShare[] memory ss = new ILivoFactory.SupplyShare[](2);
        ss[0] = ILivoFactory.SupplyShare({account: alice, shares: 5_000});
        ss[1] = ILivoFactory.SupplyShare({account: bob, shares: 5_000});

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(ILivoFactory.InvalidBuyOnDeploy.selector));
        factoryV2.createToken{value: 1 ether}(
            "TestToken", "TEST", salt, _fs(creator), ss, _emptyTaxCfg(), _emptyAntiSniperCfg()
        );
    }

    // ============ Events ============

    /// @dev BuyOnDeploy event is emitted with correct buyer
    function test_createToken_emitsBuyOnDeployEvent() public {
        uint256 ethToSpend = 0.05 ether;
        bytes32 salt = _nextValidSalt(address(factoryV2), address(livoToken));

        vm.prank(creator);
        vm.expectEmit(false, true, false, false);
        emit ILivoFactory.BuyOnDeploy(address(0), creator, 0, 0, new address[](0), new uint256[](0));
        factoryV2.createToken{value: ethToSpend}(
            "TestToken", "TEST", salt, _fs(creator), _ss(creator), _emptyTaxCfg(), _emptyAntiSniperCfg()
        );
    }

    // ============ quoteBuyOnDeploy ============

    /// @dev quoteBuyOnDeploy returns correct ETH that yields exactly tokenAmount
    function test_quoteBuyOnDeploy_roundTrip() public {
        uint256 tokenAmount = 50_000_000e18; // 5% of supply
        uint256 totalEthNeeded = factoryV2.quoteBuyOnDeploy(tokenAmount, 0, _emptyTaxCfg());

        bytes32 salt = _nextValidSalt(address(factoryV2), address(livoToken));

        vm.prank(creator);
        address token = factoryV2.createToken{value: totalEthNeeded}(
            "TestToken", "TEST", salt, _fs(creator), _ss(creator), _emptyTaxCfg(), _emptyAntiSniperCfg()
        );

        uint256 creatorBalance = LivoToken(token).balanceOf(creator);
        assertGe(creatorBalance, tokenAmount);
        assertApproxEqRel(creatorBalance, tokenAmount, 0.005e18); // quote is tight: deployer doesn't materially overpay
    }

    /// @dev quoteBuyOnDeploy at max allowed tokens does not revert on createToken
    function test_quoteBuyOnDeploy_maxAllowedTokens_doesNotRevert() public {
        uint256 maxTokens = TOTAL_SUPPLY * factoryV2.maxBuyOnDeployBps() / 10_000;
        uint256 totalEthNeeded = factoryV2.quoteBuyOnDeploy(maxTokens, 0, _emptyTaxCfg());

        bytes32 salt = _nextValidSalt(address(factoryV2), address(livoToken));

        vm.prank(creator);
        address token = factoryV2.createToken{value: totalEthNeeded}(
            "TestToken", "TEST", salt, _fs(creator), _ss(creator), _emptyTaxCfg(), _emptyAntiSniperCfg()
        );

        assertGe(LivoToken(token).balanceOf(creator), maxTokens);
    }

    /// @dev With a graduation-anchored tax window (`startTaxFromLaunch == false`) the deploy buy pays
    ///      no tax — the window hasn't opened — so the quote must exclude `buyTaxBps`. A quote that
    ///      includes it over-estimates the ETH and the exact-ETH-in deploy buy overshoots the quoted
    ///      token amount.
    function test_quoteBuyOnDeploy_graduationAnchoredTax_quoteIsTight() public {
        uint256 tokenAmount = 30_000_000e18; // 3% of supply, under the 10% cap
        uint256 totalEthNeeded = factoryV2.quoteBuyOnDeploy(tokenAmount, 0, _taxCfg(400, 0, uint32(14 days), false));

        bytes32 salt = _nextValidSalt(address(factoryV2), address(livoTaxTokenV2));

        vm.prank(creator);
        address token = factoryV2.createToken{value: totalEthNeeded}(
            "TestToken",
            "TEST",
            salt,
            _fs(creator),
            _ss(creator),
            _taxCfg(400, 0, uint32(14 days), false),
            _emptyAntiSniperCfg()
        );

        uint256 creatorBalance = LivoToken(token).balanceOf(creator);
        assertGe(creatorBalance, tokenAmount);
        assertApproxEqRel(creatorBalance, tokenAmount, 0.005e18); // within 0.5% of the quote
    }
}

contract LivoFactoryTaxTokenDeployerBuyTest is LaunchpadBaseTestsWithUniv4GraduatorTaxableToken {
    /// @dev The V4 config these tests deploy with: 100-bps hook LP fee, ownership retained. The
    ///      positional `createToken` overload they use hardcodes the same 100-bps fee, so passing this
    ///      to `quoteBuyOnDeploy` matches the token's actual buy fee.
    function _univ4Cfg100() internal pure returns (LivoFactoryUniV4Unified.UniV4Configs memory) {
        return LivoFactoryUniV4Unified.UniV4Configs({renounceOwnership: false, lpFeeBps: 100});
    }

    // ============ Happy Path ============

    /// @dev deployer can buy tokens with ETH during createToken
    function test_createToken_deployerBuy() public {
        uint256 ethToSpend = 0.1 ether;
        bytes32 salt = _nextValidSalt(address(factoryTax), address(livoTaxToken));

        vm.prank(creator);
        address token = factoryTax.createToken{value: ethToSpend}(
            "TestToken",
            "TEST",
            salt,
            _fs(creator),
            _ss(creator),
            false,
            _taxCfg(0, 400, uint32(14 days)),
            _emptyAntiSniperCfg()
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
        address token = factoryTax.createToken(
            "TestToken",
            "TEST",
            salt,
            _fs(creator),
            _noSs(),
            false,
            _taxCfg(0, 400, uint32(14 days)),
            _emptyAntiSniperCfg()
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
            "TestToken",
            "TEST",
            salt,
            _fs(creator),
            _ss(creator),
            false,
            _taxCfg(0, 400, uint32(14 days)),
            _emptyAntiSniperCfg()
        );
    }

    // ============ quoteBuyOnDeploy ============

    /// @dev quoteBuyOnDeploy returns correct ETH that yields exactly tokenAmount
    function test_quoteBuyOnDeploy_roundTrip() public {
        uint256 tokenAmount = 50_000_000e18; // 5% of supply
        uint256 totalEthNeeded =
            factoryTax.quoteBuyOnDeploy(tokenAmount, 0, _taxCfg(0, 400, uint32(14 days)), _univ4Cfg100());

        bytes32 salt = _nextValidSalt(address(factoryTax), address(livoTaxToken));

        vm.prank(creator);
        address token = factoryTax.createToken{value: totalEthNeeded}(
            "TestToken",
            "TEST",
            salt,
            _fs(creator),
            _ss(creator),
            false,
            _taxCfg(0, 400, uint32(14 days)),
            _emptyAntiSniperCfg()
        );

        uint256 creatorBalance = LivoTaxableTokenUniV4(payable(token)).balanceOf(creator);
        assertGe(creatorBalance, tokenAmount);
        assertApproxEqRel(creatorBalance, tokenAmount, 0.005e18); // quote is tight: deployer doesn't materially overpay
    }

    /// @dev With a non-zero BUY tax the deploy-buy fee is LP + buy tax, so the quote must be told that
    ///      full fee. Exercises that `buyFeeBps` is threaded into `quoteBuyOnDeploy` — the old
    ///      hardcoded-100 quote under-quoted here and the deployer would receive fewer than `tokenAmount`.
    function test_quoteBuyOnDeploy_roundTrip_withBuyTax() public {
        uint256 tokenAmount = 30_000_000e18; // 3% of supply, under the 10% cap
        uint16 buyTax = 300; // 3%; with the 100 bps V4 LP fee the deploy-buy fee is 400 bps
        uint256 totalEthNeeded =
            factoryTax.quoteBuyOnDeploy(tokenAmount, 0, _taxCfg(buyTax, 0, uint32(14 days)), _univ4Cfg100());

        bytes32 salt = _nextValidSalt(address(factoryTax), address(livoTaxToken));

        vm.prank(creator);
        address token = factoryTax.createToken{value: totalEthNeeded}(
            "TestToken",
            "TEST",
            salt,
            _fs(creator),
            _ss(creator),
            false,
            _taxCfg(buyTax, 0, uint32(14 days)),
            _emptyAntiSniperCfg()
        );

        uint256 creatorBalance = LivoTaxableTokenUniV4(payable(token)).balanceOf(creator);
        assertGe(creatorBalance, tokenAmount);
        assertApproxEqRel(creatorBalance, tokenAmount, 0.005e18); // quote is tight: deployer doesn't materially overpay
    }

    /// @dev quoteBuyOnDeploy at max allowed tokens does not revert on createToken
    function test_quoteBuyOnDeploy_maxAllowedTokens_doesNotRevert() public {
        uint256 maxTokens = TOTAL_SUPPLY * factoryTax.maxBuyOnDeployBps() / 10_000;
        uint256 totalEthNeeded =
            factoryTax.quoteBuyOnDeploy(maxTokens, 0, _taxCfg(0, 400, uint32(14 days)), _univ4Cfg100());

        bytes32 salt = _nextValidSalt(address(factoryTax), address(livoTaxToken));

        vm.prank(creator);
        address token = factoryTax.createToken{value: totalEthNeeded}(
            "TestToken",
            "TEST",
            salt,
            _fs(creator),
            _ss(creator),
            false,
            _taxCfg(0, 400, uint32(14 days)),
            _emptyAntiSniperCfg()
        );

        assertGe(LivoTaxableTokenUniV4(payable(token)).balanceOf(creator), maxTokens);
    }

    /// @dev With a graduation-anchored tax window (`startTaxFromLaunch == false`) the deploy buy pays
    ///      no tax — the window hasn't opened — so the quote must exclude `buyTaxBps`. A quote that
    ///      includes it over-estimates the ETH and the exact-ETH-in deploy buy overshoots the quoted
    ///      token amount.
    function test_quoteBuyOnDeploy_graduationAnchoredTax_quoteIsTight() public {
        uint256 tokenAmount = 30_000_000e18; // 3% of supply, under the 10% cap
        uint16 buyTax = 400;
        uint256 totalEthNeeded =
            factoryTax.quoteBuyOnDeploy(tokenAmount, 0, _taxCfg(buyTax, 0, uint32(14 days), false), _univ4Cfg100());

        bytes32 salt = _nextValidSalt(address(factoryTax), address(livoTaxToken));

        vm.prank(creator);
        address token = factoryTax.createToken{value: totalEthNeeded}(
            "TestToken",
            "TEST",
            salt,
            _fs(creator),
            _ss(creator),
            false,
            _taxCfg(buyTax, 0, uint32(14 days), false),
            _emptyAntiSniperCfg()
        );

        uint256 creatorBalance = LivoTaxableTokenUniV4(payable(token)).balanceOf(creator);
        assertGe(creatorBalance, tokenAmount);
        assertApproxEqRel(creatorBalance, tokenAmount, 0.005e18); // within 0.5% of the quote
    }

    /// @dev The user-facing harm of an inflated quote: at the `maxBuyOnDeployBps` limit, the extra
    ///      ETH from wrongly including a graduation-anchored `buyTaxBps` buys more than the cap and
    ///      `createToken` reverts with InvalidBuyOnDeploy.
    function test_quoteBuyOnDeploy_graduationAnchoredTax_maxAllowedTokens_doesNotRevert() public {
        uint256 maxTokens = TOTAL_SUPPLY * factoryTax.maxBuyOnDeployBps() / 10_000;
        uint16 buyTax = 400;
        uint256 totalEthNeeded =
            factoryTax.quoteBuyOnDeploy(maxTokens, 0, _taxCfg(buyTax, 0, uint32(14 days), false), _univ4Cfg100());

        bytes32 salt = _nextValidSalt(address(factoryTax), address(livoTaxToken));

        vm.prank(creator);
        address token = factoryTax.createToken{value: totalEthNeeded}(
            "TestToken",
            "TEST",
            salt,
            _fs(creator),
            _ss(creator),
            false,
            _taxCfg(buyTax, 0, uint32(14 days), false),
            _emptyAntiSniperCfg()
        );

        assertGe(LivoTaxableTokenUniV4(payable(token)).balanceOf(creator), maxTokens);
    }
}

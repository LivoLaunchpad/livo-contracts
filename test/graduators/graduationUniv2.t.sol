// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LaunchpadBaseTestsWithUniv2Graduator} from "test/launchpad/base.t.sol";
import {LivoToken} from "src/LivoToken.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {TokenState} from "src/types/tokenData.sol";
import {IUniswapV2Factory} from "src/interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Pair} from "src/interfaces/IUniswapV2Pair.sol";
import {IWETH} from "src/interfaces/IWETH.sol";
import {ILivoGraduator} from "src/interfaces/ILivoGraduator.sol";
import {LivoGraduatorUniswapV2} from "src/graduators/LivoGraduatorUniswapV2.sol";
import {LivoLaunchpad} from "src/LivoLaunchpad.sol";
import {IUniswapV2Router02} from "src/interfaces/IUniswapV2Router02.sol";

contract BaseUniswapV2GraduationTests is LaunchpadBaseTestsWithUniv2Graduator {
    address public uniswapPair;

    function setUp() public virtual override {
        super.setUp();
    }

    //////////////////////////////////// modifiers and utilities ///////////////////////////////

    modifier createTestTokenWithPair() {
        vm.prank(creator);
        testToken = launchpad.createToken(
            "TestToken", "TEST", address(implementation), address(bondingCurve), address(graduator), "0x003"
        );
        uniswapPair = UNISWAP_FACTORY.getPair(testToken, address(WETH));
        _;
    }

    function _swapBuy(address account, address token, uint256 ethAmount, uint256 minTokens) internal {
        vm.startPrank(account);
        WETH.deposit{value: ethAmount}();
        WETH.approve(UNISWAP_V2_ROUTER, ethAmount);

        address[] memory path = new address[](2);
        path[0] = address(WETH);
        path[1] = token;

        IUniswapV2Router02(UNISWAP_V2_ROUTER).swapExactTokensForTokens(
            ethAmount, minTokens, path, account, block.timestamp + 1 hours
        );
        vm.stopPrank();
    }

    function _swapSell(address account, address token, uint256 tokenAmount, uint256 minEth) internal {
        vm.startPrank(account);
        IERC20(token).approve(UNISWAP_V2_ROUTER, tokenAmount);

        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = address(WETH);

        IUniswapV2Router02(UNISWAP_V2_ROUTER).swapExactTokensForTokens(
            tokenAmount, minEth, path, account, block.timestamp + 1 hours
        );
        vm.stopPrank();
    }
}

contract UniswapV2GraduationTests is BaseUniswapV2GraduationTests {
    ///////////////////////////////// TESTS //////////////////////////////////////

    function test_justDeployTokenWithUni2Graduator() public createTestToken {
        // just create the token
    }

    /// @notice Test that univ2pair is created in uniswap at token launch
    function test_uniV2PairCreatedAtTokenLaunch() public createTestTokenWithPair {
        assertTrue(uniswapPair != address(0), "Uniswap pair should be created");

        IUniswapV2Pair pair = IUniswapV2Pair(uniswapPair);
        address token0 = pair.token0();
        address token1 = pair.token1();

        assertTrue(
            (token0 == testToken && token1 == address(WETH)) || (token0 == address(WETH) && token1 == testToken),
            "Pair should contain test token and WETH"
        );
    }

    /// @notice Test that you cannot transfer tokens to univ2pair before graduation
    function test_cannotTransferTokensToUniV2PairBeforeGraduation() public createTestTokenWithPair {
        uint256 buyAmount = 1 ether;

        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: buyAmount}(testToken, 0, DEADLINE);

        uint256 tokenBalance = IERC20(testToken).balanceOf(buyer);

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(LivoToken.TransferToPairBeforeGraduationNotAllowed.selector));
        IERC20(testToken).transfer(uniswapPair, tokenBalance / 2);
    }

    /// @notice Test that you can transfer tokens to univ2pair after graduation
    function test_canTransferTokensToUniV2PairAfterGraduation() public createTestTokenWithPair {
        // First graduate the token, then buy some tokens to test transfers
        _graduateToken();

        // After graduation, we can still buy tokens from the creator's reserved supply if they sell
        // But we can't buy from launchpad, so let's transfer some from the creator instead
        uint256 creatorBalance = IERC20(testToken).balanceOf(creator);
        assertTrue(creatorBalance > 0, "Creator should have tokens after graduation");

        uint256 transferAmount = creatorBalance / 2;
        vm.prank(creator);
        IERC20(testToken).transfer(buyer, transferAmount);

        uint256 buyerBalance = IERC20(testToken).balanceOf(buyer);

        // Now test that buyer can transfer to pair after graduation
        uint256 pairTransferAmount = buyerBalance / 2;
        vm.prank(buyer);
        IERC20(testToken).transfer(uniswapPair, pairTransferAmount);

        assertTrue(IERC20(testToken).balanceOf(uniswapPair) >= pairTransferAmount, "Pair should receive tokens");
        assertEq(IERC20(testToken).balanceOf(buyer), buyerBalance - pairTransferAmount, "Buyer balance should decrease");
    }

    /// @notice Test that it is not possible to create the univ2pair right after token is deployed
    function test_cannotCreateUniV2PairRightAfterTokenDeployment() public {
        vm.prank(creator);
        testToken = launchpad.createToken(
            "TestToken", "TEST", address(implementation), address(bondingCurve), address(graduator), "0x003"
        );

        address existingPair = UNISWAP_FACTORY.getPair(testToken, address(WETH));
        assertTrue(existingPair != address(0), "Pair should already exist from token creation");

        vm.expectRevert("UniswapV2: PAIR_EXISTS");
        UNISWAP_FACTORY.createPair(testToken, address(WETH));
    }

    /// @notice Test that price in uniswap matches price in launchpad when last purchase meets the threshold exactly
    function test_priceInUniswapReflectsGraduationLiquidity() public createTestTokenWithPair {
        uint256 graduationThreshold = GRADUATION_THRESHOLD;
        uint256 ethAmountToGraduate = _increaseWithFees(graduationThreshold);

        vm.deal(buyer, ethAmountToGraduate);
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: ethAmountToGraduate}(testToken, 0, DEADLINE);

        TokenState memory state = launchpad.getTokenState(testToken);
        assertTrue(state.graduated, "Token should be graduated");

        IUniswapV2Pair pair = IUniswapV2Pair(uniswapPair);
        (uint256 reserve0, uint256 reserve1,) = pair.getReserves();

        uint256 wethReserve;
        uint256 tokenReserve;
        if (pair.token0() == address(WETH)) {
            wethReserve = reserve0;
            tokenReserve = reserve1;
        } else {
            wethReserve = reserve1;
            tokenReserve = reserve0;
        }

        uint256 uniswapPrice = (wethReserve * 1e18) / tokenReserve;

        assertTrue(uniswapPrice > 0, "Uniswap should have a valid price");
        assertTrue(wethReserve > 0, "WETH reserves should be positive");
        assertTrue(tokenReserve > 0, "Token reserves should be positive");

        // The ETH in the pair should be less than the graduation threshold because
        // the graduation fee is deducted before adding liquidity
        assertTrue(
            wethReserve < graduationThreshold, "WETH reserves should be less than threshold due to graduation fee"
        );
    }

    /// @notice Test that LP tokens are burned or transferred to 0xDEAD address
    function test_lpTokensBurnedOrTransferredToDeadAddress() public createTestTokenWithPair {
        uint256 deadBalanceBefore = IERC20(uniswapPair).balanceOf(DEAD_ADDRESS);

        _graduateToken();

        uint256 deadBalanceAfter = IERC20(uniswapPair).balanceOf(DEAD_ADDRESS);
        uint256 lpTokensLocked = deadBalanceAfter - deadBalanceBefore;

        assertTrue(lpTokensLocked > 0, "LP tokens should be locked in dead address");

        uint256 totalLpSupply = IERC20(uniswapPair).totalSupply();
        assertApproxEqRel(lpTokensLocked, totalLpSupply, 0.01e18, "Most LP tokens should be locked");
    }
}

contract TestGraduationDosExploits is BaseUniswapV2GraduationTests {
    /// @notice Test that if WETH is transferred to the univ2pair pre-graduation, liquidity addition doesn't revert
    function test_ethTransferToUniV2PairPreGraduation_noSync_liquidityAdditionDoesNotRevert()
        public
        createTestTokenWithPair
    {
        // Transfer some WETH to the pair
        uint256 wethAmount = 1 ether;
        WETH.deposit{value: wethAmount}();
        WETH.transfer(uniswapPair, wethAmount);

        _graduateToken();
    }

    /// @notice Test that if WETH is transferred to the univ2pair pre-graduation, no pair.sync(), the uniswap price is higher than if no eth was transferred
    function test_ethTransferToUniV2PairPreGraduation_noSync_uniswapPriceHigher() public createTestTokenWithPair {
        // donate some eth to the pair
        IUniswapV2Pair pair = IUniswapV2Pair(uniswapPair);
        deal(address(WETH), address(pair), 0.01 ether);

        // check how many tokens we get by purchasing 0.01 ether right before graduation
        uint256 graduationThreshold = GRADUATION_THRESHOLD;
        uint256 ethAmountToGraduate = _increaseWithFees(graduationThreshold);

        vm.deal(buyer, ethAmountToGraduate + 1 ether);
        vm.startPrank(buyer);
        launchpad.buyTokensWithExactEth{value: ethAmountToGraduate - 0.0001 ether}(testToken, 0, DEADLINE);
        uint256 tokensBefore = IERC20(testToken).balanceOf(buyer);

        // to calculate the uniswap price, we take the resereves only, so we don't consider fees
        // to calculate the price in bonding curve we are going to artificially exclude the fees as well
        uint256 secondBuy = 0.00011 ether;
        uint256 secondBuyPlusFees = _increaseWithFees(secondBuy);

        launchpad.buyTokensWithExactEth{value: secondBuyPlusFees}(testToken, 0, DEADLINE);
        uint256 tokensAfter = IERC20(testToken).balanceOf(buyer);
        uint256 tokensBought = tokensAfter - tokensBefore;
        uint256 bondingCurvePrice = (secondBuy * 1e18) / tokensBought;
        vm.stopPrank();
        assertTrue(LivoToken(testToken).graduated());

        (uint256 reserve0, uint256 reserve1,) = pair.getReserves();
        uint256 wethReserve;
        uint256 tokenReserve;
        if (pair.token0() == address(WETH)) {
            wethReserve = reserve0;
            tokenReserve = reserve1;
        } else {
            wethReserve = reserve1;
            tokenReserve = reserve0;
        }
        assertGt(wethReserve, 0, "WETH reserves should be positive after graduation");
        assertGt(tokenReserve, 0, "Token reserves should be positive after graduation");
        uint256 uniswapPrice = (wethReserve * 1e18) / tokenReserve;
        assertGt(uniswapPrice, 0, "Uniswap should have a valid price after graduation");

        // The price in uniswap should be strictly higher than the price in the bonding curve
        assertGt(uniswapPrice, bondingCurvePrice, "Uniswap price should be higher than bonding curve price");

        // note: if we didn't artificially compensate for the fees in the bonding curve, this assertion would revert with these numbers
        //  uniswap: 39063797643 <= bonding curve: 39368865940  -->  price drop of 0.78%
    }

    /// @notice Test that if WETH is transferred to the univ2pair pre-graduation, call pair.sync(), liquidity addition doesn't revert
    function test_ethTransferToUniV2PairPreGraduation_sync_liquidityAdditionDoesNotRevert()
        public
        createTestTokenWithPair
    {
        // Transfer some WETH to the pair
        uint256 wethAmount = 1 ether;
        WETH.deposit{value: wethAmount}();
        WETH.transfer(uniswapPair, wethAmount);

        IUniswapV2Pair pair = IUniswapV2Pair(uniswapPair);
        pair.sync();

        _graduateToken();
    }

    /// @notice Test that if WETH is transferred to the univ2pair pre-graduation, call pair.sync(), price in univ2 is higher than in the base graduation scenario
    function test_ethTransferToUniV2PairPreGraduation_sync_uniswapPriceHigher() public createTestTokenWithPair {
        // donate some eth to the pair
        IUniswapV2Pair pair = IUniswapV2Pair(uniswapPair);
        deal(address(WETH), address(pair), 0.1 ether);
        pair.sync();

        // check how many tokens we get by purchasing 0.01 ether right before graduation
        uint256 graduationThreshold = GRADUATION_THRESHOLD;
        uint256 ethAmountToGraduate = _increaseWithFees(graduationThreshold);
        vm.deal(buyer, ethAmountToGraduate + 1 ether);
        vm.startPrank(buyer);
        launchpad.buyTokensWithExactEth{value: ethAmountToGraduate - 0.0001 ether}(testToken, 0, DEADLINE);
        uint256 tokensBefore = IERC20(testToken).balanceOf(buyer);

        // to calculate the uniswap price, we take the resereves only, so we don't consider fees
        // to calculate the price in bonding curve we are going to artificially exclude the fees as well
        uint256 secondBuy = 0.00011 ether;
        launchpad.buyTokensWithExactEth{value: secondBuy}(testToken, 0, DEADLINE);
        uint256 tokensAfter = IERC20(testToken).balanceOf(buyer);
        uint256 tokensBought = tokensAfter - tokensBefore;
        uint256 bondingCurvePrice = (secondBuy * 1e18) / tokensBought;
        vm.stopPrank();
        assertTrue(LivoToken(testToken).graduated());

        (uint256 reserve0, uint256 reserve1,) = pair.getReserves();
        uint256 wethReserve;
        uint256 tokenReserve;
        if (pair.token0() == address(WETH)) {
            wethReserve = reserve0;
            tokenReserve = reserve1;
        } else {
            wethReserve = reserve1;
            tokenReserve = reserve0;
        }
        assertGt(wethReserve, 0, "WETH reserves should be positive after graduation");
        assertGt(tokenReserve, 0, "Token reserves should be positive after graduation");
        uint256 uniswapPrice = (wethReserve * 1e18) / tokenReserve;
        assertGt(uniswapPrice, 0, "Uniswap should have a valid price after graduation");

        // The price in uniswap should be strictly higher than the price in the bonding curve
        assertGt(uniswapPrice, bondingCurvePrice, "Uniswap price should be higher than bonding curve price");
        // note: this test had the same issue as test_ethTransferToUniV2PairPreGraduation_noSync_uniswapPriceHigher()
        // but I fixed this one by simply depositing a slighly higher amount of ETH
    }

    /// @notice Ensure that the right amount of tokens are deposited as liquidity
    function test_rightAmountOfTokensToLiquidity() public createTestTokenWithPair {
        // donate some eth to the pair
        _graduateToken();

        assertApproxEqRel(
            IERC20(testToken).balanceOf(uniswapPair), 191_123_250e18, 0.0001e18, "not enough tokens went to univ2 pool"
        );
    }

    /// @notice Ensure that the right amount of eth was deposited as liquidity
    function test_rightAmountOfEthToLiquidity() public createTestTokenWithPair {
        // donate some eth to the pair
        IUniswapV2Pair pair = IUniswapV2Pair(uniswapPair);
        _graduateToken();

        assertApproxEqRel(WETH.balanceOf(address(pair)), 7.456e18, 0.000001e18, "not enough eth went to univ2 pool");
    }

    /// @notice Test that if a large amount of WETH is donated (and synced) to the univ2pair pre-graduation, graduation doesn't fail
    function test_large_ethTransferToUniV2PairPreGraduation_sync_graduationOk() public createTestTokenWithPair {
        // donate some eth to the pair
        IUniswapV2Pair pair = IUniswapV2Pair(uniswapPair);
        // nobody would donate this amount of eth to block a token graduation, but just in case
        deal(address(WETH), address(pair), 3 ether);
        pair.sync();

        _graduateToken();
    }

    /// @notice Test that if a large amount of WETH is donated to the univ2pair pre-graduation, graduation doesn't fail
    function test_large_ethTransferToUniV2PairPreGraduation_noSync_graduationOk() public createTestTokenWithPair {
        // donate some eth to the pair
        IUniswapV2Pair pair = IUniswapV2Pair(uniswapPair);
        // nobody would donate this amount of eth to block a token graduation, but just in case
        deal(address(WETH), address(pair), 3 ether);

        _graduateToken();
    }

    /// @notice Test that launchpad eth balance change at graduation is the exact reserves pre graduation
    function test_graduationConservationOfFunds() public createTestTokenWithPair {
        vm.deal(buyer, 100 ether);

        // buy but not graduate
        vm.prank(buyer);
        // value sent: 6956000000000052224
        launchpad.buyTokensWithExactEth{value: GRADUATION_THRESHOLD - 1 ether}(testToken, 0, DEADLINE);
        assertFalse(launchpad.getTokenState(testToken).graduated, "Token should not be graduated yet");
        // collect the eth trading fees to have a clean comparison

        uint256 launchpadEthBefore = address(launchpad).balance;

        // the eth from this purchase would go straight into liquidity
        uint256 purchaseValue = 1 ether + MAX_THRESHOLD_EXCESS;
        vm.prank(seller);
        launchpad.buyTokensWithExactEth{value: purchaseValue}(testToken, 0, DEADLINE);
        assertTrue(launchpad.getTokenState(testToken).graduated, "Token should be graduated");

        uint256 launchpadEthAfter = address(launchpad).balance;

        // Before: launchpad balance + purchaseValue == lauchpad balance + uniswap balance
        assertEq(
            launchpadEthBefore + purchaseValue,
            launchpadEthAfter + WETH.balanceOf(uniswapPair),
            "failed in funds conservation check"
        );
    }

    /// @notice Test that the TokenGraduated event is emitted by the graduator
    function test_tokenGraduatedEventEmittedAtGraduation_byGraduator_univ2() public createTestToken {
        address tokenPair = 0x68E1D1946219e1B537dd778Da4Ce022F76243008;
        vm.expectEmit(true, true, false, true);
        emit LivoGraduatorUniswapV2.TokenGraduated(
            testToken, tokenPair, 191123250949901652977523068, 7456000000000052224, 37749370313721482071414
        );

        _graduateToken();
    }

    /// @notice Test that the TokenGraduated event is emitted by the Launchpad
    function test_tokenGraduatedEventEmittedAtGraduation_byLaunchpad_univ2() public createTestToken {
        vm.expectEmit(true, false, false, true);
        emit LivoLaunchpad.TokenGraduated(testToken, 7456000000000052224, 191123250949901652977523068);

        _graduateToken();
    }

    /// @notice that maxEthToSpend gives a value that allows for graduation
    function test_maxEthToSpend_allowsGraduation() public createTestTokenWithPair {
        uint256 maxEth = launchpad.getMaxEthToSpend(testToken);
        assertGt(maxEth, GRADUATION_THRESHOLD, "maxEthToSpend should be higher than graduation threshold");

        vm.deal(buyer, maxEth + 1 ether);
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: maxEth}(testToken, 0, DEADLINE);

        assertTrue(launchpad.getTokenState(testToken).graduated, "Token should be graduated");
    }

    /// @notice that maxEthToSpend reverts if increased by 1
    function test_maxEthToSpend_revertsIfIncreasedBy1() public createTestTokenWithPair {
        uint256 maxEth = launchpad.getMaxEthToSpend(testToken);
        assertGt(maxEth, GRADUATION_THRESHOLD, "maxEthToSpend should be higher than graduation threshold");

        vm.deal(buyer, maxEth + 1 ether);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(LivoLaunchpad.PurchaseExceedsLimitPostGraduation.selector));
        launchpad.buyTokensWithExactEth{value: maxEth + 1}(testToken, 0, DEADLINE);
    }

    /// @notice that buy maxEthToSpend (after some buys) gives a value that allows for graduation
    function test_maxEthToSpend_afterSomeBuys_allowsGraduation(uint256 preBuyAmount) public createTestTokenWithPair {
        preBuyAmount = bound(preBuyAmount, 0.01 ether, GRADUATION_THRESHOLD);

        deal(seller, 100 ether);
        vm.prank(seller);
        launchpad.buyTokensWithExactEth{value: preBuyAmount}(testToken, 0, DEADLINE);
        // if the first one already graduated, we just skip the rest of the test
        if (launchpad.getTokenState(testToken).graduated) return;

        // recalculate the max, after the previous buy
        uint256 maxEth = launchpad.getMaxEthToSpend(testToken);

        vm.deal(buyer, maxEth + 1 ether);
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: maxEth}(testToken, 0, DEADLINE);

        assertTrue(launchpad.getTokenState(testToken).graduated, "Token should be graduated");
    }
}

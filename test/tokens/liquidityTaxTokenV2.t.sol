// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LaunchpadBaseTests, LaunchpadBaseTestsWithUniv2Graduator} from "test/launchpad/base.t.sol";
import {V2SwapHelpers} from "test/e2e/base/V2SwapHelpers.t.sol";
import {LivoTaxableTokenUniV2} from "src/tokens/LivoTaxableTokenUniV2.sol";
import {ILivoFactory} from "src/interfaces/ILivoFactory.sol";
import {LiquidityTier} from "src/types/LiquidityTier.sol";
import {TaxConfigsWithAllocation, EarningsAllocationConfig} from "src/interfaces/ILivoTaxableToken.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice Integration tests for the V2 liquidity earnings-allocation leg: the liquidity slice is set
///         aside as tax TOKENS during the swap-back, then `processLiquidity` sells half for ETH and adds
///         a locked LP position (token-native zap).
contract LiquidityTaxTokenV2Tests is LaunchpadBaseTestsWithUniv2Graduator, V2SwapHelpers {
    function setUp() public override(LaunchpadBaseTests, LaunchpadBaseTestsWithUniv2Graduator) {
        super.setUp();
    }

    /// @dev Creates an ownerless V2 tax token with a `liquidityBps` allocation via the allocation-aware
    ///      `createToken` overload. 4%-configurable sell tax, creation-anchored 14-day window.
    function _createLiquidityV2Token(uint16 sellTaxBps, uint16 liquidityBps) internal returns (address token) {
        ILivoFactory.TokenSetupTiered memory setup = ILivoFactory.TokenSetupTiered({
            name: "LiqV2",
            symbol: "LV2",
            salt: _nextValidSalt(address(factoryV2Unified), address(livoTaxTokenV2)),
            feeShares: _fs(creator),
            liquidityTier: LiquidityTier.DEFAULT
        });
        TaxConfigsWithAllocation memory cfg = TaxConfigsWithAllocation({
            buyTaxBps: 0,
            sellTaxBps: sellTaxBps,
            taxDurationSeconds: uint32(14 days),
            startTaxFromLaunch: true,
            buyTaxDecayStartBps: 0,
            sellTaxDecayStartBps: 0,
            taxDecayDuration: 0,
            earningsAllocation: EarningsAllocationConfig({burnBps: 0, dividendsBps: 0, liquidityBps: liquidityBps})
        });
        vm.prank(creator);
        token = factoryV2Unified.createToken(
            setup, cfg, _noSs(), _emptyAntiSniperCfg(), new ILivoFactory.CreatorVault[](0), address(0)
        );
    }

    function test_liquidityBps_storedAtCreation() public {
        address token = _createLiquidityV2Token(400, 5000);
        assertEq(LivoTaxableTokenUniV2(payable(token)).liquidityBps(), 5000, "liquidityBps stored via new overload");
    }

    /// @dev The dividends module has not shipped and tokens are non-upgradeable clones, so a non-zero
    ///      `dividendsBps` would silently fund-fallback for the token's whole life. Reject at creation.
    function test_createToken_revertsOnNonZeroDividendsBps() public {
        ILivoFactory.TokenSetupTiered memory setup = ILivoFactory.TokenSetupTiered({
            name: "DivV2",
            symbol: "DV2",
            salt: _nextValidSalt(address(factoryV2Unified), address(livoTaxTokenV2)),
            feeShares: _fs(creator),
            liquidityTier: LiquidityTier.DEFAULT
        });
        TaxConfigsWithAllocation memory cfg = TaxConfigsWithAllocation({
            buyTaxBps: 0,
            sellTaxBps: 400,
            taxDurationSeconds: uint32(14 days),
            startTaxFromLaunch: true,
            buyTaxDecayStartBps: 0,
            sellTaxDecayStartBps: 0,
            taxDecayDuration: 0,
            earningsAllocation: EarningsAllocationConfig({burnBps: 0, dividendsBps: 1, liquidityBps: 0})
        });
        vm.prank(creator);
        vm.expectRevert(ILivoFactory.DividendsNotSupportedYet.selector);
        factoryV2Unified.createToken(
            setup, cfg, _noSs(), _emptyAntiSniperCfg(), new ILivoFactory.CreatorVault[](0), address(0)
        );
    }

    function test_v2Liquidity_swapBackBuffersThenProcessAddsLp() public {
        address token = _createLiquidityV2Token(400, 5000); // 4% sell tax; 50% of earnings → liquidity
        testToken = token;
        LivoTaxableTokenUniV2 liqToken = LivoTaxableTokenUniV2(payable(token));

        vm.deal(buyer, 5 ether);
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: 1 ether}(token, 0, DEADLINE);
        _graduateToken();

        // A single sell accrues sell tax as tokens on the contract (no auto swap-back yet).
        uint256 sellAmount = IERC20(token).balanceOf(buyer) / 10;
        _swapSellV2(buyer, token, sellAmount, 0, true);

        // Manual swap-back: burns none, sets aside the liquidity slice as TOKENS, swaps the rest to ETH.
        uint256 taxBalance = IERC20(token).balanceOf(address(liqToken));
        vm.prank(admin);
        liqToken.swapBack(taxBalance, 0);

        uint256 pendingTokens = liqToken.liquidityPendingTokens();
        assertGt(pendingTokens, 0, "liquidity tokens should be set aside by the swap-back");
        // The set-aside tokens are held on the contract but excluded from the tradable/tax balance.
        assertGe(IERC20(token).balanceOf(address(liqToken)), pendingTokens, "buffer backed by real balance");

        address pair = liqToken.pair();
        uint256 deadLpBefore = IERC20(pair).balanceOf(DEAD_ADDRESS);

        liqToken.processLiquidity(0);

        assertEq(liqToken.liquidityPendingTokens(), 0, "liquidity buffer drained");
        assertGt(IERC20(pair).balanceOf(DEAD_ADDRESS), deadLpBefore, "LP minted and locked at the dead address");
    }

    /// @dev `LiquidityAdded` must report the router's ACTUAL amounts, not the requested ones. The
    ///      half-sell moves the price, so the retained tokens + sale proceeds never match the pool ratio
    ///      and the router refunds the excess side — reporting the requested amounts would over-state
    ///      the added depth to the indexer.
    function test_v2ProcessLiquidity_eventReportsAmountsThatReachedThePair() public {
        address token = _createLiquidityV2Token(400, 5000);
        testToken = token;
        LivoTaxableTokenUniV2 liqToken = LivoTaxableTokenUniV2(payable(token));

        vm.deal(buyer, 5 ether);
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: 1 ether}(token, 0, DEADLINE);
        _graduateToken();

        _swapSellV2(buyer, token, IERC20(token).balanceOf(buyer) / 10, 0, true);
        uint256 taxBalance = IERC20(token).balanceOf(address(liqToken));
        vm.prank(admin);
        liqToken.swapBack(taxBalance, 0);

        uint256 pendingTokens = liqToken.liquidityPendingTokens();
        uint256 tokensRequested = pendingTokens - pendingTokens / 2; // the half retained for the LP side

        vm.recordLogs();
        liqToken.processLiquidity(0);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Ground truth: the pair's own `Mint`, i.e. what the add actually deposited. Reserve deltas
        // can't serve here — the half-sell also pushes tokens into the pair within the same call.
        (uint256 mintTokens, uint256 mintEth) = _pairMintAmounts(logs, token < liqToken.WETH());
        (uint256 ethAdded, uint256 tokensAdded) = _liquidityAddedAmounts(logs);

        assertEq(tokensAdded, mintTokens, "tokensAdded == tokens the pair minted against");
        assertEq(ethAdded, mintEth, "ethAdded == WETH the pair minted against");
        // Non-vacuous: the 0.3% swap fee makes ETH the scarce side, so the router consumes all of it and
        // refunds part of the requested token side. Emitting the requested amount would over-state depth.
        assertLt(tokensAdded, tokensRequested, "router refunded part of the requested token side");
    }

    /// @dev `UniswapV2Pair.Mint(address indexed sender, uint amount0, uint amount1)`, returned as
    ///      (token side, WETH side). `tokenIsToken0` orders the pair by address, as V2 does.
    function _pairMintAmounts(Vm.Log[] memory logs, bool tokenIsToken0)
        internal
        pure
        returns (uint256 tokenAmount, uint256 ethAmount)
    {
        bytes32 sig = keccak256("Mint(address,uint256,uint256)");
        for (uint256 i = logs.length; i > 0; --i) {
            if (logs[i - 1].topics[0] == sig) {
                (uint256 amount0, uint256 amount1) = abi.decode(logs[i - 1].data, (uint256, uint256));
                return tokenIsToken0 ? (amount0, amount1) : (amount1, amount0);
            }
        }
        revert("pair Mint not emitted");
    }

    /// @dev Decodes the `ethIn`/`tokensAdded` fields of the last `LiquidityAdded` in `logs`.
    function _liquidityAddedAmounts(Vm.Log[] memory logs) internal pure returns (uint256 ethIn, uint256 tokensAdded) {
        bytes32 sig = keccak256("LiquidityAdded(uint256,uint256,uint256)");
        for (uint256 i = logs.length; i > 0; --i) {
            if (logs[i - 1].topics[0] == sig) {
                (ethIn, tokensAdded,) = abi.decode(logs[i - 1].data, (uint256, uint256, uint256));
                return (ethIn, tokensAdded);
            }
        }
        revert("LiquidityAdded not emitted");
    }

    function test_v2ProcessLiquidity_revertsWhenNothingPending() public {
        address token = _createLiquidityV2Token(400, 5000);
        testToken = token;
        vm.deal(buyer, 5 ether);
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: 1 ether}(token, 0, DEADLINE);
        _graduateToken();

        vm.expectRevert(LivoTaxableTokenUniV2.NothingToAdd.selector);
        LivoTaxableTokenUniV2(payable(token)).processLiquidity(0);
    }

    function test_v2ProcessLiquidity_revertsBeforeGraduation() public {
        address token = _createLiquidityV2Token(400, 5000);
        vm.expectRevert(LivoTaxableTokenUniV2.NotGraduated.selector);
        LivoTaxableTokenUniV2(payable(token)).processLiquidity(0);
    }
}

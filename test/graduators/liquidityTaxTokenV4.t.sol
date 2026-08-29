// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TaxTokenUniV4BaseTests} from "test/graduators/taxToken.base.t.sol";
import {LivoTaxableTokenUniV4} from "src/tokens/LivoTaxableTokenUniV4.sol";
import {LivoFactoryUniV4Unified} from "src/factories/LivoFactoryUniV4Unified.sol";
import {ILivoFactory} from "src/interfaces/ILivoFactory.sol";
import {DividendDistribution} from "src/tokens/DividendDistribution.sol";
import {LiquidityTier} from "src/types/LiquidityTier.sol";
import {TaxConfigsWithAllocation, EarningsAllocationConfig} from "src/interfaces/ILivoTaxableToken.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

interface IERC721Minimal {
    function balanceOf(address owner) external view returns (uint256);
}

/// @notice Integration tests for the V4 single-sided-ETH liquidity earnings-allocation leg: the tax ETH
///         is buffered and, on `processLiquidity`, deposited as an ETH-only bid wall below the price.
contract LiquidityTaxTokenV4Tests is TaxTokenUniV4BaseTests {
    /// @dev Creates a taxable V4 token with a `liquidityBps` earnings allocation via the allocation-aware
    ///      `createToken` overload. 4%-configurable sell tax, creation-anchored 14-day window.
    function _createLiquidityTaxToken(uint16 sellTaxBps, uint16 liquidityBps) internal returns (address token) {
        ILivoFactory.TokenSetupTiered memory setup = ILivoFactory.TokenSetupTiered({
            name: "LiqToken",
            symbol: "LIQ",
            salt: _nextValidSalt(address(factoryTax), address(livoTaxToken)),
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
            earningsAllocation: EarningsAllocationConfig({
                burnBps: 0,
                dividendsBps: 0,
                liquidityBps: liquidityBps,
                dividendTokens: [address(0), address(0), address(0)],
                dividendWeightsBps: [uint16(0), 0, 0]
            })
        });
        vm.prank(creator);
        token = factoryTax.createToken(
            setup,
            cfg,
            LivoFactoryUniV4Unified.UniV4Configs({renounceOwnership: false, lpFeeBps: 100}),
            _noSs(),
            _emptyAntiSniperCfg(),
            new ILivoFactory.CreatorVault[](0),
            address(0)
        );
    }

    function test_liquidityBps_storedAtCreation() public {
        address token = _createLiquidityTaxToken(400, 5000);
        assertEq(LivoTaxableTokenUniV4(payable(token)).liquidityBps(), 5000, "liquidityBps stored via new overload");
    }

    /// @dev A non-zero `dividendsBps` with no payout configuration would leave the slice accruing into
    ///      legs that can never be funded, forever — tokens are non-upgradeable clones. Reject at creation.
    function test_createToken_revertsOnDividendsWithoutPayoutConfig() public {
        ILivoFactory.TokenSetupTiered memory setup = ILivoFactory.TokenSetupTiered({
            name: "DivToken",
            symbol: "DIV",
            salt: _nextValidSalt(address(factoryTax), address(livoTaxToken)),
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
            earningsAllocation: EarningsAllocationConfig({
                burnBps: 0,
                dividendsBps: 1,
                liquidityBps: 0,
                dividendTokens: [address(0), address(0), address(0)],
                dividendWeightsBps: [uint16(0), 0, 0]
            })
        });
        vm.prank(creator);
        vm.expectRevert(DividendDistribution.InvalidDividendConfig.selector);
        factoryTax.createToken(
            setup,
            cfg,
            LivoFactoryUniV4Unified.UniV4Configs({renounceOwnership: false, lpFeeBps: 100}),
            _noSs(),
            _emptyAntiSniperCfg(),
            new ILivoFactory.CreatorVault[](0),
            address(0)
        );
    }

    function test_v4Liquidity_accruesThenProcessMintsPosition() public {
        address token = _createLiquidityTaxToken(400, 5000); // 4% sell tax; 50% of earnings → liquidity
        testToken = token;
        LivoTaxableTokenUniV4 liqToken = LivoTaxableTokenUniV4(payable(token));

        vm.deal(buyer, 5 ether);
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: 2 ether}(token, 0, DEADLINE);
        _graduateToken();

        // Sell to accrue tax: hook -> accrueFees -> _allocateEthEarnings -> liquidity slice buffered as ETH.
        uint256 sellAmount = IERC20(token).balanceOf(buyer) / 2;
        _swapSell(buyer, sellAmount, 0, true);

        uint256 pending = liqToken.liquidityPendingEth();
        assertGt(pending, 0, "liquidity ETH should accrue from the sell tax");

        uint256 positionsBefore = IERC721Minimal(positionManagerAddress).balanceOf(token);
        uint256 tokenEthBefore = token.balance;

        liqToken.processLiquidity();

        assertEq(liqToken.liquidityPendingEth(), 0, "liquidity buffer drained");
        assertEq(
            IERC721Minimal(positionManagerAddress).balanceOf(token),
            positionsBefore + 1,
            "token owns one more single-sided ETH position"
        );
        // The buffered ETH left the token (into the position); only rounding dust may remain.
        assertLt(token.balance, tokenEthBefore, "buffered ETH deposited into the position");
        assertApproxEqAbs(tokenEthBefore - token.balance, pending, 1e12, "almost the whole buffer went to liquidity");
    }

    function test_v4ProcessLiquidity_revertsWhenNothingPending() public {
        address token = _createLiquidityTaxToken(400, 5000);
        vm.expectRevert(LivoTaxableTokenUniV4.NothingToAdd.selector);
        LivoTaxableTokenUniV4(payable(token)).processLiquidity();
    }
}

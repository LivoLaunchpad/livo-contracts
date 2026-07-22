// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TaxTokenUniV4BaseTests} from "test/graduators/taxToken.base.t.sol";
import {LivoTaxableTokenUniV4} from "src/tokens/LivoTaxableTokenUniV4.sol";
import {LivoFactoryUniV4Unified} from "src/factories/LivoFactoryUniV4Unified.sol";
import {ILivoFactory} from "src/interfaces/ILivoFactory.sol";
import {LiquidityTier} from "src/types/LiquidityTier.sol";
import {TaxConfigsWithAllocation, EarningsAllocationConfig} from "src/interfaces/ILivoTaxableToken.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/// @notice Integration tests for the V4 buy-back-and-burn earnings-allocation leg.
contract BurnTaxTokenV4Tests is TaxTokenUniV4BaseTests {
    /// @dev Creates a taxable V4 token with a `burnBps` earnings allocation via the allocation-aware
    ///      `createToken` overload. 4%-configurable sell tax, creation-anchored 14-day window.
    function _createBurnTaxToken(uint16 sellTaxBps, uint16 burnBps) internal returns (address token) {
        ILivoFactory.TokenSetupTiered memory setup = ILivoFactory.TokenSetupTiered({
            name: "BurnToken",
            symbol: "BURN",
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
            earningsAllocation: EarningsAllocationConfig({burnBps: burnBps, dividendsBps: 0, liquidityBps: 0})
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

    function test_burnBps_storedAtCreation() public {
        address token = _createBurnTaxToken(400, 5000);
        assertEq(LivoTaxableTokenUniV4(payable(token)).burnBps(), 5000, "burnBps stored via new overload");
    }

    function test_v4Burn_accruesThenProcessBurnReducesSupply() public {
        address token = _createBurnTaxToken(400, 5000); // 4% sell tax; 50% of earnings → burn
        testToken = token;
        LivoTaxableTokenUniV4 burnToken = LivoTaxableTokenUniV4(payable(token));

        vm.deal(buyer, 5 ether);
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: 2 ether}(token, 0, DEADLINE);
        _graduateToken();

        // Sell to accrue tax: hook -> accrueFees -> _allocateEthEarnings -> burn slice buffered as ETH.
        uint256 sellAmount = IERC20(token).balanceOf(buyer) / 2;
        _swapSell(buyer, sellAmount, 0, true);

        uint256 pending = burnToken.burnPendingEth();
        assertGt(pending, 0, "burn ETH should accrue from the sell tax");

        uint256 supplyBefore = IERC20(token).totalSupply();
        burnToken.processBurn(0);

        // The buy-back itself pays LP fee (and tax, window open), a fraction of which re-accrues; so the
        // buffer is drained well below `pending`, not necessarily to exactly 0.
        assertLt(burnToken.burnPendingEth(), pending, "burn buffer drained");
        assertLt(IERC20(token).totalSupply(), supplyBefore, "total supply reduced by the buy-back-and-burn");
    }

    function test_v4ProcessBurn_revertsWhenNothingPending() public {
        address token = _createBurnTaxToken(400, 5000);
        vm.expectRevert(LivoTaxableTokenUniV4.NothingToBurn.selector);
        LivoTaxableTokenUniV4(payable(token)).processBurn(0);
    }

    function test_v4SweepStrayEth_routesStrayToBurnBuffer() public {
        address token = _createBurnTaxToken(400, 5000);
        testToken = token;
        LivoTaxableTokenUniV4 burnToken = LivoTaxableTokenUniV4(payable(token));

        vm.deal(buyer, 5 ether);
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: 2 ether}(token, 0, DEADLINE);
        _graduateToken();

        vm.deal(address(burnToken), 1 ether); // stray ETH
        uint256 pendingBefore = burnToken.burnPendingEth();

        burnToken.sweepStrayEth();

        // 50% burn allocation → ~half the stray becomes burn buffer; the rest routes to the fund wallets.
        assertApproxEqAbs(burnToken.burnPendingEth() - pendingBefore, 0.5 ether, 1, "half of stray -> burn buffer");
    }
}

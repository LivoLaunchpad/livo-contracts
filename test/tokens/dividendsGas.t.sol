// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/console.sol";
import {TaxTokenUniV4BaseTests} from "test/graduators/taxToken.base.t.sol";
import {LivoTaxableTokenUniV4} from "src/tokens/LivoTaxableTokenUniV4.sol";
import {LivoFactoryUniV4Unified} from "src/factories/LivoFactoryUniV4Unified.sol";
import {ILivoFactory} from "src/interfaces/ILivoFactory.sol";
import {LiquidityTier} from "src/types/LiquidityTier.sol";
import {TaxConfigsWithAllocation, EarningsAllocationConfig} from "src/interfaces/ILivoTaxableToken.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/// @notice The hot-path gas measurement the dividends design hangs on.
///
/// Dividends buy their trustlessness with a per-account write on the transfer path, and the design
/// document is explicit that this is "the one number that could kill the design". So it is measured
/// here rather than modelled: two IDENTICAL tokens, one with a dividend allocation and one without,
/// and the same transfers run against both.
///
/// What matters is the DELTA, and that a token WITHOUT dividends pays nothing — the whole point of
/// putting `hasDividends` in the warm `pair` slot `_update` already loads.
contract DividendsGasTests is TaxTokenUniV4BaseTests {
    address internal holderA = makeAddr("gasHolderA");
    address internal holderB = makeAddr("gasHolderB");

    function _create(uint16 dividendsBps) internal returns (LivoTaxableTokenUniV4) {
        ILivoFactory.TokenSetupTiered memory setup = ILivoFactory.TokenSetupTiered({
            name: "GasTok",
            symbol: "GAS",
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
                dividendsBps: dividendsBps,
                liquidityBps: 0,
                dividendTokens: [address(0), address(0), address(0)],
                dividendWeightsBps: dividendsBps == 0 ? [uint16(0), 0, 0] : [uint16(10_000), 0, 0]
            })
        });
        vm.prank(creator);
        address token = factoryTax.createToken(
            setup,
            cfg,
            LivoFactoryUniV4Unified.UniV4Configs({renounceOwnership: false, lpFeeBps: 100}),
            _noSs(),
            _emptyAntiSniperCfg(),
            new ILivoFactory.CreatorVault[](0),
            address(0)
        );
        testToken = token;
        _launchpadBuy(token, 2 ether);
        _graduateToken();

        // Route one lot of earnings through both tokens, identically. On the dividend token this is
        // what opens round 1 (rounds open on first earnings, not at graduation), so what follows is
        // measured with the feature actually live; on the plain token it is a no-op that keeps the two
        // set-ups symmetric.
        vm.deal(address(this), 1 ether);
        LivoTaxableTokenUniV4(payable(token)).accrueFees{value: 1 ether}();
        return LivoTaxableTokenUniV4(payable(token));
    }

    receive() external payable {}

    /// @dev Three wallet-to-wallet transfers, chosen to isolate the three cases the design cares
    ///      about: the ONE-OFF first-ever touch of an account slot, a steady-state transfer whose
    ///      sender sets a new minimum, and a steady-state transfer that writes nothing at all.
    function _measure(LivoTaxableTokenUniV4 token)
        internal
        returns (uint256 firstEver, uint256 warmDecrease, uint256 warmNoWrite)
    {
        IERC20 erc = IERC20(address(token));
        uint256 unit = erc.balanceOf(buyer) / 100;

        // 1. Both account slots are zero, so both pay the zero->non-zero SSTORE. Once per account
        //    per token, forever — not a recurring cost.
        vm.startPrank(buyer);
        uint256 g = gasleft();
        erc.transfer(holderA, unit);
        firstEver = g - gasleft();

        // 2. Both slots are now warm and non-zero. The sender's balance falls below its running
        //    minimum, so it writes its account slot AND the denominator; the receiver writes
        //    nothing, because a minimum never rises.
        g = gasleft();
        erc.transfer(holderA, unit);
        warmDecrease = g - gasleft();
        vm.stopPrank();

        // 3. Warm the receiver's slot, then measure a transfer where NOTHING is written: holderA
        //    arrived mid-round so its minimum is 0 and cannot fall further, and holderB is only
        //    increasing.
        vm.startPrank(holderA);
        erc.transfer(holderB, unit / 4);
        g = gasleft();
        erc.transfer(holderB, unit / 4);
        warmNoWrite = g - gasleft();
        vm.stopPrank();
    }

    function test_gas_hotPathOverheadOfDividends() public {
        LivoTaxableTokenUniV4 plain = _create(0);
        (uint256 pFirst, uint256 pDecrease, uint256 pNoWrite) = _measure(plain);

        LivoTaxableTokenUniV4 div = _create(5_000);
        (uint256 dFirst, uint256 dDecrease, uint256 dNoWrite) = _measure(div);

        console.log("--- wallet-to-wallet transfer, execution gas ---");
        console.log("no dividends : firstEver / warmDecrease / warmNoWrite", pFirst, pDecrease, pNoWrite);
        console.log("dividends    : firstEver / warmDecrease / warmNoWrite", dFirst, dDecrease, dNoWrite);
        console.log(
            "delta        : firstEver / warmDecrease / warmNoWrite",
            dFirst - pFirst,
            dDecrease - pDecrease,
            dNoWrite - pNoWrite
        );

        // A token WITHOUT dividends must stay in its old envelope: the gate is a bit in the `pair`
        // slot `_update` already loads, so the only cost is a JUMP into an empty virtual hook.
        assertLt(pFirst, 60_000, "a non-dividend token's transfer must not have regressed");

        // ONE-OFF. Two accounts, each paying a 20k zero->non-zero SSTORE the first time they are
        // ever tracked, plus the round reads. It never recurs for those accounts.
        assertLt(dFirst - pFirst, 55_000, "first-ever touch of two account slots");

        // STEADY STATE, the number that actually matters. The sender writes its (warm, non-zero)
        // account slot and the denominator; the receiver writes nothing.
        assertLt(dDecrease - pDecrease, 12_000, "a steady-state transfer that lowers a minimum");

        // STEADY STATE, cheapest case: a minimum never rises, so an increase after the first touch
        // is reads only.
        assertLt(dNoWrite - pNoWrite, 6_000, "a transfer that sets no new minimum writes nothing");
    }

    /// @dev The numbers above are deltas on `_update` alone. What a USER pays is the whole
    ///      transaction, so the percentages that matter are measured against that: a V4 pool swap and a
    ///      plain wallet-to-wallet transfer, both including the 21k intrinsic cost, and both in steady
    ///      state (every account slot already touched once).
    function test_gas_wholeOperationOverhead() public {
        LivoTaxableTokenUniV4 plain = _create(0);
        (uint256 pTransfer, uint256 pBuy, uint256 pSell) = _measureOperations(plain);

        LivoTaxableTokenUniV4 div = _create(5_000);
        (uint256 dTransfer, uint256 dBuy, uint256 dSell) = _measureOperations(div);

        console.log("--- whole user operation, incl. 21k intrinsic, steady state ---");
        console.log("transfer  no-div / div / +bps", pTransfer, dTransfer, _bps(pTransfer, dTransfer));
        console.log("V4 buy    no-div / div / +bps", pBuy, dBuy, _bps(pBuy, dBuy));
        console.log("V4 sell   no-div / div / +bps", pSell, dSell, _bps(pSell, dSell));

        // A pool trade is the operation that competes with other launchpads on gas. Only ONE side of
        // it is ever tracked — the `pair` is excluded — so the overhead lands on a single account slot.
        assertLt(_bps(pBuy, dBuy), 1_000, "a V4 buy must stay under +10%");
        assertLt(_bps(pSell, dSell), 1_000, "a V4 sell must stay under +10%");
    }

    /// @dev Steady-state cost of the three operations a user actually performs, each measured as a
    ///      whole transaction (21k intrinsic included).
    function _measureOperations(LivoTaxableTokenUniV4 token)
        internal
        returns (uint256 transferGas, uint256 buyGas, uint256 sellGas)
    {
        IERC20 erc = IERC20(address(token));
        testToken = address(token);
        uint256 unit = erc.balanceOf(buyer) / 1000;

        // Warm every account slot first, so what is left is the recurring cost rather than the
        // one-off zero->non-zero write.
        vm.startPrank(buyer);
        erc.transfer(holderA, unit);
        erc.transfer(holderA, unit);
        uint256 g = gasleft();
        erc.transfer(holderA, unit);
        transferGas = g - gasleft() + 21_000;
        vm.stopPrank();

        vm.deal(holderB, 1 ether);
        _swapBuy(holderB, 0.01 ether, 0, true); // warm holderB's slot
        g = gasleft();
        _swapBuy(holderB, 0.01 ether, 0, true);
        buyGas = g - gasleft() + 21_000;

        uint256 sellAmount = erc.balanceOf(holderB) / 4;
        _swapSell(holderB, sellAmount, 0, true); // warm the sell path
        g = gasleft();
        _swapSell(holderB, sellAmount, 0, true);
        sellGas = g - gasleft() + 21_000;
    }

    /// @dev Overhead of `withDiv` over `baseline`, in basis points.
    function _bps(uint256 baseline, uint256 withDiv) internal pure returns (uint256) {
        if (baseline == 0 || withDiv <= baseline) return 0;
        return ((withDiv - baseline) * 10_000) / baseline;
    }

    /// @dev The gate has to be free, not merely cheap: every non-dividend Livo token pays it forever.
    function test_gas_nonDividendTokenPaysNothingMeasurable() public {
        LivoTaxableTokenUniV4 plain = _create(0);
        IERC20 erc = IERC20(address(plain));
        uint256 unit = erc.balanceOf(buyer) / 100;

        vm.startPrank(buyer);
        erc.transfer(holderA, unit); // warm everything
        uint256 g = gasleft();
        erc.transfer(holderA, unit);
        uint256 used = g - gasleft();
        vm.stopPrank();

        console.log("non-dividend warm transfer gas", used);
        assertLt(used, 40_000, "warm transfer on a non-dividend token");
    }
}

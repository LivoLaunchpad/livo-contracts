// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {LaunchpadBaseTests, LaunchpadBaseTestsWithUniv2Graduator} from "test/launchpad/base.t.sol";
import {V2SwapHelpers} from "test/e2e/base/V2SwapHelpers.t.sol";
import {LivoTaxableTokenUniV2} from "src/tokens/LivoTaxableTokenUniV2.sol";
import {ILivoFactory} from "src/interfaces/ILivoFactory.sol";
import {LiquidityTier} from "src/types/LiquidityTier.sol";
import {TaxConfigsWithAllocation, EarningsAllocationConfig} from "src/interfaces/ILivoTaxableToken.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {noDividendRoute} from "test/helpers/DividendRouteHelpers.sol";

/// @notice Drives every path that can move a V2 dividend token's balances. Unlike the V4 handler, the
///         interesting balance here is the token's own ERC20 balance: the tax pool, the liquidity buffer,
///         the self-token dividend buffer and an undelivered self-token pot ALL live in it, and the
///         automatic swap-back fires on ordinary sells with no attacker involved.
contract DividendSolvencyV2Handler is Test, V2SwapHelpers {
    LivoTaxableTokenUniV2 public immutable TOKEN;
    address[] public holders;

    constructor(LivoTaxableTokenUniV2 token_, address[] memory holders_) {
        TOKEN = token_;
        holders = holders_;
    }

    receive() external payable {}

    /// @dev Fresh post-graduation earnings, as the launchpad fee path delivers them.
    function accrue(uint96 raw) public {
        uint256 amount = bound(uint256(raw), 0.001 ether, 3 ether);
        vm.deal(address(this), amount);
        TOKEN.accrueFees{value: amount}();
    }

    /// @dev A real sell. This is the one that matters: it fires the automatic swap-back, which processes
    ///      the tax pool out of the same balance the dividend buffers sit in.
    function sell(uint256 seed, uint96 raw) public {
        address seller = holders[seed % holders.length];
        uint256 balance = IERC20(address(TOKEN)).balanceOf(seller);
        if (balance < 1e18) return;
        uint256 amount = bound(uint256(raw), 1e18, balance);
        _swapSellV2(seller, address(TOKEN), amount, 0, true);
    }

    function buy(uint256 seed, uint96 raw) public {
        address b = holders[seed % holders.length];
        uint256 amount = bound(uint256(raw), 0.001 ether, 1 ether);
        vm.deal(b, amount);
        _swapBuyV2(b, address(TOKEN), amount, 0, true);
    }

    /// @dev Stray tokens someone sent by hand. They must be treated as tax, never as committed money.
    function donateTokens(uint256 seed, uint96 raw) public {
        address from = holders[seed % holders.length];
        uint256 balance = IERC20(address(TOKEN)).balanceOf(from);
        if (balance == 0) return;
        vm.prank(from);
        IERC20(address(TOKEN)).transfer(address(TOKEN), bound(uint256(raw), 1, balance));
    }

    function processLiquidity(uint96 raw) public {
        try TOKEN.processLiquidity(bound(uint256(raw), 0, 1)) {} catch {}
    }

    /// @dev Freeze-only: the single entry point does whichever step the round is due for, so a call with
    ///      no holders exercises the freeze and the rollover paths on their own.
    function process() public {
        try TOKEN.processRound(0, new address[](0)) {} catch {}
    }

    function distribute(uint256 seed) public {
        address[] memory batch = new address[](holders.length);
        for (uint256 i; i < holders.length; ++i) {
            batch[i] = holders[(i + seed) % holders.length];
        }
        try TOKEN.processRound(0, batch) {} catch {}
    }

    function transferBetweenHolders(uint256 seed, uint96 raw) public {
        address from = holders[seed % holders.length];
        address to = holders[(seed + 1) % holders.length];
        uint256 balance = IERC20(address(TOKEN)).balanceOf(from);
        if (balance == 0) return;
        vm.prank(from);
        IERC20(address(TOKEN)).transfer(to, bound(uint256(raw), 1, balance));
    }

    function advanceTime(uint32 raw) public {
        skip(bound(uint256(raw), 1 minutes, 3 days));
        vm.roll(block.number + 1);
    }
}

/// @notice The V2 counterpart of `DividendSolvencyInvariants`. V2 is the tangled case: three buckets
///         share ONE ERC20 balance, and `_sweepableAsset` is the only thing keeping the swap-back from
///         reprocessing committed money as tax. The failure mode is not a stuck balance — it is holders'
///         money silently converted into creator fees on every trade.
contract DividendSolvencyV2Invariants is LaunchpadBaseTestsWithUniv2Graduator, V2SwapHelpers {
    LivoTaxableTokenUniV2 internal divToken;
    DividendSolvencyV2Handler internal handler;

    address internal holderA = makeAddr("holderA");
    address internal holderB = makeAddr("holderB");

    function setUp() public override(LaunchpadBaseTests, LaunchpadBaseTestsWithUniv2Graduator) {
        super.setUp();

        ILivoFactory.TokenSetupTiered memory setup = ILivoFactory.TokenSetupTiered({
            name: "DivInvV2",
            symbol: "DIV2",
            salt: _nextValidSalt(address(factoryV2Unified), address(livoTaxTokenV2)),
            feeShares: _fs(creator),
            liquidityTier: LiquidityTier.DEFAULT
        });
        // A SELF-TOKEN dividend leg alongside a liquidity allocation, on purpose: those are the two
        // buckets that live in the token's own ERC20 balance next to the tax pool.
        TaxConfigsWithAllocation memory cfg = TaxConfigsWithAllocation({
            buyTaxBps: 0,
            sellTaxBps: 500,
            taxDurationSeconds: uint32(365 days),
            startTaxFromLaunch: true,
            buyTaxDecayStartBps: 0,
            sellTaxDecayStartBps: 0,
            taxDecayDuration: 0,
            earningsAllocation: EarningsAllocationConfig({
                burnBps: 1_000,
                dividendsBps: 4_000,
                liquidityBps: 2_000,
                dividendToken: address(type(uint160).max),
                dividendRoute: noDividendRoute()
            })
        });
        vm.prank(creator);
        address token = factoryV2Unified.createToken(
            setup, cfg, _noSs(), _emptyAntiSniperCfg(), new ILivoFactory.CreatorVault[](0), address(0)
        );

        testToken = token;
        _launchpadBuy(token, 1 ether);
        _graduateToken();
        divToken = LivoTaxableTokenUniV2(payable(token));

        uint256 float = IERC20(token).balanceOf(buyer);
        vm.startPrank(buyer);
        IERC20(token).transfer(holderA, float / 3);
        IERC20(token).transfer(holderB, float / 3);
        vm.stopPrank();

        address[] memory holders = new address[](3);
        holders[0] = buyer;
        holders[1] = holderA;
        holders[2] = holderB;

        handler = new DividendSolvencyV2Handler(divToken, holders);
        targetContract(address(handler));
    }

    /// @dev THE V2 invariant. The liquidity buffer, the self-token dividend buffer and any undelivered
    ///      self-token pot all sit in the token's own balance. If the total ever exceeds the balance,
    ///      something has already been spent twice.
    function invariant_selfTokenBalanceCoversEveryCommitment() public view {
        uint256 committed = divToken.liquidityPendingTokens() + divToken.dividendPendingTokens()
            + divToken.committedDividends(address(divToken));
        assertGe(
            IERC20(address(divToken)).balanceOf(address(divToken)),
            committed,
            "the token's own balance must cover the liquidity + dividend buffers it holds"
        );
    }

    /// @dev The native side, same argument: the native dividend buffers and any undelivered native pot
    ///      must stay backed even as swap-backs push ETH through the split on every qualifying sell.
    function invariant_nativeBalanceCoversEveryCommitment() public view {
        uint256 committed = divToken.pendingNative() + divToken.committedDividends(address(0));
        assertGe(address(divToken).balance, committed, "native balance must cover the native commitments");
    }

    /// @dev Over-distribution is impossible by construction; if this trips, the frozen-denominator
    ///      argument has been broken.
    function invariant_roundNeverPaysMoreThanItsPot() public view {
        assertLe(divToken.roundPaid(), divToken.roundPot(), "the round paid out more than it froze");
    }

    /// @dev The denominator is a sum of per-account minima, so it can never exceed the supply it was
    ///      seeded from — even as the burn leg shrinks that supply underneath it.
    function invariant_denominatorNeverExceedsSupply() public view {
        assertLe(uint256(divToken.roundTotalShares()), IERC20(address(divToken)).totalSupply(), "denominator sane");
    }
}

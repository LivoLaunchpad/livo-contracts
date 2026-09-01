// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DividendDistributionLogic} from "src/tokens/DividendDistributionLogic.sol";
import {DividendDistribution} from "src/tokens/DividendDistribution.sol";
import {DeploymentAddressesEthereumMainnet as DeploymentAddresses} from "src/config/DeploymentAddresses.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IUniswapV2Router} from "src/interfaces/IUniswapV2Router.sol";
import {ERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {DividendRoute} from "src/types/DividendRoute.sol";
import {v2DividendRoute, v3DividendRoute, v4DividendRoute} from "test/helpers/DividendRouteHelpers.sol";

/// @notice A bare `DividendDistributionLogic` with the token's hooks stubbed out. It exists so the
///         third-asset payout shape — the only one that actually performs a swap — can be exercised
///         against real Uniswap pools without dragging a launchpad, a graduator and a pool through
///         the test. Balances are set directly instead of being moved by transfers.
contract DividendHarness is DividendDistributionLogic {
    mapping(address => uint256) public balances;
    uint256 public eligibleSupply;

    function configure(address asset, DividendRoute memory route) external {
        _initializeDividends(asset, route);
    }

    function openRound() external {
        _openDividendRound();
    }

    function accrue() external payable {
        _accrueDividends(msg.value);
    }

    function setBalance(address account, uint256 value) external {
        eligibleSupply = eligibleSupply + value - balances[account];
        balances[account] = value;
    }

    function _dividendBalanceOf(address account) internal view override returns (uint256) {
        return balances[account];
    }

    function _dividendExcluded(address) internal pure override returns (bool) {
        return false;
    }

    function _dividendEligibleSupply() internal view override returns (uint256) {
        return eligibleSupply;
    }

    receive() external payable {}
}

/// @notice An ERC20 with no pool anywhere, standing in for an asset a creator names without liquidity.
contract GhostToken is ERC20 {
    constructor() ERC20("Ghost", "GHOST") {
        _mint(msg.sender, 1_000_000e18);
    }
}

/// @notice The third-token payout shape: an accrued native buffer is converted into an arbitrary ERC20
///         on the pool the creator named at creation, and pushed to holders in that asset. Any ERC20
///         with a deep enough pool qualifies — there is no asset whitelist and no admin approval, only
///         the creation-time liquidity proof.
contract DividendsThirdAssetTests is Test {
    uint256 internal constant BLOCKNUMBER = 23327777;
    address internal constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    DividendHarness internal harness;

    address internal holder = makeAddr("holder");

    /// @dev `addLiquidityETH` refunds the unused ETH side to the caller.
    receive() external payable {}

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), BLOCKNUMBER);
        harness = _harness(DAI, v2DividendRoute());
    }

    /// @dev A harness paying `asset` through `route`, configured and ready to have its round opened.
    function _harness(address asset, DividendRoute memory route) internal returns (DividendHarness h) {
        h = new DividendHarness();
        h.configure(asset, route);
    }

    function _fundAndOpen(DividendHarness h) internal {
        h.setBalance(holder, 1_000e18);
        h.openRound();
        vm.deal(address(this), 1 ether);
        h.accrue{value: 1 ether}();
        skip(h.MIN_ROUND_DURATION() + 1);
    }

    function _holders() internal view returns (address[] memory list) {
        list = new address[](1);
        list[0] = holder;
    }

    function _noHolders() internal pure returns (address[] memory list) {
        list = new address[](0);
    }

    //////////////////////// the payout shape //////////////////////

    function test_thirdAsset_boughtOnFreezeAndPaidToHolders() public {
        _fundAndOpen(harness);
        assertEq(harness.pendingNative(), 1 ether, "native buffered for the DAI payout");

        harness.processRound(0, _noHolders());

        uint256 pot = harness.roundPot();
        assertGt(pot, 0, "native converted into DAI");
        // A swapping payout converts at most `MAX_DIVIDEND_PER_FREEZE` per freeze; the rest stays
        // buffered.
        assertEq(harness.pendingNative(), 1 ether - harness.MAX_DIVIDEND_PER_FREEZE(), "only the cap was converted");
        assertEq(IERC20(DAI).balanceOf(address(harness)), pot, "the pot is a real DAI balance");
        // What every sweep path subtracts: an undelivered third-asset pot is COMMITTED, not stray, so
        // `rescueTokens` cannot hand holders' money to the owner while it is still owed.
        assertEq(harness.committedDividends(DAI), pot, "the whole pot is owed to holders");

        harness.processRound(0, _holders());

        assertEq(IERC20(DAI).balanceOf(holder), pot, "sole holder paid the whole pot, in DAI");
        assertEq(harness.committedDividends(DAI), 0, "nothing left owed");
    }

    /// @dev A Uniswap-V3-only asset is a first-class dividend asset: the route names the pool's fee tier
    ///      and the swap goes through the universal router.
    function test_thirdAsset_v3Route() public {
        DividendHarness v3 = _harness(USDC, v3DividendRoute(500));
        _fundAndOpen(v3);

        v3.processRound(0, _noHolders());

        assertGt(v3.roundPot(), 0, "the V3 pool funded the round");
        assertEq(IERC20(USDC).balanceOf(address(v3)), v3.roundPot(), "the pot is a real USDC balance");
    }

    /// @dev Same for a Uniswap-V4 pool, keyed by fee + tick spacing + hooks rather than a fee tier alone.
    function test_thirdAsset_v4Route() public {
        DividendHarness v4 = _harness(USDC, v4DividendRoute(500, 10, address(0)));
        _fundAndOpen(v4);

        v4.processRound(0, _noHolders());

        assertGt(v4.roundPot(), 0, "the V4 pool funded the round");
        assertEq(IERC20(USDC).balanceOf(address(v4)), v4.roundPot(), "the pot is a real USDC balance");
    }

    /// @dev The per-freeze cap bounds one sandwich, it does not cap what a token can ever pay: whatever
    ///      it leaves behind stays buffered and converts in a later round, so nothing strands.
    function test_thirdAsset_cappedFreezeLeavesTheRemainderForTheNextRound() public {
        _fundAndOpen(harness);
        uint256 cap = harness.MAX_DIVIDEND_PER_FREEZE();

        harness.processRound(0, _holders());
        assertEq(harness.pendingNative(), 1 ether - cap, "the first freeze took exactly the cap");
        assertEq(harness.currentRound(), 2, "a fully paid round rolls over in the same call");

        skip(harness.MIN_ROUND_DURATION() + 1);
        harness.processRound(0, _noHolders());
        assertEq(harness.pendingNative(), 1 ether - 2 * cap, "the next round takes the next slice");
    }

    //////////////////////// the liquidity proof //////////////////////

    /// @dev THE eligibility rule, and the only one. Any ERC20 is fair game as long as the pool the
    ///      creator names for it actually exists and is worth swapping against — no whitelist, no admin.
    function test_anyErc20WithADeepPoolIsConfigurable() public {
        assertEq(_harness(DAI, v2DividendRoute()).dividendToken(), DAI, "a V2 asset");
        assertEq(_harness(USDC, v3DividendRoute(500)).dividendToken(), USDC, "a V3 asset");
        assertEq(_harness(USDC, v4DividendRoute(500, 10, address(0))).dividendToken(), USDC, "a V4 asset");
    }

    /// @dev An asset nobody has ever made a market for is refused at creation, not left to accrue into a
    ///      buffer that could never be converted — the failure mode a clone cannot be patched out of.
    function test_anAssetWithNoPoolAtAllIsRejected() public {
        address ghost = address(new GhostToken());

        DividendHarness h = new DividendHarness();
        vm.expectRevert(DividendDistribution.InsufficientDividendPoolLiquidity.selector);
        h.configure(ghost, v2DividendRoute());

        DividendHarness v3 = new DividendHarness();
        vm.expectRevert(DividendDistribution.InsufficientDividendPoolLiquidity.selector);
        v3.configure(ghost, v3DividendRoute(3000));

        DividendHarness v4 = new DividendHarness();
        vm.expectRevert(DividendDistribution.InsufficientDividendPoolLiquidity.selector);
        v4.configure(ghost, v4DividendRoute(3000, 60, address(0)));
    }

    /// @dev A pool that EXISTS but is too thin is refused just the same. The floor is denominated in the
    ///      quote asset, so it means the same thing whatever the payout asset's own decimals are.
    function test_aPoolTooThinToSwapAgainstIsRejected() public {
        GhostToken thin = new GhostToken();
        IUniswapV2Router router = IUniswapV2Router(DeploymentAddresses.UNIV2_ROUTER);

        // A real pair on the real factory, seeded with less than the floor.
        uint256 seeded = harness.MIN_DIVIDEND_POOL_LIQUIDITY() / 2;
        vm.deal(address(this), seeded);
        thin.approve(address(router), type(uint256).max);
        router.addLiquidityETH{value: seeded}(address(thin), 500_000e18, 0, 0, address(this), block.timestamp);

        DividendHarness h = new DividendHarness();
        vm.expectRevert(DividendDistribution.InsufficientDividendPoolLiquidity.selector);
        h.configure(address(thin), v2DividendRoute());

        // Top the same pair up over the floor and the very same asset becomes eligible. Nothing about
        // the ASSET changed — only its liquidity, which is the whole rule.
        vm.deal(address(this), seeded + 1);
        router.addLiquidityETH{value: seeded + 1}(address(thin), 500_000e18, 0, 0, address(this), block.timestamp);

        DividendHarness ok = new DividendHarness();
        ok.configure(address(thin), v2DividendRoute());
        assertEq(ok.dividendToken(), address(thin), "eligible once the pool is deep enough");
    }

    /// @dev Route validation still refuses what this chain could never execute at all. A V3 pool is keyed
    ///      by its fee tier and a V4 pool by its tick spacing; zero is not a pool, it is a typo.
    function test_routesThatCouldNeverExecuteAreRejectedAtConfiguration() public {
        DividendHarness a = new DividendHarness();
        vm.expectRevert(DividendDistribution.UnsupportedDividendAsset.selector);
        a.configure(DAI, v3DividendRoute(0));

        DividendHarness b = new DividendHarness();
        vm.expectRevert(DividendDistribution.UnsupportedDividendAsset.selector);
        b.configure(DAI, v4DividendRoute(500, 0, address(0)));
    }

    /// @dev Native and the token itself buy nothing, so they need no route and prove no liquidity.
    function test_nativeAndSelfTokenNeedNoProof() public {
        DividendHarness nativeH = new DividendHarness();
        nativeH.configure(address(0), v3DividendRoute(0)); // a route that would be refused for an ERC20
        assertEq(nativeH.dividendToken(), address(0), "native configured");

        DividendHarness selfH = new DividendHarness();
        selfH.configure(selfH.DIVIDEND_SELF_TOKEN(), v3DividendRoute(0));
        assertEq(selfH.dividendToken(), address(selfH), "the sentinel resolved to the token itself");
    }

    //////////////////////// conversion failures //////////////////////

    /// @dev `minOut` is what bounds the swap. A floor the pool cannot meet leaves the round unfrozen with
    ///      its buffer untouched — and says so precisely: the money IS there, the swap is the problem, so
    ///      the keeper is told to retry rather than to wait for earnings it already has.
    function test_aMissedSlippageFloorLeavesTheRoundUnfrozen() public {
        _fundAndOpen(harness);

        vm.expectRevert(DividendDistribution.DividendConversionFailed.selector);
        harness.processRound(1_000_000e18, _noHolders());

        assertEq(harness.pendingNative(), 1 ether, "nothing was spent");
        assertFalse(harness.roundFrozen(), "the round did not freeze");

        harness.processRound(0, _noHolders());
        assertGt(harness.roundPot(), 0, "the same buffer converts once the floor is reachable");
    }

    /// @dev A round that simply has not earned enough yet reports the OTHER error: the keeper is told to
    ///      wait, not sent looking for a broken pool.
    function test_aBelowThresholdBufferReportsBelowDividendThreshold() public {
        harness.setBalance(holder, 1_000e18);
        harness.openRound();
        vm.deal(address(this), 1 wei);
        harness.accrue{value: 1 wei}();
        skip(harness.MIN_ROUND_DURATION() + 1);

        vm.expectRevert(DividendDistribution.BelowDividendThreshold.selector);
        harness.processRound(0, _noHolders());
    }

    /// @dev A payout asset that returns a non-boolean word from `transfer` must be TOLERATED, not
    ///      decoded strictly. `abi.decode(_, (bool))` reverts on any word above 1, which is legal for a
    ///      non-standard ERC20 — and a revert inside `_payDividend` is precisely what the skip-don't-revert
    ///      contract exists to prevent: it would take down the whole `processRound` batch, `claimRound`
    ///      for everyone, and the round's ability to settle until `PAYOUT_WINDOW`.
    function test_aNonBooleanTransferReturnDoesNotBrickTheBatch() public {
        _fundAndOpen(harness);
        harness.processRound(0, _noHolders()); // freeze in DAI

        uint256 pot = harness.roundPot();
        vm.mockCall(DAI, abi.encodeWithSelector(IERC20.transfer.selector), abi.encode(uint256(2)));

        vm.expectEmit(true, true, true, true, address(harness));
        emit DividendDistribution.DividendPaid(harness.currentRound(), holder, DAI, pot);
        harness.processRound(0, _holders());

        assertEq(harness.roundPot(), 0, "the pot was delivered and the round rolled over");
    }

    //////////////////////// the dead-pool escape //////////////////////

    /// @dev The replacement for an admin-curated route override: nobody can repair a dead pool, so the
    ///      token repairs itself. Once the round has gone `STALE_ROUND_WINDOW` without rolling over AND
    ///      the swap cannot execute at ANY price, the payout asset is permanently downgraded to native —
    ///      the one asset that needs no pool. Without it, a buffer owed to holders would strand forever.
    function test_aPermanentlyDeadPoolDowngradesThePayoutToNative() public {
        _fundAndOpen(harness);
        _killTheV2Router();

        // Not yet: a live token retries rather than downgrading.
        vm.expectRevert(DividendDistribution.DividendConversionFailed.selector);
        harness.processRound(0, _noHolders());

        skip(harness.STALE_ROUND_WINDOW());

        vm.expectEmit(true, false, false, false, address(harness));
        emit DividendDistribution.DividendAssetDowngradedToNative(DAI);
        harness.processRound(0, _holders());

        assertEq(harness.dividendToken(), address(0), "the payout asset is native from here on");
        assertEq(harness.pendingNative(), 0, "the whole buffer became the pot - native has no swap to cap");
        assertEq(holder.balance, 1 ether, "the holder was paid in native");
    }

    /// @dev The downgrade cannot be manufactured. A caller who supplies an unreachable floor gets a
    ///      conversion failure, however stale the round is: `minOut == 0` is what proves the pool itself
    ///      is gone rather than the caller's price.
    function test_aStaleRoundWithALiveePoolCannotBeForcedToDowngrade() public {
        _fundAndOpen(harness);
        skip(harness.STALE_ROUND_WINDOW());

        vm.expectRevert(DividendDistribution.DividendConversionFailed.selector);
        harness.processRound(1_000_000e18, _noHolders());
        assertEq(harness.dividendToken(), DAI, "still paying DAI");

        harness.processRound(0, _noHolders());
        assertEq(harness.dividendToken(), DAI, "a live pool converts and never downgrades");
        assertGt(harness.roundPot(), 0, "funded in DAI as usual");
    }

    /// @dev A residual left in the OLD asset has to reach holders before the asset can change, or the pot
    ///      would mix two currencies. So the first stale round after the pool dies drains the residual,
    ///      and only the round after that downgrades — against an empty pot.
    function test_anOldAssetResidualIsDrainedBeforeTheDowngrade() public {
        _fundAndOpen(harness);
        harness.processRound(0, _noHolders()); // freeze in DAI, pay nobody
        uint256 residual = harness.roundPot();
        assertGt(residual, 0, "a DAI pot nobody was paid from");

        skip(harness.PAYOUT_WINDOW() + 1);
        harness.processRound(0, _noHolders()); // the window expires and the residual rolls forward
        assertEq(harness.roundPot(), residual, "the residual seeds the next round");

        _killTheV2Router();
        vm.deal(address(this), 1 ether);
        harness.accrue{value: 1 ether}();
        skip(harness.STALE_ROUND_WINDOW());

        harness.processRound(0, _holders());
        assertEq(harness.dividendToken(), DAI, "the asset survives the residual drain");
        assertEq(IERC20(DAI).balanceOf(holder), residual, "the residual reached the holder in DAI");

        // Now the pot is empty, so the NEXT round downgrades — and "next round" means next round, not
        // another `STALE_ROUND_WINDOW`. The drain rolled the round over, which reset the stale clock;
        // `dividendPoolDead` is what carries the proof across that rollover. Without it every
        // `processRound` here would revert `DividendConversionFailed` for another 30 days while the
        // buffer sat unspendable.
        assertTrue(harness.dividendPoolDead(), "the drain recorded that the pool is gone");
        skip(harness.MIN_ROUND_DURATION() + 1);
        harness.processRound(0, _noHolders());
        assertEq(harness.dividendToken(), address(0), "downgraded once nothing was owed in the old asset");
        assertFalse(harness.dividendPoolDead(), "the flag is consumed by the downgrade it unlocked");
    }

    /// @dev The short-circuit is not a permanent downgrade licence: a pool that starts converting again
    ///      clears it, so a later failure has to re-earn a full `STALE_ROUND_WINDOW` like any other.
    function test_aPoolThatRecoversClearsTheDeadFlag() public {
        _fundAndOpen(harness);
        harness.processRound(0, _noHolders());
        uint256 residual = harness.roundPot();

        skip(harness.PAYOUT_WINDOW() + 1);
        harness.processRound(0, _noHolders());

        _killTheV2Router();
        vm.deal(address(this), 2 ether);
        harness.accrue{value: 1 ether}();
        skip(harness.STALE_ROUND_WINDOW());
        harness.processRound(0, _holders()); // drains the residual, sets the flag
        assertTrue(harness.dividendPoolDead(), "flagged");
        assertEq(IERC20(DAI).balanceOf(holder), residual, "residual paid in DAI");

        // The pool comes back before the downgrade round runs.
        vm.clearMockedCalls();
        skip(harness.MIN_ROUND_DURATION() + 1);
        harness.processRound(0, _noHolders());

        assertEq(harness.dividendToken(), DAI, "still paying DAI - the conversion worked");
        assertFalse(harness.dividendPoolDead(), "and the short-circuit is gone with it");
    }

    /// @dev Makes every V2 swap revert, whatever the price — the on-chain shape of a pool that is gone.
    function _killTheV2Router() internal {
        vm.mockCallRevert(
            DeploymentAddresses.UNIV2_ROUTER,
            abi.encodeWithSelector(IUniswapV2Router.swapExactETHForTokensSupportingFeeOnTransferTokens.selector),
            ""
        );
    }
}

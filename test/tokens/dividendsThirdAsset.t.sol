// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DividendDistributionLogic} from "src/tokens/DividendDistributionLogic.sol";
import {DividendDistribution} from "src/tokens/DividendDistribution.sol";
import {DeploymentAddressesEthereumMainnet as DeploymentAddresses} from "src/config/DeploymentAddresses.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IUniswapV2Router} from "src/interfaces/IUniswapV2Router.sol";
import {ERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {LivoDividendSwapRegistry} from "src/dividends/LivoDividendSwapRegistry.sol";
import {SwapRejection} from "src/interfaces/ILivoDividendSwapRegistry.sol";
import {installDividendSwapRegistry, DEFAULT_DIVIDEND_POOL_LIQUIDITY} from "test/helpers/DividendRegistryHelpers.sol";

/// @notice A bare `DividendDistributionLogic` with the token's hooks stubbed out. It exists so the
///         third-asset payout shape — the only one that actually performs a swap — can be exercised
///         against real Uniswap pools without dragging a launchpad, a graduator and a pool through
///         the test. Balances are set directly instead of being moved by transfers.
contract DividendHarness is DividendDistributionLogic {
    mapping(address => uint256) public balances;
    uint256 public eligibleSupply;

    function configure(address asset) external {
        _initializeDividends(asset);
    }

    function activate() external {
        _activateDividends();
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
///         through `LivoDividendSwapRegistry`, and pushed to holders in that asset. Any ERC20 with a
///         deep enough Uniswap V2 pair qualifies — there is no asset whitelist and no per-asset
///         approval, only the liquidity the registry measures.
contract DividendsThirdAssetTests is Test {
    uint256 internal constant BLOCKNUMBER = 23327777;
    address internal constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    DividendHarness internal harness;
    LivoDividendSwapRegistry internal registry;

    address internal holder = makeAddr("holder");
    address internal registryOwner = makeAddr("registryOwner");

    /// @dev `addLiquidityETH` refunds the unused ETH side to the caller.
    receive() external payable {}

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), BLOCKNUMBER);
        registry = installDividendSwapRegistry(registryOwner);
        harness = _harness(DAI);
    }

    /// @dev A harness paying `asset`, configured and ready to be activated.
    function _harness(address asset) internal returns (DividendHarness h) {
        h = new DividendHarness();
        h.configure(asset);
    }

    function _fundAndActivate(DividendHarness h) internal {
        h.setBalance(holder, 1_000e18);
        h.activate();
        vm.deal(address(this), 1 ether);
        h.accrue{value: 1 ether}();
    }

    /// @dev Lets a funded stream run all the way out, so the sole holder has accrued the whole of it.
    function _drain(DividendHarness h) internal {
        skip(h.DIVIDEND_DRIP_DURATION());
    }

    function _holders() internal view returns (address[] memory list) {
        list = new address[](1);
        list[0] = holder;
    }

    function _noHolders() internal pure returns (address[] memory list) {
        list = new address[](0);
    }

    //////////////////////// the payout shape //////////////////////

    function test_thirdAsset_boughtOnFundingAndStreamedToHolders() public {
        _fundAndActivate(harness);
        assertEq(harness.pendingNative(), 1 ether, "native buffered for the DAI payout");

        harness.processDividends(0, _noHolders());

        uint256 pot = harness.dividendsOwed();
        assertGt(pot, 0, "native converted into DAI");
        // A swapping payout converts at most `MAX_DIVIDEND_PER_CONVERSION` at a time; the rest stays
        // buffered.
        assertEq(harness.pendingNative(), 1 ether - harness.MAX_DIVIDEND_PER_CONVERSION(), "only the cap was converted");
        assertEq(IERC20(DAI).balanceOf(address(harness)), pot, "the distribution is a real DAI balance");
        // What every sweep path subtracts: an undelivered third-asset payout is COMMITTED, not stray, so
        // `rescueTokens` cannot hand holders' money to the owner while it is still owed.
        assertEq(harness.committedDividends(DAI), pot, "the whole of it is owed to holders");

        // It arrives as a SLOPE, not a drop: nothing is claimable at the instant of funding. (This call
        // converts the next capped slice too, which is why the total owed is re-read below.)
        harness.processDividends(0, _holders());
        assertEq(IERC20(DAI).balanceOf(holder), 0, "nothing accrues in zero seconds");

        _drain(harness);
        uint256 owed = harness.dividendsOwed();
        harness.processDividends(0, _holders());

        assertApproxEqRel(IERC20(DAI).balanceOf(holder), owed, 1e12, "sole holder paid the whole stream, in DAI");
        // What is still owed is the slice this very call converted, not an undelivered remainder of the
        // one that just drained: a payout call funds the next stream on its way through.
        assertApproxEqRel(
            harness.committedDividends(DAI), harness.dividendsOwed(), 1e12, "only the freshly-funded slice is owed"
        );
    }

    /// @dev The per-conversion cap bounds one sandwich, it does not cap what a token can ever pay:
    ///      whatever it leaves behind stays buffered and converts on a later call, so nothing strands.
    function test_thirdAsset_cappedConversionLeavesTheRemainderBuffered() public {
        _fundAndActivate(harness);
        uint256 cap = harness.MAX_DIVIDEND_PER_CONVERSION();

        harness.processDividends(0, _holders());
        assertEq(harness.pendingNative(), 1 ether - cap, "the first conversion took exactly the cap");

        harness.processDividends(0, _noHolders());
        assertEq(harness.pendingNative(), 1 ether - 2 * cap, "and the next one takes the next slice");
    }

    //////////////////////// the liquidity proof //////////////////////

    /// @dev THE eligibility rule, and the only one. Any ERC20 is fair game as long as the pool the
    ///      creator names for it actually exists and is worth swapping against — no whitelist, no admin.
    function test_anyErc20WithADeepPoolIsConfigurable() public {
        assertEq(_harness(DAI).dividendToken(), DAI, "DAI");
        assertEq(_harness(USDC).dividendToken(), USDC, "USDC");
    }

    /// @dev An asset nobody has ever made a market for is refused at creation, not left to accrue into a
    ///      buffer that could never be converted — the failure mode a clone cannot be patched out of.
    function test_anAssetWithNoPoolAtAllIsRejected() public {
        address ghost = address(new GhostToken());

        DividendHarness h = new DividendHarness();
        vm.expectRevert(
            abi.encodeWithSelector(DividendDistribution.DividendAssetNotSupported.selector, SwapRejection.NoPair)
        );
        h.configure(ghost);
    }

    /// @dev A pool that EXISTS but is too thin is refused just the same. The floor is denominated in the
    ///      quote asset, so it means the same thing whatever the payout asset's own decimals are.
    function test_aPoolTooThinToSwapAgainstIsRejected() public {
        GhostToken thin = new GhostToken();
        IUniswapV2Router router = IUniswapV2Router(DeploymentAddresses.UNIV2_ROUTER);

        // A real pair on the real factory, seeded with less than the floor.
        uint256 seeded = DEFAULT_DIVIDEND_POOL_LIQUIDITY / 2;
        vm.deal(address(this), seeded);
        thin.approve(address(router), type(uint256).max);
        router.addLiquidityETH{value: seeded}(address(thin), 500_000e18, 0, 0, address(this), block.timestamp);

        DividendHarness h = new DividendHarness();
        vm.expectRevert(
            abi.encodeWithSelector(
                DividendDistribution.DividendAssetNotSupported.selector, SwapRejection.InsufficientLiquidity
            )
        );
        h.configure(address(thin));

        // Top the same pair up over the floor and the very same asset becomes eligible. Nothing about
        // the ASSET changed — only its liquidity, which is the whole rule.
        vm.deal(address(this), seeded + 1);
        router.addLiquidityETH{value: seeded + 1}(address(thin), 500_000e18, 0, 0, address(this), block.timestamp);

        DividendHarness ok = new DividendHarness();
        ok.configure(address(thin));
        assertEq(ok.dividendToken(), address(thin), "eligible once the pool is deep enough");
    }

    /// @dev An asset whose only liquidity lives on V3 or V4 has no V2 pair, so it is refused — the
    ///      deliberate cost of a V2-only registry, and the reason the registry is upgradeable.
    function test_anAssetWithoutAV2PairIsRejectedEvenIfItTradesElsewhere() public {
        DividendHarness h = new DividendHarness();
        vm.expectRevert(
            abi.encodeWithSelector(DividendDistribution.DividendAssetNotSupported.selector, SwapRejection.NoPair)
        );
        h.configure(makeAddr("v4OnlyToken"));
    }

    /// @dev Native and the token itself buy nothing, so they never touch the registry.
    function test_nativeAndSelfTokenNeedNoProof() public {
        DividendHarness nativeH = new DividendHarness();
        nativeH.configure(address(0));
        assertEq(nativeH.dividendToken(), address(0), "native configured");

        DividendHarness selfH = new DividendHarness();
        selfH.configure(selfH.DIVIDEND_SELF_TOKEN());
        assertEq(selfH.dividendToken(), address(selfH), "the sentinel resolved to the token itself");
    }

    //////////////////////// what the registry buys //////////////////////

    /// @dev The point of putting the rule behind a proxy: a threshold raised AFTER a token was created
    ///      still governs it. A creation-time check compiled into an unpatchable clone could not.
    function test_aRaisedThresholdRefusesAssetsThatUsedToQualify() public {
        assertTrue(registry.isSwapSupported(registry.nativeQuoteToken(), DAI), "DAI qualifies today");

        vm.prank(registryOwner);
        registry.setDefaultThreshold(type(uint128).max);

        DividendHarness h = new DividendHarness();
        vm.expectRevert(
            abi.encodeWithSelector(
                DividendDistribution.DividendAssetNotSupported.selector, SwapRejection.InsufficientLiquidity
            )
        );
        h.configure(DAI);
    }

    /// @dev The one admin veto, and it reaches tokens that ALREADY exist: an asset blacklisted after a
    ///      token was configured for it stops converting on the next freeze. The buffer is not lost —
    ///      it stays put, and the dead-pool escape eventually downgrades the token to native.
    function test_blacklistingAnAssetStopsAnExistingTokenFromConverting() public {
        _fundAndActivate(harness);

        // Read the constant BEFORE the prank: `vm.prank` applies to the next call, view calls included.
        uint8 blacklisted = registry.TRUST_BLACKLISTED();
        vm.prank(registryOwner);
        registry.setTrustStatus(DAI, blacklisted);

        vm.expectRevert(DividendDistribution.DividendConversionFailed.selector);
        harness.processDividends(0, _noHolders());
        assertEq(harness.pendingNative(), 1 ether, "the buffer is untouched, not seized");

        uint8 unknown = registry.TRUST_UNKNOWN();
        vm.prank(registryOwner);
        registry.setTrustStatus(DAI, unknown);
        harness.processDividends(0, _noHolders());
        assertGt(harness.dividendsOwed(), 0, "and it converts again once the veto is lifted");
    }

    /// @dev The registry is a swap venue, not a vault: it forwards everything it buys inside the same
    ///      call and is empty before and after.
    function test_theRegistryHoldsNothing() public {
        _fundAndActivate(harness);
        harness.processDividends(0, _noHolders());

        assertEq(address(registry).balance, 0, "no native retained");
        assertEq(IERC20(DAI).balanceOf(address(registry)), 0, "no asset retained");
        assertEq(IERC20(DAI).balanceOf(address(harness)), harness.dividendsOwed(), "it all reached the token");
    }

    //////////////////////// conversion failures //////////////////////

    /// @dev `minOut` is what bounds the swap. A floor the pool cannot meet leaves the buffer untouched —
    ///      and says so precisely: the money IS there, the swap is the problem, so the keeper is told to
    ///      retry rather than to wait for earnings it already has.
    function test_aMissedSlippageFloorLeavesTheBufferUntouched() public {
        _fundAndActivate(harness);

        vm.expectRevert(DividendDistribution.DividendConversionFailed.selector);
        harness.processDividends(1_000_000e18, _noHolders());

        assertEq(harness.pendingNative(), 1 ether, "nothing was spent");
        assertEq(harness.dividendsOwed(), 0, "and no stream was funded");

        harness.processDividends(0, _noHolders());
        assertGt(harness.dividendsOwed(), 0, "the same buffer converts once the floor is reachable");
    }

    /// @dev A token that simply has not earned enough yet reports the OTHER error: the keeper is told to
    ///      wait, not sent looking for a broken pool.
    function test_aBelowThresholdBufferReportsBelowDividendThreshold() public {
        harness.setBalance(holder, 1_000e18);
        harness.activate();
        vm.deal(address(this), 1 wei);
        harness.accrue{value: 1 wei}();

        vm.expectRevert(DividendDistribution.BelowDividendThreshold.selector);
        harness.processDividends(0, _noHolders());
    }

    /// @dev A payout asset that returns a non-boolean word from `transfer` must be TOLERATED, not
    ///      decoded strictly. `abi.decode(_, (bool))` reverts on any word above 1, which is legal for a
    ///      non-standard ERC20 — and a revert inside `_payDividend` is precisely what the skip-don't-revert
    ///      contract exists to prevent: it would take down the whole `processDividends` batch and
    ///      `claimDividends` for everyone.
    function test_aNonBooleanTransferReturnDoesNotBrickTheBatch() public {
        _fundAndActivate(harness);
        harness.processDividends(0, _noHolders()); // buy DAI, fund the stream
        _drain(harness);

        uint256 owed = harness.previewDividend(holder);
        assertGt(owed, 0, "the holder has accrued the stream");
        vm.mockCall(DAI, abi.encodeWithSelector(IERC20.transfer.selector), abi.encode(uint256(2)));

        vm.expectEmit(true, true, true, true, address(harness));
        emit DividendDistribution.DividendPaid(holder, DAI, owed);
        harness.processDividends(0, _holders());

        assertEq(harness.previewDividend(holder), 0, "the payout was accepted, not skipped");
    }

    //////////////////////// the dead-pool escape //////////////////////

    /// @dev The replacement for an admin-curated route override: nobody can repair a dead pool, so the
    ///      token repairs itself. Once the token has gone `STALE_DIVIDEND_WINDOW` without a distribution
    ///      AND the swap cannot execute at ANY price, the payout asset is permanently downgraded to
    ///      native — the one asset that needs no pool. Without it, a buffer owed to holders would strand
    ///      forever.
    function test_aPermanentlyDeadPoolDowngradesThePayoutToNative() public {
        _fundAndActivate(harness);
        _killTheV2Router();

        // Not yet: a live token retries rather than downgrading.
        vm.expectRevert(DividendDistribution.DividendConversionFailed.selector);
        harness.processDividends(0, _noHolders());

        skip(harness.STALE_DIVIDEND_WINDOW() + 1);

        vm.expectEmit(true, false, false, false, address(harness));
        emit DividendDistribution.DividendAssetDowngradedToNative(DAI);
        harness.processDividends(0, _noHolders());

        assertEq(harness.dividendToken(), address(0), "the payout asset is native from here on");
        assertEq(harness.pendingNative(), 0, "the whole buffer funded the stream - native has no swap to cap");
        assertEq(harness.dividendsOwed(), 1 ether, "and it is owed in native now");

        _drain(harness);
        harness.processDividends(0, _holders());
        assertApproxEqRel(holder.balance, 1 ether, 1e12, "the holder was paid in native");
    }

    /// @dev The downgrade cannot be manufactured. A caller who supplies an unreachable floor gets a
    ///      conversion failure, however stale the token is: `minOut == 0` is what proves the pool itself
    ///      is gone rather than the caller's price.
    function test_aStaleTokenWithALivePoolCannotBeForcedToDowngrade() public {
        _fundAndActivate(harness);
        skip(harness.STALE_DIVIDEND_WINDOW() + 1);

        vm.expectRevert(DividendDistribution.DividendConversionFailed.selector);
        harness.processDividends(1_000_000e18, _noHolders());
        assertEq(harness.dividendToken(), DAI, "still paying DAI");

        harness.processDividends(0, _noHolders());
        assertEq(harness.dividendToken(), DAI, "a live pool converts and never downgrades");
        assertGt(harness.dividendsOwed(), 0, "funded in DAI as usual");
    }

    /// @dev What the downgrade does to money already accrued in the DEAD asset: it writes it off, by
    ///      bumping `dividendEpoch`. `Acct.rewards` is a bare number of units with no asset attached, so
    ///      carrying it across would pay an old-asset debt out of a new-asset balance at a 1:1 unit
    ///      ratio between two assets that need not even share decimals. Holders had the whole
    ///      `STALE_DIVIDEND_WINDOW` to claim — claiming never depended on the pool being alive.
    function test_theDowngradeWritesOffUnclaimedAccrualsInTheDeadAsset() public {
        _fundAndActivate(harness);
        harness.processDividends(0, _noHolders()); // a real DAI stream
        _drain(harness);

        uint256 daiOwed = harness.previewDividend(holder);
        assertGt(daiOwed, 0, "the holder accrued DAI it never claimed");

        _killTheV2Router();
        vm.deal(address(this), 1 ether);
        harness.accrue{value: 1 ether}();
        skip(harness.STALE_DIVIDEND_WINDOW() + 1);
        // The whole native buffer — the fresh ether plus whatever the capped first conversion left.
        uint256 buffered = harness.pendingNative();
        harness.processDividends(0, _noHolders());

        assertEq(harness.dividendToken(), address(0), "downgraded");
        assertEq(harness.previewDividend(holder), 0, "the DAI claim was written off, not repaid in native");
        assertEq(harness.dividendsOwed(), buffered, "only the newly-streamed native is owed");
        // The stranded DAI stops being committed, which is the only way it is ever recoverable at all.
        assertEq(harness.committedDividends(DAI), 0, "the dead asset is no longer holders' money");

        // And the holder accrues normally from here, in the new asset.
        _drain(harness);
        assertApproxEqRel(harness.previewDividend(holder), buffered, 1e12, "rebased onto native");
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

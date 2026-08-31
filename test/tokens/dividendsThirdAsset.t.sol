// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DividendDistributionLogic} from "src/tokens/DividendDistributionLogic.sol";
import {DividendDistribution} from "src/tokens/DividendDistribution.sol";
import {SwapRouteRegistry} from "src/registries/SwapRouteRegistry.sol";
import {DeploymentAddressesEthereumMainnet as DeploymentAddresses} from "src/config/DeploymentAddresses.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {DividendRoute, DividendVenue} from "src/types/DividendRoute.sol";
import {
    noDividendRoutes,
    v2DividendRoute,
    v3DividendRoute,
    v4DividendRoute
} from "test/helpers/DividendRouteHelpers.sol";

/// @notice A bare `DividendDistributionLogic` with the token's four hooks stubbed out. It exists so the
///         third-asset payout shape — the only one that actually performs a swap — can be exercised
///         against real Uniswap pools without dragging a launchpad, a graduator and a pool through
///         the test. Balances are set directly instead of being moved by transfers.
contract DividendHarness is DividendDistributionLogic {
    address internal immutable ROUTE_REGISTRY;

    mapping(address => uint256) public balances;
    uint256 public eligibleSupply;

    constructor(address registry) {
        ROUTE_REGISTRY = registry;
    }

    function configure(address[3] memory assets, uint16[3] memory weights, DividendRoute[3] memory routes) external {
        _initializeDividends(assets, weights, routes);
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

    function _dividendRouteRegistry() internal view override returns (address) {
        return ROUTE_REGISTRY;
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

    function _dividendEarningsMayStillArrive() internal pure override returns (bool) {
        return true;
    }

    receive() external payable {}
}

/// @notice The third-token payout shape: an accrued native pot is converted into an arbitrary ERC20 on
///         the pool the creator named at creation, and pushed to holders in that asset. Any ERC20 with a
///         Uniswap V2, V3 or V4 pool qualifies — there is no asset whitelist.
contract DividendsThirdAssetTests is Test {
    uint256 internal constant BLOCKNUMBER = 23327777;
    address internal constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    SwapRouteRegistry internal registry;
    DividendHarness internal harness;

    address internal owner = makeAddr("owner");
    address internal routeAdmin = makeAddr("routeAdmin");
    address internal holder = makeAddr("holder");

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), BLOCKNUMBER);

        registry = new SwapRouteRegistry(owner);
        vm.prank(owner);
        registry.setAdmin(routeAdmin, true);

        harness = _harness(DAI, v2DividendRoute(address(0)));
    }

    /// @dev A single-leg harness paying `asset` through `route`, funded and with its round open.
    function _harness(address asset, DividendRoute memory route) internal returns (DividendHarness h) {
        h = new DividendHarness(address(registry));
        DividendRoute[3] memory routes = noDividendRoutes();
        routes[0] = route;
        h.configure([asset, address(0), address(0)], [uint16(10_000), 0, 0], routes);
    }

    function _fundAndOpen(DividendHarness h) internal {
        h.setBalance(holder, 1_000e18);
        h.openRound();
        vm.deal(address(this), 1 ether);
        h.accrue{value: 1 ether}();
        skip(h.MIN_ROUND_DURATION() + 1);
    }

    function test_thirdAsset_boughtOnFreezeAndPaidToHolders() public {
        _fundAndOpen(harness);
        assertEq(harness.pendingNative(0), 1 ether, "native buffered for the DAI leg");

        harness.processDividends([uint256(0), 0, 0]);

        uint256 pot = harness.roundPot(0);
        assertGt(pot, 0, "native converted into DAI");
        // A swapping leg converts at most `MAX_DIVIDEND_PER_FREEZE` per freeze; the rest stays buffered.
        assertEq(harness.pendingNative(0), 1 ether - harness.MAX_DIVIDEND_PER_FREEZE(), "only the cap was converted");
        assertEq(IERC20(DAI).balanceOf(address(harness)), pot, "the pot is a real DAI balance");
        // What every sweep path subtracts: an undelivered third-asset pot is COMMITTED, not stray, so
        // `rescueTokens` cannot hand holders' money to the owner while it is still owed.
        assertEq(harness.committedDividends(DAI), pot, "the whole pot is owed to holders");

        address[] memory holders = new address[](1);
        holders[0] = holder;
        harness.distributeDividends(holders);

        assertEq(IERC20(DAI).balanceOf(holder), pot, "sole holder paid the whole pot, in DAI");
        assertEq(harness.committedDividends(DAI), 0, "nothing left owed");
    }

    /// @dev The V2 route's optional intermediate hop: WETH -> USDC -> DAI instead of the direct pair.
    function test_thirdAsset_v2RouteWithAnIntermediateHop() public {
        DividendHarness hop = _harness(DAI, v2DividendRoute(USDC));
        _fundAndOpen(hop);

        hop.processDividends([uint256(0), 0, 0]);

        assertGt(hop.roundPot(0), 0, "the hop route funded the leg");
        assertEq(IERC20(DAI).balanceOf(address(hop)), hop.roundPot(0), "the pot is a real DAI balance");
    }

    /// @dev A Uniswap-V3-only asset is a first-class dividend asset: the route names the pool's fee tier
    ///      and the swap goes through the universal router.
    function test_thirdAsset_v3Route() public {
        DividendHarness v3 = _harness(USDC, v3DividendRoute(500));
        _fundAndOpen(v3);

        v3.processDividends([uint256(0), 0, 0]);

        assertGt(v3.roundPot(0), 0, "the V3 pool funded the leg");
        assertEq(IERC20(USDC).balanceOf(address(v3)), v3.roundPot(0), "the pot is a real USDC balance");
    }

    /// @dev Same for a Uniswap-V4 pool, keyed by fee + tick spacing + hooks rather than a fee tier alone.
    function test_thirdAsset_v4Route() public {
        DividendHarness v4 = _harness(USDC, v4DividendRoute(500, 10, address(0)));
        _fundAndOpen(v4);

        v4.processDividends([uint256(0), 0, 0]);

        assertGt(v4.roundPot(0), 0, "the V4 pool funded the leg");
        assertEq(IERC20(USDC).balanceOf(address(v4)), v4.roundPot(0), "the pot is a real USDC balance");
    }

    /// @dev The per-freeze cap bounds one sandwich, it does not cap what a leg can ever pay: whatever
    ///      it leaves behind stays buffered and converts in a later round, so nothing strands.
    function test_thirdAsset_cappedFreezeLeavesTheRemainderForTheNextRound() public {
        _fundAndOpen(harness);
        uint256 cap = harness.MAX_DIVIDEND_PER_FREEZE();

        harness.processDividends([uint256(0), 0, 0]);
        assertEq(harness.pendingNative(0), 1 ether - cap, "the first freeze took exactly the cap");

        address[] memory holders = new address[](1);
        holders[0] = holder;
        harness.distributeDividends(holders);
        harness.finalizeRound();

        skip(harness.MIN_ROUND_DURATION() + 1);
        harness.processDividends([uint256(0), 0, 0]);
        assertEq(harness.pendingNative(0), 1 ether - 2 * cap, "the next round takes the next slice");
    }

    /// @dev The failed conversion is ANNOUNCED, and only that case is. An empty or below-threshold
    ///      buffer is the normal quiet path and stays silent, so this event firing always means a leg
    ///      that held enough and still did not fund — the one thing an operator can act on.
    function test_aFailedConversionEmitsTheDiagnosticEvent() public {
        _fundAndOpen(harness);

        vm.expectEmit(true, true, true, false, address(harness));
        emit DividendDistribution.DividendLegConversionFailed(1, 0, DAI);
        vm.expectRevert(DividendDistribution.DividendConversionFailed.selector);
        harness.processDividends([uint256(1_000_000e18), 0, 0]);
    }

    /// @dev A leg that simply has not earned enough yet reports the OTHER error, and says nothing: the
    ///      keeper is told to wait, not sent looking for a broken pool.
    function test_aBelowThresholdLegIsQuietAndReportsNoLegAboveThreshold() public {
        harness.setBalance(holder, 1_000e18);
        harness.openRound();
        vm.deal(address(this), 1 wei);
        harness.accrue{value: 1 wei}();
        skip(harness.MIN_ROUND_DURATION() + 1);

        vm.expectRevert(DividendDistribution.NoLegAboveThreshold.selector);
        harness.processDividends([uint256(0), 0, 0]);
    }

    /// @dev `minOut` is what bounds the swap. A floor the pool cannot meet leaves the leg unfrozen with
    ///      its buffer untouched — and says so precisely: the money IS there, the swap is the problem, so
    ///      the keeper is told to retry rather than to wait for earnings it already has.
    function test_thirdAsset_aMissedSlippageFloorLeavesTheLegUnfrozen() public {
        _fundAndOpen(harness);

        vm.expectRevert(DividendDistribution.DividendConversionFailed.selector);
        harness.processDividends([uint256(1_000_000e18), 0, 0]);

        assertEq(harness.pendingNative(0), 1 ether, "nothing was spent");
        assertEq(harness.frozenLegs(), 0, "no leg froze");

        harness.processDividends([uint256(0), 0, 0]);
        assertGt(harness.roundPot(0), 0, "the same buffer converts once the floor is reachable");
    }

    /// @dev A route pointing at a pool that does not exist cannot brick the token: the swap fails, the
    ///      leg keeps its buffer, and the token's OTHER legs still freeze and pay.
    function test_deadRouteSkipsItsLegWithoutBlockingTheOthers() public {
        DividendHarness split = new DividendHarness(address(registry));
        DividendRoute[3] memory routes = noDividendRoutes();
        routes[1] = v3DividendRoute(3000); // no WETH/`ghost` pool at any fee tier
        address ghost = address(new GhostToken());
        split.configure([address(0), ghost, address(0)], [uint16(5_000), 5_000, 0], routes);

        split.setBalance(holder, 1_000e18);
        split.openRound();
        vm.deal(address(this), 1 ether);
        split.accrue{value: 1 ether}();
        skip(split.MIN_ROUND_DURATION() + 1);

        split.processDividends([uint256(0), 0, 0]);

        assertEq(split.frozenLegs(), 1, "only the native leg froze");
        assertEq(split.pendingNative(1), 0.5 ether, "the dead leg kept every wei of its buffer");
        assertGt(split.roundPot(0), 0, "the native leg paid as usual");
    }

    /// @dev The registry is no longer a gate but it is still a repair hatch: an entry for the asset
    ///      overrides the creator's route, which is how a leg whose pool died is pointed somewhere alive.
    function test_registryRouteOverridesTheCreatorRoute() public {
        // Fee tier 1234 is not enabled on the V3 factory, so this route has no pool at all — the same
        // shape as a creator's pool that has since died.
        DividendHarness dead = _harness(DAI, v3DividendRoute(1234));
        _fundAndOpen(dead);

        // The sole leg cannot convert, so there is nothing to freeze at all — reported as a conversion
        // failure, not as "no earnings yet", which is what points an operator at the dead pool.
        vm.expectRevert(DividendDistribution.DividendConversionFailed.selector);
        dead.processDividends([uint256(0), 0, 0]);
        assertEq(dead.pendingNative(0), 1 ether, "the buffer is intact");

        address[] memory path = new address[](2);
        path[0] = DeploymentAddresses.WETH;
        path[1] = DAI;
        vm.prank(routeAdmin);
        registry.setRoute(DAI, path);

        dead.processDividends([uint256(0), 0, 0]);
        assertGt(dead.roundPot(0), 0, "the curated route repaired the leg");
        assertEq(IERC20(DAI).balanceOf(address(dead)), dead.roundPot(0), "paid in DAI all the same");
    }

    /// @dev Route validation is limited to what this chain could never execute at all. A V3 pool is keyed
    ///      by its fee tier and a V4 pool by its tick spacing; zero is not a pool, it is a typo that would
    ///      leave the leg accruing forever on a clone nobody can patch.
    function test_routesThatCouldNeverExecuteAreRejectedAtConfiguration() public {
        DividendRoute[3] memory routes = noDividendRoutes();

        routes[0] = v3DividendRoute(0);
        DividendHarness a = new DividendHarness(address(registry));
        vm.expectRevert(DividendDistribution.UnsupportedDividendAsset.selector);
        a.configure([DAI, address(0), address(0)], [uint16(10_000), 0, 0], routes);

        routes[0] = v4DividendRoute(500, 0, address(0));
        DividendHarness b = new DividendHarness(address(registry));
        vm.expectRevert(DividendDistribution.UnsupportedDividendAsset.selector);
        b.configure([DAI, address(0), address(0)], [uint16(10_000), 0, 0], routes);
    }

    /// @dev An asset with no curated route at all is now perfectly configurable — that is the point of
    ///      the feature. Only the leg's own route decides whether it can be funded.
    function test_anyErc20IsConfigurableWithoutACuratedRoute() public {
        assertFalse(registry.hasRoute(DAI), "no curated route for DAI");
        DividendHarness h = _harness(DAI, v2DividendRoute(address(0)));
        assertEq(h.dividendTokens(0), DAI, "configured anyway");
    }

    /// @dev Two legs on different cadences: the heavy one crosses the threshold first and is frozen
    ///      alone, while the light one keeps accruing. Forcing them together would either gate on the
    ///      slowest leg or push dust every round.
    function test_legsFreezeIndependently() public {
        DividendRoute[3] memory routes = noDividendRoutes();
        routes[1] = v2DividendRoute(address(0));

        DividendHarness split = new DividendHarness(address(registry));
        split.configure([address(0), DAI, address(0)], [uint16(9_000), 1_000, 0], routes);
        split.setBalance(holder, 1_000e18);
        split.openRound();

        vm.deal(address(this), 1 ether);
        split.accrue{value: 1 ether}();
        assertEq(split.pendingNative(0), 0.9 ether, "90% to the native leg");
        assertEq(split.pendingNative(1), 0.1 ether, "10% to the DAI leg");

        skip(split.MIN_ROUND_DURATION() + 1);
        split.processDividends([uint256(0), 0, 0]);

        // The DAI leg sits exactly AT the 0.1 ETH threshold, so both freeze here; drop it under and only
        // the native leg qualifies.
        assertEq(split.frozenLegs(), 3, "both legs frozen at this funding level");

        DividendHarness lopsided = new DividendHarness(address(registry));
        lopsided.configure([address(0), DAI, address(0)], [uint16(9_900), 100, 0], routes);
        lopsided.setBalance(holder, 1_000e18);
        lopsided.openRound();
        vm.deal(address(this), 1 ether);
        lopsided.accrue{value: 1 ether}();
        skip(lopsided.MIN_ROUND_DURATION() + 1);
        lopsided.processDividends([uint256(0), 0, 0]);

        assertEq(lopsided.frozenLegs(), 1, "only the leg over its threshold froze");
        assertEq(lopsided.pendingNative(1), 0.01 ether, "the light leg keeps accruing");
    }
}

/// @notice An ERC20 with no pool anywhere, standing in for an asset whose route has died.
contract GhostToken {
    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }
}

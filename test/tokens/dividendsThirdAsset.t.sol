// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DividendDistribution} from "src/tokens/DividendDistribution.sol";
import {SwapRouteRegistry} from "src/registries/SwapRouteRegistry.sol";
import {DeploymentAddressesEthereumMainnet as DeploymentAddresses} from "src/config/DeploymentAddresses.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/// @notice A bare `DividendDistribution` with the token's four hooks stubbed out. It exists so the
///         third-asset payout shape — the only one that actually performs a swap — can be exercised
///         against a real Uniswap V2 pool without dragging a launchpad, a graduator and a pool through
///         the test. Balances are set directly instead of being moved by transfers.
contract DividendHarness is DividendDistribution {
    address internal immutable ROUTE_REGISTRY;

    mapping(address => uint256) public balances;
    uint256 public eligibleSupply;

    constructor(address registry) {
        ROUTE_REGISTRY = registry;
    }

    function configure(address[3] memory assets, uint16[3] memory weights) external {
        _initializeDividends(assets, weights);
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

/// @notice The third-token payout shape: an accrued native pot is converted into an arbitrary ERC20
///         through the protocol's curated route and pushed to holders in that asset.
contract DividendsThirdAssetTests is Test {
    uint256 internal constant BLOCKNUMBER = 23327777;
    address internal constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;

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

        address[] memory path = new address[](2);
        path[0] = DeploymentAddresses.WETH;
        path[1] = DAI;
        vm.prank(routeAdmin);
        registry.setRoute(DAI, path);

        harness = new DividendHarness(address(registry));
        harness.configure([DAI, address(0), address(0)], [uint16(10_000), 0, 0]);
    }

    function test_thirdAsset_boughtOnFreezeAndPaidToHolders() public {
        harness.setBalance(holder, 1_000e18);
        harness.openRound();

        vm.deal(address(this), 1 ether);
        harness.accrue{value: 1 ether}();
        assertEq(harness.pendingNative(0), 1 ether, "native buffered for the DAI leg");

        skip(harness.MIN_ROUND_DURATION() + 1);
        harness.processDividends([uint256(0), 0, 0]);

        uint256 pot = harness.roundPot(0);
        assertGt(pot, 0, "native converted into DAI");
        // A swapping leg converts at most `MAX_DIVIDEND_PER_FREEZE` per freeze; the rest stays buffered.
        assertEq(harness.pendingNative(0), 1 ether - harness.MAX_DIVIDEND_PER_FREEZE(), "only the cap was converted");
        assertEq(IERC20(DAI).balanceOf(address(harness)), pot, "the pot is a real DAI balance");

        address[] memory holders = new address[](1);
        holders[0] = holder;
        harness.distributeDividends(holders);

        assertEq(IERC20(DAI).balanceOf(holder), pot, "sole holder paid the whole pot, in DAI");
        assertEq(harness.committedDividends(DAI), 0, "nothing left owed");
    }

    /// @dev The per-freeze cap bounds one sandwich, it does not cap what a leg can ever pay: whatever
    ///      it leaves behind stays buffered and converts in a later round, so nothing strands.
    function test_thirdAsset_cappedFreezeLeavesTheRemainderForTheNextRound() public {
        harness.setBalance(holder, 1_000e18);
        harness.openRound();

        vm.deal(address(this), 1 ether);
        harness.accrue{value: 1 ether}();
        uint256 cap = harness.MAX_DIVIDEND_PER_FREEZE();

        skip(harness.MIN_ROUND_DURATION() + 1);
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

    /// @dev The route is protocol-owned, but `minOut` is what actually bounds the swap — an admin who
    ///      repoints a route cannot make the conversion return less than the caller accepted.
    function test_thirdAsset_respectsTheSlippageFloor() public {
        harness.setBalance(holder, 1_000e18);
        harness.openRound();

        vm.deal(address(this), 1 ether);
        harness.accrue{value: 1 ether}();
        skip(harness.MIN_ROUND_DURATION() + 1);

        vm.expectRevert(); // the router's own INSUFFICIENT_OUTPUT_AMOUNT
        harness.processDividends([uint256(1_000_000e18), 0, 0]);
    }

    /// @dev An unroutable asset must be refused at configuration time: a clone cannot be patched, so a
    ///      leg that can never be funded would accrue forever.
    function test_unroutableAssetRejectedAtConfiguration() public {
        DividendHarness fresh = new DividendHarness(address(registry));
        vm.expectRevert(DividendDistribution.UnsupportedDividendAsset.selector);
        fresh.configure([makeAddr("noRoute"), address(0), address(0)], [uint16(10_000), 0, 0]);
    }

    /// @dev Two legs on different cadences: the heavy one crosses the threshold first and is frozen
    ///      alone, while the light one keeps accruing. Forcing them together would either gate on the
    ///      slowest leg or push dust every round.
    function test_legsFreezeIndependently() public {
        DividendHarness split = new DividendHarness(address(registry));
        split.configure([address(0), DAI, address(0)], [uint16(9_000), 1_000, 0]);
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
        lopsided.configure([address(0), DAI, address(0)], [uint16(9_900), 100, 0]);
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

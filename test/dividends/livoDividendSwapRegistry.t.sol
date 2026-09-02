// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {OwnableUpgradeable} from "lib/openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";

import {LivoDividendSwapRegistry} from "src/dividends/LivoDividendSwapRegistry.sol";
import {SwapRejection, Hop} from "src/interfaces/ILivoDividendSwapRegistry.sol";
import {IUniswapV2Router} from "src/interfaces/IUniswapV2Router.sol";
import {DeploymentAddressesEthereumMainnet as DeploymentAddresses} from "src/config/DeploymentAddresses.sol";
import {installDividendSwapRegistry, DEFAULT_DIVIDEND_POOL_LIQUIDITY} from "test/helpers/DividendRegistryHelpers.sol";

contract Ghost is ERC20 {
    constructor() ERC20("Ghost", "GHOST") {
        _mint(msg.sender, 1_000_000e18);
    }
}

/// @notice The eligibility gate and swap venue for third-asset dividends, tested on its own. The rule it
///         enforces is deliberately permissionless — a deep enough Uniswap V2 pair, nothing else — so
///         most of what is asserted here is what the admin levers CANNOT do.
contract LivoDividendSwapRegistryTests is Test {
    uint256 internal constant BLOCKNUMBER = 23327777;
    address internal constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

    /// @dev The mainnet V4 pools the route tests cross, live at `BLOCKNUMBER`. Hookless and static-fee,
    ///      unlike Robinhood Chain's xStock pools — the encoding under test is the same either way.
    uint24 internal constant V4_FEE_005 = 500;
    int24 internal constant V4_SPACING_10 = 10;
    uint24 internal constant V4_FEE_001 = 100;
    int24 internal constant V4_SPACING_1 = 1;

    LivoDividendSwapRegistry internal registry;
    address internal weth;

    address internal owner = makeAddr("owner");
    address internal admin = makeAddr("admin");
    address internal stranger = makeAddr("stranger");
    address internal recipient = makeAddr("recipient");

    /// @dev `addLiquidityETH` refunds the unused ETH side to the caller.
    receive() external payable {}

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), BLOCKNUMBER);
        registry = installDividendSwapRegistry(owner);
        weth = registry.nativeQuoteToken();

        vm.prank(owner);
        registry.setAdmin(admin, true);
    }

    //////////////////////// the rule //////////////////////

    /// @dev The whole eligibility rule: liquidity, measured live, with nobody's approval. An asset the
    ///      admins have never heard of passes as readily as one they have.
    function test_anyAssetWithADeepPairQualifiesUnprompted() public view {
        assertTrue(registry.isSwapSupported(weth, DAI), "DAI");
        assertTrue(registry.isSwapSupported(weth, USDC), "USDC");
        assertEq(registry.trustStatus(DAI), registry.TRUST_UNKNOWN(), "and neither is whitelisted");
    }

    function test_anAssetWithNoPairIsRejectedWithNoPair() public {
        (bool ok,, SwapRejection why) = registry.checkSwapSupported(weth, address(new Ghost()));
        assertFalse(ok);
        assertEq(uint8(why), uint8(SwapRejection.NoPair));
    }

    /// @dev A pair that exists but is too thin reports a DIFFERENT reason from one that does not exist.
    ///      The distinction is the whole point of the detailed view: "seed more liquidity" and "you have
    ///      the wrong address" are different problems for a creator.
    function test_aThinPairIsRejectedWithInsufficientLiquidity() public {
        Ghost thin = new Ghost();
        IUniswapV2Router router = IUniswapV2Router(DeploymentAddresses.UNIV2_ROUTER);

        uint256 seeded = DEFAULT_DIVIDEND_POOL_LIQUIDITY / 2;
        vm.deal(address(this), seeded);
        thin.approve(address(router), type(uint256).max);
        router.addLiquidityETH{value: seeded}(address(thin), 500_000e18, 0, 0, address(this), block.timestamp);

        (bool ok,, SwapRejection why) = registry.checkSwapSupported(weth, address(thin));
        assertFalse(ok);
        assertEq(uint8(why), uint8(SwapRejection.InsufficientLiquidity));

        (address pair, uint256 depth) = registry.pairFor(weth, address(thin));
        assertTrue(pair != address(0), "the pair does exist");
        assertEq(depth, seeded, "and its depth is what was seeded");
    }

    /// @dev `whitelisted` is a UI badge. If it ever starts gating eligibility, the feature has quietly
    ///      become a curated list — which is exactly what this design refuses to be.
    function test_whitelistingChangesNothingAboutEligibility() public {
        assertTrue(registry.isSwapSupported(weth, DAI), "eligible while unknown");

        uint8 whitelisted = registry.TRUST_WHITELISTED();
        vm.prank(admin);
        registry.setTrustStatus(DAI, whitelisted);

        (bool ok, uint8 trust,) = registry.checkSwapSupported(weth, DAI);
        assertTrue(ok, "still eligible");
        assertEq(trust, whitelisted, "the badge is reported, not required");
    }

    /// @dev The one veto.
    function test_blacklistingRefusesTheAsset() public {
        uint8 blacklisted = registry.TRUST_BLACKLISTED();
        vm.prank(admin);
        registry.setTrustStatus(DAI, blacklisted);

        (bool ok,, SwapRejection why) = registry.checkSwapSupported(weth, DAI);
        assertFalse(ok);
        assertEq(uint8(why), uint8(SwapRejection.Blacklisted));
    }

    function test_anUnlistedQuoteTokenIsRefused() public view {
        (bool ok,, SwapRejection why) = registry.checkSwapSupported(USDC, DAI);
        assertFalse(ok);
        assertEq(uint8(why), uint8(SwapRejection.QuoteNotAllowed));
    }

    /// @dev A per-quote override beats the default in both directions.
    function test_aPerQuoteThresholdOverridesTheDefault() public {
        vm.prank(admin);
        registry.setQuoteTokenThreshold(weth, type(uint128).max);
        assertFalse(registry.isSwapSupported(weth, DAI), "the override refuses what the default allowed");

        vm.prank(admin);
        registry.setQuoteTokenThreshold(weth, 0);
        assertTrue(registry.isSwapSupported(weth, DAI), "clearing it falls back to the default");
    }

    //////////////////////// the swap //////////////////////

    function test_swapDeliversToTheRecipientAndKeepsNothing() public {
        vm.deal(address(this), 1 ether);
        uint256 out = registry.swapNativeToAsset{value: 1 ether}(DAI, 1, recipient);

        assertGt(out, 0, "bought something");
        assertEq(IERC20(DAI).balanceOf(recipient), out, "the recipient got exactly what was reported");
        assertEq(IERC20(DAI).balanceOf(address(registry)), 0, "the registry kept no asset");
        assertEq(address(registry).balance, 0, "and no native");
    }

    function test_swapRevertsForAnIneligibleAsset() public {
        address ghost = address(new Ghost());
        vm.deal(address(this), 1 ether);

        vm.expectRevert(
            abi.encodeWithSelector(LivoDividendSwapRegistry.SwapNotSupported.selector, SwapRejection.NoPair)
        );
        registry.swapNativeToAsset{value: 1 ether}(ghost, 1, recipient);
    }

    /// @dev Eligibility is re-checked on every conversion, not trusted from creation time. Without this
    ///      a blacklist would only ever bind tokens created after it was set.
    function test_swapRevertsForAnAssetBlacklistedAfterCreation() public {
        uint8 blacklisted = registry.TRUST_BLACKLISTED();
        vm.prank(admin);
        registry.setTrustStatus(DAI, blacklisted);

        vm.deal(address(this), 1 ether);
        vm.expectRevert(
            abi.encodeWithSelector(LivoDividendSwapRegistry.SwapNotSupported.selector, SwapRejection.Blacklisted)
        );
        registry.swapNativeToAsset{value: 1 ether}(DAI, 1, recipient);
    }

    function test_swapRevertsOnAMissedFloor() public {
        vm.deal(address(this), 1 ether);
        vm.expectRevert();
        registry.swapNativeToAsset{value: 1 ether}(DAI, 1_000_000e18, recipient);
    }

    function test_swapRevertsWithNothingToSwap() public {
        vm.expectRevert(LivoDividendSwapRegistry.NothingToSwap.selector);
        registry.swapNativeToAsset(DAI, 1, recipient);
    }

    //////////////////////// access control //////////////////////

    /// @dev Two tiers: the owner is a cold key that manages admins and upgrades; admins do the frequent,
    ///      operational work. Neither tier can be reached by anyone else.
    function test_onlyTheOwnerManagesAdmins() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, admin));
        registry.setAdmin(stranger, true);

        vm.prank(owner);
        registry.setAdmin(stranger, true);
        assertTrue(registry.isAdmin(stranger), "the owner can");
    }

    function test_strangersCannotTouchEntries() public {
        vm.startPrank(stranger);
        vm.expectRevert(LivoDividendSwapRegistry.NotAdmin.selector);
        registry.setTrustStatus(DAI, 2);
        vm.expectRevert(LivoDividendSwapRegistry.NotAdmin.selector);
        registry.setDefaultThreshold(1);
        vm.expectRevert(LivoDividendSwapRegistry.NotAdmin.selector);
        registry.setAllowedQuoteToken(USDC, true);
        vm.expectRevert(LivoDividendSwapRegistry.NotAdmin.selector);
        registry.setQuoteTokenThreshold(weth, 1);
        vm.stopPrank();
    }

    /// @dev The owner is an admin implicitly, so a deployment is usable before any admin is appointed.
    function test_theOwnerCanActAsAnAdmin() public {
        vm.prank(owner);
        registry.setAllowedQuoteToken(USDC, true);
        assertTrue(registry.isAllowedQuoteToken(USDC));
    }

    function test_thresholdCannotBeZeroed() public {
        vm.prank(admin);
        vm.expectRevert(LivoDividendSwapRegistry.ZeroThreshold.selector);
        registry.setDefaultThreshold(0);
    }

    function test_trustStatusIsBounded() public {
        vm.prank(admin);
        vm.expectRevert(LivoDividendSwapRegistry.InvalidTrustStatus.selector);
        registry.setTrustStatus(DAI, 3);
    }

    /// @dev The chain's own quote currency is allowed from the start, so the first token created after a
    ///      deployment does not need an admin transaction to name a payout asset.
    function test_theNativeQuoteIsAllowedOutOfTheBox() public view {
        assertTrue(registry.isAllowedQuoteToken(weth));
        assertEq(registry.defaultThreshold(), DEFAULT_DIVIDEND_POOL_LIQUIDITY);
    }

    //////////////////////// curated V4 routes //////////////////////

    /// @dev The whole point of the feature: an asset with NO native pair anywhere becomes reachable
    ///      because an admin named the pools, and nothing about the depth test is consulted.
    function test_aRoutedAssetIsEligibleWithNoV2PairAtAll() public {
        address ghost = address(new Ghost());
        (bool before,, SwapRejection why) = registry.checkSwapSupported(weth, ghost);
        assertFalse(before, "no pair to start with");
        assertEq(uint8(why), uint8(SwapRejection.NoPair));

        _setRoute(ghost, _hop(ghost, V4_FEE_005, V4_SPACING_10, address(0)));

        (bool ok,, SwapRejection rejection) = registry.checkSwapSupported(weth, ghost);
        assertTrue(ok, "the route is the eligibility");
        assertEq(uint8(rejection), uint8(SwapRejection.OK));
        assertEq(registry.routeOf(ghost).length, 1, "and it is readable by a keeper");
    }

    /// @dev A route ADMITS; it never overrides the veto. Otherwise an admin fixing a route would be one
    ///      slip away from un-blacklisting a hostile asset.
    function test_aRoutedAssetIsStillRefusedWhenBlacklisted() public {
        address ghost = address(new Ghost());
        _setRoute(ghost, _hop(ghost, V4_FEE_005, V4_SPACING_10, address(0)));

        uint8 blacklisted = registry.TRUST_BLACKLISTED();
        vm.prank(admin);
        registry.setTrustStatus(ghost, blacklisted);

        (bool ok,, SwapRejection why) = registry.checkSwapSupported(weth, ghost);
        assertFalse(ok);
        assertEq(uint8(why), uint8(SwapRejection.Blacklisted));
    }

    /// @dev Clearing a route is not a blacklist: the asset simply goes back to being judged on its own
    ///      liquidity, and an asset that has a deep pair still passes.
    function test_clearingARouteReturnsTheAssetToTheV2Test() public {
        _setRoute(DAI, _hop(DAI, V4_FEE_005, V4_SPACING_10, address(0)));
        assertEq(registry.routeOf(DAI).length, 1);

        vm.prank(admin);
        registry.setRoute(DAI, new Hop[](0));

        assertEq(registry.routeOf(DAI).length, 0, "cleared");
        assertTrue(registry.isSwapSupported(weth, DAI), "and still eligible on its own merits");
    }

    /// @dev A route whose last hop buys something else would leave the swap unable to take what it was
    ///      told to take. Caught where it is cheap to catch instead of at the next freeze.
    function test_aRouteMustEndAtTheAsset() public {
        Hop[] memory hops = _hop(USDC, V4_FEE_005, V4_SPACING_10, address(0));
        vm.prank(admin);
        vm.expectRevert(LivoDividendSwapRegistry.RouteMustEndAtAsset.selector);
        registry.setRoute(DAI, hops);
    }

    function test_aRouteLongerThanTheCapIsRefused() public {
        Hop[] memory hops = new Hop[](registry.MAX_ROUTE_HOPS() + 1);
        for (uint256 i; i < hops.length; ++i) {
            hops[i] = Hop({currency: DAI, fee: V4_FEE_005, tickSpacing: V4_SPACING_10, hooks: address(0)});
        }
        vm.prank(admin);
        vm.expectRevert(LivoDividendSwapRegistry.RouteTooLong.selector);
        registry.setRoute(DAI, hops);
    }

    function test_strangersCannotSetARoute() public {
        Hop[] memory hops = _hop(DAI, V4_FEE_005, V4_SPACING_10, address(0));
        vm.prank(stranger);
        vm.expectRevert(LivoDividendSwapRegistry.NotAdmin.selector);
        registry.setRoute(DAI, hops);
    }

    /// @dev The single-hop shape: an asset that DOES have a native V4 pool, bought through it rather
    ///      than through V2.
    function test_aSingleHopRouteBuysTheAssetOnV4() public {
        _setRoute(USDC, _hop(USDC, V4_FEE_005, V4_SPACING_10, address(0)));

        vm.deal(address(this), 1 ether);
        uint256 out = registry.swapNativeToAsset{value: 1 ether}(USDC, 1, recipient);

        assertGt(out, 0, "bought something");
        assertEq(IERC20(USDC).balanceOf(recipient), out, "the recipient got exactly what was reported");
        assertEq(IERC20(USDC).balanceOf(address(registry)), 0, "the registry kept no asset");
        assertEq(address(registry).balance, 0, "and no native");
    }

    /// @dev THE xStock SHAPE. The asset has no native pool of its own, so the route goes through an
    ///      intermediate — USDC here, USDG on Robinhood Chain — and the swap is still one call.
    function test_aTwoHopRouteReachesAnAssetWithNoNativePool() public {
        Hop[] memory hops = new Hop[](2);
        hops[0] = Hop({currency: USDC, fee: V4_FEE_005, tickSpacing: V4_SPACING_10, hooks: address(0)});
        hops[1] = Hop({currency: USDT, fee: V4_FEE_001, tickSpacing: V4_SPACING_1, hooks: address(0)});
        vm.prank(admin);
        registry.setRoute(USDT, hops);

        vm.deal(address(this), 1 ether);
        uint256 out = registry.swapNativeToAsset{value: 1 ether}(USDT, 1, recipient);

        assertGt(out, 0, "bought something two pools away");
        assertEq(IERC20(USDT).balanceOf(recipient), out, "the recipient got exactly what was reported");
        assertEq(IERC20(USDT).balanceOf(address(registry)), 0, "the registry kept no asset");
        assertEq(IERC20(USDC).balanceOf(address(registry)), 0, "nor any of the intermediate");
        assertEq(address(registry).balance, 0, "and no native");
    }

    /// @dev The floor is the keeper's protection and it is the ROUTER that enforces it. A route does not
    ///      soften it just because an admin vouched for the pools.
    function test_aRoutedSwapStillHonoursTheFloor() public {
        _setRoute(USDC, _hop(USDC, V4_FEE_005, V4_SPACING_10, address(0)));

        vm.deal(address(this), 1 ether);
        vm.expectRevert(LivoDividendSwapRegistry.SwapFailed.selector);
        registry.swapNativeToAsset{value: 1 ether}(USDC, 1_000_000e6, recipient);
    }

    /// @dev A route that names a pool nobody ever initialized fails the CONVERSION, not the round: the
    ///      caller keeps its native and the registry keeps nothing.
    function test_aRouteToAPoolThatDoesNotExistFailsTheSwap() public {
        _setRoute(USDC, _hop(USDC, 3000, int24(199), address(0)));

        vm.deal(address(this), 1 ether);
        vm.expectRevert(LivoDividendSwapRegistry.SwapFailed.selector);
        registry.swapNativeToAsset{value: 1 ether}(USDC, 1, recipient);
        assertEq(address(registry).balance, 0);
    }

    //////////////////////// helpers //////////////////////

    function _hop(address currency, uint24 fee, int24 tickSpacing, address hooks)
        internal
        pure
        returns (Hop[] memory hops)
    {
        hops = new Hop[](1);
        hops[0] = Hop({currency: currency, fee: fee, tickSpacing: tickSpacing, hooks: hooks});
    }

    function _setRoute(address asset, Hop[] memory hops) internal {
        vm.prank(admin);
        registry.setRoute(asset, hops);
    }
}

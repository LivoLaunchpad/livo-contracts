// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IUniswapV2Router} from "src/interfaces/IUniswapV2Router.sol";
import {UniswapV2Venue} from "src/libraries/UniswapV2Venue.sol";
import {UniswapV2VenueArc} from "src/libraries/UniswapV2VenueArc.sol";

/// @dev Records the liquidity-add it was called with, and hands back configurable amounts.
contract MockRouter {
    bool public wasEthPath;
    address public lastToken;
    address public lastQuote;
    uint256 public lastTokenDesired;
    uint256 public lastQuoteDesired; // amountBDesired (addLiquidity) or msg.value (addLiquidityETH)
    uint256 internal rToken;
    uint256 internal rQuote;
    uint256 internal rLiq;

    function setReturns(uint256 t, uint256 q, uint256 l) external {
        (rToken, rQuote, rLiq) = (t, q, l);
    }

    function WETH() external pure returns (address) {
        return address(0xE);
    }

    function factory() external pure returns (address) {
        return address(0xF);
    }

    function addLiquidityETH(address token, uint256 amountTokenDesired, uint256, uint256, address, uint256)
        external
        payable
        returns (uint256, uint256, uint256)
    {
        wasEthPath = true;
        lastToken = token;
        lastTokenDesired = amountTokenDesired;
        lastQuoteDesired = msg.value;
        return (rToken, rQuote, rLiq);
    }

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256,
        uint256,
        address,
        uint256
    ) external returns (uint256, uint256, uint256) {
        wasEthPath = false;
        lastToken = tokenA;
        lastQuote = tokenB;
        lastTokenDesired = amountADesired;
        lastQuoteDesired = amountBDesired;
        return (rToken, rQuote, rLiq);
    }
}

/// @dev Minimal ERC20 supporting the `forceApprove` path used by the ARC venue.
contract MockERC20 {
    mapping(address => mapping(address => uint256)) public allowance;

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        return true;
    }
}

/// @dev Exposes the internal library functions as external calls.
contract VenueHarness {
    function supplyEth(MockRouter r, address token, address quote, uint256 tokenAmount, uint256 nativeValue)
        external
        payable
        returns (uint256, uint256, uint256)
    {
        return UniswapV2Venue.supplyLiquidity(
            IUniswapV2Router(address(r)), token, quote, tokenAmount, nativeValue, address(0xdEaD)
        );
    }

    function supplyArc(MockRouter r, address token, address quote, uint256 tokenAmount, uint256 nativeValue)
        external
        returns (uint256, uint256, uint256)
    {
        return UniswapV2VenueArc.supplyLiquidity(
            IUniswapV2Router(address(r)), token, quote, tokenAmount, nativeValue, address(0xdEaD)
        );
    }
}

/// @notice Unit-tests the per-chain V2 venue math: the ARC path's 18-dec native ↔ 6-dec USDC quote
///         conversion (the money-path arithmetic most likely to break), and that the ETH path stays
///         the native-value `addLiquidityETH` path.
contract UniswapV2VenueTest is Test {
    VenueHarness harness;
    MockRouter router;
    MockERC20 usdc;

    address constant TOKEN = address(0xABCD);

    function setUp() public {
        harness = new VenueHarness();
        router = new MockRouter();
        usdc = new MockERC20();
    }

    function test_scaleConstants() public pure {
        assertEq(UniswapV2Venue.QUOTE_TO_NATIVE_SCALE, 1, "eth scale");
        assertEq(UniswapV2VenueArc.QUOTE_TO_NATIVE_SCALE, 1e12, "arc scale");
    }

    function test_arcPairTokenIsUsdc() public pure {
        assertEq(UniswapV2VenueArc.pairToken(IUniswapV2Router(address(0))), 0x3600000000000000000000000000000000000000);
    }

    function test_ethVenue_usesNativeValuePath() public {
        router.setReturns(1000e18, 3e18, 5e18);
        vm.deal(address(harness), 3e18);

        (uint256 amountToken, uint256 amountNative, uint256 liquidity) =
            harness.supplyEth(router, TOKEN, address(usdc), 1000e18, 3e18);

        assertTrue(router.wasEthPath(), "should take addLiquidityETH");
        assertEq(router.lastQuoteDesired(), 3e18, "native value forwarded as msg.value");
        assertEq(amountToken, 1000e18);
        assertEq(amountNative, 3e18, "native returned as-is (scale 1)");
        assertEq(liquidity, 5e18);
    }

    function test_arcVenue_convertsNativeToUsdc6AndBack() public {
        // Router reports it pulled 3e6 USDC (6-dec) and 1000e18 tokens.
        router.setReturns(1000e18, 3e6, 5e18);

        (uint256 amountToken, uint256 amountNative, uint256 liquidity) =
            harness.supplyArc(router, TOKEN, address(usdc), 1000e18, 3e18);

        assertFalse(router.wasEthPath(), "should take two-ERC20 addLiquidity");
        assertEq(router.lastQuote(), address(usdc), "paired against USDC");
        assertEq(router.lastQuoteDesired(), 3e6, "18-dec native -> 6-dec USDC desired");
        assertEq(usdc.allowance(address(harness), address(router)), 3e6, "router approved for usdc6");
        assertEq(amountToken, 1000e18);
        assertEq(amountNative, 3e18, "6-dec quote scaled back to 18-dec native");
        assertEq(liquidity, 5e18);
    }

    function test_arcVenue_floorsSubMicroUsdcDust() public {
        router.setReturns(0, 0, 0);
        // 3e18 + 999 wei of native: the < 1e12 remainder is sub-1e-6 USDC and must floor away.
        harness.supplyArc(router, TOKEN, address(usdc), 1000e18, 3e18 + 999);
        assertEq(router.lastQuoteDesired(), 3e6, "dust below 1e12 floored out of the USDC amount");
    }
}

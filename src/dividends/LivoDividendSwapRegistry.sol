// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "lib/openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

import {IUniswapV2Router} from "src/interfaces/IUniswapV2Router.sol";
import {IUniswapV2Factory} from "src/interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Pair} from "src/interfaces/IUniswapV2Pair.sol";
import {ILivoDividendSwapRegistry, SwapRejection} from "src/interfaces/ILivoDividendSwapRegistry.sol";

/// this line below is swapped per target chain at deploy time (the addresses are compile-time
/// constants baked into bytecode): DeploymentAddressesEthereumSepolia, DeploymentAddressesRobinhood*,
/// or DeploymentAddressesArc{Mainnet,Testnet}.
import {DeploymentAddressesEthereumMainnet as DeploymentAddresses} from "src/config/DeploymentAddresses.sol";
// Aliased so the `chain-arc-*` recipe can import-swap it: on ARC the "native" leg is 18-dec native USDC
// and the V2 quote token is its 6-dec ERC-20 alias, so the depth check needs a scale factor.
import {UniswapV2Venue as UniswapV2Venue} from "src/libraries/UniswapV2Venue.sol";

/// @title LivoDividendSwapRegistry
/// @notice Decides which ERC20s a token may pay dividends in, and performs the native -> asset
///         conversion when it does. Uniswap V2 only.
///
/// @dev WHY IT EXISTS AT ALL. Taxable tokens are clones of an implementation that can never be patched.
///      Both halves of the third-asset payout — "is this asset reachable" and "buy it" — used to be
///      compiled into that implementation, which meant a threshold that turned out wrong, an asset that
///      turned out malicious, or a venue that had to change, could only ever apply to tokens minted
///      AFTERWARDS. Behind a proxy at an address the token holds as a constant, a fix reaches every
///      token that already exists. Nothing else here would justify a separate contract.
///
/// @dev ELIGIBILITY IS PERMISSIONLESS. `isSwapSupported` is a liquidity test, not a list: any ERC20 with
///      a Uniswap V2 pair against the quote token holding at least the configured depth passes, with no
///      admin action of any kind. The admin levers are a blacklist (a veto, for an asset that turns out
///      hostile), the quote-token allowlist (the `from` side, which is protocol configuration rather
///      than a creator's choice) and the thresholds. `whitelisted` is a UI badge and gates nothing —
///      it deliberately has no effect on `isSwapSupported`, so it can never quietly become a gate.
///
/// @dev V2 ONLY, ON PURPOSE. A V2 pair is a contract that holds its own reserves, so the eligibility
///      test is a `balanceOf` on a known address and the swap is one router call. V3 and V4 need a fee
///      tier / tick spacing / hooks tuple the creator would have to supply and the registry would have
///      to trust, and V4's singleton makes the depth test a much weaker "is there any active liquidity".
///      Almost every long-tail ERC20 worth paying dividends in has a V2 pair; the ones that only have
///      V3/V4 liquidity are refused with `NoPair` and can be admitted later by upgrading this contract.
///
/// @dev CUSTODIES NOTHING. `swapNativeToAsset` receives, swaps and forwards inside one call, and holds
///      no balance between calls. There is deliberately no `receive()`, so the only native that can
///      reach it is native someone is actively converting. The one exception is ARC, where the venue
///      floors the 18-dec native amount to 6-dec USDC and leaves sub-1e-6 dust behind; it is unreachable
///      rather than owed to anyone, and a sweep for it would buy less than it costs to review.
contract LivoDividendSwapRegistry is ILivoDividendSwapRegistry, Initializable, OwnableUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    /// @notice Trust status values. Advisory: read by frontends, never by `isSwapSupported`, except
    ///         `BLACKLISTED`, which is the one veto.
    uint8 public constant TRUST_UNKNOWN = 0;
    uint8 public constant TRUST_WHITELISTED = 1;
    uint8 public constant TRUST_BLACKLISTED = 2;

    /// @notice Router every conversion goes through, and the source of the canonical quote token.
    address public constant SWAP_ROUTER = DeploymentAddresses.UNIV2_ROUTER;

    /// @notice Factory the quote/asset pair is resolved through.
    address public constant UNIV2_FACTORY = DeploymentAddresses.UNIV2_FACTORY;

    //////////////////////// storage //////////////////////

    /// @notice Addresses allowed to manage entries (thresholds, trust status, the quote allowlist).
    ///         The owner manages THIS set and the upgrade; admins manage everything else.
    /// @dev Two tiers because the entry-level operations are frequent and operational (blacklisting an
    ///      asset that just turned hostile) while the owner is a cold multisig that should not be in
    ///      that loop. See [[feedback_two_tier_admin_for_whitelists]].
    mapping(address => bool) public isAdmin;

    /// @notice Quote tokens a conversion may start from. Always enforced: an asset is only eligible
    ///         against a quote token on this list.
    /// @dev Today this holds exactly one entry — the router's WETH — because every Livo token's
    ///      earnings are denominated in the chain's native currency. It is a mapping rather than a
    ///      constant so a future non-ETH-quoted token needs a transaction here, not a new token
    ///      implementation.
    mapping(address => bool) public isAllowedQuoteToken;

    /// @notice Per-quote-token depth override, in native 18-dec units. 0 means "use `defaultThreshold`".
    mapping(address => uint256) public quoteTokenThreshold;

    /// @notice Advisory trust status per asset. Only `TRUST_BLACKLISTED` changes any decision.
    mapping(address => uint8) public trustStatus;

    /// @notice Quote-side depth an asset's pair must hold, in native 18-dec units, when its quote token
    ///         has no override.
    uint256 public defaultThreshold;

    /// @dev Reserved for future storage. Appending past this on an upgrade is safe; reordering anything
    ///      above it is not.
    uint256[45] private __gap;

    //////////////////////// events //////////////////////

    event AdminSet(address indexed account, bool allowed);
    event QuoteTokenAllowed(address indexed quote, bool allowed);
    event QuoteTokenThresholdSet(address indexed quote, uint256 threshold);
    event DefaultThresholdSet(uint256 threshold);
    event TrustStatusSet(address indexed asset, uint8 status);
    event DividendAssetPurchased(address indexed asset, address indexed recipient, uint256 nativeIn, uint256 assetOut);

    //////////////////////// errors //////////////////////

    error NotAdmin();
    error InvalidTrustStatus();
    error ZeroThreshold();
    error SwapNotSupported(SwapRejection rejection);
    error NothingToSwap();
    /// @notice The venue call reverted: a drained pair, a missed floor, a token that refuses the swap.
    ///         Reported as a revert because the caller (a dividend freeze) must keep its native.
    error SwapFailed();
    error InsufficientOutput();

    modifier onlyAdmin() {
        require(isAdmin[msg.sender] || msg.sender == owner(), NotAdmin());
        _;
    }

    constructor() {
        _disableInitializers();
    }

    /// @param initialOwner cold multisig: manages admins and upgrades, nothing else
    /// @param initialThreshold quote-side depth, native 18-dec, an asset's pair must hold by default
    function initialize(address initialOwner, uint256 initialThreshold) external initializer {
        __Ownable_init(initialOwner);
        __UUPSUpgradeable_init();

        require(initialThreshold != 0, ZeroThreshold());
        defaultThreshold = initialThreshold;
        emit DefaultThresholdSet(initialThreshold);

        // The chain's canonical quote token is the one every token's earnings already arrive in, so it
        // is allowed from the start: a registry that had to be configured before the first token could
        // name an asset would be a deployment-order footgun for no benefit.
        address quote = UniswapV2Venue.pairToken(IUniswapV2Router(SWAP_ROUTER));
        isAllowedQuoteToken[quote] = true;
        emit QuoteTokenAllowed(quote, true);
    }

    //////////////////////// views //////////////////////

    /// @inheritdoc ILivoDividendSwapRegistry
    /// @dev `pure` because Uniswap's router declares `WETH()` that way; it is a STATICCALL either way.
    function nativeQuoteToken() public pure returns (address) {
        return UniswapV2Venue.pairToken(IUniswapV2Router(SWAP_ROUTER));
    }

    /// @inheritdoc ILivoDividendSwapRegistry
    function isSwapSupported(address quote, address asset) public view returns (bool supported) {
        (supported,,) = checkSwapSupported(quote, asset);
    }

    /// @inheritdoc ILivoDividendSwapRegistry
    function checkSwapSupported(address quote, address asset)
        public
        view
        returns (bool supported, uint8 trust, SwapRejection rejection)
    {
        trust = trustStatus[asset];

        if (!isAllowedQuoteToken[quote]) return (false, trust, SwapRejection.QuoteNotAllowed);
        if (trust == TRUST_BLACKLISTED) return (false, trust, SwapRejection.Blacklisted);

        (address pair, uint256 quoteDepth) = pairFor(quote, asset);
        if (pair == address(0)) return (false, trust, SwapRejection.NoPair);

        uint256 threshold = quoteTokenThreshold[quote];
        if (threshold == 0) threshold = defaultThreshold;
        if (quoteDepth < threshold) return (false, trust, SwapRejection.InsufficientLiquidity);

        return (true, trust, SwapRejection.OK);
    }

    /// @inheritdoc ILivoDividendSwapRegistry
    /// @dev Reads the pair's own reserves rather than a `balanceOf`, so a donation that has not been
    ///      `sync`ed cannot inflate the depth a swap will actually cross.
    function pairFor(address quote, address asset) public view returns (address pair, uint256 quoteDepth) {
        pair = IUniswapV2Factory(UNIV2_FACTORY).getPair(quote, asset);
        if (pair == address(0)) return (address(0), 0);

        (uint112 reserve0, uint112 reserve1,) = IUniswapV2Pair(pair).getReserves();
        uint256 reserve = IUniswapV2Pair(pair).token0() == quote ? reserve0 : reserve1;
        // `QUOTE_TO_NATIVE_SCALE` lifts the pool's quote units to native 18-dec, which is what every
        // threshold here is denominated in. 1 on ETH-family chains, 1e12 on ARC.
        quoteDepth = reserve * UniswapV2Venue.QUOTE_TO_NATIVE_SCALE;
    }

    //////////////////////// the swap //////////////////////

    /// @inheritdoc ILivoDividendSwapRegistry
    /// @dev Re-checks eligibility on every conversion rather than trusting the creation-time proof. A
    ///      pair can be drained, and an asset can be blacklisted, long after a token was configured for
    ///      it; without this the blacklist would only ever apply to tokens created after it was set.
    function swapNativeToAsset(address asset, uint256 minOut, address recipient)
        external
        payable
        returns (uint256 out)
    {
        require(msg.value != 0, NothingToSwap());

        address quote = nativeQuoteToken();
        (bool supported,, SwapRejection rejection) = checkSwapSupported(quote, asset);
        require(supported, SwapNotSupported(rejection));

        address[] memory path = new address[](2);
        path[0] = quote;
        path[1] = asset;

        // Through the venue lib, not the router directly: the `chain-arc-*` recipe import-swaps it, and
        // ARC has no WETH — its native USDC shares a balance with the 6-dec ERC-20 the pair is quoted
        // in, so the same `msg.value` becomes a two-ERC20 swap there rather than an ETH-in one.
        // Buy to THIS contract, not straight to `recipient`: the amount forwarded has to be a balance
        // delta measured here, because a fee-on-transfer asset delivers less than the router reports.
        uint256 balanceBefore = IERC20(asset).balanceOf(address(this));
        bool swapped =
            UniswapV2Venue.trySwapNativeToAsset(IUniswapV2Router(SWAP_ROUTER), quote, path, msg.value, minOut);
        require(swapped, SwapFailed());
        out = IERC20(asset).balanceOf(address(this)) - balanceBefore;

        // The router enforces `minOut` against what IT received; a fee-on-transfer asset can take a cut
        // on the transfer to us afterwards, so the floor is re-checked against what actually landed.
        require(out >= minOut, InsufficientOutput());

        IERC20(asset).safeTransfer(recipient, out);
        emit DividendAssetPurchased(asset, recipient, msg.value, out);
    }

    //////////////////////// admin //////////////////////

    /// @notice Owner-only: manage the admin set.
    function setAdmin(address account, bool allowed) external onlyOwner {
        isAdmin[account] = allowed;
        emit AdminSet(account, allowed);
    }

    /// @notice Allow or refuse a quote token as the `from` side of a conversion.
    function setAllowedQuoteToken(address quote, bool allowed) external onlyAdmin {
        isAllowedQuoteToken[quote] = allowed;
        emit QuoteTokenAllowed(quote, allowed);
    }

    /// @notice Override the depth threshold for one quote token. 0 clears the override.
    function setQuoteTokenThreshold(address quote, uint256 threshold) external onlyAdmin {
        quoteTokenThreshold[quote] = threshold;
        emit QuoteTokenThresholdSet(quote, threshold);
    }

    /// @notice Set the fallback depth threshold, in native 18-dec units.
    function setDefaultThreshold(uint256 threshold) external onlyAdmin {
        require(threshold != 0, ZeroThreshold());
        defaultThreshold = threshold;
        emit DefaultThresholdSet(threshold);
    }

    /// @notice Set an asset's trust status. `TRUST_BLACKLISTED` is the only value that changes a
    ///         decision; `TRUST_WHITELISTED` is a badge for the UI.
    function setTrustStatus(address asset, uint8 status) external onlyAdmin {
        require(status <= TRUST_BLACKLISTED, InvalidTrustStatus());
        trustStatus[asset] = status;
        emit TrustStatusSet(asset, status);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}

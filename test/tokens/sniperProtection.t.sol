// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {Clones} from "lib/openzeppelin-contracts/contracts/proxy/Clones.sol";
import {ILivoToken} from "src/interfaces/ILivoToken.sol";
import {ILivoGraduator} from "src/interfaces/ILivoGraduator.sol";
import {LivoToken} from "src/tokens/LivoToken.sol";
import {LivoTaxableTokenUniV4} from "src/tokens/LivoTaxableTokenUniV4.sol";
import {LivoTokenSniperProtected} from "src/tokens/LivoTokenSniperProtected.sol";
import {LivoTaxableTokenUniV4SniperProtected} from "src/tokens/LivoTaxableTokenUniV4SniperProtected.sol";
import {TaxConfigInit} from "src/interfaces/ILivoTaxableTokenUniV4.sol";
import {SniperProtection, AntiSniperConfigs} from "src/tokens/SniperProtection.sol";
import {DeploymentAddressesMainnet} from "src/config/DeploymentAddresses.sol";

/// @dev Minimal graduator mock — returns a caller-chosen `pair` address from `initialize()`
///      and lets the test drive `markGraduated` on the token.
contract MockGraduator is ILivoGraduator {
    address public immutable PAIR;

    constructor(address pair_) {
        PAIR = pair_;
    }

    function initialize(address) external view returns (address) {
        return PAIR;
    }

    function graduateToken(address, uint256) external payable {}
}

/// @dev Minimal launchpad stub. The sniper-protection check no longer queries this contract, but
///      a standalone address is still used as the "launchpad" from the token's perspective.
contract MockLaunchpad {
    function launchToken(address, address) external {}
}

/// @dev Shared test base for both sniper-protected variants. Subclasses wire in the concrete
///      token type and the appropriate pair address.
abstract contract SniperProtectionBaseTest is Test {
    address internal tokenOwner = makeAddr("tokenOwner");
    address internal feeHandler = makeAddr("feeHandler");
    address internal feeReceiver = makeAddr("feeReceiver");
    address internal buyer = makeAddr("buyer");
    address internal buyer2 = makeAddr("buyer2");
    address internal seller = makeAddr("seller");
    address internal factory = makeAddr("factory");
    address internal deployer = makeAddr("deployer");
    address internal whitelisted1 = makeAddr("whitelisted1");
    address internal whitelisted2 = makeAddr("whitelisted2");

    MockLaunchpad internal launchpadMock;
    MockGraduator internal graduator;

    address internal launchpad; // cached address(launchpadMock) for terse assertions

    uint256 internal constant TOTAL_SUPPLY = 1_000_000_000e18;

    // Default AntiSniperConfigs values used by subclass setUp(). Match the old hardcoded behavior
    // so tests that don't care about configurability continue to make sense (3% / 3% / 3h).
    uint16 internal constant DEFAULT_MAX_BUY_BPS = 300;
    uint16 internal constant DEFAULT_MAX_WALLET_BPS = 300;
    uint40 internal constant DEFAULT_WINDOW = 3 hours;

    uint256 internal constant MAX_BUY_PER_TX = 30_000_000e18; // 3% of 1B
    uint256 internal constant MAX_WALLET = 30_000_000e18; // 3% of 1B

    function _token() internal view virtual returns (LivoToken);

    /// @dev Passed to the token's initializer by subclass setUp(). Single hook so individual tests
    ///      can override by re-deploying before their own setUp.
    function _defaultCfg() internal view returns (AntiSniperConfigs memory cfg) {
        address[] memory wl = new address[](2);
        wl[0] = whitelisted1;
        wl[1] = whitelisted2;
        cfg = AntiSniperConfigs({
            maxBuyPerTxBps: DEFAULT_MAX_BUY_BPS,
            maxWalletBps: DEFAULT_MAX_WALLET_BPS,
            protectionWindowSeconds: DEFAULT_WINDOW,
            whitelist: wl
        });
    }

    /// @dev Called via prank(launchpad) to simulate a curve buy.
    function _curveBuy(address to, uint256 amount) internal {
        vm.prank(launchpad);
        _token().transfer(to, amount);
    }

    /// @dev Pretend a user sells back to the curve.
    function _curveSell(address from, uint256 amount) internal {
        vm.prank(from);
        _token().transfer(launchpad, amount);
    }

    /// -------------------- TESTS --------------------

    function test_initialMintNotBlocked() public view {
        assertEq(_token().balanceOf(launchpad), TOTAL_SUPPLY);
    }

    function test_launchTimestampRecorded() public view {
        uint40 ts = SniperProtection(address(_token())).launchTimestamp();
        assertGt(ts, 0);
        assertEq(ts, uint40(block.timestamp));
    }

    function test_configsStored() public view {
        SniperProtection sp = SniperProtection(address(_token()));
        assertEq(sp.maxBuyPerTxBps(), DEFAULT_MAX_BUY_BPS);
        assertEq(sp.maxWalletBps(), DEFAULT_MAX_WALLET_BPS);
        assertEq(uint256(sp.protectionWindowSeconds()), DEFAULT_WINDOW);
    }

    function test_whitelistRecorded() public view {
        SniperProtection sp = SniperProtection(address(_token()));
        assertTrue(sp.sniperBypass(whitelisted1));
        assertTrue(sp.sniperBypass(whitelisted2));
        assertFalse(sp.sniperBypass(buyer));
    }

    function test_maxBuyPerTx_boundary() public {
        _curveBuy(buyer, MAX_BUY_PER_TX);
        assertEq(_token().balanceOf(buyer), MAX_BUY_PER_TX);
    }

    function test_maxBuyPerTx_reverts() public {
        vm.prank(launchpad);
        vm.expectRevert(SniperProtection.MaxBuyPerTxExceeded.selector);
        _token().transfer(buyer, MAX_BUY_PER_TX + 1);
    }

    function test_maxWallet_boundary() public {
        _curveBuy(buyer, MAX_BUY_PER_TX);
        _curveBuy(buyer, MAX_WALLET - MAX_BUY_PER_TX);
        assertEq(_token().balanceOf(buyer), MAX_WALLET);
    }

    function test_maxWallet_reverts() public {
        _curveBuy(buyer, MAX_WALLET);

        vm.prank(launchpad);
        vm.expectRevert(SniperProtection.MaxWalletExceeded.selector);
        _token().transfer(buyer, 1);
    }

    function test_sellsUnaffected() public {
        _curveBuy(seller, MAX_BUY_PER_TX);
        _curveSell(seller, MAX_BUY_PER_TX);
        assertEq(_token().balanceOf(seller), 0);
    }

    /// Wallet-to-wallet transfers within the protection window must be uncapped: the check only
    /// gates `from == launchpad`. Receiver may end up holding more than `maxWallet`, and the
    /// transfer amount may exceed `maxBuyPerTx`.
    function test_walletToWalletUnaffected_withinWindow() public {
        _curveBuy(buyer, MAX_BUY_PER_TX);
        _curveBuy(seller, MAX_BUY_PER_TX);

        assertLt(block.timestamp, SniperProtection(address(_token())).launchTimestamp() + DEFAULT_WINDOW);

        vm.prank(buyer);
        _token().transfer(seller, MAX_BUY_PER_TX);
        assertEq(_token().balanceOf(seller), MAX_BUY_PER_TX * 2);
    }

    function test_windowExpiry_capsLift() public {
        uint40 launchTs = SniperProtection(address(_token())).launchTimestamp();
        vm.warp(launchTs + DEFAULT_WINDOW + 1);

        _curveBuy(buyer, MAX_BUY_PER_TX + 1);
        assertEq(_token().balanceOf(buyer), MAX_BUY_PER_TX + 1);

        _curveBuy(buyer, MAX_WALLET * 2);
        assertEq(_token().balanceOf(buyer), MAX_BUY_PER_TX + 1 + MAX_WALLET * 2);
    }

    function test_postGraduationBypass_withinWindow() public {
        vm.warp(block.timestamp + 30 minutes);
        vm.prank(address(graduator));
        _token().markGraduated();

        _curveBuy(buyer, MAX_BUY_PER_TX + 1);
        assertEq(_token().balanceOf(buyer), MAX_BUY_PER_TX + 1);
    }

    function test_walletToWalletUnaffected_postGraduation() public {
        _curveBuy(buyer, MAX_BUY_PER_TX);

        vm.prank(address(graduator));
        _token().markGraduated();

        vm.prank(buyer);
        _token().transfer(buyer2, MAX_BUY_PER_TX);
        assertEq(_token().balanceOf(buyer2), MAX_BUY_PER_TX);
    }

    function test_multipleBuyersIndependentWalletCaps() public {
        _curveBuy(buyer, MAX_WALLET);
        _curveBuy(buyer2, MAX_WALLET);
        assertEq(_token().balanceOf(buyer), MAX_WALLET);
        assertEq(_token().balanceOf(buyer2), MAX_WALLET);
    }

    /// Deployer-buy path: launchpad → factory → supplyShares. The launchpad → factory hop moves
    /// up to 10% of supply (factory's `maxBuyOnDeployBps`), which is far above the 3% cap. The
    /// recipient-is-factory exemption lets this pass.
    function test_deployerBuyViaDeployingFactory_bypassesCaps() public {
        uint256 deployerBuyAmount = TOTAL_SUPPLY / 10; // 10%

        // The token captured `factory = msg.sender` at init — the test contract itself, since
        // this base setUp() calls `initialize()` directly on the clone.
        address deployingFactory = address(this);

        vm.prank(launchpad);
        _token().transfer(deployingFactory, deployerBuyAmount);
        assertEq(_token().balanceOf(deployingFactory), deployerBuyAmount);

        // Factory → deployer (from != launchpad): sniper check is inactive regardless.
        vm.prank(deployingFactory);
        _token().transfer(deployer, deployerBuyAmount);
        assertEq(_token().balanceOf(deployer), deployerBuyAmount);
    }

    /// Non-factory, non-whitelisted recipients are still capped — ensures the bypass is scoped.
    function test_nonWhitelistedRecipient_stillCapped() public {
        address otherContract = makeAddr("otherContract");

        vm.prank(launchpad);
        vm.expectRevert(SniperProtection.MaxBuyPerTxExceeded.selector);
        _token().transfer(otherContract, MAX_BUY_PER_TX + 1);
    }

    function test_devWhitelistBypassesMaxBuyPerTx() public {
        _curveBuy(whitelisted1, MAX_BUY_PER_TX * 5);
        assertEq(_token().balanceOf(whitelisted1), MAX_BUY_PER_TX * 5);
    }

    function test_devWhitelistBypassesMaxWallet() public {
        _curveBuy(whitelisted1, MAX_WALLET);
        _curveBuy(whitelisted1, MAX_WALLET * 3);
        assertEq(_token().balanceOf(whitelisted1), MAX_WALLET * 4);
    }

    function test_devWhitelist_onlyAppliesToWhitelistedAddresses() public {
        _curveBuy(whitelisted2, MAX_BUY_PER_TX * 4);
        assertEq(_token().balanceOf(whitelisted2), MAX_BUY_PER_TX * 4);

        vm.prank(launchpad);
        vm.expectRevert(SniperProtection.MaxBuyPerTxExceeded.selector);
        _token().transfer(buyer, MAX_BUY_PER_TX + 1);
    }

    function test_customConfigsEnforced() public {
        // Deploy a second token with tight configs: 1% / 3% / 10 min. Wallet cap is a 3x multiple
        // of the per-tx cap so we can fill a wallet with exactly 3 back-to-back max-per-tx buys.
        uint16 tightBuyBps = 100; // 1% → 10_000_000e18
        uint16 tightWalletBps = 300; // 3% → 30_000_000e18
        uint40 shortWindow = 10 minutes;

        LivoToken t = _deployCustom(tightBuyBps, tightWalletBps, shortWindow, new address[](0));

        uint256 tightMaxBuy = (TOTAL_SUPPLY * tightBuyBps) / 10_000;
        uint256 tightMaxWallet = (TOTAL_SUPPLY * tightWalletBps) / 10_000;

        // Boundary passes.
        vm.prank(launchpad);
        t.transfer(buyer, tightMaxBuy);
        assertEq(t.balanceOf(buyer), tightMaxBuy);

        // One wei over the tx cap reverts.
        vm.prank(launchpad);
        vm.expectRevert(SniperProtection.MaxBuyPerTxExceeded.selector);
        t.transfer(buyer2, tightMaxBuy + 1);

        // Fill the wallet to the cap with additional max-per-tx buys.
        vm.prank(launchpad);
        t.transfer(buyer, tightMaxBuy);
        vm.prank(launchpad);
        t.transfer(buyer, tightMaxBuy);
        assertEq(t.balanceOf(buyer), tightMaxWallet);

        // One more wei reverts on MaxWallet.
        vm.prank(launchpad);
        vm.expectRevert(SniperProtection.MaxWalletExceeded.selector);
        t.transfer(buyer, 1);

        // Window expires after 10 minutes; caps lift. Send well above the former per-tx cap.
        vm.warp(block.timestamp + shortWindow + 1);
        vm.prank(launchpad);
        t.transfer(buyer2, tightMaxBuy * 10);
        assertEq(t.balanceOf(buyer2), tightMaxBuy * 10);
    }

    function test_emitsSniperProtectionInitialized() public {
        address[] memory wl = new address[](1);
        wl[0] = whitelisted1;

        vm.expectEmit(true, true, true, true);
        emit SniperProtection.SniperProtectionInitialized(123, 234, 1 hours, wl);
        _deployCustom(123, 234, 1 hours, wl);
    }

    function test_revertsMaxBuyPerTxBpsTooLow() public {
        address clone = _cloneImpl();
        vm.expectRevert(SniperProtection.MaxBuyPerTxBpsTooLow.selector);
        _initClone(clone, 9, DEFAULT_MAX_WALLET_BPS, DEFAULT_WINDOW, new address[](0));
    }

    function test_revertsMaxBuyPerTxBpsTooHigh() public {
        address clone = _cloneImpl();
        vm.expectRevert(SniperProtection.MaxBuyPerTxBpsTooHigh.selector);
        _initClone(clone, 301, DEFAULT_MAX_WALLET_BPS, DEFAULT_WINDOW, new address[](0));
    }

    function test_revertsMaxWalletBpsTooLow() public {
        address clone = _cloneImpl();
        vm.expectRevert(SniperProtection.MaxWalletBpsTooLow.selector);
        _initClone(clone, DEFAULT_MAX_BUY_BPS, 9, DEFAULT_WINDOW, new address[](0));
    }

    function test_revertsMaxWalletBpsTooHigh() public {
        address clone = _cloneImpl();
        vm.expectRevert(SniperProtection.MaxWalletBpsTooHigh.selector);
        _initClone(clone, DEFAULT_MAX_BUY_BPS, 301, DEFAULT_WINDOW, new address[](0));
    }

    function test_revertsProtectionWindowTooShort() public {
        address clone = _cloneImpl();
        vm.expectRevert(SniperProtection.ProtectionWindowTooShort.selector);
        _initClone(clone, DEFAULT_MAX_BUY_BPS, DEFAULT_MAX_WALLET_BPS, 59 seconds, new address[](0));
    }

    function test_revertsProtectionWindowTooLong() public {
        address clone = _cloneImpl();
        vm.expectRevert(SniperProtection.ProtectionWindowTooLong.selector);
        _initClone(clone, DEFAULT_MAX_BUY_BPS, DEFAULT_MAX_WALLET_BPS, 1 days + 1, new address[](0));
    }

    /// @dev Deploy a fresh clone (pre-init). Split from `_initClone` so revert tests can
    ///      wrap only the init call with `expectRevert` (the CREATE opcode otherwise confuses it).
    function _cloneImpl() internal virtual returns (address);

    /// @dev Initialize a clone with the given configs.
    function _initClone(address clone, uint16 maxBuyBps, uint16 maxWalletBps, uint40 window, address[] memory whitelist)
        internal
        virtual;

    /// @dev Convenience: clone + init in one step, returning the typed token.
    function _deployCustom(uint16 maxBuyBps, uint16 maxWalletBps, uint40 window, address[] memory whitelist)
        internal
        returns (LivoToken)
    {
        address clone = _cloneImpl();
        _initClone(clone, maxBuyBps, maxWalletBps, window, whitelist);
        return LivoToken(payable(clone));
    }
}

/// -------------------- Plain variant --------------------

contract LivoTokenSniperProtectedTest is SniperProtectionBaseTest {
    LivoTokenSniperProtected internal token;
    LivoTokenSniperProtected internal impl;

    function setUp() public {
        launchpadMock = new MockLaunchpad();
        launchpad = address(launchpadMock);

        graduator = new MockGraduator(makeAddr("pair"));
        impl = new LivoTokenSniperProtected();
        token = LivoTokenSniperProtected(Clones.clone(address(impl)));
        token.initialize(
            ILivoToken.InitializeParams({
                name: "TestSniper",
                symbol: "TSNP",
                tokenOwner: tokenOwner,
                graduator: address(graduator),
                launchpad: launchpad,
                feeHandler: feeHandler,
                feeReceiver: feeReceiver
            }),
            _defaultCfg()
        );
    }

    function _token() internal view override returns (LivoToken) {
        return LivoToken(address(token));
    }

    function _cloneImpl() internal override returns (address) {
        return Clones.clone(address(impl));
    }

    function _initClone(address clone, uint16 maxBuyBps, uint16 maxWalletBps, uint40 window, address[] memory whitelist)
        internal
        override
    {
        LivoTokenSniperProtected(clone)
            .initialize(
                ILivoToken.InitializeParams({
                    name: "CustomSniper",
                    symbol: "CSNP",
                    tokenOwner: tokenOwner,
                    graduator: address(graduator),
                    launchpad: launchpad,
                    feeHandler: feeHandler,
                    feeReceiver: feeReceiver
                }),
                AntiSniperConfigs({
                    maxBuyPerTxBps: maxBuyBps,
                    maxWalletBps: maxWalletBps,
                    protectionWindowSeconds: window,
                    whitelist: whitelist
                })
            );
    }
}

/// -------------------- Taxable variant --------------------

contract LivoTaxableTokenUniV4SniperProtectedTest is SniperProtectionBaseTest {
    LivoTaxableTokenUniV4SniperProtected internal token;
    LivoTaxableTokenUniV4SniperProtected internal impl;

    function setUp() public {
        vm.chainId(DeploymentAddressesMainnet.BLOCKCHAIN_ID);

        launchpadMock = new MockLaunchpad();
        launchpad = address(launchpadMock);

        graduator = new MockGraduator(DeploymentAddressesMainnet.UNIV4_POOL_MANAGER);
        impl = new LivoTaxableTokenUniV4SniperProtected();
        token = LivoTaxableTokenUniV4SniperProtected(payable(Clones.clone(address(impl))));
        token.initialize(
            ILivoToken.InitializeParams({
                name: "TestSniperTax",
                symbol: "TSNT",
                tokenOwner: tokenOwner,
                graduator: address(graduator),
                launchpad: launchpad,
                feeHandler: feeHandler,
                feeReceiver: feeReceiver
            }),
            TaxConfigInit({buyTaxBps: 100, sellTaxBps: 100, taxDurationSeconds: uint32(1 days)}),
            _defaultCfg()
        );
    }

    function _token() internal view override returns (LivoToken) {
        return LivoToken(payable(address(token)));
    }

    function _cloneImpl() internal override returns (address) {
        return Clones.clone(address(impl));
    }

    function _initClone(address clone, uint16 maxBuyBps, uint16 maxWalletBps, uint40 window, address[] memory whitelist)
        internal
        override
    {
        LivoTaxableTokenUniV4SniperProtected(payable(clone))
            .initialize(
                ILivoToken.InitializeParams({
                    name: "CustomSniperTax",
                    symbol: "CSNT",
                    tokenOwner: tokenOwner,
                    graduator: address(graduator),
                    launchpad: launchpad,
                    feeHandler: feeHandler,
                    feeReceiver: feeReceiver
                }),
                TaxConfigInit({buyTaxBps: 100, sellTaxBps: 100, taxDurationSeconds: uint32(1 days)}),
                AntiSniperConfigs({
                    maxBuyPerTxBps: maxBuyBps,
                    maxWalletBps: maxWalletBps,
                    protectionWindowSeconds: window,
                    whitelist: whitelist
                })
            );
    }
}

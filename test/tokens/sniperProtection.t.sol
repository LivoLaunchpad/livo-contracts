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
import {SniperProtection} from "src/tokens/SniperProtection.sol";
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

/// @dev Minimal launchpad stub exposing `whitelistedFactories` — the only method the token
///      queries from the sniper-protection check.
contract MockLaunchpad {
    mapping(address => bool) public whitelistedFactories;

    function setWhitelistedFactory(address factory, bool value) external {
        whitelistedFactories[factory] = value;
    }
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

    MockLaunchpad internal launchpadMock;
    MockGraduator internal graduator;

    address internal launchpad; // cached address(launchpadMock) for terse assertions

    uint256 internal constant TOTAL_SUPPLY = 1_000_000_000e18;
    uint256 internal constant MAX_BUY_PER_TX = 30_000_000e18; // 3% — SniperProtection.SNIPER_MAX_BUY_PER_TX
    uint256 internal constant MAX_WALLET = 30_000_000e18; // 3% — SniperProtection.SNIPER_MAX_WALLET
    uint40 internal constant WINDOW = 3 hours;

    function _token() internal view virtual returns (LivoToken);

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
        // Setup completed in subclass setUp(); reaching this point proves initialize() succeeded.
        assertEq(_token().balanceOf(launchpad), TOTAL_SUPPLY);
    }

    function test_launchTimestampRecorded() public view {
        uint40 ts = SniperProtection(address(_token())).launchTimestamp();
        assertGt(ts, 0);
        assertEq(ts, uint40(block.timestamp));
    }

    function test_maxBuyPerTx_boundary() public {
        _curveBuy(buyer, MAX_BUY_PER_TX); // exactly at the cap — ok
        assertEq(_token().balanceOf(buyer), MAX_BUY_PER_TX);
    }

    function test_maxBuyPerTx_reverts() public {
        vm.prank(launchpad);
        vm.expectRevert(SniperProtection.MaxBuyPerTxExceeded.selector);
        _token().transfer(buyer, MAX_BUY_PER_TX + 1);
    }

    function test_maxWallet_boundary() public {
        // Two buys that land exactly on the wallet cap.
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
        // Seed the seller with tokens first (within caps), then sell a large chunk back.
        _curveBuy(seller, MAX_BUY_PER_TX);

        // A sell moves tokens FROM user TO launchpad — `from != launchpad`, so the check no-ops.
        _curveSell(seller, MAX_BUY_PER_TX);
        assertEq(_token().balanceOf(seller), 0);
    }

    function test_windowExpiry_capsLift() public {
        uint40 launchTs = SniperProtection(address(_token())).launchTimestamp();
        vm.warp(launchTs + WINDOW + 1);

        // Full cap + 1 should now succeed.
        _curveBuy(buyer, MAX_BUY_PER_TX + 1);
        assertEq(_token().balanceOf(buyer), MAX_BUY_PER_TX + 1);

        // Wallet cap also lifted: second buy far above max-wallet succeeds.
        _curveBuy(buyer, MAX_WALLET * 2);
        assertEq(_token().balanceOf(buyer), MAX_BUY_PER_TX + 1 + MAX_WALLET * 2);
    }

    function test_postGraduationBypass_withinWindow() public {
        // Still inside the 3h window, but graduated — caps must not apply.
        vm.warp(block.timestamp + 30 minutes);
        vm.prank(address(graduator));
        _token().markGraduated();

        // After graduation, `to == pair` no longer reverts, and the sniper branch short-circuits on `graduated`.
        _curveBuy(buyer, MAX_BUY_PER_TX + 1);
        assertEq(_token().balanceOf(buyer), MAX_BUY_PER_TX + 1);
    }

    function test_walletToWalletUnaffected_postGraduation() public {
        // Seed buyer within caps, graduate, then do a large wallet-to-wallet transfer.
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

    /// Deployer-buy path: launchpad → whitelisted factory → deployer. The launchpad → factory
    /// hop carries the full deployer-buy amount (up to the factory's `maxDeployerBuyBps`, 10%),
    /// which is far above the 3% sniper cap. Both the max-per-tx and max-wallet checks must be
    /// skipped when the recipient is a whitelisted factory.
    function test_deployerBuyViaWhitelistedFactory_bypassesCaps() public {
        uint256 deployerBuyAmount = TOTAL_SUPPLY / 10; // 10% — well above MAX_BUY_PER_TX and MAX_WALLET

        // Simulate the launchpad's internal transfer into the factory during `_buyOnBehalf`.
        vm.prank(launchpad);
        _token().transfer(factory, deployerBuyAmount);
        assertEq(_token().balanceOf(factory), deployerBuyAmount);

        // And the factory's follow-up transfer to the deployer (from != launchpad, so sniper
        // check is inactive regardless of whitelist status).
        vm.prank(factory);
        _token().transfer(deployer, deployerBuyAmount);
        assertEq(_token().balanceOf(deployer), deployerBuyAmount);
    }

    /// Non-whitelisted recipients are still capped — ensures the exemption is scoped to the
    /// launchpad's own factory set and not open to arbitrary contract recipients.
    function test_nonWhitelistedRecipient_stillCapped() public {
        address otherContract = makeAddr("otherContract");
        assertFalse(launchpadMock.whitelistedFactories(otherContract));

        vm.prank(launchpad);
        vm.expectRevert(SniperProtection.MaxBuyPerTxExceeded.selector);
        _token().transfer(otherContract, MAX_BUY_PER_TX + 1);
    }

    function test_constantsMatchSpec() public view {
        SniperProtection sp = SniperProtection(address(_token()));
        assertEq(sp.SNIPER_MAX_BUY_PER_TX(), 30_000_000e18);
        assertEq(sp.SNIPER_MAX_WALLET(), 30_000_000e18);
        assertEq(uint256(sp.SNIPER_PROTECTION_WINDOW()), 3 hours);
    }
}

/// -------------------- Plain variant --------------------

contract LivoTokenSniperProtectedTest is SniperProtectionBaseTest {
    LivoTokenSniperProtected internal token;

    function setUp() public {
        launchpadMock = new MockLaunchpad();
        launchpad = address(launchpadMock);
        launchpadMock.setWhitelistedFactory(factory, true);

        graduator = new MockGraduator(makeAddr("pair"));
        LivoTokenSniperProtected impl = new LivoTokenSniperProtected();
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
            })
        );
    }

    function _token() internal view override returns (LivoToken) {
        return LivoToken(address(token));
    }
}

/// -------------------- Taxable variant --------------------

contract LivoTaxableTokenUniV4SniperProtectedTest is SniperProtectionBaseTest {
    LivoTaxableTokenUniV4SniperProtected internal token;

    function setUp() public {
        // LivoTaxableTokenUniV4 constructor enforces mainnet chain id.
        vm.chainId(DeploymentAddressesMainnet.BLOCKCHAIN_ID);

        launchpadMock = new MockLaunchpad();
        launchpad = address(launchpadMock);
        launchpadMock.setWhitelistedFactory(factory, true);

        // The taxable token requires pair == UNIV4_POOL_MANAGER.
        graduator = new MockGraduator(DeploymentAddressesMainnet.UNIV4_POOL_MANAGER);
        LivoTaxableTokenUniV4SniperProtected impl = new LivoTaxableTokenUniV4SniperProtected();
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
            100, // buyTaxBps
            100, // sellTaxBps
            uint40(1 days)
        );
    }

    function _token() internal view override returns (LivoToken) {
        return LivoToken(payable(address(token)));
    }
}

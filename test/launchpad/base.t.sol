// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {LivoLaunchpad} from "src/LivoLaunchpad.sol";
import {LivoToken} from "src/tokens/LivoToken.sol";
import {ILivoToken} from "src/interfaces/ILivoToken.sol";
import {ILivoFactory} from "src/interfaces/ILivoFactory.sol";
import {LivoFactoryTaxToken as _LFTT} from "src/factories/LivoFactoryTaxToken.sol";
import {LivoFactoryExtendedTax as _LFET} from "src/factories/LivoFactoryExtendedTax.sol";
import {LivoFactoryTaxTokenSniperProtected as _LFTTS} from "src/factories/LivoFactoryTaxTokenSniperProtected.sol";
import {LivoFactorySniperProtected} from "src/factories/LivoFactorySniperProtected.sol";
import {LivoFactoryUniV2SniperProtected} from "src/factories/LivoFactoryUniV2SniperProtected.sol";
import {LivoTokenSniperProtected} from "src/tokens/LivoTokenSniperProtected.sol";
import {LivoTaxableTokenUniV4SniperProtected} from "src/tokens/LivoTaxableTokenUniV4SniperProtected.sol";
import {AntiSniperConfigs} from "src/tokens/SniperProtection.sol";
import {ConstantProductBondingCurve} from "src/bondingCurves/ConstantProductBondingCurve.sol";
import {LivoGraduatorUniswapV2} from "src/graduators/LivoGraduatorUniswapV2.sol";
import {LivoGraduatorUniswapV4} from "src/graduators/LivoGraduatorUniswapV4.sol";
import {DeploymentAddressesMainnet} from "src/config/DeploymentAddresses.sol";
import {ILivoGraduator} from "src/interfaces/ILivoGraduator.sol";
import {TokenConfig, TokenState} from "src/types/tokenData.sol";
import {IUniswapV2Router02} from "src/interfaces/IUniswapV2Router02.sol";
import {IUniswapV2Factory} from "src/interfaces/IUniswapV2Factory.sol";
import {IWETH} from "src/interfaces/IWETH.sol";
import {LivoSwapHook} from "src/hooks/LivoSwapHook.sol";
import {LivoTaxableTokenUniV4} from "src/tokens/LivoTaxableTokenUniV4.sol";
import {LivoFactoryBase} from "src/factories/LivoFactoryBase.sol";
import {LivoFactoryUniV2} from "src/factories/LivoFactoryUniV2.sol";
import {Clones} from "lib/openzeppelin-contracts/contracts/proxy/Clones.sol";
import {LivoFactoryTaxToken} from "src/factories/LivoFactoryTaxToken.sol";
import {LivoFeeHandler} from "src/feeHandlers/LivoFeeHandler.sol";
import {LivoFeeSplitter} from "src/feeSplitters/LivoFeeSplitter.sol";

contract TestLivoFactory is LivoFactoryBase {
    constructor(
        address launchpad,
        address tokenImplementation,
        address bondingCurve,
        address graduator,
        address feeHandler,
        address feeSplitterImplementation
    ) LivoFactoryBase(launchpad, tokenImplementation, bondingCurve, graduator, feeHandler, feeSplitterImplementation) {}
}

contract TestLivoFactoryUniV2 is LivoFactoryUniV2 {
    constructor(
        address launchpad,
        address tokenImplementation,
        address bondingCurve,
        address graduator,
        address feeHandler,
        address feeSplitterImplementation
    )
        LivoFactoryUniV2(launchpad, tokenImplementation, bondingCurve, graduator, feeHandler, feeSplitterImplementation)
    {}
}

contract LaunchpadBaseTests is Test {
    LivoLaunchpad public launchpad;

    LivoToken public livoToken;
    LivoTaxableTokenUniV4 public livoTaxToken;

    ILivoToken public implementation;

    ConstantProductBondingCurve public bondingCurve;

    ILivoGraduator public graduator;

    TestLivoFactoryUniV2 public factoryV2;
    TestLivoFactory public factoryV4;
    LivoFactoryTaxToken public factoryTax;
    LivoFactorySniperProtected public factorySniper;
    LivoFactoryUniV2SniperProtected public factoryV2Sniper;
    _LFTTS public factoryTaxSniper;
    LivoTokenSniperProtected public livoTokenSniper;
    LivoTaxableTokenUniV4SniperProtected public livoTaxTokenSniper;
    LivoFeeHandler public feeHandler;

    address public treasury = makeAddr("treasury");
    address public creator = makeAddr("creator");
    address public buyer = makeAddr("buyer");
    address public seller = makeAddr("seller");

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    address public admin = makeAddr("admin");

    address public testToken;

    uint256 public constant INITIAL_ETH_BALANCE = 100 ether;
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;
    uint256 public constant CREATOR_GRADUATION_COMPENSATION = 0.05 ether;
    uint256 constant GRADUATION_FEE = 0.25 ether;
    uint16 public constant BASE_BUY_FEE_BPS = 100;
    uint16 public constant BASE_SELL_FEE_BPS = 100;

    uint256 constant GRADUATION_THRESHOLD = 3.75 ether;
    uint256 constant MAX_THRESHOLD_EXCESS = 0.05 ether;

    // we don't test deadlines mostly
    uint256 constant DEADLINE = type(uint256).max;
    address constant DEAD_ADDRESS = DeploymentAddressesMainnet.DEAD_ADDRESS;

    // Hook address with correct Uniswap V4 permission bits; deployCodeTo() overrides whatever is at this address
    address constant TEST_HOOK_ADDRESS = 0x2ca2764a626de36331E20b08aEd13E5C7A0240cC;

    // for fork tests
    uint256 constant BLOCKNUMBER = 23327777;

    // uniswapv4 addresses in mainnet
    address constant poolManagerAddress = DeploymentAddressesMainnet.UNIV4_POOL_MANAGER;
    address constant positionManagerAddress = DeploymentAddressesMainnet.UNIV4_POSITION_MANAGER;
    address constant permit2Address = DeploymentAddressesMainnet.PERMIT2;
    address constant universalRouter = DeploymentAddressesMainnet.UNIV4_UNIVERSAL_ROUTER;

    // Uniswap V2 router address on mainnet
    address constant UNISWAP_V2_ROUTER = DeploymentAddressesMainnet.UNIV2_ROUTER;
    IUniswapV2Factory constant UNISWAP_FACTORY = IUniswapV2Factory(DeploymentAddressesMainnet.UNIV2_FACTORY);
    IWETH constant WETH = IWETH(DeploymentAddressesMainnet.WETH);

    // This is the effective price when buying at graduation (from bonding curve slope)
    uint256 constant GRADUATION_PRICE = 12373924040; // ETH/token (eth per token, expressed in wei)
    // This is the pool setpoint price derived from SQRT_PRICEX96_GRADUATION
    uint256 constant POOL_SETPOINT_PRICE = 12249999999; // ETH/token (eth per token, expressed in wei)

    LivoGraduatorUniswapV2 public graduatorV2;
    LivoGraduatorUniswapV4 public graduatorV4;
    LivoSwapHook public taxHook;

    uint256 internal _saltCounter;

    function _nextValidSalt(address factory, address impl) internal returns (bytes32 salt) {
        for (uint256 i = _saltCounter;; i++) {
            salt = bytes32(i);
            address predicted = Clones.predictDeterministicAddress(impl, salt, factory);
            if (uint16(uint160(predicted)) == 0x1110) {
                _saltCounter = i + 1;
                return salt;
            }
        }
    }

    /// @dev Build a single-entry FeeShare[] with `account` getting 100% of fees.
    function _fs(address account) internal pure returns (ILivoFactory.FeeShare[] memory arr) {
        arr = new ILivoFactory.FeeShare[](1);
        arr[0] = ILivoFactory.FeeShare({account: account, shares: 10_000});
    }

    /// @dev Build an empty FeeShare[] (only valid for UniV2 factory).
    function _noFs() internal pure returns (ILivoFactory.FeeShare[] memory arr) {
        return new ILivoFactory.FeeShare[](0);
    }

    /// @dev Build an empty SupplyShare[] (valid when msg.value == 0).
    function _noSs() internal pure returns (ILivoFactory.SupplyShare[] memory arr) {
        return new ILivoFactory.SupplyShare[](0);
    }

    /// @dev Build a single-entry SupplyShare[] with `account` receiving 100% of the bought supply.
    function _ss(address account) internal pure returns (ILivoFactory.SupplyShare[] memory arr) {
        arr = new ILivoFactory.SupplyShare[](1);
        arr[0] = ILivoFactory.SupplyShare({account: account, shares: 10_000});
    }

    /// @dev Build a `LivoFactoryTaxToken.TaxCfg` calldata-compatible struct for passing to `factoryTax.createToken`.
    function _taxCfg(uint16 buyTaxBps, uint16 sellTaxBps, uint32 taxDurationSeconds)
        internal
        pure
        returns (_LFTT.TaxCfg memory)
    {
        return _LFTT.TaxCfg({buyTaxBps: buyTaxBps, sellTaxBps: sellTaxBps, taxDurationSeconds: taxDurationSeconds});
    }

    /// @dev Build a `LivoFactoryExtendedTax.TaxCfg` struct.
    function _taxCfgExt(uint16 buyTaxBps, uint16 sellTaxBps, uint32 taxDurationSeconds)
        internal
        pure
        returns (_LFET.TaxCfg memory)
    {
        return _LFET.TaxCfg({buyTaxBps: buyTaxBps, sellTaxBps: sellTaxBps, taxDurationSeconds: taxDurationSeconds});
    }

    /// @dev Build a `LivoFactoryTaxTokenSniperProtected.TaxCfg` struct (same fields as the non-sniper one).
    function _taxCfgSniper(uint16 buyTaxBps, uint16 sellTaxBps, uint32 taxDurationSeconds)
        internal
        pure
        returns (_LFTTS.TaxCfg memory)
    {
        return _LFTTS.TaxCfg({buyTaxBps: buyTaxBps, sellTaxBps: sellTaxBps, taxDurationSeconds: taxDurationSeconds});
    }

    /// @dev Build a default `AntiSniperConfigs` (3% / 3% / 3h, empty whitelist).
    function _defaultAntiSniperCfg() internal pure returns (AntiSniperConfigs memory) {
        return AntiSniperConfigs({
            maxBuyPerTxBps: 300, maxWalletBps: 300, protectionWindowSeconds: 3 hours, whitelist: new address[](0)
        });
    }

    /// @dev Build a custom `AntiSniperConfigs`.
    function _antiSniperCfg(uint16 maxBuyBps, uint16 maxWalletBps, uint40 window, address[] memory whitelist)
        internal
        pure
        returns (AntiSniperConfigs memory)
    {
        return AntiSniperConfigs({
            maxBuyPerTxBps: maxBuyBps, maxWalletBps: maxWalletBps, protectionWindowSeconds: window, whitelist: whitelist
        });
    }

    function setUp() public virtual {
        string memory mainnetRpcUrl = vm.envString("MAINNET_RPC_URL");
        vm.createSelectFork(mainnetRpcUrl, BLOCKNUMBER);

        vm.deal(creator, INITIAL_ETH_BALANCE);
        vm.deal(buyer, INITIAL_ETH_BALANCE);
        vm.deal(seller, INITIAL_ETH_BALANCE);
        vm.deal(alice, INITIAL_ETH_BALANCE);
        vm.deal(bob, INITIAL_ETH_BALANCE);

        vm.startPrank(admin);
        livoToken = new LivoToken();
        livoTaxToken = new LivoTaxableTokenUniV4();

        // todo do we need this outside this setup ?
        implementation = livoToken;
        launchpad = new LivoLaunchpad(treasury, admin);
        bondingCurve = new ConstantProductBondingCurve();
        graduatorV2 = new LivoGraduatorUniswapV2(UNISWAP_V2_ROUTER, address(launchpad));

        deployCodeTo(
            "LivoSwapHook.sol:LivoSwapHook", abi.encode(poolManagerAddress, address(launchpad)), TEST_HOOK_ADDRESS
        );
        taxHook = LivoSwapHook(payable(TEST_HOOK_ADDRESS));

        feeHandler = new LivoFeeHandler();

        graduatorV4 = new LivoGraduatorUniswapV4(
            address(launchpad), poolManagerAddress, positionManagerAddress, permit2Address, TEST_HOOK_ADDRESS
        );

        LivoFeeSplitter feeSplitterImpl = new LivoFeeSplitter();

        factoryV2 = new TestLivoFactoryUniV2(
            address(launchpad),
            address(livoToken),
            address(bondingCurve),
            address(graduatorV2),
            address(feeHandler),
            address(feeSplitterImpl)
        );

        factoryV4 = new TestLivoFactory(
            address(launchpad),
            address(livoToken),
            address(bondingCurve),
            address(graduatorV4),
            address(feeHandler),
            address(feeSplitterImpl)
        );

        factoryTax = new LivoFactoryTaxToken(
            address(launchpad),
            address(livoTaxToken),
            address(bondingCurve),
            address(graduatorV4),
            address(feeHandler),
            address(feeSplitterImpl)
        );

        livoTokenSniper = new LivoTokenSniperProtected();
        livoTaxTokenSniper = new LivoTaxableTokenUniV4SniperProtected();

        factorySniper = new LivoFactorySniperProtected(
            address(launchpad),
            address(livoTokenSniper),
            address(bondingCurve),
            address(graduatorV4),
            address(feeHandler),
            address(feeSplitterImpl)
        );

        factoryV2Sniper = new LivoFactoryUniV2SniperProtected(
            address(launchpad),
            address(livoTokenSniper),
            address(bondingCurve),
            address(graduatorV2),
            address(feeHandler),
            address(feeSplitterImpl)
        );

        factoryTaxSniper = new _LFTTS(
            address(launchpad),
            address(livoTaxTokenSniper),
            address(bondingCurve),
            address(graduatorV4),
            address(feeHandler),
            address(feeSplitterImpl)
        );

        launchpad.whitelistFactory(address(factoryV2));
        launchpad.whitelistFactory(address(factoryV4));
        launchpad.whitelistFactory(address(factoryTax));
        launchpad.whitelistFactory(address(factorySniper));
        launchpad.whitelistFactory(address(factoryV2Sniper));
        launchpad.whitelistFactory(address(factoryTaxSniper));

        vm.stopPrank();
    }

    modifier createTestToken() virtual {
        vm.prank(creator);
        if (address(graduator) == address(graduatorV4)) {
            if (address(implementation) == address(livoTaxToken)) {
                (testToken,) = factoryTax.createToken(
                    "TestToken",
                    "TEST",
                    _nextValidSalt(address(factoryTax), address(livoTaxToken)),
                    _fs(creator),
                    _noSs(),
                    _taxCfg(0, 400, uint32(14 days))
                );
            } else {
                (testToken,) = factoryV4.createToken(
                    "TestToken", "TEST", _nextValidSalt(address(factoryV4), address(livoToken)), _fs(creator), _noSs()
                );
            }
        } else {
            (testToken,) = factoryV2.createToken(
                "TestToken", "TEST", _nextValidSalt(address(factoryV2), address(livoToken)), _fs(creator), _noSs()
            );
        }
        _;
    }

    function _graduateToken() internal {
        uint256 ethReserves = launchpad.getTokenState(testToken).ethCollected;
        uint256 missingForGraduation = _increaseWithFees(GRADUATION_THRESHOLD - ethReserves);
        _launchpadBuy(testToken, missingForGraduation);
    }

    function _launchpadBuy(address token, uint256 value) internal {
        vm.deal(buyer, value);
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: value}(token, 0, DEADLINE);
    }

    function _increaseWithFees(uint256 ethIntoReserves) internal pure returns (uint256 ethBuy) {
        ethBuy = (ethIntoReserves * 10000) / (10000 - BASE_BUY_FEE_BPS);
    }
}

contract LaunchpadBaseTestsWithUniv2Graduator is LaunchpadBaseTests {
    uint256 public SELL_TAX_BPS = 0; // 0% sell tax

    function setUp() public virtual override {
        super.setUp();

        graduator = graduatorV2;
    }
}

contract LaunchpadBaseTestsWithUniv4Graduator is LaunchpadBaseTests {
    uint256 public SELL_TAX_BPS = 0; // 0% sell tax

    function setUp() public virtual override {
        super.setUp();

        graduator = graduatorV4;
    }
}

contract LaunchpadBaseTestsWithUniv4GraduatorTaxableToken is LaunchpadBaseTests {
    uint256 public SELL_TAX_BPS = 400; // 4% sell tax

    function setUp() public virtual override {
        super.setUp();

        graduator = graduatorV4;
        /// todo question do we need this?
        implementation = livoTaxToken;
    }
}

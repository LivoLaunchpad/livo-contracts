// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {LivoLaunchpad} from "src/LivoLaunchpad.sol";
import {LivoToken} from "src/tokens/LivoToken.sol";
import {ILivoToken} from "src/interfaces/ILivoToken.sol";
import {ILivoFactory} from "src/interfaces/ILivoFactory.sol";
import {TaxConfigInit} from "src/interfaces/ILivoTaxableTokenUniV4.sol";
import {LivoFactoryUniV2Unified} from "src/factories/LivoFactoryUniV2Unified.sol";
import {LivoFactoryUniV4Unified} from "src/factories/LivoFactoryUniV4Unified.sol";
import {DeployersWhitelist} from "src/factories/DeployersWhitelist.sol";
import {LivoTokenSniperProtected} from "src/tokens/LivoTokenSniperProtected.sol";
import {LivoTaxableTokenUniV2} from "src/tokens/LivoTaxableTokenUniV2.sol";
import {LivoTaxableTokenUniV2SniperProtected} from "src/tokens/LivoTaxableTokenUniV2SniperProtected.sol";
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
import {Clones} from "lib/openzeppelin-contracts/contracts/proxy/Clones.sol";
import {LivoMasterFeeHandler} from "src/feeHandlers/LivoMasterFeeHandler.sol";

contract LaunchpadBaseTests is Test {
    LivoLaunchpad public launchpad;

    LivoToken public livoToken;
    LivoTaxableTokenUniV4 public livoTaxToken;
    LivoTaxableTokenUniV2 public livoTaxTokenV2;
    LivoTaxableTokenUniV2SniperProtected public livoTaxTokenV2Sniper;

    ILivoToken public implementation;

    ConstantProductBondingCurve public bondingCurve;

    ILivoGraduator public graduator;

    // Two unified factories. Legacy aliases below point to these instances so existing call sites
    // that read `factoryV2`, `factoryV4`, `factoryTax`, `factoryV2Sniper`, `factorySniper`, and
    // `factoryTaxSniper` keep working. The unified factories dispatch implementations based on
    // `TaxConfigInit`/`AntiSniperConfigs` sentinels.
    LivoFactoryUniV2Unified public factoryV2Unified;
    LivoFactoryUniV4Unified public factoryV4Unified;
    DeployersWhitelist public deployersWhitelist;

    // Legacy aliases (read-only). The pre-consolidation factories (`LivoFactoryUniV2`,
    // `LivoFactoryUniV4`, `LivoFactoryTaxToken`, `LivoFactoryUniV2SniperProtected`,
    // `LivoFactoryUniV4SniperProtected`, `LivoFactoryTaxTokenSniperProtected`) no longer exist;
    // these names now refer to the unified factories so the test surface remains stable.
    LivoFactoryUniV2Unified public factoryV2;
    LivoFactoryUniV2Unified public factoryV2Sniper;
    LivoFactoryUniV4Unified public factoryV4;
    LivoFactoryUniV4Unified public factoryTax;
    LivoFactoryUniV4Unified public factorySniper;
    LivoFactoryUniV4Unified public factoryTaxSniper;

    LivoTokenSniperProtected public livoTokenSniper;
    LivoTaxableTokenUniV4SniperProtected public livoTaxTokenSniper;
    LivoMasterFeeHandler public feeHandler;

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
    uint256 public constant CREATOR_GRADUATION_COMPENSATION = 0.125 ether;
    uint256 public constant TRIGGERER_GRADUATION_COMPENSATION = 0.002 ether;
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

    /// @dev Build a single-entry FeeShare[] with `account` getting 100% of fees (claimable, no direct).
    function _fs(address account) internal pure returns (ILivoFactory.FeeShare[] memory arr) {
        arr = new ILivoFactory.FeeShare[](1);
        arr[0] = ILivoFactory.FeeShare({account: account, shares: 10_000, directFeesEnabled: false});
    }

    /// @dev Build a single-entry FeeShare[] with `account` opted into direct fee forwarding.
    function _fsDirect(address account) internal pure returns (ILivoFactory.FeeShare[] memory arr) {
        arr = new ILivoFactory.FeeShare[](1);
        arr[0] = ILivoFactory.FeeShare({account: account, shares: 10_000, directFeesEnabled: true});
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

    /// @dev Build a `TaxConfigInit` struct for passing to any tax-factory's `createToken`.
    function _taxCfg(uint16 buyTaxBps, uint16 sellTaxBps, uint32 taxDurationSeconds)
        internal
        pure
        returns (TaxConfigInit memory)
    {
        return TaxConfigInit({buyTaxBps: buyTaxBps, sellTaxBps: sellTaxBps, taxDurationSeconds: taxDurationSeconds});
    }

    /// @dev Empty `TaxConfigInit` — sentinel for "no tax variant" (taxDurationSeconds == 0 disables dispatch).
    function _emptyTaxCfg() internal pure returns (TaxConfigInit memory) {
        return TaxConfigInit({buyTaxBps: 0, sellTaxBps: 0, taxDurationSeconds: 0});
    }

    /// @dev Empty `AntiSniperConfigs` — sentinel for "no sniper protection" (protectionWindowSeconds == 0).
    function _emptyAntiSniperCfg() internal pure returns (AntiSniperConfigs memory) {
        return AntiSniperConfigs({
            maxBuyPerTxBps: 0, maxWalletBps: 0, protectionWindowSeconds: 0, whitelist: new address[](0)
        });
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

        implementation = livoToken;
        launchpad = new LivoLaunchpad(treasury, admin);
        bondingCurve = new ConstantProductBondingCurve();
        graduatorV2 = new LivoGraduatorUniswapV2(
            UNISWAP_V2_ROUTER, address(launchpad), DeploymentAddressesMainnet.UNIV2_PAIR_INIT_CODE_HASH
        );

        deployCodeTo(
            "LivoSwapHook.sol:LivoSwapHook", abi.encode(poolManagerAddress, address(launchpad)), TEST_HOOK_ADDRESS
        );
        taxHook = LivoSwapHook(payable(TEST_HOOK_ADDRESS));

        feeHandler = new LivoMasterFeeHandler();

        graduatorV4 = new LivoGraduatorUniswapV4(
            address(launchpad), poolManagerAddress, positionManagerAddress, permit2Address, TEST_HOOK_ADDRESS
        );

        livoTokenSniper = new LivoTokenSniperProtected();
        livoTaxTokenSniper = new LivoTaxableTokenUniV4SniperProtected();
        livoTaxTokenV2 = new LivoTaxableTokenUniV2();
        livoTaxTokenV2Sniper = new LivoTaxableTokenUniV2SniperProtected();
        deployersWhitelist = new DeployersWhitelist();
        deployersWhitelist.setAdmin(admin, true);

        factoryV2Unified = new LivoFactoryUniV2Unified(
            address(launchpad),
            address(livoToken),
            address(livoTokenSniper),
            address(livoTaxTokenV2),
            address(livoTaxTokenV2Sniper),
            address(bondingCurve),
            address(graduatorV2),
            address(feeHandler),
            address(deployersWhitelist)
        );

        factoryV4Unified = new LivoFactoryUniV4Unified(
            address(launchpad),
            address(livoToken),
            address(livoTokenSniper),
            address(livoTaxToken),
            address(livoTaxTokenSniper),
            address(bondingCurve),
            address(graduatorV4),
            address(feeHandler),
            address(deployersWhitelist)
        );

        // Legacy aliases — same instance, different reference name. Kept so existing tests that
        // distinguish "tax factory" vs "sniper factory" vs "plain V4 factory" don't all need to
        // be rewritten. Dispatch happens at the call site via the cfg structs.
        factoryV2 = factoryV2Unified;
        factoryV2Sniper = factoryV2Unified;
        factoryV4 = factoryV4Unified;
        factoryTax = factoryV4Unified;
        factorySniper = factoryV4Unified;
        factoryTaxSniper = factoryV4Unified;

        launchpad.whitelistFactory(address(factoryV2Unified));
        launchpad.whitelistFactory(address(factoryV4Unified));

        vm.stopPrank();
    }

    modifier createTestToken() virtual {
        vm.prank(creator);
        if (address(graduator) == address(graduatorV4)) {
            if (address(implementation) == address(livoTaxToken)) {
                testToken = factoryV4Unified.createToken(
                    "TestToken",
                    "TEST",
                    _nextValidSalt(address(factoryV4Unified), address(livoTaxToken)),
                    _fs(creator),
                    _noSs(),
                    false,
                    _taxCfg(0, 400, uint32(14 days)),
                    _emptyAntiSniperCfg()
                );
            } else {
                testToken = factoryV4Unified.createToken(
                    "TestToken",
                    "TEST",
                    _nextValidSalt(address(factoryV4Unified), address(livoToken)),
                    _fs(creator),
                    _noSs(),
                    false,
                    _emptyTaxCfg(),
                    _emptyAntiSniperCfg()
                );
            }
        } else {
            testToken = factoryV2Unified.createToken(
                "TestToken",
                "TEST",
                _nextValidSalt(address(factoryV2Unified), address(livoToken)),
                _fs(creator),
                _noSs(),
                false,
                _emptyTaxCfg(),
                _emptyAntiSniperCfg()
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
        implementation = livoTaxToken;
    }
}

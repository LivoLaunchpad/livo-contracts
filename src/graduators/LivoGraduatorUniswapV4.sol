// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ILivoGraduator} from "src/interfaces/ILivoGraduator.sol";
import {ILivoToken} from "src/interfaces/ILivoToken.sol";
import {ILivoLaunchpad} from "src/interfaces/ILivoLaunchpad.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
// import {IUniswapV2Router} from "src/interfaces/IUniswapV2Router.sol";
// import {IUniswapV2Factory} from "src/interfaces/IUniswapV2Factory.sol";
// import {IUniswapV2Pair} from "src/interfaces/IUniswapV2Pair.sol";

// import {ERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
// import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
// // import {BasicHooks} from "src/BasicHooks.sol";

import {PoolKey} from "lib/v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "lib/v4-core/src/interfaces/IPoolManager.sol";
import {CurrencyLibrary, Currency} from "lib/v4-core/src/types/Currency.sol";
import {IHooks} from "lib/v4-core/src/interfaces/IHooks.sol";

import {Actions} from "lib/v4-periphery/src/libraries/Actions.sol";
import {IPositionManager} from "lib/v4-periphery/src/interfaces/IPositionManager.sol";
// import {PositionInfo} from "lib/v4-periphery/src/libraries/PositionInfoLibrary.sol";
// import {IAllowanceTransfer} from "lib/v4-periphery/lib/permit2/src/interfaces/IAllowanceTransfer.sol";
// import {StateLibrary} from "lib/v4-core/src/libraries/StateLibrary.sol";

// import {IPermit2} from "lib/v4-periphery/lib/permit2/src/interfaces/IPermit2.sol";
// import {IV4Router} from "lib/v4-periphery/src/interfaces/IV4Router.sol";
// import {Commands} from "src/dependencies/Univ4UniversalRouterCommands.sol";
import {LiquidityAmounts} from "lib/v4-periphery/src/libraries/LiquidityAmounts.sol";

contract LivoGraduatorUniswapV4 is ILivoGraduator {
    using SafeERC20 for ILivoToken;

    address public immutable LIVO_LAUNCHPAD;

    // /// @notice Uniswap router and factory addresses
    // IUniswapV2Router internal immutable UNISWAP_ROUTER;
    // IUniswapV2Factory internal immutable UNISWAP_FACTORY;

    address internal immutable WETH;

    // todo make these addresses conditional to the chainId
    IPoolManager public immutable poolManager = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    IPositionManager public immutable posm = IPositionManager(0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e);
    // IUniversalRouter public immutable universalRouter = IUniversalRouter(0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af);
    // IPermit2 public immutable permit2 = IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3); // review if this is needed

    // fees in pips, i.e. 1e6 = 100%, so 10000 = 1%
    // todo make hook to distribute lp fees to treasury & token creator
    uint24 constant lpFee = 10000;

    // tick spacing used to be 200 for volatile pairs in univ3. (60 for 0.3% fee tier)
    int24 constant tickSpacing = 200;

    //////////////////////////// price setpoint ///////////////////////////////

    // `sqrtPriceX96` is denominated as sqrt(amountToken1/amountToken0) * 2^96

    // starting price: 0.000000003 ETH/token, 333333334 tokens/ETH ->
    // this correspond to a upper tick of 196256
    // to align with 200 tick spacing, and include the starting price, we round up to 196400
    int24 constant tickUpper = 196400;
    uint160 constant sqrtPriceBX96 = 1456928274337359229878378703093760; // upper tick [token/ETH](min token price as ETH/token) --> starting price

    // for the lower tick, we consider the current market cap of BTC as a the max price with liquidity (2305 billion USD)
    // with a token supply of 1 billion, this corresponds to 2305 USD/token
    // the price is denominated in ETH. If ETH price is 2305 USD/ETH, the token price would be 1:1.
    // to be conservative, we consider the scenario in which ETH goes down significantly: ETH price (2.3$ / ETH).
    // So the max price at which we will deploy liquidity will be at 1000 ETH/token
    // The upper ticket for that price would be 69081, but to align it with -196200, we round it down to 69000, which is still pretty conservative
    int24 constant tickLower = -69000;
    uint160 constant sqrtPriceAX96 = 2515582309682650804192804864; // lower tick [token/ETH](max expected price)

    // this starting price is roughly 338156060 tokens for 1 wei, i.e. 0.000000003 ETH/token
    uint160 constant startingPriceX96 = sqrtPriceBX96 - 1; // just below the upper tick price. In range, but minimal eth required to mint the position.

    constructor(address _launchpad, address _poolManager, address _positionManager) {
        LIVO_LAUNCHPAD = _launchpad;
        poolManager = IPoolManager(_poolManager);
        posm = IPositionManager(_positionManager);
    }

    modifier onlyLaunchpad() {
        require(msg.sender == LIVO_LAUNCHPAD, OnlyLaunchpadAllowed());
        _;
    }

    function initializePair(address tokenAddress) external override onlyLaunchpad returns (address) {
        PoolKey memory pool = _getPoolKey(tokenAddress);

        // this sets the price even if there is no liquidity yet
        poolManager.initialize(pool, startingPriceX96);

        // in univ4, there is not a pair address.
        // We return the address of the pool manager, to prevent liquidity deposits until graduation
        emit PairInitialized(tokenAddress, address(poolManager));

        return address(poolManager);
    }

    function graduateToken(address tokenAddress) external payable override onlyLaunchpad {
        ILivoToken token = ILivoToken(tokenAddress);

        // eth can only enter through msg.value, and all of it is deposited as liquidity
        uint256 ethValue = msg.value;
        uint256 tokenBalance = token.balanceOf(address(this));

        require(tokenBalance > 0, NoTokensToGraduate());
        require(ethValue > 0, NoETHToGraduate());

        // this opens the gate of transferring tokens to the uniswap pair
        token.markGraduated();

        // uniswap v4 liquidity position creation
        // question where should we put the nft?
        _mintLiquidity(tokenAddress, ethValue, tokenBalance);

        // emit TokenGraduated(tokenAddress, pair, tokenBalance, amountEth, liquidity);// todo
    }

    function _getPoolKey(address tokenAddress) internal view returns (PoolKey memory) {
        return
            PoolKey({
                currency0: Currency.wrap(address(0)), // native ETH
                currency1: Currency.wrap(address(tokenAddress)),
                fee: lpFee,
                tickSpacing: tickSpacing,
                hooks: IHooks(address(0)) // no hooks ? // todo build necessary hooks if relevant
            });
    }

    function _mintLiquidity(address tokenAddress, uint256 ethValue, uint256 tokenAmount) internal {

        address excessEthRecipient = ILivoLaunchpad(LIVO_LAUNCHPAD).treasury();

        PoolKey memory pool = _getPoolKey(tokenAddress);

        // calculate liquidity based on the startingPrice and the range
        // calculate the liquidity range, assuming we just hit graduation exactly // todo
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            uint160(startingPriceX96), // current pool price --> presumably the starting price which cannot be modified until graduation
            uint160(sqrtPriceAX96), // lower tick price
            uint160(sqrtPriceBX96), // upper tick price
            ethValue, // desired amount0
            tokenAmount // desired amount1
        );
       
        // uint128 liquidity = 54380365000000000000000; // 1e27, somewhat arbitrary, but should be sufficient to move the price
        // console.log("liquidity calculated:", liquidity);

        // Actions for ETH liquidity positions
        // 1. Mint position
        // 2. Settle pair (send ETH and tokens)
        // 3. Sweep any remaining native ETH back to the treasury (only required with native eth positions)
        bytes memory actions =
            abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP));
        bytes[] memory params = new bytes[](3);     

        // parameters for MINT_POSITION action
        // review if this contract should be the receiver of the position NFT
        params[0] = abi.encode(pool, tickLower, tickUpper, liquidity, ethValue, tokenAmount, address(this), "");

        // parameters for SETTLE_PAIR action
        params[1] = abi.encode(pool.currency0, pool.currency1);

        // parameters for SWEEP action
        params[2] = abi.encode(pool.currency0, excessEthRecipient); // sweep all remaining native ETH to recipient

        // the actual call to the position manager to mint the liquidity position
        // deadline = block.timestamp (no effective deadline)
        IPositionManager(posm).modifyLiquidities{value: ethValue}(abi.encode(actions, params), block.timestamp);
    }

    /// @notice Any account can claim these fees, which are sent to token creators (tokens) and to livo treasury (eth)
    function claimFees(address tokenAddress) external {
        // todo 
    }
}

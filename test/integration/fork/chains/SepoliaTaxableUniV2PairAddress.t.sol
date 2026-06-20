// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import {ForkIntegrationBase} from "test/integration/fork/base/ForkIntegrationBase.t.sol";
import {ForkIntegrationCaseLib} from "test/integration/fork/base/ForkIntegrationCaseLib.t.sol";

import {ILivoFactory} from "src/interfaces/ILivoFactory.sol";
import {ILivoToken} from "src/interfaces/ILivoToken.sol";
import {TaxConfigInit} from "src/interfaces/ILivoTaxableToken.sol";
import {IUniswapV2Factory} from "src/interfaces/IUniswapV2Factory.sol";
import {AntiSniperConfigs} from "src/tokens/SniperProtection.sol";

/// @notice Sepolia fork regression test for V2 taxable token pair prediction.
contract SepoliaTaxableUniV2PairAddress is ForkIntegrationBase {
    function _chainConfig() internal view override returns (ForkIntegrationCaseLib.ForkChainConfig memory) {
        return _sepoliaConfig();
    }

    function test_taxableUniV2_pairMatchesUniV2FactoryPairAfterGraduationLiquidityDeployed() public {
        address creator = makeAddr("sepoliaTaxableUniV2Creator");
        vm.deal(creator, INITIAL_ETH_BALANCE);

        ILivoFactory.FeeShare[] memory fees = new ILivoFactory.FeeShare[](1);
        fees[0] = ILivoFactory.FeeShare({account: creator, shares: 10_000, directFeesEnabled: false});
        ILivoFactory.SupplyShare[] memory supply = new ILivoFactory.SupplyShare[](0);
        TaxConfigInit memory taxCfg = TaxConfigInit({
            buyTaxBps: TAX_BUY_BPS,
            sellTaxBps: TAX_SELL_BPS,
            taxDurationSeconds: TAX_DURATION_SECONDS,
            startTaxFromLaunch: true
        });
        AntiSniperConfigs memory noSniper = AntiSniperConfigs({
            maxBuyPerTxBps: 0, maxWalletBps: 0, protectionWindowSeconds: 0, whitelist: new address[](0)
        });

        address impl = factoryV2.previewTokenImplementation(fees, supply, _toCfgs(taxCfg), noSniper);
        _assertCode(impl, "v2 tax impl code missing");
        bytes32 salt = _nextValidSalt(address(factoryV2), impl);

        vm.prank(creator);
        address token = factoryV2.createToken("Sepolia Tax V2", "STV2", salt, fees, supply, taxCfg, noSniper);

        IUniswapV2Factory uniV2Factory = IUniswapV2Factory(forkCfg.uniV2Factory);
        address predictedPair = ILivoToken(token).pair();
        assertEq(uniV2Factory.getPair(token, forkCfg.weth), address(0), "pair exists before graduation");
        assertEq(predictedPair.code.length, 0, "pair code exists before graduation");

        _graduateWithQuoter(token, 0, false);

        address deployedPair = uniV2Factory.getPair(token, forkCfg.weth);
        assertEq(deployedPair, predictedPair, "token.pair must match deployed UniV2 pair");
        assertGt(deployedPair.code.length, 0, "pair contract not deployed");
        assertGt(IERC20(token).balanceOf(deployedPair), 0, "pair missing token liquidity");
        assertGt(IERC20(forkCfg.weth).balanceOf(deployedPair), 0, "pair missing WETH liquidity");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {ConstantProductBondingCurve} from "src/bondingCurves/ConstantProductBondingCurve.sol";

contract ConstantProductPriceImpactSimulations is Test {
    ConstantProductBondingCurve bondingCurve = new ConstantProductBondingCurve();

    uint256 E0 = bondingCurve.E0();
    uint256 K = bondingCurve.K();

    function _estimateSpotPrice(uint256 ethReserves) internal view returns (uint256) {
        // Closed-form spot price (ETH per token, 1e18-scaled): 1e18 * (ethReserves + E0)^2 / K
        return 1e18 * (ethReserves + E0) ** 2 / K;
    }

    function _formatBpsAsPercent(uint256 bps) internal view returns (string memory) {
        // bps: 100 = 1.00%. Print as "X.YZ%" with 2 decimals.
        uint256 whole = bps / 100;
        uint256 frac = bps % 100;
        string memory fracStr = frac < 10 ? string.concat("0", vm.toString(frac)) : vm.toString(frac);
        return string.concat(vm.toString(whole), ".", fracStr, "%");
    }

    function _logPriceImpact(uint256 buySize) internal view {
        uint256 graduation = bondingCurve.ethGraduationThreshold();
        uint256 maxReserves = bondingCurve.maxEthReserves();

        console.log("reserves | currentPrice | priceAfterBuy | priceImpact");

        for (uint256 ethReserves = 0; ethReserves <= graduation; ethReserves += 0.1 ether) {
            if (ethReserves + buySize > maxReserves) break;

            uint256 currentPrice = _estimateSpotPrice(ethReserves);
            (uint256 tokensReceived,) = bondingCurve.buyTokensWithExactEth(ethReserves, buySize);
            uint256 priceAfterBuy = 1e18 * buySize / tokensReceived;
            uint256 priceImpactBps = (priceAfterBuy - currentPrice) * 10000 / currentPrice;

            console.log(ethReserves, currentPrice, priceAfterBuy, _formatBpsAsPercent(priceImpactBps));
        }
    }

    function test_priceImpact_0_1_eth() public {
        vm.skip(true);
        _logPriceImpact(0.1 ether);
    }

    function test_priceImpact_0_5_eth() public {
        vm.skip(true);
        _logPriceImpact(0.5 ether);
    }

    function test_priceImpact_1_eth() public {
        vm.skip(true);
        _logPriceImpact(1 ether);
    }
}

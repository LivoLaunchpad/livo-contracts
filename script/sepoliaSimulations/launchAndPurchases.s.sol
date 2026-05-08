// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LivoLaunchpad} from "src/LivoLaunchpad.sol";
import {LivoFactoryUniV2Unified} from "src/factories/LivoFactoryUniV2Unified.sol";
import {LivoFactoryUniV4Unified} from "src/factories/LivoFactoryUniV4Unified.sol";
import {ILivoFactory} from "src/interfaces/ILivoFactory.sol";
import {TaxConfigInit} from "src/interfaces/ILivoTaxableTokenUniV4.sol";
import {AntiSniperConfigs} from "src/tokens/SniperProtection.sol";
import {Script} from "lib/forge-std/src/Script.sol";

contract BuySellSimulations is Script {
    address LIVODEV = 0xBa489180Ea6EEB25cA65f123a46F3115F388f181;

    function run() public {
        address launchpadAddress = vm.envAddress("LIVOLAUNCHPAD");
        address factoryV2Address = vm.envAddress("FACTORY_UNIV2_UNIFIED");
        address factoryV4Address = vm.envAddress("FACTORY_UNIV4_UNIFIED");

        LivoLaunchpad launchpad = LivoLaunchpad(launchpadAddress);
        LivoFactoryUniV2Unified factoryV2 = LivoFactoryUniV2Unified(factoryV2Address);
        LivoFactoryUniV4Unified factoryV4 = LivoFactoryUniV4Unified(factoryV4Address);

        vm.startBroadcast();
        bytes32 salt = bytes32(uint256(0x123));

        ILivoFactory.FeeShare[] memory devFeeShare = new ILivoFactory.FeeShare[](1);
        devFeeShare[0] = ILivoFactory.FeeShare({account: LIVODEV, shares: 10_000, directFeesEnabled: false});
        ILivoFactory.SupplyShare[] memory noSupplyShares = new ILivoFactory.SupplyShare[](0);
        TaxConfigInit memory noTaxCfg = TaxConfigInit({buyTaxBps: 0, sellTaxBps: 0, taxDurationSeconds: 0});
        AntiSniperConfigs memory noSniperCfg = AntiSniperConfigs({
            maxBuyPerTxBps: 0, maxWalletBps: 0, protectionWindowSeconds: 0, whitelist: new address[](0)
        });

        address TOKEN1 =
            factoryV2.createToken("MEMEV2", "MAMIV2", salt, devFeeShare, noSupplyShares, false, noTaxCfg, noSniperCfg);
        address TOKEN2 = factoryV4.createToken(
            "projecTV4", "PROJECTV4", salt, devFeeShare, noSupplyShares, false, noTaxCfg, noSniperCfg
        );
        TaxConfigInit memory taxCfg =
            TaxConfigInit({buyTaxBps: 0, sellTaxBps: 500, taxDurationSeconds: uint32(14 days)});
        address TOKEN3 = factoryV4.createToken(
            "projecTaxTV4", "PROJECTAXV4", salt, devFeeShare, noSupplyShares, false, taxCfg, noSniperCfg
        );

        uint256 deadline = block.timestamp + 300 days;

        // TOKEN1
        launchpad.buyTokensWithExactEth{value: 0.00005 ether}(TOKEN1, 0, deadline);
        launchpad.sellExactTokens(TOKEN1, 0.000008 ether, 0, deadline);
        launchpad.buyTokensWithExactEth{value: 0.0000051 ether}(TOKEN1, 0, deadline);
        launchpad.sellExactTokens(TOKEN1, 0.0000018 ether, 0, deadline);

        // TOKEN2
        launchpad.buyTokensWithExactEth{value: 0.000021 ether}(TOKEN2, 0, deadline);
        launchpad.sellExactTokens(TOKEN2, 0.000011 ether, 0, deadline);
        launchpad.buyTokensWithExactEth{value: 0.000041 ether}(TOKEN2, 0, deadline);
        launchpad.buyTokensWithExactEth{value: 0.000031 ether}(TOKEN2, 0, deadline);
        launchpad.sellExactTokens(TOKEN2, 0.000025 ether, 0, deadline);

        // TOKEN 3
        launchpad.buyTokensWithExactEth{value: 0.000033 ether}(TOKEN3, 0, deadline);
        launchpad.sellExactTokens(TOKEN3, 0.000021 ether, 0, deadline);
        launchpad.sellExactTokens(TOKEN3, 0.000015 ether, 0, deadline);
        launchpad.sellExactTokens(TOKEN2, 0.0000444 ether, 0, deadline);
        launchpad.buyTokensWithExactEth{value: 0.000015 ether}(TOKEN3, 0, deadline);

        vm.stopBroadcast();
    }
}

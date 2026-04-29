// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LaunchpadBaseTests, LaunchpadBaseTestsWithUniv2Graduator} from "test/launchpad/base.t.sol";
import {ILivoFactory} from "src/interfaces/ILivoFactory.sol";
import {E2EHappyPath} from "test/e2e/suites/E2EHappyPath.t.sol";
import {E2EGraduationFlows} from "test/e2e/suites/E2EGraduationFlows.t.sol";
import {E2ESniperWindow} from "test/e2e/suites/E2ESniperWindow.t.sol";

contract E2E_FactoryUniV2SniperProtected is
    E2EHappyPath,
    E2EGraduationFlows,
    E2ESniperWindow,
    LaunchpadBaseTestsWithUniv2Graduator
{
    function setUp() public override(LaunchpadBaseTests, LaunchpadBaseTestsWithUniv2Graduator) {
        super.setUp();
    }

    function _factory() internal view override returns (address) {
        return address(factoryV2Sniper);
    }

    function _tokenImpl() internal view override returns (address) {
        return address(livoTokenSniper);
    }

    function _createTestToken(bytes32 salt) internal override returns (address token) {
        vm.prank(creator);
        (token,) = factoryV2Sniper.createToken("E2E", "E2E", salt, _fs(creator), _noSs(), _defaultE2EAntiSniperCfg());
    }

    function _createTestTokenWithSplit(bytes32 salt, ILivoFactory.FeeShare[] memory feeReceivers)
        internal
        override
        returns (address token, address splitter)
    {
        vm.prank(creator);
        (token, splitter) =
            factoryV2Sniper.createToken("E2E", "E2E", salt, feeReceivers, _noSs(), _defaultE2EAntiSniperCfg());
    }

    function _createTokenWithDeployerBuy(bytes32 salt, uint256 ethValue, ILivoFactory.SupplyShare[] memory supplyShares)
        internal
        override
        returns (address token)
    {
        vm.deal(creator, ethValue);
        vm.prank(creator);
        (token,) = factoryV2Sniper.createToken{value: ethValue}(
            "E2E", "E2E", salt, _fs(creator), supplyShares, _defaultE2EAntiSniperCfg()
        );
    }

    function _isV4Graduator() internal pure override returns (bool) {
        return false;
    }

    function _hasSniperProtection() internal pure override returns (bool) {
        return true;
    }

    function _hasTax() internal pure override returns (bool) {
        return false;
    }

    function _supportsRenounceOwnership() internal pure override returns (bool) {
        return false;
    }
}
